#!/bin/bash
#
# scripts/vault-lxc-init.sh
#
# Run on the Proxmox host (ssh root@<proxmox-ip> 'bash -s' < scripts/vault-lxc-init.sh).
# Creates an unprivileged LXC container and runs Vault inside it as a systemd
# service (no Docker), raft (integrated) storage — no external Consul needed
# for a single-node deploy. Deliberately NOT managed by Terraform, same
# reasoning as scripts/minio-lxc-init.sh: the only non-declarative parts
# (user creation, binary install, setcap, systemd unit) would need
# null_resource + local-exec either way, so there's nothing to gain from
# wrapping the CT "hardware" in the provider and everything to lose by
# coupling secrets storage to a Terraform state lifecycle.
#
# TLS is intentionally disabled (tls_disable = true) — same class of
# trade-off as the plaintext terraform-token.json noted in the root
# README (acceptable for a local lab behind no public exposure, not
# something to carry into anything internet-facing). Put this behind
# Tailscale/LAN-only ACLs, not behind "the traffic is encrypted".
#
# mlock: Vault normally mlock()s its memory so secrets can't get swapped
# to disk in plaintext. Handled here via `setcap cap_ipc_lock=+ep` on the
# binary (works fine in an unprivileged LXC, no container-level privilege
# needed) rather than `disable_mlock = true` — keeps the protection live
# regardless of whether swap ever gets enabled on the host later.
#
# Unseal: NOT automated here on purpose. Raft storage survives a CT
# restart fine, but Vault comes back sealed after every process start
# (Shamir key shares, no external KMS available in this lab for
# auto-unseal) — that's a deliberate manual step every time, not a bug in
# this script. Root token / unseal keys are printed ONCE on first init
# and never again — copy them out before closing the terminal.
#
# Idempotent — safe to re-run.

set -e

CTID=300
CT_HOSTNAME="vault"
CT_MEMORY=512
CT_CORES=1
CT_DISK_GB=8
CT_BRIDGE="vmbr0"
# Pinned, not DHCP — same reasoning as CT 200/MinIO (see README
# Troubleshooting notes, DHCP-drift entry). Pick an address outside every
# other environment's static range (nodes .101-.103, poly-nodes
# .110-.112, immich .60, runner .50, minio .100).
CT_IP="192.168.100.200/24"
CT_GATEWAY="192.168.100.1"
# Pinned, not inherited from the host — bare-pve's own /etc/resolv.conf is
# Tailscale MagicDNS (100.100.100.100), which only resolves inside the
# host's netns (tailscaled intercepts it via host-only iptables rules).
# A freshly-created LXC copies that resolv.conf verbatim but has no such
# interception in its own netns, so 100.100.100.100 is a dead address
# inside the container -> apt-get et al hang/fail with DNS resolution
# errors even though routing/NAT is fine. Same issue hit CT 201 on first
# run; see README Troubleshooting notes.
CT_NAMESERVERS="192.168.100.1 8.8.8.8"
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"
TEMPLATE="ubuntu-24.04-standard_24.04-2_amd64.tar.zst"

VAULT_VERSION="1.19.0"
# Internal mirror on CT 200 (minio), bucket made anonymously-downloadable
# via 'mc anonymous set download local/tools'. Plain binary (not a .zip),
# uploaded manually — avoids depending on releases.hashicorp.com's uptime
# and, more importantly, on the CT having a working CA store for HTTPS
# (see ca-certificates note below — kept as a general LXC hygiene default
# even though this particular fetch is now plain HTTP against a LAN host).
MINIO_ENDPOINT="http://192.168.100.100:9000"
VAULT_BINARY_URL="${MINIO_ENDPOINT}/tools/vault_${VAULT_VERSION}_linux_amd64"

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
        --net0 "name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},gw=${CT_GATEWAY}" \
        --nameserver "${CT_NAMESERVERS}" \
        --unprivileged 1 \
        --features "nesting=1" \
        --onboot 1
