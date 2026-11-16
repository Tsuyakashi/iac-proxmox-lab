#!/bin/bash
#
# Tier-0 secrets: Vault in an unprivileged LXC, integrated (raft) storage.
#
#   ssh bare-pve 'bash -s' < scripts/vault-lxc-init.sh
#   ssh bare-pve 'VAULT_VERSION=2.1.0 bash -s' < scripts/vault-lxc-init.sh
#
# Not managed by Terraform: Terraform reads its secrets from here.
# Idempotent: re-running upgrades the binary on a version change and never
# touches vault.hcl or the data dir once they exist.
#
# Reached over the tailnet as svc:vault (https://vault.<tailnet>.ts.net),
# served by lxc-bare-pve (CT 430). TLS ends at Tailscale; the LAN listener is
# plain HTTP and must stay LAN-only.
#
# Binary: releases.hashicorp.com is unreachable from BY addresses, so the
# zip comes from the Yandex Cloud mirror of HashiCorp releases and is
# checked against the mirror's SHA256SUMS. Override with VAULT_BASE_URL.
#
# Unseal is manual on purpose (Shamir, no KMS in the lab): Vault comes back
# sealed after every restart of the CT or the node.

set -euo pipefail

CTID="${CTID:-300}"
CT_HOSTNAME="vault"
CT_MEMORY=1024
CT_CORES=1
CT_DISK_GB=8
CT_BRIDGE="vmbr0"
CT_IP="${CT_IP:-192.168.100.200/24}"
CT_GATEWAY="192.168.100.1"
# Never inherit the node's resolv.conf: it is MagicDNS, dead inside the CT.
CT_NAMESERVERS="192.168.100.1 1.1.1.1"
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"
TEMPLATE_PATTERN="ubuntu-26.04-standard_"

# lxc-bare-pve (CT 430): its `tailscale serve --service=svc:vault` is the
# only way in from the tailnet. XFF is trusted from it alone, so Vault sees
# the real tailnet client (AppRole/token *_bound_cidrs depend on that).
PROXY_IP="${PROXY_IP:-192.168.100.230}"
PUBLIC_URL="${PUBLIC_URL:-https://vault.tail65829d.ts.net}"

VAULT_VERSION="${VAULT_VERSION:-2.1.0}"
VAULT_BASE_URL="${VAULT_BASE_URL:-https://hashicorp-releases.yandexcloud.net/vault}"

export LC_ALL=C LANG=C

# 0. Fail fast if the mirror has no such version (from the node, like the CT).
curl -fsSI --max-time 20 "${VAULT_BASE_URL}/${VAULT_VERSION}/vault_${VAULT_VERSION}_SHA256SUMS" >/dev/null \
  || { echo "no vault ${VAULT_VERSION} at ${VAULT_BASE_URL} (from $(hostname))"; exit 1; }

# 1. Template
pveam update >/dev/null
TEMPLATE="$(pveam available --section system | awk '{print $2}' | grep "^${TEMPLATE_PATTERN}" | sort -V | tail -1)"
[ -n "${TEMPLATE}" ] || { echo "no ${TEMPLATE_PATTERN}* template in pveam index"; exit 1; }
pveam list "${TEMPLATE_STORAGE}" | grep -q "${TEMPLATE}" || pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE}"

# 2. Container. No swap: with raft, Vault runs with disable_mlock (HashiCorp's
# recommendation for integrated storage), so the CT must not swap instead.
if ! pct status "${CTID}" &>/dev/null; then
  pct create "${CTID}" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "${CT_HOSTNAME}" \
    --memory "${CT_MEMORY}" --swap 0 --cores "${CT_CORES}" \
    --rootfs "${STORAGE}:${CT_DISK_GB}" \
    --net0 "name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},gw=${CT_GATEWAY}" \
    --nameserver "${CT_NAMESERVERS}" \
    --unprivileged 1 --features nesting=1 \
    --onboot 1 --startup order=2 \
    --tags "tier0"
fi
[ "$(pct status "${CTID}" | awk '{print $2}')" = running ] || { pct start "${CTID}"; sleep 5; }

# 3. Vault inside the CT
pct exec "${CTID}" -- env \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  LC_ALL=C VAULT_VERSION="${VAULT_VERSION}" VAULT_BASE_URL="${VAULT_BASE_URL}" \
  CT_ADDR="${CT_IP%/*}" PROXY_IP="${PROXY_IP}" PUBLIC_URL="${PUBLIC_URL}" \
  bash -euo pipefail -c '
