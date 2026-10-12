#!/bin/bash
#
# scripts/wireguard-lxc-init.sh
#
# Run on the oci-pve host:
#   ssh oci-pve 'WG_CLIENTS="phone laptop" bash -s' < scripts/wireguard-lxc-init.sh
#
# Creates an unprivileged LXC container running a plain WireGuard server
# (kernel module on the host, wg-quick inside the CT) as a personal VPN
# endpoint. Deliberately NOT managed by Terraform — same reasoning as
# scripts/tailscale-lxc-init.sh / minio-lxc-init.sh / vault-lxc-init.sh.
#
# NOT for corosync: guests only autostart on a quorate node, so a corosync
# link living inside a CT on this node is a boot-time deadlock. A
# site-to-site tunnel for the cluster belongs on the host itself.
#
# Traffic path (double NAT):
#   client -> OCI reserved public IP (1:1 NAT) -> host private IP
#          -> host DNAT udp/${WG_PORT} -> CT 10.10.10.20 (vmbr0, container_subnet)
#          -> wg0 -> CT MASQUERADE out eth0 -> host MASQUERADE out WAN (bootstrap.sh.tpl)
#
# Prerequisite outside this script: an ingress UDP ${WG_PORT} rule in the
# OCI security list (oci-proxmox-node/mod/oci-pve-node/network.tf).
# Without it, packets never reach the host.
#
# Clients: WG_CLIENTS="a b c". Each one gets a keypair + PSK + next free
# address under /etc/wireguard/clients/<name>/ inside the CT. Existing
# clients are left untouched, and wg0.conf is rebuilt from that directory
# on every run. To revoke a client: `pct exec 411 -- rm -r
# /etc/wireguard/clients/<name>` and re-run. Backing up the CT is the same
# as backing up /etc/wireguard (server key + all clients).
#
# Idempotent — safe to re-run.

set -euo pipefail

PVE_NODE="$(hostname -s)"

# Only oci-pve has a public IP (home nodes sit behind CGNAT). An unlisted
# node is a hard error.
case "${PVE_NODE}" in
    oci-pve)
        # VMIDs are cluster-wide in nexus-cluster: 410/420/430/440 are
        # already taken by the lxc-<node> tailscale CTs.
        CTID=411
        # Static, outside dnsmasq's DHCP range (.100-.200) on vmbr0.
        CT_IP="10.10.10.20/24"
        CT_GATEWAY="10.10.10.1"
        CT_NAMESERVERS="10.10.10.1 1.1.1.1"
        STORAGE="tank"
        TEMPLATE="debian-13-standard_13.6-1_arm64.tar.zst"
        ;;
    *)
        echo "wireguard-lxc-init: no config for node '${PVE_NODE}'." >&2
        echo "Only oci-pve has a public endpoint; add a 'case' entry if that changes." >&2
        exit 1
        ;;
esac

CT_HOSTNAME="wg-${PVE_NODE}"
CT_MEMORY=256
CT_CORES=1
CT_DISK_GB=4
CT_BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"

WG_PORT="${WG_PORT:-51820}"
WG_PREFIX="${WG_PREFIX:-10.66.66}"            # tunnel subnet ${WG_PREFIX}.0/24, server = .1
WG_CLIENTS="${WG_CLIENTS:-}"
WG_DNS="${WG_DNS:-1.1.1.1, 1.0.0.1}"
# ::/0 with no IPv6 on the server blackholes v6 on clients, so apps fall
# back to v4 through the tunnel instead of leaking around it.
WG_CLIENT_ALLOWED_IPS="${WG_CLIENT_ALLOWED_IPS:-0.0.0.0/0, ::/0}"
WG_ENDPOINT="${WG_ENDPOINT:-}"

# Egress from OCI leaves via the reserved IP (1:1 NAT), so this returns it.
# Cloudflare trace by IP literal (cert has an IP SAN): no dependency on the
# host resolver.
if [ -z "${WG_ENDPOINT}" ]; then
    WG_ENDPOINT="$(curl -4 -fsS --max-time 10 https://1.1.1.1/cdn-cgi/trace | awk -F= '/^ip=/{print $2}')" || true
    if [ -z "${WG_ENDPOINT}" ]; then
        echo "Could not detect public IP; set WG_ENDPOINT (terraform output -raw public_ip)." >&2
        exit 1
    fi
