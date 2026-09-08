#!/bin/bash
#
# scripts/tailscale-lxc-init.sh
#
# Run on the Proxmox host (ssh root@<proxmox-ip> 'bash -s' < scripts/tailscale-lxc-init.sh).
# Creates an unprivileged LXC container and runs Tailscale inside it as the
# distro's own systemd service. Deliberately NOT managed by Terraform, same
# reasoning as scripts/minio-lxc-init.sh / scripts/vault-lxc-init.sh: LXC
# has no cloud-init user-data path in Proxmox (the provider's container
# `initialization` only does hostname/DNS/IP/SSH-key), so the actual work —
# installing tailscale, `tailscale up` with an auth key — would need
# null_resource + remote-exec over SSH either way. A plain host-side script
# is simpler and has nothing to gain from a Terraform state lifecycle.
#
# Purpose of this container: a dedicated tailnet node used as
#   - SSH jump-host onto the Proxmox hosts (ProxyJump in ~/.ssh/config),
#     via Tailscale SSH (`tailscale up --ssh`)
#   - `tailscale serve` reverse-proxy for the Proxmox / Vault UIs, the
#     MinIO console and the MinIO S3 API (set up manually once, see the
#     footer — needs HTTPS certificates enabled for the tailnet, which
#     requires MagicDNS on). Access to all four ports is restricted to
#     group:lxc-admin + admins in the tailscale-acl repo.
#
# The CT and its tailnet node are named lxc-<pve-node> (e.g. lxc-bare-pve),
# derived from the host this runs on — so a second one on another node is
# lxc-pve-rog, no collision, and MagicDNS gives you `ssh lxc-bare-pve`.
#
# Deliberately NO `--advertise-routes` on 192.168.100.0/24: the Zenbook
# (QDevice arbiter) is physically on that LAN when home, so advertising the
# same /24 overlaps its direct L2 path and produces the "works away, flaky
# at home" asymmetry already documented for the QDevice. A jump-host
# sidesteps the overlap entirely — the second SSH hop leaves this CT over
# its own vmbr0 interface as an ordinary LAN client.
#
# /dev/net/tun is passed in with the native `pct set -dev0` device
# passthrough (Proxmox VE 8.1+), NOT the lxc.mount.entry / cgroup2 hack in
# /etc/pve/lxc/<ctid>.conf.
#
# Idempotent — safe to re-run.

set -e

# Runs on a Proxmox host — name the CT (and its tailnet node) after which
# host it sits on, so a second one on another node reads as lxc-pve-rog
# without a naming collision. hostname -s on a cluster node is the node
# name (bare-pve / pve-rog).
PVE_NODE="$(hostname -s)"

CTID=400
CT_HOSTNAME="lxc-${PVE_NODE}"
CT_MEMORY=512
CT_CORES=1
CT_DISK_GB=8
CT_BRIDGE="vmbr0"
# Pinned, not DHCP — same reasoning as CT 200/300 (see README
# Troubleshooting notes, DHCP-drift entry). Sits clear of every
# environment's static range (nodes .101-.103, poly-nodes .110-.112,
# immich .60, runner .50) and of minio(.100) / vault(.200).
CT_IP="192.168.100.230/24"
CT_GATEWAY="192.168.100.1"
# Pinned, not inherited from the host — bare-pve's own /etc/resolv.conf is
# Tailscale MagicDNS (100.100.100.100), which only resolves inside the
# host's netns. A freshly-created LXC copies that resolv.conf verbatim but
# has no such interception in its own netns, so apt-get et al hang/fail
# with DNS errors even though routing/NAT is fine. See README
# Troubleshooting notes.
CT_NAMESERVERS="192.168.100.1 8.8.8.8"
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"
TEMPLATE="ubuntu-24.04-standard_24.04-2_amd64.tar.zst"

# Reusable auth key from https://login.tailscale.com/admin/settings/keys.
# Not in Vault yet (same status as minecraft-node's playit_secret_key) —
# export it before running:  TS_AUTHKEY=tskey-auth-... ./scripts/tailscale-lxc-init.sh
TS_AUTHKEY="${TS_AUTHKEY:?set TS_AUTHKEY env var before running (tskey-auth-... from the Tailscale admin console)}"
# Optional: a path to an SSH public key file to drop into the CT's root
# authorized_keys. Tailscale SSH doesn't need it (auth is by tailnet
# identity), but it's handy as a `pct`-console-independent fallback.
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-}"

# 1. Template
if ! pveam list "${TEMPLATE_STORAGE}" | grep -q "${TEMPLATE}"; then
    pveam update
    pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE}"
fi

# 2. Container
if ! pct status "${CTID}" &>/dev/null; then
    CREATE_ARGS=(
        "${CTID}" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"
        --hostname "${CT_HOSTNAME}"
        --memory "${CT_MEMORY}"
        --cores "${CT_CORES}"
        --rootfs "${STORAGE}:${CT_DISK_GB}"
        --net0 "name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},gw=${CT_GATEWAY}"
        --nameserver "${CT_NAMESERVERS}"
        --unprivileged 1
        # keyctl=1: tailscaled fails to start in an unprivileged LXC
        # without it (needs its own session keyring).
        --features "nesting=1,keyctl=1"
        --onboot 1
    )
    if [ -n "${SSH_PUBKEY_FILE}" ]; then
        CREATE_ARGS+=(--ssh-public-keys "${SSH_PUBKEY_FILE}")
    fi
    pct create "${CREATE_ARGS[@]}"
