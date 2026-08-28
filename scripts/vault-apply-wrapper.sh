#!/bin/bash
#
# scripts/vault-apply-wrapper.sh
#
# Source this once (e.g. from ~/.bashrc) and every plain `terraform apply`/
# `plan`/etc. you type afterward auto-fetches proxmox_api_token, the SSH
# public keys, and MinIO state-backend creds from Vault (CT 300) the first
# time it's needed in a given shell session — no separate command to
# remember, no alias to type instead of `terraform`. Just:
#
#   echo 'source /path/to/scripts/vault-apply-wrapper.sh' >> ~/.bashrc
#
# then open a new terminal, cd into any of this repo's environments/*, and
# run terraform normally. Nothing in terraform.tfvars is needed for any of
# these environments anymore — proxmox_endpoint/template_vm_id are now
# derived from proxmox_node inside each environment's locals.tf, and the
# API token / SSH keys / MinIO creds all come from here.
#
# How it decides whether to touch Vault at all: the terraform() function
# below only fires the Vault fetch when the current directory's
# variables.tf declares proxmox_api_token — i.e. only inside one of this
# repo's environments/*. Any other terraform project on the same machine
# is untouched; `terraform` behaves exactly like the real binary there.
#
# Requires:
#   - VAULT_ADDR set (defaults below to the CT 300 address on the LAN)
#   - vault CLI logged in via a method with read access to the
#     operator-manual-apply policy (userpass, not the ci-runner AppRole —
#     that one's scoped to CI and short-lived on purpose):
#       vault login -method=userpass username=<you>
#     The resulting token caches to ~/.vault-token; this only needs
#     redoing once the token's TTL (4h/12h, see vault-userpass-init.sh)
#     expires. NOTE: a root token also passes the `vault token lookup`
#     check below, since it's valid for everything — but using it
#     defeats the point of the narrower operator-manual-apply policy
#     (root can read every path in Vault, not just what this repo needs).
#     Prefer a userpass login day to day; save the root token for actual
#     Vault administration (unseal, policy changes, etc).
#   - proxmox/ssh-keys (vm_public_key / ci_public_key fields) must exist
#     in Vault, and operator-manual-apply's policy must grant read on
#     proxmox/data/ssh-keys — see scripts/vault-userpass-init.sh.
#   - minecraft-node only: also needs proxmox/minecraft-playit-key in
#     Vault (not yet migrated as of writing — playit_secret_key still
#     comes from terraform.tfvars there until that KV path exists; the
#     function warns instead of failing silently).
#
# Does NOT fetch the CI SSH private key or the GitHub runner PAT — those
# are pipeline.yml-only concerns, irrelevant to a manual apply.
#
# Executing this file directly (not sourcing it) still works too, for
# one-off/scripted use — fetches secrets then execs terraform with
# whatever args you passed:
#   ./scripts/vault-apply-wrapper.sh apply -parallelism=1
#
# IMPORTANT: this file must NEVER run `set -u`/`set -e`/`set -o pipefail`
# at the top level. Those are shell OPTIONS, not script-local state — run
# unconditionally in a file that gets `source`d, they leak into and
# permanently alter your entire interactive shell (nounset in particular
# will then throw "unbound variable" on anything else in your shell/
# .bashrc/prompt — e.g. Starship's own $STARSHIP_SESSION_KEY — that was
# never written to be nounset-safe). Any strictness below is scoped with
# `local -` inside a function instead, which bash saves/restores
# automatically on return, so it never touches the caller's shell.

# Detect sourced vs executed. No `set` calls before this — see warning above.
if (return 0 2>/dev/null); then
    _tfv_sourced=1
else
    _tfv_sourced=0
fi

# _tfv_fetch_secrets: the actual Vault work, shared by both the sourced
# terraform() function and the executed (subprocess) path below.
# `local -` scopes every `set`/`shopt` change below to this function only
# — it's restored to whatever it was the instant the function returns,
# so this is safe to call from an interactive shell without side effects.
_tfv_fetch_secrets() {
    local -
    set -u
    set -o pipefail

    : "${VAULT_ADDR:=http://192.168.100.200:8200}"
    export VAULT_ADDR

    if ! command -v vault &>/dev/null; then
        echo "error: vault CLI not found in PATH" >&2
        return 1
    fi

    if ! vault token lookup &>/dev/null; then
        echo "error: no valid Vault token — run 'vault login -method=userpass username=<you>' first" >&2
        return 1
    fi

    echo "Fetching secrets from Vault (${VAULT_ADDR})..." >&2

    TF_VAR_proxmox_api_token="$(vault kv get -field=api_token proxmox/terraform-provider)" || return 1
    export TF_VAR_proxmox_api_token

    TF_VAR_vm_ssh_public_key="$(vault kv get -field=vm_public_key proxmox/ssh-keys)" || return 1
    TF_VAR_ci_ssh_public_key="$(vault kv get -field=ci_public_key proxmox/ssh-keys)" || return 1
    export TF_VAR_vm_ssh_public_key
    export TF_VAR_ci_ssh_public_key

    AWS_ACCESS_KEY_ID="$(vault kv get -field=access_key proxmox/minio-credentials)" || return 1
    AWS_SECRET_ACCESS_KEY="$(vault kv get -field=secret_key proxmox/minio-credentials)" || return 1
    export AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY

    # minecraft-node needs one more secret this function doesn't fetch yet —
    # warn loud instead of letting terraform prompt for it interactively.
    if [ -f "./variables.tf" ] && grep -q "playit_secret_key" ./variables.tf 2>/dev/null; then
        if [ -z "${TF_VAR_playit_secret_key:-}" ]; then
            echo "warning: this looks like environments/minecraft-node — playit_secret_key" >&2
            echo "         is not yet migrated to Vault. Set TF_VAR_playit_secret_key" >&2
            echo "         yourself or terraform will prompt for it." >&2
        fi
    fi

    return 0
}

if [ "${_tfv_sourced}" -eq 1 ]; then
    # Main use case: install a terraform() shell function and stop —
    # nothing is fetched yet, so opening a new terminal costs nothing
    # against Vault until you actually run terraform somewhere that needs it.
    terraform() {
        # Только для этого репозитория — распознаём по variables.tf,
        # требующему proxmox_api_token. Любой другой terraform-проект
        # на машине идёт мимо Vault как обычно.
        if [ -f "./variables.tf" ] && grep -q "proxmox_api_token" ./variables.tf 2>/dev/null; then
            if [ -z "${TF_VAR_proxmox_api_token:-}" ]; then
                _tfv_fetch_secrets || return $?
            fi
        fi
        command terraform "$@"
    }
else
    # Executed directly as its own process (not sourced) — strictness here
    # is fine, this subprocess's options die with it either way.
    set -euo pipefail
    if [ "$#" -eq 0 ]; then
        echo "usage: $(basename "$0") <terraform-subcommand> [args...]" >&2
        exit 1
    fi
    _tfv_fetch_secrets || exit $?
    exec terraform "$@"
fi