fi

# 0. CTID must be free cluster-wide, not just on this node
if ! pct status "${CTID}" &>/dev/null; then
    if pvesh get /cluster/resources --type vm --output-format json | grep -qE "\"vmid\":${CTID}[,}]"; then
        echo "CTID ${CTID} is already used on another nexus-cluster node." >&2
        exit 1
    fi
fi

# 1. Kernel module on the host. The unprivileged CT can then create a wg
#    interface in its own netns (CAP_NET_ADMIN there is enough).
modprobe wireguard
echo wireguard > /etc/modules-load.d/wireguard.conf

# 2. Template
if ! pveam list "${TEMPLATE_STORAGE}" | grep -q "${TEMPLATE}"; then
    pveam update
    pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE}"
fi

# 3. Container
if ! pct status "${CTID}" &>/dev/null; then
    pct create "${CTID}" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
        --hostname "${CT_HOSTNAME}" \
        --arch arm64 --ostype debian \
        --memory "${CT_MEMORY}" \
        --cores "${CT_CORES}" \
        --rootfs "${STORAGE}:${CT_DISK_GB}" \
        --net0 "name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},gw=${CT_GATEWAY}" \
        --nameserver "${CT_NAMESERVERS}" \
        --unprivileged 1 \
        --features "nesting=1" \
        --onboot 1
else
    if ! pct config "${CTID}" | awk '/^net0:/' | grep -q "ip=${CT_IP}"; then
        echo "net0 not pinned to ${CT_IP}, updating (CT will restart to apply)..."
        pct set "${CTID}" --net0 "name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},gw=${CT_GATEWAY}"
        pct reboot "${CTID}" 2>/dev/null || true
        sleep 5
    fi
fi

if [ "$(pct status "${CTID}" | awk '{print $2}')" != "running" ]; then
    pct start "${CTID}"
    sleep 5
fi

# 4. Host DNAT: public udp/${WG_PORT} -> CT. Kept as a separate systemd
#    unit rather than a post-up in /etc/network/interfaces, because that
#    file is owned by bootstrap.sh.tpl. -C before -A makes it idempotent.
WAN_IF="$(ip -4 route show default | awk '{print $5; exit}')"
DNAT_RULE="PREROUTING -i ${WAN_IF} -p udp --dport ${WG_PORT} -j DNAT --to-destination ${CT_IP%/*}:${WG_PORT}"

