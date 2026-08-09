#!/bin/bash
#
# Run on the Proxmox host (ssh root@<proxmox-ip> 'bash -s' < scripts/minio-lxc-init.sh).
# Creates an unprivileged LXC container and runs MinIO inside it as a systemd
# service (no Docker). Deliberately NOT managed by Terraform — this backs
# the terraform state itself, so it must survive independently of any
# `terraform apply`/`destroy` on the nodes it stores state for.
#
# Idempotent — safe to re-run.

set -e

CTID=200
CT_HOSTNAME="minio"
CT_MEMORY=512
CT_CORES=1
CT_DISK_GB=8
CT_BRIDGE="vmbr0"
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"
TEMPLATE="ubuntu-24.04-standard_24.04-2_amd64.tar.zst"

MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:?set MINIO_ROOT_PASSWORD env var before running}"
MINIO_VERSION_URL="https://dl.min.io/server/minio/release/linux-amd64/minio"

# 1. Template
if ! pveam list "${TEMPLATE_STORAGE}" | grep -q "${TEMPLATE}"; then
    pveam update
    pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE}"
fi

# 2. Container
if ! pct status "${CTID}" &>/dev/null; then
    pct create "${CTID}" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
        --hostname "${CT_HOSTNAME}" \
        --memory "${CT_MEMORY}" \
        --cores "${CT_CORES}" \
        --rootfs "${STORAGE}:${CT_DISK_GB}" \
        --net0 "name=eth0,bridge=${CT_BRIDGE},ip=dhcp" \
        --unprivileged 1 \
        --features "nesting=1" \
        --onboot 1
fi

if [ "$(pct status "${CTID}" | awk '{print $2}')" != "running" ]; then
    pct start "${CTID}"
    sleep 5
fi

# 3. MinIO install + systemd service (idempotent — checks inside container)
pct exec "${CTID}" -- bash -c "
set -e

if ! id minio-user &>/dev/null; then
    useradd -r minio-user -s /sbin/nologin
fi

if [ ! -f /usr/local/bin/minio ]; then
    apt-get update -qq
    apt-get install -y -qq wget
    wget -q '${MINIO_VERSION_URL}' -O /usr/local/bin/minio
    chmod +x /usr/local/bin/minio
fi

mkdir -p /var/lib/minio
chown minio-user:minio-user /var/lib/minio

cat > /etc/default/minio << EOF
MINIO_ROOT_USER=${MINIO_ROOT_USER}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
MINIO_VOLUMES=/var/lib/minio
MINIO_OPTS=\"--address :9000 --console-address :9001\"
EOF
chmod 600 /etc/default/minio

cat > /etc/systemd/system/minio.service << 'EOF'
[Unit]
Description=MinIO
After=network-online.target
Wants=network-online.target

[Service]
User=minio-user
Group=minio-user
EnvironmentFile=/etc/default/minio
ExecStart=/usr/local/bin/minio server \$MINIO_VOLUMES \$MINIO_OPTS
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now minio
"

CT_IP=$(pct exec "${CTID}" -- hostname -I | awk '{print $1}')

echo "MinIO LXC ready: CT ${CTID} (${CT_HOSTNAME})"
echo "  S3 endpoint:      http://${CT_IP}:9000"
echo "  Console:           http://${CT_IP}:9001"
echo "  Root user:          ${MINIO_ROOT_USER}"
echo "Update backend.tf 'endpoints.s3' to point at http://${CT_IP}:9000"
echo "then create the bucket via the console or 'mc' before running terraform init."