else
    # idempotent guard: CT already exists — make sure net0 is still pinned
    # to CT_IP, not left on a stale config (same pattern as the other
    # *-lxc-init.sh scripts).
    CURRENT_NET0=$(pct config "${CTID}" | awk '/^net0:/{print}')
    if ! echo "${CURRENT_NET0}" | grep -q "ip=${CT_IP}"; then
        echo "net0 not pinned to ${CT_IP}, updating (CT will restart to apply)..."
        pct set "${CTID}" --net0 "name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},gw=${CT_GATEWAY}"
        pct reboot "${CTID}" 2>/dev/null || true
        sleep 5
    fi

    CURRENT_NS=$(pct config "${CTID}" | awk '/^nameserver:/{print}')
    if ! echo "${CURRENT_NS}" | grep -q "192.168.100.1"; then
        echo "nameserver not pinned to ${CT_NAMESERVERS}, updating (CT will restart to apply)..."
        pct set "${CTID}" --nameserver "${CT_NAMESERVERS}"
        pct reboot "${CTID}" 2>/dev/null || true
        sleep 5
    fi

    # idempotent guard: keyctl may be missing on a CT created before this
    # script grew the flag.
    if ! pct config "${CTID}" | grep -E '^features:' | grep -q 'keyctl=1'; then
        echo "keyctl not enabled, adding (CT will restart to apply)..."
        pct set "${CTID}" --features "nesting=1,keyctl=1"
        pct reboot "${CTID}" 2>/dev/null || true
        sleep 5
    fi
fi

# 3. /dev/net/tun passthrough — native `pct set -dev0` (PVE 8.1+), applied
#    at container start, so reboot a running CT to pick it up.
if ! pct config "${CTID}" | grep -qE '^dev[0-9]+:.*/dev/net/tun'; then
    echo "adding /dev/net/tun passthrough (dev0)..."
    pct set "${CTID}" -dev0 /dev/net/tun
    if [ "$(pct status "${CTID}" | awk '{print $2}')" == "running" ]; then
        pct reboot "${CTID}" 2>/dev/null || true
        sleep 5
    fi
fi

if [ "$(pct status "${CTID}" | awk '{print $2}')" != "running" ]; then
    pct start "${CTID}"
    sleep 5
fi

# 4. Tailscale install + `tailscale up` (idempotent — checks inside container)
pct exec "${CTID}" -- bash -c "
set -e

if ! command -v tailscale &>/dev/null; then
    apt-get update -qq
    # ca-certificates + curl are NOT in the minimal Ubuntu LXC template;
    # without them the install.sh fetch fails HTTPS verification, and
    # under 'set -e' that failure is easy to miss in the log.
    apt-get install -y -qq curl ca-certificates
    curl -fsSL https://tailscale.com/install.sh | sh
fi

systemctl enable --now tailscaled

# Only run 'tailscale up' if not already connected — the auth key may be
# single-use, and re-running would fail on a second pass.
if ! tailscale status &>/dev/null; then
    tailscale up \
        --authkey='${TS_AUTHKEY}' \
        --hostname='${CT_HOSTNAME}' \
        --ssh \
        --accept-dns=false
else
    # already connected (e.g. a re-run, or an earlier run under a different
    # name) — reconcile the hostname without touching auth or the key.
    tailscale set --hostname='${CT_HOSTNAME}' 2>/dev/null || true
fi
"

TS_IP=$(pct exec "${CTID}" -- tailscale ip -4 2>/dev/null || echo "<pending>")

echo "Tailscale LXC ready: CT ${CTID} (${CT_HOSTNAME})"
echo "  LAN IP:        ${CT_IP%/*}"
echo "  Tailscale IP:  ${TS_IP}"
echo ""
PVE_NODE_IP="$(ip -4 -o addr show "${CT_BRIDGE}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"

echo "SSH jump-host — add to ~/.ssh/config on the laptop"
echo "(HostName ${CT_HOSTNAME} resolves over MagicDNS; ${TS_IP} also works):"
echo "  Host ts-jump"
echo "      HostName ${CT_HOSTNAME}"
echo "      User root"
echo "  Host ${PVE_NODE}"
echo "      HostName ${PVE_NODE_IP:-<this-node-ip>}"
echo "      ProxyJump ts-jump"
echo "      User root"
echo ""
echo "Web UIs + APIs via 'tailscale serve' (run once inside the CT; needs HTTPS"
echo "certificates enabled for the tailnet — DNS settings in the admin"
echo "console, MagicDNS must be on). --bg persists across CT/tailscaled restarts:"
echo "  pct exec ${CTID} -- tailscale serve --bg --https=8006 https+insecure://192.168.100.30:8006  # proxmox"
echo "  pct exec ${CTID} -- tailscale serve --bg --https=9001 http://192.168.100.100:9001           # minio console"
echo "  pct exec ${CTID} -- tailscale serve --bg --https=9000 http://192.168.100.100:9000           # minio S3 API"
echo "  pct exec ${CTID} -- tailscale serve --bg --https=8200 http://192.168.100.200:8200           # vault ui/API"
echo ""
echo "The S3 API proxy (9000) is what lets tf-secrets / the terraform S3"
echo "backend reach MinIO from off-LAN. All four ports are restricted to"
echo "group:lxc-admin + admins in the tailscale-acl repo (host 'lxc-jump')."