cat >/etc/systemd/system/wg-lxc-dnat.service <<EOF
[Unit]
Description=DNAT udp/${WG_PORT} on ${WAN_IF} -> WireGuard CT ${CTID} (${CT_IP%/*})
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'iptables -t nat -C ${DNAT_RULE} 2>/dev/null || iptables -t nat -A ${DNAT_RULE}'
ExecStop=/bin/sh -c 'iptables -t nat -D ${DNAT_RULE} 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wg-lxc-dnat.service >/dev/null 2>&1
systemctl restart wg-lxc-dnat.service

# 5. Inside the CT: wireguard-tools, server key, clients, wg0.conf
INNER="$(mktemp)"
trap 'rm -f "${INNER}"' EXIT

cat >"${INNER}" <<'INNER_EOF'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if ! command -v wg >/dev/null || ! command -v iptables >/dev/null || ! command -v qrencode >/dev/null; then
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends wireguard-tools iptables qrencode
fi

# /proc/sys/net is per-netns and writable in an unprivileged CT
printf 'net.ipv4.ip_forward = 1\n' >/etc/sysctl.d/99-wireguard.conf
sysctl -q -p /etc/sysctl.d/99-wireguard.conf

umask 077
D=/etc/wireguard
mkdir -p "${D}/clients"
[ -s "${D}/server.key" ] || wg genkey >"${D}/server.key"
wg pubkey <"${D}/server.key" >"${D}/server.pub"
SERVER_PUB="$(cat "${D}/server.pub")"

NEW_CLIENTS=()
for name in ${WG_CLIENTS}; do
    [[ "${name}" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "bad client name: ${name}" >&2; exit 1; }
    C="${D}/clients/${name}"
    [ -d "${C}" ] && continue

    octet=2
    while grep -qx "${octet}" "${D}"/clients/*/octet 2>/dev/null; do
        octet=$((octet + 1))
    done
    [ "${octet}" -le 254 ] || { echo "tunnel subnet ${WG_PREFIX}.0/24 is full" >&2; exit 1; }

    mkdir -p "${C}"
    echo "${octet}" >"${C}/octet"
    wg genkey >"${C}/private.key"
    wg pubkey <"${C}/private.key" >"${C}/public.key"
    wg genpsk >"${C}/psk"

    cat >"${C}/client.conf" <<EOF
[Interface]
PrivateKey = $(cat "${C}/private.key")
Address = ${WG_PREFIX}.${octet}/32
DNS = ${WG_DNS}

[Peer]
PublicKey = ${SERVER_PUB}
PresharedKey = $(cat "${C}/psk")
Endpoint = ${WG_ENDPOINT}:${WG_PORT}
AllowedIPs = ${WG_CLIENT_ALLOWED_IPS}
PersistentKeepalive = 25
EOF
    NEW_CLIENTS+=("${name}")
done

# wg0.conf is fully derived from server.key + clients/*: removing a client
# directory and re-running removes the peer.
{
    cat <<EOF
[Interface]
Address = ${WG_PREFIX}.1/24
ListenPort = ${WG_PORT}
PrivateKey = $(cat "${D}/server.key")
PostUp = iptables -t nat -A POSTROUTING -s ${WG_PREFIX}.0/24 -o eth0 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s ${WG_PREFIX}.0/24 -o eth0 -j MASQUERADE
EOF
    for C in "${D}"/clients/*/; do
        [ -f "${C}public.key" ] || continue
        cat <<EOF

# $(basename "${C}")
[Peer]
PublicKey = $(cat "${C}public.key")
PresharedKey = $(cat "${C}psk")
AllowedIPs = ${WG_PREFIX}.$(cat "${C}octet")/32
EOF
    done
} >"${D}/wg0.conf.new"
mv "${D}/wg0.conf.new" "${D}/wg0.conf"

systemctl enable wg-quick@wg0 >/dev/null 2>&1
if ip link show wg0 &>/dev/null; then
    # Hot reload of peers only. Changing Address/ListenPort/PostUp needs
    # `systemctl restart wg-quick@wg0`.
    wg syncconf wg0 <(wg-quick strip wg0)
else
    systemctl start wg-quick@wg0
fi

for name in "${NEW_CLIENTS[@]}"; do
    echo ""
    echo "=== new client: ${name} (${D}/clients/${name}/client.conf) ==="
    cat "${D}/clients/${name}/client.conf"
    qrencode -t ansiutf8 <"${D}/clients/${name}/client.conf"
done

echo ""
wg show wg0
INNER_EOF

pct push "${CTID}" "${INNER}" /root/wg-setup.sh --perms 0700
pct exec "${CTID}" -- env \
    WG_PORT="${WG_PORT}" \
    WG_PREFIX="${WG_PREFIX}" \
    WG_CLIENTS="${WG_CLIENTS}" \
    WG_DNS="${WG_DNS}" \
    WG_CLIENT_ALLOWED_IPS="${WG_CLIENT_ALLOWED_IPS}" \
    WG_ENDPOINT="${WG_ENDPOINT}" \
    bash /root/wg-setup.sh

echo ""
echo "WireGuard LXC ready: CT ${CTID} (${CT_HOSTNAME})"
echo "  Bridge IP: ${CT_IP%/*}   Tunnel: ${WG_PREFIX}.0/24   Endpoint: ${WG_ENDPOINT}:${WG_PORT}"
echo "  Host DNAT: wg-lxc-dnat.service (${WAN_IF} udp/${WG_PORT} -> ${CT_IP%/*})"
echo ""
echo "Not done here: OCI security list ingress udp/${WG_PORT} (network.tf)."
echo "Re-show an existing client config:"
echo "  pct exec ${CTID} -- cat /etc/wireguard/clients/<name>/client.conf"
echo "  pct exec ${CTID} -- qrencode -t ansiutf8 -r /etc/wireguard/clients/<name>/client.conf"
