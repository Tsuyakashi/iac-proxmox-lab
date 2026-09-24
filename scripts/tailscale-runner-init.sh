#!/bin/bash
#
# scripts/tailscale-runner-init.sh
#
# Puts the CI runner VM (environments/runner, ci-node 192.168.100.50) into the
# tailnet as tag:ci. Run ON ci-node as root. The auth key goes in over stdin,
# together with the script, so it never shows up in a command line / `ps`:
#
#   { printf 'export TS_AUTHKEY=%q\n' "$(vault kv get -field=auth-key tailscale/ci-node)"
#     cat scripts/tailscale-runner-init.sh; } | ssh ubuntu@192.168.100.50 'sudo bash -s'
#
# Re-run without a key to refresh the /etc/hosts pins only (already joined):
#
#   ssh ubuntu@192.168.100.50 'sudo bash -s' < scripts/tailscale-runner-init.sh
#
# tailscale/ci-node auth-key: Tailscale admin console -> Keys -> Generate auth key,
# NOT reusable, pre-approved, tags = tag:ci. tag:ci and its grants are defined in
# the tailscale-acl repo (tag:ci -> tag:web tcp:22, -> lxc-jump tcp:8200).
#
# Why a script and not environments/runner cloud-init: modules/proxmox-vm wires
# user_data_file_id to the snippet resource's id, so any cloud-init change
# re-creates ci-node — and with it every repo's registered runner. This script
# changes the running host in place. After a from-scratch `terraform apply` of
# environments/runner, run it together with the runners' register scripts.
#
# tag:ci is the identity of the HOST: every runner on ci-node (all repos) gets
# tag:ci's grants. The per-repo boundary is each repo's own deploy secrets in
# Vault, not the network.
#
# DNS: --accept-dns=false. ci-node is shared; switching every runner's resolver
# to MagicDNS (tailnet DNS overrides local DNS) for a couple of names is not
# worth the blast radius. The names jobs need are pinned in /etc/hosts from
# `tailscale ip` (resolved from the netmap, no MagicDNS involved), in a block
# this script owns and rewrites. A peer this node can't see yet (no grant, not
# tagged yet) is skipped with a warning — re-run once it is.
#
# Idempotent — safe to re-run.

set -euo pipefail

TS_HOSTNAME="${TS_HOSTNAME:-ci-node}"
TS_TAG="tag:ci"
TAILNET_DOMAIN="${TAILNET_DOMAIN:-tail65829d.ts.net}"
# Short tailnet names to pin: lxc-bare-pve = lxc-jump (Vault :8200 via tailscale
# serve), lombel-landing-dev = lombel-landing's deploy target.
PIN_HOSTS="${PIN_HOSTS:-lxc-bare-pve lombel-landing-dev}"
TS_KEY_FPR="2596A99EAAB33821893C0A79458CA832957F5868"   # Tailscale package signing key

log() { echo -e "\n=== $* ===" >&2; }

[ "$(id -u)" -eq 0 ] || { echo "error: run as root (sudo bash -s)" >&2; exit 1; }

# ---------------------------------------------------------------------------
log "1. tailscale package (pkgs.tailscale.com apt repo)"
# ---------------------------------------------------------------------------
if ! command -v tailscale >/dev/null; then
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
    keyring=/usr/share/keyrings/tailscale-archive-keyring.gpg
    tmpkey="$(mktemp)"
    trap 'rm -f "$tmpkey"' EXIT
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.noarmor.gpg" -o "$tmpkey"
    # Refuse a key we don't expect instead of trusting whatever the URL served.
    if ! gpg --show-keys --with-colons "$tmpkey" 2>/dev/null | grep -q "^fpr:::::::::${TS_KEY_FPR}:"; then
        echo "error: downloaded Tailscale key is not ${TS_KEY_FPR}" >&2
        exit 1
    fi
    install -m 0644 "$tmpkey" "$keyring"
    # Same file name as tailscale's install.sh.
    echo "deb [signed-by=${keyring}] https://pkgs.tailscale.com/stable/ubuntu ${codename} main" \
        > /etc/apt/sources.list.d/tailscale.list
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tailscale
else
    echo "  already installed: $(tailscale version | head -n1)"
fi
systemctl enable --now tailscaled

# ---------------------------------------------------------------------------
log "2. join the tailnet as ${TS_TAG}"
# ---------------------------------------------------------------------------
backend_state() {
    tailscale status --json 2>/dev/null \
        | sed -n 's/.*"BackendState": *"\([A-Za-z]*\)".*/\1/p' | head -n1
}
state=""
for _ in $(seq 1 30); do
    state="$(backend_state)"
    [ -n "$state" ] && break
    sleep 1
done

if [ "$state" = "NeedsLogin" ] || [ "$state" = "NoState" ]; then
    : "${TS_AUTHKEY:?not logged in yet — pass TS_AUTHKEY (Vault tailscale/ci-node auth-key), see header}"
    tailscale up --authkey="${TS_AUTHKEY}" --hostname="${TS_HOSTNAME}" \
        --advertise-tags="${TS_TAG}" --accept-dns=false
else
    echo "  already joined (BackendState=${state:-unknown}), key not needed"
fi

tags="$(tailscale status --json | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["Self"].get("Tags") or []))')"
case ",${tags}," in
    *",${TS_TAG},"*) echo "  tags: ${tags}" ;;
    *) echo "error: node is not ${TS_TAG} (tags: '${tags:-none}') — was the key generated with tag:ci?" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
log "3. /etc/hosts pins for tailnet names (accept-dns=false)"
# ---------------------------------------------------------------------------
begin="# BEGIN tailscale-runner-init (managed, rewritten on every run)"
end="# END tailscale-runner-init"
block="$begin"$'\n'
for h in ${PIN_HOSTS}; do
    if ip4="$(tailscale ip -4 "$h" 2>/dev/null)" && [ -n "$ip4" ]; then
        block+="${ip4} ${h}.${TAILNET_DOMAIN}"$'\n'
        echo "  ${h}.${TAILNET_DOMAIN} -> ${ip4}"
    else
        echo "  warning: ${h} not visible from this node yet (no grant / not tagged) — skipped, re-run later" >&2
    fi
done
block+="$end"

tmp="$(mktemp)"
# Drop the previous managed block, append the fresh one.
awk -v b="$begin" -v e="$end" '$0==b{skip=1} !skip{print} $0==e{skip=0}' /etc/hosts > "$tmp"
printf '%s\n' "$block" >> "$tmp"
cat "$tmp" > /etc/hosts   # keep the inode/permissions of /etc/hosts
rm -f "$tmp"

# ---------------------------------------------------------------------------
log "4. done"
# ---------------------------------------------------------------------------
echo "  tailnet IP: $(tailscale ip -4)"
echo "  check:      tailscale status; getent hosts lxc-bare-pve.${TAILNET_DOMAIN}"
