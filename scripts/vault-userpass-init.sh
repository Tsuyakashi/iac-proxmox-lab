#!/bin/bash
#
# scripts/vault-userpass-init.sh
#
# Companion to scripts/vault-approle-init.sh — that one sets up the
# ci-runner AppRole pipeline.yml authenticates with; this one sets up a
# userpass login for humans running scripts/vault-apply-wrapper.sh against
# the manually-applied environments (runner, poly-nodes, minecraft-node,
# immich-node).
#
# Deliberately a SEPARATE auth method and policy from ci-runner's AppRole,
# not a shared one:
#   - ci-runner's AppRole has secret_id_ttl=0 / secret_id_num_uses=0 (an
#     effectively permanent machine credential, sitting in GitHub Secrets)
#     — reusing it for a human on a laptop would mean one leaked laptop
#     and one leaked GitHub Secret both have to be rotated together.
#   - operator-manual-apply's policy is intentionally narrower: no
#     ci-ssh-key, no github-runner-pat — see the path list below. A
#     manual `terraform apply` from a laptop only ever needs the Proxmox
#     API token, the SSH public keys, and the MinIO (state backend)
#     credentials; the CI SSH *private* key and GitHub PAT are
#     pipeline.yml-only concerns (Ansible deploy / runner
#     self-registration), never touched by vault-apply-wrapper.sh.
#
# Run once against Vault (CT 300), same way as vault-approle-init.sh:
#   VAULT_ADDR=http://192.168.100.200:8200 ./scripts/vault-userpass-init.sh
#
# Then, per operator, either this script creates the account interactively
# (prompts for username, reads password with -s so it isn't echoed/logged),
# or run the vault write line at the bottom by hand for additional
# operators later without re-running the whole script.
#
# Token TTL is longer than ci-runner's (15m/1h) on purpose — a manual
# apply plus troubleshooting on immich-node can run well past
# an hour; re-authenticating mid-troubleshooting is just friction, not a
# meaningful security win for a LAN-only lab Vault.
#
# NOTE: proxmox/data/ssh-keys must actually contain the two public keys
# before scripts/vault-apply-wrapper.sh can read them:
#   vault kv put proxmox/ssh-keys \
#     vm_public_key="$(cat ~/.ssh/<your-key>.pub)" \
#     ci_public_key="$(ssh-keygen -y -f <ci-private-key-path>)"
# This script only grants the read policy — it doesn't seed the values.

set -e
: "${VAULT_ADDR:?set VAULT_ADDR before running (e.g. http://192.168.100.200:8200)}"

vault auth enable userpass 2>/dev/null || true

# ssh-keys added here — the two SSH public keys (not secret by nature, but
# centralizing them in Vault means no environment's terraform.tfvars needs
# to carry them anymore, same reasoning as the API token/MinIO creds. No
# ci-ssh-key (the private key) / github-runner-pat here — see header.
vault policy write operator-manual-apply - <<EOF
path "proxmox/data/terraform-provider" {
  capabilities = ["read"]
}
path "proxmox/data/minio-credentials" {
  capabilities = ["read"]
}
path "proxmox/data/ssh-keys" {
  capabilities = ["read"]
}
EOF

read -rp "Username for the new/updated Vault operator account: " VAULT_OPERATOR_USER
read -rsp "Password: " VAULT_OPERATOR_PASSWORD
echo

vault write "auth/userpass/users/${VAULT_OPERATOR_USER}" \
  password="${VAULT_OPERATOR_PASSWORD}" \
  token_policies="operator-manual-apply" \
  token_ttl=4h \
  token_max_ttl=12h

unset VAULT_OPERATOR_PASSWORD

echo ""
echo "Operator account '${VAULT_OPERATOR_USER}' ready with policy operator-manual-apply."
echo "Log in from a laptop with:"
echo "  vault login -method=userpass username=${VAULT_OPERATOR_USER}"
echo ""
echo "The resulting token caches to ~/.vault-token and scripts/vault-apply-wrapper.sh"
echo "reuses it silently until it expires (4h, renewable up to 12h)."
echo ""
echo "To add another operator later without re-running this whole script:"
echo "  vault write auth/userpass/users/<name> password='<pw>' \\"
echo "    token_policies=\"operator-manual-apply\" token_ttl=4h token_max_ttl=12h"
