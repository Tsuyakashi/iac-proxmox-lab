#!/bin/bash
#
# Tier-0 object storage: SILO (pgsty/silo, the maintained MinIO fork with the
# full admin console) in an unprivileged LXC, single node / single drive.
# Upstream MinIO CE is archived and its binaries are gone (dl.min.io -> 410).
#
#   ssh bare-pve 'bash -s' < scripts/silo-lxc-init.sh
#   SILO_TAG=RELEASE.2026-10-26T00-00-00Z ssh bare-pve 'bash -s' < ...   # pin
#
# Not managed by Terraform on purpose: it holds Terraform state itself.
# Idempotent: re-running keeps credentials and data, upgrades only on a new tag.
#
# Layout: one versioned bucket per repo, "<repo>-tfstate", key
# "<env>/terraform.tfstate". Buckets are created per project, not here:
#   mcli mb local/<repo>-tfstate && mcli version enable local/<repo>-tfstate
# Terraform uses the "terraform" user (policy tfstate-rw: *-tfstate only),
# never root. The S3 API and the console are reached over the tailnet as
# svc:s3 and svc:s3-console:9001; the LAN address is for the proxy only.

set -euo pipefail

CTID="${CTID:-200}"
CT_HOSTNAME="silo"
CT_MEMORY=2048
CT_SWAP=512
CT_CORES=2
CT_DISK_GB=32
CT_BRIDGE="vmbr0"
CT_IP="${CT_IP:-192.168.100.100/24}"
CT_GATEWAY="192.168.100.1"
# Never inherit the node's resolv.conf: it is MagicDNS, dead inside the CT.
CT_NAMESERVERS="192.168.100.1 1.1.1.1"
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"
TEMPLATE_PATTERN="ubuntu-26.04-standard_"

SILO_TAG="${SILO_TAG:-latest}"
MC_TAG="${MC_TAG:-latest}"
# Public console URL behind svc:s3-console (redirects after login).
# The S3-API public URL is deliberately NOT set: the console reaches the
# API through it from inside the CT, which is not on the tailnet
# ("network error" on login).
CONSOLE_URL="${CONSOLE_URL:-https://s3-console.tail65829d.ts.net:9001}"

export LC_ALL=C LANG=C

# 1. Template
pveam update >/dev/null
TEMPLATE="$(pveam available --section system | awk '{print $2}' | grep "^${TEMPLATE_PATTERN}" | sort -V | tail -1)"
[ -n "${TEMPLATE}" ] || { echo "no ${TEMPLATE_PATTERN}* template in pveam index"; exit 1; }
pveam list "${TEMPLATE_STORAGE}" | grep -q "${TEMPLATE}" || pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE}"

# 2. Container
if ! pct status "${CTID}" &>/dev/null; then
  pct create "${CTID}" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "${CT_HOSTNAME}" \
    --memory "${CT_MEMORY}" --swap "${CT_SWAP}" --cores "${CT_CORES}" \
    --rootfs "${STORAGE}:${CT_DISK_GB}" \
    --net0 "name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},gw=${CT_GATEWAY}" \
    --nameserver "${CT_NAMESERVERS}" \
    --unprivileged 1 --features nesting=1 \
    --onboot 1 --startup order=1 \
    --tags "tier0"
fi
[ "$(pct status "${CTID}" | awk '{print $2}')" = running ] || { pct start "${CTID}"; sleep 5; }

# 3. SILO + mcli inside the CT
pct exec "${CTID}" -- env \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  LC_ALL=C SILO_TAG="${SILO_TAG}" MC_TAG="${MC_TAG}" CONSOLE_URL="${CONSOLE_URL}" \
  bash -euo pipefail -c '
export DEBIAN_FRONTEND=noninteractive
command -v jq >/dev/null || { apt-get update -qq; apt-get install -y -qq curl jq openssl ca-certificates; }

