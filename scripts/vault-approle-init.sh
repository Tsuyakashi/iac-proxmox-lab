#!/bin/bash
set -e
: "${VAULT_ADDR:?set VAULT_ADDR before running (e.g. http://192.168.100.200:8200)}"

vault auth enable approle 2>/dev/null || true

vault policy write terraform-provisioner - <<EOF
path "proxmox/data/terraform-provider" {
  capabilities = ["read"]
}
path "proxmox/data/ci-ssh-key" {
  capabilities = ["read"]
}
path "proxmox/data/ssh-keys" {
  capabilities = ["read"]
}
path "proxmox/data/minio-credentials" {
  capabilities = ["read"]
}
path "proxmox/data/github-runner-pat" {
  capabilities = ["read"]
}
EOF

vault write auth/approle/role/ci-runner \
  token_policies="terraform-provisioner" \
  token_ttl=15m \
  token_max_ttl=1h \
  secret_id_ttl=0 \
  secret_id_num_uses=0

vault read auth/approle/role/ci-runner/role-id
vault write -f auth/approle/role/ci-runner/secret-id
