# IAC Proxmox Lab

Infrastructure-as-Code lab for provisioning VMs on Proxmox VE using Terraform.
Built as a bare-metal/self-hosted counterpart to cloud-focused IaC work — a
Proxmox + Terraform stack closer to how bare-metal infrastructure is
actually managed, used as an alternative provisioning path for
[`swarm-lab`](../swarm-lab)'s nodes. This is deliberately **not** a
replacement for `swarm-lab`'s own `Vagrantfile` — that stays, so `swarm-lab`
remains fully self-contained and can be spun up on its own hardware without
this repo (see [CI/CD](#cicd) for how the two connect via a pinned tag).

For the full reasoning behind the topology, the state-backend split, and
the raw-disk/USB passthrough pattern, see
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
│       ├ VM 9000 golden image   │       │       ├ VM 9000 golden image (own)    │
│       ├ prod/stage/dev nodes   │       │       ├ CT 200: minio (state backend) │
│       ├ poly-nodes (WIP)       │       │       ├ CT 300: vault (secrets)       │
│       └ VM 100: workstation    │       │       ├ VM: ci-runner                 │
│         (GUI-installed desktop)│       │       ├ VM 101: immich-node           │
│                                │       │       └ NFS export → shared-storage   │
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

Managed remotely from a laptop (Zenbook) over the LAN — Terraform, `qm`/`pveum`
commands, and the web UI are all driven from there.

**Two nodes, one cluster (`nexus-cluster`), plus a QDevice arbiter — both
nodes bare metal.** `bare-pve` (`.30`) holds storage and anything that must
not go down (MinIO, Vault, CI runner, immich-node); `pve-rog` (`.20`) keeps
the "extra CPU/RAM for peak load" role and also hosts `workstation` — a
GUI-installed desktop VM used as an actual personal computer (see
[Other environments](docs/architecture.md#other-environments)). The full
story of how both nodes ended up bare metal (one of them was nested Proxmox
on a laptop for a while) is in [docs/history.md](docs/history.md); the full
reasoning behind the cluster topology, the QDevice/Tailscale setup, the
physical LAN quirks, and the state-backend placement is in
[docs/architecture.md](docs/architecture.md#architecture-in-depth).

## Stack

- **Proxmox VE 9.2** — hypervisor, clustered (`nexus-cluster`, 2 nodes +
  QDevice), both nodes bare metal
- **Terraform** + [`bpg/proxmox`](https://github.com/bpg/terraform-provider-proxmox)
  provider (chosen over `Telmate/proxmox` — more actively maintained, fuller
  API coverage)
- **cloud-init** — VM bootstrapping (user creation, SSH keys, package install)
  for every environment except `workstation/`, which is installed by hand
  through the GUI installer instead (see
  [environments/workstation/README.md](environments/workstation/README.md))
- **Ubuntu 24.04 (Noble) cloud image** — golden template, cloned per VM
- **MinIO** (LXC, systemd daemon, no Docker) — S3-compatible Terraform state
  backend for every root module, independent of the runner and the node
  VMs; also serves as an internal binary mirror for tools blocked by
  regional restrictions (see [docs/architecture.md](docs/architecture.md#state-backend-lives-off-both))
- **Vault** (LXC, systemd daemon, no Docker, raft/integrated storage) —
  standing up on `bare-pve` (CT 300) as the future home for secrets
  currently living as plaintext on disk (`/root/terraform-token.json`,
  cloud-init snippets). Not yet wired into any environment's secret flow —
  see the Status section below and `scripts/vault-lxc-init.sh`.
- **Ansible** — post-provision configuration, delegated to
  [`swarm-lab`](../swarm-lab)'s playbook via a pinned git tag (see
  [CI/CD](#cicd) below)
- **Docker Compose + systemd** — `immich-node`'s provisioning model,
  deliberately not swarm (see
  [environments/immich-node/README.md](environments/immich-node/README.md))
- **SPICE (`qxl2`) + a local kiosk session** — `workstation/`'s display
  model (see [environments/workstation/README.md](environments/workstation/README.md))

## Repo layout

Standard `modules/` + `environments/` split. `modules/proxmox-vm` is the one
reusable building block — a single cloned VM with a cloud-init snippet — and
every root module except `environments/workstation` calls it (see
[docs/architecture.md#other-environments](docs/architecture.md#other-environments)
for why `workstation` is the exception).

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
├── poly-nodes/                       # ROOT MODULE — infra for poly-ci, manual apply, WIP
├── minecraft-node/                   # ROOT MODULE — isolated Minecraft node, manual apply
├── immich-node/                      # ROOT MODULE — Immich (docker compose), manual apply
│   └── README.md                     #   cpu_type / recovery-ro details specific to this env
└── workstation/                      # ROOT MODULE — GUI-installed desktop VM(s), manual apply
    └── README.md                     #   qxl2 vs virtio-gl vs GPU passthrough, kiosk mechanics

.github/workflows/pipeline.yml        # provision (terraform, environments/nodes) + deploy (ansible)
scripts/
├── install-proxmox-with-libvirt.sh   # HISTORICAL — see docs/history.md
├── proxmox-init.sh                   # Proxmox-side (either node): terraform user/role/token,
│                                     #   golden image, thin-pool autoextend threshold
├── minio-lxc-init.sh                 # Proxmox-side (bare-pve): MinIO LXC (state backend)
├── vault-lxc-init.sh                 # Proxmox-side (bare-pve): Vault LXC (CT 300), manual unseal
├── shared-storage-creation.sh        # Proxmox-side (bare-pve): NFS export prep
├── desktop-kiosk-setup.sh            # Proxmox-side (pve-rog): local SPICE kiosk for workstation
└── register-github-runner.sh         # Registers the GitHub Actions runner agent on ci-runner
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
an API token, and the `ubuntu-cloud-template` (VM 9000) golden image. Also
pins `/etc/resolv.conf`, enables the `snippets` content type on the `local`
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

### 4. (Optional, WIP) Stand up Vault (on `bare-pve`)

```bash
ssh root@<proxmox-ip> 'bash -s' < scripts/vault-lxc-init.sh
```

Creates CT 300 (Vault, statically addressed, raft/integrated storage — no
external Consul needed for a single-node deploy). Not yet consuming any
secret currently living on disk — this stands up the service itself. See
[docs/architecture.md](docs/architecture.md) and the script header for the
`mlock`/unseal reasoning, and
[docs/troubleshooting.md](docs/troubleshooting.md#vault-mlock-enomem-in-unprivileged-lxc)
for the `Failed to lock memory: cannot allocate memory` pitfall this
script now guards against on unprivileged LXC.

After the first run, initialize and unseal by hand (deliberately manual —
no external KMS available in this lab for auto-unseal):

```bash
pct exec 300 -- env VAULT_ADDR=http://127.0.0.1:8200 vault operator init
# copy out all 5 unseal keys + the root token — shown ONCE
pct exec 300 -- env VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal   # x3, different keys
```

Vault comes back **sealed** after every CT/host restart — repeat the
`operator unseal` step manually each time.

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
cp terraform.tfvars.example terraform.tfvars   # fill in endpoint, token, SSH keys
export AWS_ACCESS_KEY_ID=<minio-user>
export AWS_SECRET_ACCESS_KEY=<minio-password>
terraform init
terraform apply -parallelism=1
```

`-parallelism=1` is not cosmetic — see
[docs/troubleshooting.md](docs/troubleshooting.md#concurrent-clones-unreliable)
for the disk-contention/timeout story.

### 8. (Optional, manual, rare) Provision the CI runner

```bash
cd environments/runner/
cp terraform.tfvars.example terraform.tfvars   # same values as the nodes tfvars
export AWS_ACCESS_KEY_ID=<minio-user>
export AWS_SECRET_ACCESS_KEY=<minio-password>
terraform init
terraform apply
```

Always run this by hand, never from the self-hosted runner's own CI job —
see [docs/architecture.md#two-independent-root-modules](docs/architecture.md#two-independent-root-modules)
for the incident that made this a hard rule.

### 9. (Optional, manual, as-needed) poly-nodes / minecraft-node / immich-node / workstation

Same pattern as steps 7/8 — `cd` into the environment, copy the
`.tfvars.example`, `terraform init`, `terraform apply`. None are wired into
`pipeline.yml`. `immich-node` and `workstation` each need a manual pass
after the first `apply` that Terraform can't reach (guest-OS config, GUI
install) — see their own READMEs:
[environments/immich-node/README.md](environments/immich-node/README.md),
[environments/workstation/README.md](environments/workstation/README.md).

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

Required repo/environment secrets: `PROXMOX_ENDPOINT`, `PROXMOX_API_TOKEN`,
`VM_SSH_PUBLIC_KEY`, `CI_SSH_PUBLIC_KEY`, `CI_SSH_PRIVATE_KEY`,
`MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY`, `GH_RUNNER_PAT`.

## Status

- [x] Two-node Proxmox cluster (`nexus-cluster`) — `pve-rog` and `bare-pve`,
      both bare metal — plus a QDevice arbiter on the Zenbook
- [x] `bpg/proxmox` provider authenticated (API token + SSH key)
- [x] Golden image template (cloud-init–ready Ubuntu 24.04), present on
      both nodes
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
- [x] `environments/poly-nodes` added — WIP, blocked on a flaky HDD
- [x] `environments/immich-node` added — Immich via `docker compose` on a
      dedicated `bare-pve` VM
- [x] `environments/workstation` added — GUI-installed Ubuntu Desktop VM
      on `pve-rog`, local SPICE kiosk
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
- [x] Vault (CT 300) stood up on `bare-pve` — LXC, systemd, raft storage,
      `mlock` genuinely enforced (`setcap cap_ipc_lock` on the binary plus
      `lxc.prlimit.memlock: unlimited` in the CT's Proxmox-side config —
      the capability alone isn't sufficient in an unprivileged LXC's user
      namespace, see
      [docs/troubleshooting.md](docs/troubleshooting.md#vault-mlock-enomem-in-unprivileged-lxc)),
      initialized and unsealed. **Not yet wired into any environment's
      secret flow** — `/root/terraform-token.json` and cloud-init secrets
      still live as plaintext on disk; migrating them to Vault (AppRole/
      token auth for the runner, etc.) is a separate follow-up.
- [x] `immich-node`'s recovery-disk bind is Terraform-managed; what remains
      manual is guest-OS-level config — see
      [environments/immich-node/README.md](environments/immich-node/README.md)
- [x] `swarm-lab`'s `Vagrantfile` stays — deliberately kept so `swarm-lab`
      remains a fully independent, self-contained project
