# IAC Proxmox Lab

Infrastructure-as-Code lab for provisioning VMs on Proxmox VE using Terraform.
Built as a bare-metal/self-hosted counterpart to cloud-focused IaC work — a
Proxmox + Terraform stack closer to how bare-metal infrastructure is
actually managed, used as an alternative provisioning path for
[`swarm-lab`](../swarm-lab)'s nodes. This is deliberately **not** a
replacement for `swarm-lab`'s own `Vagrantfile` — that stays, so `swarm-lab`
remains fully self-contained and can be spun up on its own hardware without
this repo (see [CI/CD](#cicd) for how the two connect via a pinned tag).

For the full reasoning behind the topology, the state-backend split, the
raw-disk/USB passthrough pattern, and the cluster firewall, see
**[docs/architecture.md](docs/architecture.md)**. For "things that actually
broke and how" (the big one), see
**[docs/troubleshooting.md](docs/troubleshooting.md)**. For how the repo got
here (nested → bare metal, the flat-layout → modules refactor), see
**[docs/history.md](docs/history.md)**.

## Architecture

```
┌────────────────────────────────┐       ┌───────────────────────────────────────┐
│ pve-rog (bare metal, G750JX)   │       │ bare-pve (bare metal, i5-4460/16GB)   │
│ 192.168.100.20 — 8 vCPU/24GB   │       │ 192.168.100.30 — 4 vCPU/16GB          │
│ peak-load capacity             │       │ must-have always-on services          │
│  │                             │       │  │                                    │
│  └── vmbr0 ─────────┐          │       │  └── vmbr0 ─────────┐                 │
│       ├ VM 9001 golden image   │       │       ├ VM 9000 golden image (own)    │
│       ├ prod/stage/dev nodes   │       │       ├ CT 200: minio (state backend) │
│       ├ poly-nodes             │       │       ├ CT 300: vault (secrets)       │
│       └ VM 101: immich-node    │       │       ├ CT 400: tailscale (jump-host) │
│         (see note below)       │       │       └ VM: ci-runner                 │
└──────────────┬─────────────────┘       └──────────────┬────────────────────────┘
               │                                        │
               └──────────────── corosync/knet ─────────┘
                            nexus-cluster (2 nodes)
                                     │
                         ┌───────────┴─────────────┐
                         │ Zenbook — QDevice only  │
                         │ 192.168.100.12          │
                         │ corosync-qnetd arbiter, │
                         │ no guests               │
                         └─────────────────────────┘
```

> **`immich-node` lives on `pve-rog`, not `bare-pve`.** The environment's
> own `terraform.tfvars`/README history assumed `bare-pve` (matching the
> "must-have always-on services" node), but the actual Datacenter tree has
> always shown VM 101 on `pve-rog`. Per the "what's deployed stays where it
> is" rule, `environments/immich-node/variables.tf`'s `proxmox_node` default
> (and the matching `proxmox_host_ip` used for the raw-disk `qm set` SSH
> call) were fixed to `pve-rog` to match reality, rather than migrating the
> VM to match the old docs. See
> [environments/immich-node/README.md](environments/immich-node/README.md).

Managed remotely from a laptop (Zenbook) over the LAN — Terraform, `qm`/`pveum`
commands, and the web UI are all driven from there.

**Two nodes, one cluster (`nexus-cluster`), plus a QDevice arbiter — both
nodes bare metal.** `bare-pve` (`.30`) holds storage and anything that must
not go down (MinIO, Vault, CI runner); `pve-rog` (`.20`) keeps the "extra
CPU/RAM for peak load" role and, in practice, hosts `immich-node`
(see the note above). The full story of how both nodes ended up bare
metal (one of them was nested Proxmox on a laptop for a while) is in
[docs/history.md](docs/history.md); the full reasoning behind the cluster
topology, the QDevice/Tailscale setup, the physical LAN quirks, and the
state-backend placement is in
[docs/architecture.md](docs/architecture.md#architecture-in-depth).

## Stack

- **Proxmox VE 9.2** — hypervisor, clustered (`nexus-cluster`, 2 nodes +
  QDevice), both nodes bare metal
- **Terraform** + [`bpg/proxmox`](https://github.com/bpg/terraform-provider-proxmox)
  provider (chosen over `Telmate/proxmox` — more actively maintained, fuller
  API coverage)
- **cloud-init** — VM bootstrapping (user creation, SSH keys, package install)
  for every environment
- **Ubuntu 24.04 (Noble) cloud image** — golden template, cloned per VM.
  Each cluster node keeps its own local copy (VM 9000 on `bare-pve`, VM
  9001 on `pve-rog`) — see [Node placement](#node-placement-endpoint--golden-image-resolution)
  below for why every environment resolves both from `proxmox_node` alone
  now, instead of a separate `template_vm_id` input.
- **MinIO** (LXC, systemd daemon, no Docker) — S3-compatible Terraform state
  backend for every root module, independent of the runner and the node
  VMs; also serves as an internal binary mirror for tools blocked by
  regional restrictions (see [docs/architecture.md](docs/architecture.md#state-backend-lives-off-both))
- **Vault** (LXC, systemd daemon, no Docker, raft/integrated storage) —
  secrets backend for both CI and manual `apply`s. `scripts/vault-lxc-init.sh`
  stands up the service; `scripts/vault-approle-init.sh` configures the
  `ci-runner` AppRole for `pipeline.yml`; `scripts/vault-userpass-init.sh`
  configures the `operator-manual-apply` policy/login for manual applies
  from a laptop via `scripts/vault-apply-wrapper.sh`. Beyond the Proxmox
  API token and MinIO credentials, Vault now also holds the SSH public
  key every environment injects via cloud-init
  (`proxmox/ssh-keys` → `public_key`) — see
  [Secrets](#secrets) below. `/root/terraform-token.json` on the Proxmox
  host has been deleted now that its contents live in Vault
  (`proxmox/terraform-provider`).
- **Tailscale** (LXC, distro systemd service) — dedicated tailnet node,
  stood up by `scripts/tailscale-lxc-init.sh` on whichever node it runs on
  (CTID + LAN IP keyed on the node name: `bare-pve` → CT 400, `pve-rog` →
  CT 420). Used as
  an SSH jump-host onto the Proxmox hosts (Tailscale SSH + `ProxyJump`) and
  a `tailscale serve` reverse-proxy for the Proxmox / MinIO / Vault web
  UIs. Deliberately **no** `--advertise-routes` on `192.168.100.0/24` — see
  [docs/architecture.md](docs/architecture.md#other-services) for why the
  overlap with the Zenbook's direct LAN path is avoided rather than
  configured around.
- **Ansible** — post-provision configuration, delegated to
  [`swarm-lab`](../swarm-lab)'s playbook via a pinned git tag (see
  [CI/CD](#cicd) below)
- **Docker Compose + systemd** — `immich-node`'s provisioning model,
  deliberately not swarm (see
  [environments/immich-node/README.md](environments/immich-node/README.md))

> **GPU-passthrough desktop VMs moved out of this repo.** A dedicated
> workstation (Windows/Linux guest with full GPU + USB-controller
> passthrough on `bare-pve`, `bpg/proxmox` + `proxmox_hardware_mapping_pci`)
> now lives in [`proxmox-hosted-workstation`](../proxmox-hosted-workstation).
> The old `environments/workstation` here (paravirtual `qxl2` + SPICE kiosk
> on `pve-rog`, GPU passthrough deliberately rejected for that Kepler card)
> was removed — the passthrough-specific troubleshooting notes are kept in
> [docs/troubleshooting.md](docs/troubleshooting.md) as reference.

## Node placement: endpoint + golden-image resolution

Every root module used to take `proxmox_endpoint` (and, where relevant,
`template_vm_id`) as separate input variables — which meant a manual
`terraform.tfvars` could silently point the provider at one node while
cloning from the other node's golden image (the "unable to find
configuration file for VM 9000 on node 'pve-rog'" class of bug in
[docs/troubleshooting.md](docs/troubleshooting.md)). Both are now derived
from `proxmox_node` alone, via a `locals.tf` present in every environment:

```hcl
locals {
  proxmox_nodes = {
    "bare-pve" = { endpoint = "https://192.168.100.30:8006/", template_vm_id = 9000 }
    "pve-rog"  = { endpoint = "https://192.168.100.20:8006/", template_vm_id = 9001 }
  }

  proxmox_endpoint = local.proxmox_nodes[var.proxmox_node].endpoint
  template_vm_id   = local.proxmox_nodes[var.proxmox_node].template_vm_id
}
```

`proxmox_node` is the only thing that ever needs setting (and every
environment already defaults it to wherever that environment's VM(s)
actually live). For multi-VM environments (`nodes`, `poly-nodes`,
`minecraft-node`), each `var.nodes` entry can still override
`proxmox_node` per-VM — `template_node`/`template_vm_id` always resolve
from that same per-entry value, so a VM's clone source can never drift
from the node it's actually placed on.

## Secrets

Nothing environment-specific needs to be typed into `terraform.tfvars`
anymore — every one of the six environments' `.tfvars.example` files is
now just a comment block. `scripts/vault-apply-wrapper.sh`, sourced once
from `~/.bashrc`, wraps the `terraform` command: the first time a plain
`terraform plan`/`apply` runs inside one of this repo's environments, it
fetches from Vault (CT 300) and exports as `TF_VAR_*`:

- `proxmox_api_token` (`proxmox/terraform-provider`)
- `ssh_public_key` (`proxmox/ssh-keys` → `public_key`)
- `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` for the MinIO state backend
  (`minio/credentials`)

Only `minecraft-node`'s `playit_secret_key` isn't migrated yet — it still
needs a manual `terraform.tfvars` (or `TF_VAR_playit_secret_key`) until
that path exists in Vault. See `scripts/vault-apply-wrapper.sh`'s header
and [docs/troubleshooting.md](docs/troubleshooting.md) for the one gotcha
this wrapper has (a cached `TF_VAR_proxmox_api_token` from an old shell
session can silently skip the SSH-key fetch — open a fresh terminal after
pulling wrapper updates).

`pipeline.yml` (CI) is unaffected by any of this — it authenticates as the
separate `ci-runner` AppRole and never touches the operator's userpass
login.

### Vault layout and downstream repos

This repo is the base Proxmox install, so it owns the shared Vault paths
every other repo in the lab reuses rather than duplicates:

| Path | Fields | Used by |
| --- | --- | --- |
| `proxmox/terraform-provider` | `api_token` | anything with the Proxmox provider |
| `proxmox/ssh-keys` | `public_key` (single, unified) | anything injecting a key via cloud-init |
| `minio/credentials` | `access_key`, `secret_key` | anything with the S3 state backend |
| `github-actions/*` | CI SSH key, runner PAT | `pipeline.yml` (`ci-runner` AppRole) |

Every other service repo gets its **own** KV mount `<repo>/` with
per-category paths and its own init script (`vault secrets enable
-path=<repo> kv-v2`, a policy on the `<repo>/data/*` glob, attach to the
operator / an AppRole). It reuses the shared paths above via the
`proxmox/data/*` + `minio/data/*` globs already in `operator-manual-apply`
— no edit to this repo's policy per downstream repo. Current downstream
mounts: `oci/` (`oci-proxmox-node`), `k8s-lab/` (`k8s-lab`),
`relief-landing/` (`relief-landing`), `tailscale/` (`tailscale-acl`),
`valheim/` (`valheim-lxc`).

## Repo layout

Standard `modules/` + `environments/` split. `modules/proxmox-vm` is the one
reusable building block — a single cloned VM with a cloud-init snippet — and
every root module calls it.

```
modules/
└── proxmox-vm/                       # reusable module — no backend, no provider block
    ├── main.tf                       #   VM + cloud-init file resource
    ├── variables.tf                  #   name, sizing, cpu_type, ip_config (static|dhcp),
    │                                 #   ssh keys, extra_packages/extra_runcmd/write_files/
    │                                 #   docker_group
    ├── versions.tf                   #   required_version + required_providers
    ├── outputs.tf                    #   vm_id, ipv4_addresses
    ├── README.md
    └── templates/user-data.yml.tpl   #   cloud-init template

environments/
├── nodes/                            # ROOT MODULE — prod/stage/dev nodes (in CI)
├── runner/                           # ROOT MODULE — CI runner, own state/lifecycle
├── poly-nodes/                       # ROOT MODULE — infra for poly-ci, manual apply
├── minecraft-node/                   # ROOT MODULE — isolated Minecraft node, manual apply
└── immich-node/                      # ROOT MODULE — Immich (docker compose), manual apply
    └── README.md                     #   cpu_type / recovery-ro details specific to this env

.github/workflows/pipeline.yml        # provision (terraform, environments/nodes) + deploy (ansible)
scripts/
├── install-proxmox-with-libvirt.sh   # HISTORICAL — see docs/history.md
├── proxmox-init.sh                   # Proxmox-side (either node): terraform user/role/token,
│                                     #   golden image, thin-pool autoextend threshold
├── minio-lxc-init.sh                 # Proxmox-side (bare-pve): MinIO LXC (state backend)
├── vault-lxc-init.sh                 # Proxmox-side (bare-pve): Vault LXC (CT 300), manual unseal
├── tailscale-lxc-init.sh             # Proxmox-side: Tailscale LXC (CT 400 bare-pve / 420 pve-rog), SSH jump-host + serve
├── vault-approle-init.sh             # Vault: ci-runner AppRole (CI-only, pipeline.yml)
├── vault-userpass-init.sh            # Vault: operator-manual-apply policy/login (laptop)
├── vault-apply-wrapper.sh            # Sourced shell wrapper: auto-fetches secrets for manual apply
├── shared-storage-creation.sh        # Proxmox-side (bare-pve): NFS export prep
├── register-github-runner.sh         # Registers the GitHub Actions runner agent on ci-runner
└── tailscale-runner-init.sh          # On ci-node: joins the tailnet as tag:ci + /etc/hosts pins (step 8a)
```

Full detail on every one of the six manually-applied environments, the
module's optional inputs, and everything that changed vs. the original flat
layout (and why) lives in [docs/architecture.md](docs/architecture.md) and
[docs/history.md](docs/history.md) — kept out of this file so the root
README stays a map, not the whole territory.

## Quickstart

### 1. Stand up a Proxmox node

Both cluster nodes are bare metal — install Proxmox VE 9.2 directly on the
target hardware, disable the enterprise repos in favor of
`pve-no-subscription` (see
[docs/troubleshooting.md](docs/troubleshooting.md#apt-enterprise-401)
for the exact `deb822`-format fix on 9.x).

### 2. Initialize Proxmox for Terraform (on either node)

```bash
ssh root@<proxmox-ip> 'bash -s' < scripts/proxmox-init.sh
```

Creates the `terraform@pve` user, a scoped `TerraformProv` role (full
privilege list and reasoning in
[docs/architecture.md#terraformprov-role](docs/architecture.md#terraformprov-role)),
an API token, and the `ubuntu-cloud-template` golden image (VM 9000 on
`bare-pve`, VM 9001 on `pve-rog` — run this once per node). Also pins
`/etc/resolv.conf`, enables the `snippets` content type on the `local`
datastore, and sets `activation { thin_pool_autoextend_threshold = 80 }` in
`/etc/lvm/lvm.conf`. Idempotent.

**SSH key auth is required, not just API access** — the `bpg/proxmox`
provider uploads cloud-init snippets over SSH:

```bash
ssh-copy-id -i ~/.ssh/<your-key>.pub root@<proxmox-ip>
ssh-add ~/.ssh/<your-key>
```

### 3. Stand up the state backend (on `bare-pve`, before the first `terraform init`)

```bash
MINIO_ROOT_PASSWORD='<pick-a-password>' ssh root@<proxmox-ip> 'bash -s' < scripts/minio-lxc-init.sh
```

Creates CT 200 (MinIO, statically addressed — see
[docs/architecture.md#state-backend-lives-off-both](docs/architecture.md#state-backend-lives-off-both)
for why it's an LXC, not a Terraform resource). Then, via the printed
console URL, create a bucket named `iac-proxmox-lab-tfstate` and confirm
`endpoints.s3` in every environment's `backend.tf` matches the static IP.

**Optional, one-time:** create a `tools/` prefix in the same bucket for the
runner's `terraform`/`mc` binaries (needed because HashiCorp's and MinIO's
own distribution paths are unreachable from this network — see
[docs/troubleshooting.md](docs/troubleshooting.md#hashicorp-cli-blocked)):

```bash
mc alias set local http://<minio-ip>:9000 <minio-user> <minio-password>
mc mb local/tools --ignore-existing
mc anonymous set download local/tools
```

### 4. Stand up Vault (on `bare-pve`) and seed the ssh-key path

```bash
ssh root@<proxmox-ip> 'bash -s' < scripts/vault-lxc-init.sh
```

Creates CT 300 (Vault, statically addressed, raft/integrated storage). See
`scripts/vault-lxc-init.sh`'s header and
[docs/troubleshooting.md](docs/troubleshooting.md#vault-mlock-enomem-in-unprivileged-lxc)
for the `mlock`/unseal mechanics.

After the first run, initialize and unseal by hand (deliberately manual —
no external KMS available in this lab for auto-unseal):

```bash
pct exec 300 -- env VAULT_ADDR=http://127.0.0.1:8200 vault operator init
# copy out all 5 unseal keys + the root token — shown ONCE
pct exec 300 -- env VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal   # x3, different keys
```

Vault comes back **sealed** after every CT/host restart — repeat the
`operator unseal` step manually each time.

#### Vault: X-Forwarded-For listener (real client IPs)

Tailnet clients reach Vault through `tailscale serve` on CT 400
(`lxc-bare-pve`, `192.168.100.230`), so on the socket every request comes
from the proxy. The listener in `/etc/vault.d/vault.hcl` trusts
`X-Forwarded-For` from that one address (`x_forwarded_for_authorized_addrs =
192.168.100.230/32`, `hop_skips = 0`, `reject_not_authorized = false`,
`reject_not_present = false`; the why is next to it in
`scripts/vault-lxc-init.sh`). Vault then sees — and the audit log records — the
real tailnet address. `lombel-landing` depends on it: its app AppRole binds
secret_ids and tokens to the landing VM's tailnet IP, its CI JWT role to
`ci-node`'s. **A CT 300 without these lines = the landing VM's agents and
that CI can't log in.**

`vault-lxc-init.sh` writes `vault.hcl` only if it doesn't exist, so a re-run
never touches a live CT. On the current CT 300 the lines were added by hand
(2026-09-25) and match the script; a re-created CT gets them from the script.

Check that a CT matches (read-only):

```bash
pct exec 300 -- grep -E 'x_forwarded_for_' /etc/vault.d/vault.hcl
# x_forwarded_for_authorized_addrs      = "192.168.100.230/32"
# x_forwarded_for_hop_skips             = 0
# x_forwarded_for_reject_not_authorized = false
# x_forwarded_for_reject_not_present    = false
```

Bring an existing CT in line if they are missing (a listener change needs a
Vault restart, i.e. **unseal x3** afterwards):

```bash
pct exec 300 -- cp -a /etc/vault.d/vault.hcl /etc/vault.d/vault.hcl.bak
pct exec 300 -- sed -i '/^  tls_disable = true$/a\
  x_forwarded_for_authorized_addrs      = "192.168.100.230/32"\
  x_forwarded_for_hop_skips             = 0\
  x_forwarded_for_reject_not_authorized = false\
  x_forwarded_for_reject_not_present    = false' /etc/vault.d/vault.hcl
pct exec 300 -- grep -c 'x_forwarded_for_' /etc/vault.d/vault.hcl      # 4
pct exec 300 -- systemctl restart vault
pct exec 300 -- env VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal   # x3
```

Verify:

```bash
# 1. the audit log shows tailnet addresses (ci-node 100.70.240.34, landing VM
#    100.117.51.111, your laptop), not 192.168.100.230, for requests after the change
pct exec 300 -- tail -n 2000 /var/log/vault/audit.log | grep -o '"remote_address":"[^"]*"' | sort | uniq -c
# 2. a client can't spoof it: from the laptop, through the proxy, with a forged header —
#    the audit entry still has the laptop's tailnet IP, not 203.0.113.9
curl -s -o /dev/null -H "X-Vault-Token: $(vault print token)" -H 'X-Forwarded-For: 203.0.113.9' \
  https://lxc-bare-pve.tail65829d.ts.net:8200/v1/auth/token/lookup-self
pct exec 300 -- tail -n 20 /var/log/vault/audit.log | grep -o '"remote_address":"[^"]*"' | tail -n 1
# 3. lombel-landing: agents on the landing VM and its CI log in as before —
#    lombel-landing tf/README.md, «Vault без ротации: раскатка», checks after phase 1
```

Rollback: restore `vault.hcl.bak`, restart, unseal x3. Note that it breaks the
CIDR-bound logins above until those roles drop their CIDRs.

**Not yet: closing 8200 to the LAN.** The listener is plain HTTP on
`0.0.0.0:8200`. A Proxmox firewall on CT 300 allowing 8200 only from
`192.168.100.230` (and 8201 from nobody) is the next step, but not before
everything that still talks to `http://192.168.100.200:8200` directly moves
to `https://lxc-bare-pve.tail65829d.ts.net:8200`:
`relief-landing`'s deploy job (self-hosted on `ci-node`, hardcoded in its
`pipeline.yml`) and the `VAULT_ADDR` defaults of the apply wrappers /
init scripts in this repo, `tailscale-acl`, `relief-landing`,
`proxmox-hosted-workstation`, `tools-sandbox`, `k8s-lab`, `oci-proxmox-node`,
`valheim-lxc`'s README. The audit log (since 2026-09-25) shows no direct LAN
client, but `relief-landing` last deployed before it existed.

Then wire up both auth paths and seed the SSH key every environment
injects via cloud-init:

```bash
export VAULT_ADDR=http://192.168.100.200:8200

./scripts/vault-approle-init.sh        # ci-runner AppRole, used by pipeline.yml
./scripts/vault-userpass-init.sh       # operator-manual-apply policy + your login

vault kv put proxmox/ssh-keys \
  public_key="$(cat ~/.ssh/<your-key>.pub)"

vault kv get proxmox/ssh-keys          # confirm the field landed
```

Then, once per shell session (or via `~/.bashrc`):

```bash
vault login -method=userpass username=<you>
source scripts/vault-apply-wrapper.sh
```

### 5. (Optional) Cluster the nodes and add a QDevice arbiter

Only relevant once more than one Proxmox node exists.

```bash
pvecm create nexus-cluster                                  # on the more stable node
pvecm add <first-node-ip> --link0 <this-node-ip>             # on the second node
```

**`--link0` is not optional in practice** — see
[docs/troubleshooting.md](docs/troubleshooting.md#pvecm-add-link0-split)
for the split-brain this causes otherwise.

Then, for quorum that survives either node going down:

```bash
sudo apt install corosync-qnetd            # on the arbiter machine
apt install -y corosync-qdevice            # on both pve-rog and bare-pve
pvecm qdevice setup <arbiter-ip>
```

See [docs/architecture.md](docs/architecture.md#architecture-in-depth) for
the SSH/`PermitRootLogin` dance this needs and the Tailscale fallback when
the arbiter isn't on the LAN.

### 6. (Optional) Register cluster-wide shared storage (`bare-pve`)

```bash
ssh root@192.168.100.30 'bash -s' < scripts/shared-storage-creation.sh
pvesm add nfs shared-storage \
  --server 192.168.100.30 \
  --export /srv/shared-storage \
  --content iso,vztmpl,backup,snippets,images
```

See [docs/architecture.md#shared-storage](docs/architecture.md#shared-storage)
for why the second command is separate and cluster-wide.

### 7. Provision the nodes

```bash
cd environments/nodes/
export AWS_ACCESS_KEY_ID=<minio-user>       # or just `source scripts/vault-apply-wrapper.sh` once (step 4)
export AWS_SECRET_ACCESS_KEY=<minio-password>
terraform init
terraform apply -parallelism=1
```

No `terraform.tfvars` needed if `vault-apply-wrapper.sh` is sourced —
`proxmox_api_token`/`ssh_public_key` are fetched
automatically on first use in this directory.

`-parallelism=1` is not cosmetic — see
[docs/troubleshooting.md](docs/troubleshooting.md#concurrent-clones-unreliable)
for the disk-contention/timeout story.

### 8. (Optional, manual, rare) Provision the CI runner

```bash
cd environments/runner/
terraform init
terraform apply
```

Always run this by hand, never from the self-hosted runner's own CI job —
see [docs/architecture.md#two-independent-root-modules](docs/architecture.md#two-independent-root-modules)
for the incident that made this a hard rule.

#### 8a. Put ci-node into the tailnet (`tag:ci`)

Some deploy jobs no longer reach their targets over the home LAN — e.g.
`lombel-landing`'s VM lives on an isolated SDN segment and is only reachable
over Tailscale. The runner host therefore joins the tailnet as `tag:ci`:

```bash
{ printf 'export TS_AUTHKEY=%q\n' "$(vault kv get -field=auth-key tailscale/ci-node)"
  cat scripts/tailscale-runner-init.sh; } | ssh ubuntu@192.168.100.50 'sudo bash -s'
```

The key goes in over stdin with the script, never on a command line.
`tailscale/ci-node` holds a single-use, pre-approved auth key tagged `tag:ci`
(admin console -> Keys). The tag and its grants (`tag:ci` -> `tag:web`
`tcp:22`, -> `lxc-jump` `tcp:8200`) live in `tailscale-acl`.

- **Every runner on ci-node gets `tag:ci`'s grants** — it's one Tailscale node
  for the whole VM, not per runner. The per-repo boundary is each repo's own
  deploy secrets in Vault (AppRole-scoped), not the network. A repo that needs
  a hard boundary needs its own runner VM with its own tag.
- `--accept-dns=false`: ci-node is shared, and tailnet DNS overrides local DNS
  for every job on it. The tailnet names jobs need (`lxc-bare-pve`,
  `lombel-landing-dev`) are pinned in a managed `/etc/hosts` block from
  `tailscale ip`. A peer not visible yet is skipped with a warning; re-run the
  script (no key needed once joined) after it gets tagged / granted, or after
  a target VM is re-created with a new tailnet IP.
- A script, not `environments/runner` cloud-init: `modules/proxmox-vm` wires
  `user_data_file_id` to the snippet resource id, so any cloud-init change
  re-creates ci-node and every registered runner with it. After a
  from-scratch `terraform apply` of `environments/runner`, run this together
  with the runners' register scripts.
- Not a `ProxyJump` through `lxc-bare-pve`: jobs talk to tailnet targets
  directly as a tailnet node.

### 9. (Optional, manual, as-needed) poly-nodes / minecraft-node / immich-node

Same pattern as steps 7/8 — `cd` into the environment, `terraform init`,
`terraform apply` (with `vault-apply-wrapper.sh` sourced). `minecraft-node`
is the one exception still needing a manual `terraform.tfvars` for
`playit_secret_key` (see [Secrets](#secrets) above). None are wired into
`pipeline.yml`. `immich-node` needs a manual pass after the first `apply`
that Terraform can't reach (guest-OS config) — see
[environments/immich-node/README.md](environments/immich-node/README.md).

### 10. (Optional) Stand up the Tailscale jump-host

```bash
TS_AUTHKEY=tskey-auth-... ssh root@192.168.100.30 'bash -s' < scripts/tailscale-lxc-init.sh
```

Creates a dedicated tailnet node (`lxc-<node>`, named after the host it runs
on — CTID and LAN IP are keyed on that name: `bare-pve` → CT 400, `pve-rog`
→ CT 420, an unlisted node is a hard error). Used as an SSH `ProxyJump` onto
the Proxmox hosts and a
`tailscale serve` proxy for the web UIs. Not a Terraform resource: LXC has
no cloud-init user-data path in Proxmox, so the install + `tailscale up`
would need `null_resource` + SSH either way (see
[docs/architecture.md](docs/architecture.md#other-services)). The auth key
is a reusable key from the Tailscale admin console, not yet in Vault (same
status as `minecraft-node`'s `playit_secret_key`). The script prints the
`~/.ssh/config` snippet and the `tailscale serve` commands to run once
afterward — `serve` needs HTTPS certificates enabled for the tailnet,
which needs MagicDNS on (`tailscale-acl`'s `magic_dns = true`).

## CI/CD

`.github/workflows/pipeline.yml` runs two jobs on the self-hosted runner,
triggered on `workflow_dispatch` or a push to `main` touching
`environments/nodes/**` or `modules/**`:

1. **provision** — `terraform apply` against `environments/nodes`,
   producing `environments/nodes/inventory.ini` and uploading it as a build
   artifact.
2. **deploy** — checks out this repo (for `inventory.ini`) alongside a
   **pinned tag** of [`swarm-lab`](../swarm-lab) (currently `v0.3.3`),
   waits for every node to finish booting, then runs
   `swarm-lab/ansible/site.yml` against the freshly provisioned nodes.

**Why a pinned tag instead of `main`:** the deploy job needs a stable,
reproducible target — bumping the pin is a deliberate, visible action
rather than silently picking up whatever `swarm-lab`'s `main` happens to be
at trigger time. See [swarm-lab's own README](../swarm-lab/README.md#cicd)
for how its application images are versioned separately.

Required repo secrets: `VAULT_ROLE_ID`, `VAULT_SECRET_ID`. Everything the
pipeline needs (the Proxmox API token, the shared SSH public key, the CI
SSH private key, MinIO credentials, the GitHub runner PAT) is fetched
from Vault at job runtime via the `ci-runner` AppRole — see
`scripts/vault-approle-init.sh` and the `Fetch secrets from Vault` step
in both `provision` and `deploy` jobs of `pipeline.yml`. The CI SSH
private key and runner PAT now live under `github-actions/*`; MinIO
creds under `minio/credentials`. `PROXMOX_ENDPOINT`/`CI_SSH_PUBLIC_KEY`/
`VM_SSH_PUBLIC_KEY` are no longer read from GitHub Secrets — the endpoint
is derived from `proxmox_node` (see
[Node placement](#node-placement-endpoint--golden-image-resolution) above)
and the public key now comes from Vault's `proxmox/ssh-keys` path
(`public_key` field), matching the manual-apply path. The old repo secrets can be removed if
nothing else references them.

## Status

- [x] Two-node Proxmox cluster (`nexus-cluster`) — `pve-rog` and `bare-pve`,
      both bare metal — plus a QDevice arbiter on the Zenbook
- [x] `bpg/proxmox` provider authenticated (API token + SSH key)
- [x] Golden image template (cloud-init–ready Ubuntu 24.04), present on
      both nodes (VM 9000 on `bare-pve`, VM 9001 on `pve-rog`)
- [x] End-to-end `terraform apply` — clone, cloud-init, guest agent, IP
      assignment all working
- [x] Runner split into an independent root module with its own backend
- [x] State backend (MinIO/CT 200) moved off both the runner and the node
      VMs it describes, pinned to `bare-pve` on a static IP
- [x] Runner state migrated onto the same MinIO bucket as the nodes
- [x] Full `provision` → `deploy` pipeline green end-to-end
- [x] `docker`/`github-runner` Ansible roles are provisioning-flow
      agnostic (`ansible_user`-driven), no more hardcoded `vagrant`
- [x] Node/runner VM provisioning extracted into a reusable module
      (`modules/proxmox-vm`) — node *count* is still driven by each
      environment's `var.nodes` map default, not yet parameterized
      externally
- [x] Node/runner VMs have an explicit serial console
- [x] Runner host prerequisites folded into `runner/`'s cloud-init — a
      runner recreate needs no manual dependency pass
- [x] `scripts/register-github-runner.sh` installs/re-registers the
      GitHub Actions runner agent — kept manual (registration token is
      one-time-use, ~1hr expiry)
- [x] LVM thin pool exhaustion on `pve-rog` is now caught early
      (`thin_pool_autoextend_threshold = 80`), but the underlying
      overcommit is structural — see
      [docs/troubleshooting.md](docs/troubleshooting.md#lvm-thin-pool-exhaustion)
- [x] `environments/minecraft-node` added — isolated node, manual apply
- [x] `environments/poly-nodes` added — same `proxmox_node`-derived
      placement as every other environment (VM 9001 on `pve-rog`'s own
      `local-lvm`, no separate datastore); manual apply, not wired into
      `pipeline.yml` — `poly-ci`'s own topology/state, spin-up/test/
      tear-down workflow rather than always-up infra
- [x] `environments/immich-node` added — Immich via `docker compose` on a
      dedicated VM, actually running on `pve-rog` (docs/tfvars previously
      assumed `bare-pve` — corrected to match the deployed reality, see
      the architecture note above)
- [x] `environments/workstation` (GUI-installed Ubuntu Desktop on `pve-rog`,
      `qxl2` + local SPICE kiosk) **removed** — GPU-passthrough desktop VMs
      now live in the dedicated
      [`proxmox-hosted-workstation`](../proxmox-hosted-workstation) repo
- [x] Dedicated hardware acquired for `bare-pve`, and `pve-rog`
      subsequently rebuilt onto bare metal too — see
      [docs/history.md](docs/history.md)
- [x] Cluster-wide NFS shared storage (`shared-storage`, hosted on
      `bare-pve`) registered
- [x] New-host unreachability on `bare-pve` (MT-PON-AT-4 L2 quirk) handled
      automatically via a wake-ping in the shared base cloud-init `runcmd`
- [x] MinIO (CT 200) and the CI runner live on `bare-pve`
- [x] `TerraformProv` role/ACLs live in `/etc/pve` (pmxcfs), cluster-wide —
      no per-node re-verification needed
- [x] Datacenter firewall enabled cluster-wide (management IPSet, corosync/
      Tailscale/SSH/UI + Valheim-ingress ACCEPT rules, per-node rollout
      without lockout) — needed so downstream guests get veth-level
      isolation; config still pmxcfs-only, see
      [docs/architecture.md#cluster-firewall](docs/architecture.md#cluster-firewall)
- [x] Vault (CT 300) stood up on `bare-pve` — LXC, systemd, raft storage,
      `mlock` genuinely enforced, initialized and unsealed. Wired into
      both the CI pipeline (`ci-runner` AppRole) and manual applies
      (`operator-manual-apply` userpass policy + `vault-apply-wrapper.sh`).
      `/root/terraform-token.json` removed from both Proxmox hosts.
- [x] **Every environment's `proxmox_endpoint`/`template_vm_id` are now
      derived from `proxmox_node` via a per-environment `locals.tf`** —
      no environment takes either as a separate input variable anymore,
      closing the class of bug where the provider endpoint and the golden
      image clone source could silently disagree (see
      [Node placement](#node-placement-endpoint--golden-image-resolution)
      above and the `--link0`-adjacent entries in
      [docs/troubleshooting.md](docs/troubleshooting.md)).
- [x] **SSH public key (`ssh_public_key`, was `vm_ssh_public_key`/
      `ci_ssh_public_key`) migrated into Vault** (`proxmox/ssh-keys` →
      `public_key`) — `scripts/vault-apply-wrapper.sh` fetches it
      alongside the API token and MinIO credentials.
      Manual-apply environments (`runner`, `poly-nodes`, `minecraft-node`,
      `immich-node`) no longer need a filled-in
      `terraform.tfvars` at all, except `minecraft-node`'s
      `playit_secret_key` (not yet in Vault, tracked as a follow-up).
- [x] `immich-node`'s recovery-disk bind is Terraform-managed; what remains
      manual is guest-OS-level config — see
      [environments/immich-node/README.md](environments/immich-node/README.md)
- [x] `swarm-lab`'s `Vagrantfile` stays — deliberately kept so `swarm-lab`
      remains a fully independent, self-contained project