else
    # idempotent guard: CT already exists — make sure net0 is still
    # pinned to CT_IP, not left on a stale config from before this
    # value ever changed (same pattern as minio-lxc-init.sh).
    CURRENT_NET0=$(pct config "${CTID}" | awk '/^net0:/{print}')
    if ! echo "${CURRENT_NET0}" | grep -q "ip=${CT_IP}"; then
        echo "net0 not pinned to ${CT_IP}, updating (CT will restart to apply)..."
        pct set "${CTID}" --net0 "name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},gw=${CT_GATEWAY}"
        pct reboot "${CTID}" 2>/dev/null || true
        sleep 5
    fi

    # idempotent guard: same story for nameserver — CT may have inherited
    # the host's Tailscale MagicDNS resolv.conf at creation time (as CT
    # 201 did), or the host may join/leave tailscale between runs.
    CURRENT_NS=$(pct config "${CTID}" | awk '/^nameserver:/{print}')
    if ! echo "${CURRENT_NS}" | grep -q "192.168.100.1"; then
        echo "nameserver not pinned to ${CT_NAMESERVERS}, updating (CT will restart to apply)..."
        pct set "${CTID}" --nameserver "${CT_NAMESERVERS}"
        pct reboot "${CTID}" 2>/dev/null || true
        sleep 5
    fi
fi

if [ "$(pct status "${CTID}" | awk '{print $2}')" != "running" ]; then
    pct start "${CTID}"
    sleep 5
fi

# 3. Vault install + systemd service (idempotent — checks inside container)
pct exec "${CTID}" -- bash -c "
set -e

if ! id vault &>/dev/null; then
    useradd -r vault -s /sbin/nologin -m -d /etc/vault.d
fi

if [ ! -f /usr/local/bin/vault ]; then
    apt-get update -qq
    # ca-certificates is NOT in the minimal Ubuntu LXC template — without it
    # wget's HTTPS cert verification against releases.hashicorp.com fails,
    # and under 'set -e' + 'wget -q' that failure is silent: the script just
    # stops here with no vault binary, no service, no error text in the log.
    apt-get install -y -qq wget libcap2-bin
    wget -q '${VAULT_BINARY_URL}' -O /usr/local/bin/vault
    chmod +x /usr/local/bin/vault
fi

# mlock via capability on the binary, not disable_mlock in config — see
# header note above. Idempotent by nature (re-running setcap is a no-op),
# so no guard needed, just re-apply on every pass in case the binary was
# just (re)installed above.
setcap cap_ipc_lock=+ep /usr/local/bin/vault

mkdir -p /opt/vault/data /etc/vault.d
chown -R vault:vault /opt/vault/data /etc/vault.d

if [ ! -f /etc/vault.d/vault.hcl ]; then
cat > /etc/vault.d/vault.hcl << 'EOF'
ui = true

storage \"raft\" {
  path    = \"/opt/vault/data\"
  node_id = \"vault-300\"
}

listener \"tcp\" {
  address     = \"0.0.0.0:8200\"
  tls_disable = true
}

# Single-node raft — this IS its own cluster/api address.
api_addr     = \"http://${CT_IP%/*}:8200\"
cluster_addr = \"http://${CT_IP%/*}:8201\"

disable_mlock = false
EOF
chown vault:vault /etc/vault.d/vault.hcl
chmod 640 /etc/vault.d/vault.hcl
fi

if [ ! -f /etc/systemd/system/vault.service ]; then
cat > /etc/systemd/system/vault.service << 'EOF'
[Unit]
Description=Vault
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
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl daemon-reload
systemctl enable --now vault
"

echo "Vault LXC ready: CT ${CTID} (${CT_HOSTNAME})"
echo "  API:  http://${CT_IP%/*}:8200"
echo "  UI:   http://${CT_IP%/*}:8200/ui"
echo ""
echo "NOT initialized/unsealed yet if this is the first run. From inside the CT:"
echo "  pct exec ${CTID} -- env VAULT_ADDR=http://127.0.0.1:8200 vault operator init"
echo "  (copy the 5 unseal keys + root token somewhere safe — shown ONCE)"
echo "  pct exec ${CTID} -- env VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal   # x3, different keys"
echo ""
echo "After every CT/host restart, Vault comes back sealed — repeat the"
echo "'operator unseal' step (x3) manually. Not automated, see script header."