export DEBIAN_FRONTEND=noninteractive
command -v unzip >/dev/null || { apt-get update -qq; apt-get install -y -qq curl unzip ca-certificates; }

id vault &>/dev/null || useradd --system --home-dir /etc/vault.d --shell /usr/sbin/nologin vault
install -d -o vault -g vault -m 0750 /etc/vault.d /opt/vault /opt/vault/data

# Binary: install only on version change, verified against SHA256SUMS.
if [ "$(/usr/local/bin/vault version 2>/dev/null | awk "{print \$2}")" != "v${VAULT_VERSION}" ]; then
  tmp=$(mktemp -d); cd "$tmp"
  zip="vault_${VAULT_VERSION}_linux_amd64.zip"
  curl -fsSL --retry 3 -O "${VAULT_BASE_URL}/${VAULT_VERSION}/${zip}"
  curl -fsSL --retry 3 -O "${VAULT_BASE_URL}/${VAULT_VERSION}/vault_${VAULT_VERSION}_SHA256SUMS"
  grep " ${zip}\$" "vault_${VAULT_VERSION}_SHA256SUMS" | sha256sum -c -
  unzip -o -q "$zip" vault
  install -m 0755 vault /usr/local/bin/vault
  cd /; rm -rf "$tmp"
  [ -f /etc/vault.d/vault.hcl ] && systemctl restart vault 2>/dev/null || true
fi
/usr/local/bin/vault version

# Written once: a changed listener means a restart and a manual unseal.
if [ ! -f /etc/vault.d/vault.hcl ]; then
cat > /etc/vault.d/vault.hcl <<EOF
ui = true

storage "raft" {
  path    = "/opt/vault/data"
  node_id = "vault-300"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true

  # Real client IP from tailscale serve on lxc-bare-pve. hop_skips = 0:
  # serve sets X-Forwarded-For itself, so a client-sent XFF cannot spoof it.
  # XFF from anyone else is ignored (socket address counts), and LAN or
  # 127.0.0.1 clients without XFF keep working.
  x_forwarded_for_authorized_addrs      = "${PROXY_IP}/32"
  x_forwarded_for_hop_skips             = 0
  x_forwarded_for_reject_not_authorized = false
  x_forwarded_for_reject_not_present    = false
}

api_addr     = "${PUBLIC_URL}"
cluster_addr = "http://${CT_ADDR}:8201"

# Integrated storage memory-maps its DB; HashiCorp recommends no mlock here.
# The CT has no swap instead.
disable_mlock = true
EOF
chown vault:vault /etc/vault.d/vault.hcl; chmod 0640 /etc/vault.d/vault.hcl
fi

cat > /etc/systemd/system/vault.service <<EOF
[Unit]
Description=HashiCorp Vault
Documentation=https://developer.hashicorp.com/vault
Requires=network-online.target
After=network-online.target
ConditionFileNotEmpty=/etc/vault.d/vault.hcl

[Service]
User=vault
Group=vault
ExecStart=/usr/local/bin/vault server -config=/etc/vault.d/vault.hcl
ExecReload=/bin/kill --signal HUP \$MAINPID
KillMode=process
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
PrivateDevices=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now vault >/dev/null

for i in $(seq 30); do
  curl -s -o /dev/null http://127.0.0.1:8200/v1/sys/health && break; sleep 1
done
VAULT_ADDR=http://127.0.0.1:8200 /usr/local/bin/vault status || true
'

cat <<EOF

Vault CT ${CTID} (${CT_HOSTNAME}): http://${CT_IP%/*}:8200 (LAN), ${PUBLIC_URL} (svc:vault)

First run only — init (keys and root token are shown ONCE):
  ssh bare-pve "pct exec ${CTID} -- env VAULT_ADDR=http://127.0.0.1:8200 /usr/local/bin/vault operator init -key-shares=5 -key-threshold=3"

After every restart of the CT or the node — unseal with 3 different keys:
  ssh -t bare-pve "pct exec ${CTID} -- env VAULT_ADDR=http://127.0.0.1:8200 /usr/local/bin/vault operator unseal"   # x3
EOF
