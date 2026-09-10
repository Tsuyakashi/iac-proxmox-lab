#!/bin/bash
#
# scripts/tailscale-lxc-init.sh
#
# Run on the Proxmox host (ssh root@<proxmox-ip> 'bash -s' < scripts/tailscale-lxc-init.sh).
# Creates an unprivileged LXC container and runs Tailscale inside it as the
# distro's own systemd service. Deliberately NOT managed by Terraform — same
# reasoning as scripts/minio-lxc-init.sh / scripts/vault-lxc-init.sh.
#
# Purpose differs by node:
#   - bare-pve / pve-rog: SSH jump-host onto hosts that are NOT themselves
#     tailnet members (home LAN topology), plus `tailscale serve` reverse
#     proxy for Proxmox/Vault/MinIO UIs.
#   - oci-pve: the HOST is already a full tailnet node (app-connector,
#     `tailscale up` in its own cloud-init). This CT is NOT a bypass for
#     closed ports — it's a REDUNDANT access path: an independent
#     tailscaled install, so if tailscaled dies/hangs on the host itself,
#     you still have a way in. You SSH into this CT over its own tailnet
#     identity, then hop to the host over the internal container_subnet
#     bridge (no internet, no security list involved — pure host<->CT L2),
#     entirely bypassing whatever's wrong with the host's own tailscaled.
#
# The CT and its tailnet node are named lxc-<pve-node> (e.g. lxc-bare-pve),
# derived from the host this runs on.
#
# /dev/net/tun is passed in with the native `pct set -dev0` device
# passthrough (Proxmox VE 8.1+), NOT the lxc.mount.entry / cgroup2 hack.
#
# Idempotent — safe to re-run.

set -e

PVE_NODE="$(hostname -s)"

# Per-node identity + per-node environment (storage backend, template arch,
# bridge topology) — bare-pve/pve-rog sit on flat home LAN with LVM-thin
# storage and amd64 templates; oci-pve is an isolated NAT bridge
# (container_subnet from oci-proxmox-node, see its README) with ZFS
# storage and arm64 templates (VM.Standard.A1.Flex has no EL2 -> no QEMU,
# but LXC/templates are unaffected — arm64 userspace runs natively).
# An unlisted node is a hard error: add a case entry before running there.
case "${PVE_NODE}" in
    bare-pve)
        CTID=430
        CT_IP="192.168.100.230/24"
        CT_GATEWAY="192.168.100.1"
        # Pinned, not inherited from the host — see README Troubleshooting
        # notes (host's own resolv.conf is MagicDNS, only valid in its netns).
        CT_NAMESERVERS="192.168.100.1 8.8.8.8"
        STORAGE="local-lvm"
        TEMPLATE="ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
        ;;
    pve-rog)
        CTID=420
        CT_IP="192.168.100.220/24"
        CT_GATEWAY="192.168.100.1"
        CT_NAMESERVERS="192.168.100.1 8.8.8.8"
        STORAGE="local-lvm"
        TEMPLATE="ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
        ;;
    oci-pve)
        CTID=410
        # 10.10.10.1 is the bridge address (BRIDGE_ADDR in
        # oci-proxmox-node's bootstrap.sh.tpl) — .10 sits clear of
        # dnsmasq's DHCP range (.100-.200) on that bridge.
        CT_IP="10.10.10.10/24"
        CT_GATEWAY="10.10.10.1"
        # dnsmasq on the bridge itself resolves (no-resolv + upstream
        # 1.1.1.1/1.0.0.1, see bootstrap.sh.tpl) — same address as gateway.
        CT_NAMESERVERS="10.10.10.1 1.1.1.1"
        # No LVM here — boot volume is ext4 'local', the real storage is
        # the ZFS pool on the second block volume, added via
        # `pvesm add zfspool tank` in bootstrap.sh.tpl.
        STORAGE="tank"
        # VM.Standard.A1.Flex is Arm — needs an arm64 template, not amd64.
        TEMPLATE="ubuntu-24.04-standard_24.04-2_arm64.tar.zst"
        ;;
    *)
        echo "tailscale-lxc-init: no config for node '${PVE_NODE}'." >&2
        echo "Add a 'case' entry above (CTID, CT_IP, gateway, nameservers, storage, template) and re-run." >&2
        exit 1
        ;;
