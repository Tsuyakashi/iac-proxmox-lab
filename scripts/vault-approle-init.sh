#!/bin/bash
set -e
: "${VAULT_ADDR:?set VAULT_ADDR before running (e.g. http://192.168.100.200:8200)}"

vault auth enable approle 2>/dev/null || true

# Секреты разложены по сервису/категории, не всё под proxmox/*:
#   proxmox/*         — API token, SSH-ключи для VM/CI (пути не менялись)
#   minio/*           — креды S3-бэкенда (было proxmox/minio-credentials)
#   github-actions/*  — CI SSH private key, runner PAT
#                        (было proxmox/ci-ssh-key, proxmox/github-runner-pat)
vault policy write terraform-provisioner - <<EOF
path "proxmox/data/*" {
  capabilities = ["read"]
}
path "minio/data/*" {
  capabilities = ["read"]
}
path "github-actions/data/*" {
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
