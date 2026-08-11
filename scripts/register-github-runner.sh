#!/bin/bash
#
# scripts/register-github-runner.sh
#
# Installs/re-registers the GitHub Actions self-hosted runner agent on the
# ci-runner VM. Run manually after `terraform apply` in environments/runner/
# has produced a live VM — this is NOT part of cloud-init, because the
# registration token GitHub issues is one-time-use and expires in ~1 hour,
# so it can't be baked statically into a cloud-init template that might be
# applied at some unknown later time.
#
# Usage:
#   GH_RUNNER_PAT=<pat> ./scripts/register-github-runner.sh <runner-ip>
#
# Requires:
#   - GH_RUNNER_PAT: classic PAT with 'repo' scope, or fine-grained with
#     Administration:read/write on the target repo (same PAT used as
#     GH_RUNNER_PAT in pipeline.yml secrets).
#   - jq, curl, ssh on the machine running this script.
#   - SSH access to ubuntu@<runner-ip> (key already in ssh-agent).
#
# Safe to re-run: `--replace` reconfigures an already-registered runner
# instead of failing.

set -e

REPO="Tsuyakashi/iac-proxmox-lab"
RUNNER_IP="${1:?usage: register-github-runner.sh <runner-ip>}"
RUNNER_VERSION="2.319.1"   # bump as needed; check github.com/actions/runner/releases

: "${GH_RUNNER_PAT:?set GH_RUNNER_PAT env var before running}"

echo "Requesting registration token for ${REPO}..."
TOKEN=$(curl -sX POST \
  -H "Authorization: token ${GH_RUNNER_PAT}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${REPO}/actions/runners/registration-token" \
  | jq -r .token)

if [ -z "${TOKEN}" ] || [ "${TOKEN}" = "null" ]; then
  echo "error: failed to obtain registration token — check GH_RUNNER_PAT scope/permissions"
  exit 1
fi

echo "Configuring runner on ${RUNNER_IP}..."
ssh ubuntu@"${RUNNER_IP}" bash -s <<EOF
set -e
mkdir -p ~/actions-runner && cd ~/actions-runner

if [ ! -f config.sh ]; then
  curl -o actions-runner.tar.gz -L \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
  tar xzf actions-runner.tar.gz
fi

# Stop+uninstall existing service first if this is a re-register (safe no-op otherwise)
if [ -f svc.sh ]; then
  sudo ./svc.sh stop 2>/dev/null || true
  sudo ./svc.sh uninstall 2>/dev/null || true
fi

./config.sh --url "https://github.com/${REPO}" --token "${TOKEN}" \
  --unattended --name ci-runner --labels self-hosted --replace

sudo ./svc.sh install ubuntu
sudo ./svc.sh start
EOF

echo "Done. Check registration: https://github.com/${REPO}/settings/actions/runners"