esac

CT_HOSTNAME="lxc-${PVE_NODE}"
CT_MEMORY=512
CT_CORES=1
CT_DISK_GB=8
CT_BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"

TS_AUTHKEY="${TS_AUTHKEY:?set TS_AUTHKEY env var before running (tskey-auth-... from the Tailscale admin console)}"
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
        --features "nesting=1,keyctl=1"
        --onboot 1
    )
    if [ -n "${SSH_PUBKEY_FILE}" ]; then
        CREATE_ARGS+=(--ssh-public-keys "${SSH_PUBKEY_FILE}")
    fi
    pct create "${CREATE_ARGS[@]}"
else
    CURRENT_NET0=$(pct config "${CTID}" | awk '/^net0:/{print}')
    if ! echo "${CURRENT_NET0}" | grep -q "ip=${CT_IP}"; then
        echo "net0 not pinned to ${CT_IP}, updating (CT will restart to apply)..."
        pct set "${CTID}" --net0 "name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},gw=${CT_GATEWAY}"
        pct reboot "${CTID}" 2>/dev/null || true
        sleep 5
    fi

    CURRENT_NS=$(pct config "${CTID}" | awk '/^nameserver:/{print}')
    if ! echo "${CURRENT_NS}" | grep -q "${CT_NAMESERVERS%% *}"; then
        echo "nameserver not pinned to ${CT_NAMESERVERS}, updating (CT will restart to apply)..."
        pct set "${CTID}" --nameserver "${CT_NAMESERVERS}"
        pct reboot "${CTID}" 2>/dev/null || true
        sleep 5
    fi

    if ! pct config "${CTID}" | grep -E '^features:' | grep -q 'keyctl=1'; then
        echo "keyctl not enabled, adding (CT will restart to apply)..."
        pct set "${CTID}" --features "nesting=1,keyctl=1"
        pct reboot "${CTID}" 2>/dev/null || true
        sleep 5
    fi
fi

# 3. /dev/net/tun passthrough
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

# 4. Tailscale install + `tailscale up`
pct exec "${CTID}" -- bash -c "
set -e

if ! command -v tailscale &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates
    curl -fsSL https://tailscale.com/install.sh | sh
fi

systemctl enable --now tailscaled

if ! tailscale status &>/dev/null; then
    tailscale up \
        --authkey='${TS_AUTHKEY}' \
        --hostname='${CT_HOSTNAME}' \
        --ssh \
        --accept-dns=false
else
    tailscale set --hostname='${CT_HOSTNAME}' 2>/dev/null || true
fi
"

TS_IP=$(pct exec "${CTID}" -- tailscale ip -4 2>/dev/null || echo "<pending>")

echo "Tailscale LXC ready: CT ${CTID} (${CT_HOSTNAME})"
echo "  Bridge/LAN IP: ${CT_IP%/*}"
echo "  Tailscale IP:  ${TS_IP}"
echo ""

if [ "${PVE_NODE}" == "oci-pve" ]; then
    echo "This CT is a FALLBACK path for oci-pve, not a jump-host — the host"
    echo "already has its own tailscaled (app-connector). If the host's"
    echo "tailscaled ever dies/hangs, use this instead:"
    echo "  ssh root@${CT_HOSTNAME}          # (or ${TS_IP}) — this CT's OWN tailscaled"
    echo "  ssh root@${CT_GATEWAY}           # from inside the CT: hop to the host"
    echo "                                   # over the internal bridge — no internet,"
    echo "                                   # no security list, doesn't touch the"
    echo "                                   # host's tailscaled at all"
else
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
    echo "certificates enabled for the tailnet — MagicDNS must be on). --bg persists"
    echo "across CT/tailscaled restarts:"
    echo "  pct exec ${CTID} -- tailscale serve --bg --https=8006 https+insecure://192.168.100.30:8006  # proxmox"
    echo "  pct exec ${CTID} -- tailscale serve --bg --https=9001 http://192.168.100.100:9001           # minio console"
    echo "  pct exec ${CTID} -- tailscale serve --bg --https=9000 http://192.168.100.100:9000           # minio S3 API"
    echo "  pct exec ${CTID} -- tailscale serve --bg --https=8200 http://192.168.100.200:8200           # vault ui/API"
fi