# Resolve a release and its amd64 .deb through the GitHub API, install if new.
install_deb() {   # repo tag name-regex
  local repo=$1 tag=$2 re=$3 api rel url name
  api="https://api.github.com/repos/${repo}/releases"
  [ "$tag" = latest ] && rel="$api/latest" || rel="$api/tags/$tag"
  rel="$(curl -fsSL --retry 3 "$rel")"
  url="$(jq -r --arg re "$re" ".assets[] | select(.name|test(\$re)) | .browser_download_url" <<<"$rel" | head -1)"
  [ -n "$url" ] || { echo "no asset /$re/ in $repo $(jq -r .tag_name <<<"$rel")"; exit 1; }
  name="${url##*/}"
  if [ "$(cat "/etc/silo/installed.${repo##*/}" 2>/dev/null)" = "$name" ]; then return; fi
  curl -fsSL --retry 3 "$url" -o "/tmp/$name"
  # Verify against the published checksum when the release has one.
  if curl -fsSL "$url.sha256sum" -o "/tmp/$name.sha256sum" 2>/dev/null; then
    (cd /tmp && sha256sum -c "$name.sha256sum")
  fi
  apt-get install -y -qq "/tmp/$name"
  rm -f "/tmp/$name" "/tmp/$name.sha256sum"
  echo "$name" > "/etc/silo/installed.${repo##*/}"
  echo "installed $name"
}

install -d -m 0755 /etc/silo
install_deb pgsty/silo "$SILO_TAG" "^silo_.*_amd64[.]deb$"
install_deb pgsty/mc   "$MC_TAG"   "^mc(li)?_.*_amd64[.]deb$"
SILO="$(command -v silo || command -v minio)"
MCLI="$(command -v mcli || command -v mc)"
"$SILO" --version | head -1
"$MCLI" --version | head -1

id silo-user &>/dev/null || useradd --system --home-dir /var/lib/silo --shell /usr/sbin/nologin silo-user
install -d -o silo-user -g silo-user -m 0750 /var/lib/silo /var/lib/silo/data

# Credentials: generated once, never rotated by a re-run.
if [ ! -f /etc/silo/credentials ]; then
  umask 077
  cat > /etc/silo/credentials <<EOF
ROOT_USER=admin
ROOT_PASSWORD=$(openssl rand -base64 30 | tr -d "/+=" | cut -c1-32)
TF_ACCESS_KEY=terraform
TF_SECRET_KEY=$(openssl rand -base64 30 | tr -d "/+=" | cut -c1-40)
EOF
fi
. /etc/silo/credentials

umask 077
{
  echo "MINIO_ROOT_USER=$ROOT_USER"
  echo "MINIO_ROOT_PASSWORD=$ROOT_PASSWORD"
  echo "MINIO_VOLUMES=/var/lib/silo/data"
  echo "MINIO_OPTS=\"--address :9000 --console-address :9001\""
  echo "MINIO_BROWSER=on"
  if [ -n "$CONSOLE_URL" ]; then echo "MINIO_BROWSER_REDIRECT_URL=$CONSOLE_URL"; fi
} > /etc/default/silo
chown root:silo-user /etc/default/silo; chmod 0640 /etc/default/silo
umask 022

# Own unit in /etc: the packaged one may differ between releases.
cat > /etc/systemd/system/silo.service <<EOF
[Unit]
Description=SILO object storage (MinIO fork)
After=network-online.target
Wants=network-online.target

[Service]
User=silo-user
Group=silo-user
EnvironmentFile=/etc/default/silo
ExecStart=$SILO server \$MINIO_VOLUMES \$MINIO_OPTS
Restart=always
RestartSec=5
LimitNOFILE=65536
TimeoutStopSec=30
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/silo
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
systemctl disable --now minio.service 2>/dev/null || true
systemctl daemon-reload
systemctl enable silo >/dev/null
systemctl restart silo

for i in $(seq 30); do
  curl -fs -o /dev/null http://127.0.0.1:9000/minio/health/live && break; sleep 1
done
curl -fs -o /dev/null http://127.0.0.1:9000/minio/health/live || { journalctl -u silo -n 30 --no-pager; exit 1; }

# Bucket, versioning, scoped terraform user.
export MC_CONFIG_DIR=/root/.mcli
"$MCLI" alias set local http://127.0.0.1:9000 "$ROOT_USER" "$ROOT_PASSWORD" >/dev/null

cat > /etc/silo/tfstate-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": ["arn:aws:s3:::*-tfstate"] },
    { "Effect": "Allow", "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": ["arn:aws:s3:::*-tfstate/*"] }
  ]
}
EOF
"$MCLI" admin policy create local tfstate-rw /etc/silo/tfstate-policy.json >/dev/null
"$MCLI" admin user add local "$TF_ACCESS_KEY" "$TF_SECRET_KEY" >/dev/null
"$MCLI" admin policy attach local tfstate-rw --user "$TF_ACCESS_KEY" >/dev/null 2>&1 || true

"$MCLI" admin info local | head -8
"$MCLI" ls local
'

echo
echo "SILO ready: CT ${CTID} (${CT_HOSTNAME})"
echo "  S3:      http://${CT_IP%/*}:9000   region: any, backends keep \"auto\""
echo "  Console: http://${CT_IP%/*}:9001"
echo "Credentials (copy now; Vault: s3/root and s3/terraform):"
pct exec "${CTID}" -- cat /etc/silo/credentials
