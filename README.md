# IAC Proxmox Lab

Infrastructure-as-Code lab for provisioning VMs on Proxmox VE using Terraform.
Built as a bare-metal/self-hosted counterpart to cloud-focused IaC work — a
Proxmox + Terraform stack closer to how bare-metal infrastructure is
actually managed, used as an alternative provisioning path for
[`swarm-lab`](../swarm-lab)'s nodes. This is deliberately **not** a
replacement for `swarm-lab`'s own `Vagrantfile` — that stays, so `swarm-lab`
remains fully self-contained and can be spun up on its own hardware without
this repo (see [CI/CD](#cicd) for how the two connect via a pinned tag).

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│ G750JX (physical host, 24GB RAM / 8 cores)                          │
│                                                                     │
│  br0 (NetworkManager bridge, bound to enp4s0 → LAN)                 │
│   │                                                                 │
│   └── proxmox-lab (KVM/libvirt VM, nested virtualization)           │
│         18GB RAM / 6 vCPU, host-passthrough CPU                     │
│         Proxmox VE 8.4, reachable at 192.168.100.20:8006            │
│          │                                                          │
│          └── vmbr0 (Proxmox-internal bridge, port: enp1s0)          │
│               │                                                     │
│               ├── VM 9000: ubuntu-cloud-template (golden image)     │
│               ├── CT 200: minio (LXC, systemd daemon)               │
│               │     — Terraform state backend, NOT managed          │
│               │       by Terraform itself, static IP                │
│               ├── VM: ci-runner (root module: environments/runner/) │
│               └── VM: prod-node / stage-node / dev-node             │
│                     (root module: environments/nodes/)              │
└─────────────────────────────────────────────────────────────────────┘
```

Managed remotely from a laptop (Zenbook) over the LAN — Terraform, `qm`/`pveum`
commands, and the web UI are all driven from there; the G750JX just hosts the
nested Proxmox VM.

**Why nested and not bare metal:** dedicated hardware for this is planned but
not yet available. Running Proxmox nested inside libvirt on the G750JX lets
the Terraform/provider work start now; the only hardware-specific piece
(`install-proxmox-with-libvirt.sh`) is isolated so it's a non-issue once real
hardware shows up — everything from `proxmox-init.sh` onward is portable.

**Why the G750JX's 18GB isn't a problem:** other lab projects that would
normally run on bare metal via Vagrant ([`swarm-lab`](../swarm-lab),
`poly-ci`) get tested *inside* this Proxmox instance instead of directly on
the host, so the 18GB doesn't compete with them for host resources.

**Storage is comfortably overcommitted, not a coincidence.** The nested
disk backing `local-lvm` is 60GB, and the sum of the nominal sizes of every
thin volume on it (VMs + MinIO CT) already exceeds that — thin provisioning
means this "works" until actual usage catches up. See the LVM thin pool
entries in [Troubleshooting notes](#troubleshooting-notes-things-that-actually-broke)
below for what happens when it does, and what's in place to catch it early.

### Two independent root modules, on purpose

`environments/nodes/` and `environments/runner/` are **two separate
Terraform root modules**, each with its own backend, state, and lifecycle,
both built from the same shared `modules/proxmox-vm`. This is not
incidental structure — it's the fix for an actual incident: the CI runner
used to live in the same state/config as the nodes it provisions. A routine
change to the shared cloud-init template forced a replace on every resource
in one `apply`, including the runner VM — which destroyed itself mid-job
while running that very `apply`. See
[Troubleshooting notes](#troubleshooting-notes-things-that-actually-broke)
below for the full story.

Consequences of the split:
- `terraform apply` in `environments/nodes/` never touches the runner, and
  vice versa — no shared blast radius.
- The runner is applied **manually, from a laptop**, never from CI on
  itself. Both `environments/nodes/` and `environments/runner/` now use an
  S3 (MinIO) backend — the runner's state was migrated off `local` onto the
  same bucket (separate `key`), since the actual risk with a local backend
  wasn't Proxmox dying (in that case state is moot either way — the VMs
  are gone), but losing the laptop the runner is applied from while the
  runner VM itself keeps running. See the S3-migration troubleshooting
  entries below for the mechanics of that move.
- `pipeline.yml`'s `paths: ['environments/nodes/**', 'modules/**']` filter
  means pushes under `environments/runner/**` don't trigger the CI job on
  the nodes — this was true before the split too, but now it's structurally
  reinforced rather than accidental. Changes under `modules/**` *do*
  trigger it, since `environments/nodes` depends on that module.

### Other environments

Two more root modules live under `environments/`, both built on the same
`modules/proxmox-vm` as `nodes/`, neither wired into `pipeline.yml` — both
are applied manually, on demand:

- **`poly-nodes/`** — infra for a separate project,
  [`poly-ci`](https://github.com/tsuyakashi/poly-ci): runner/prod/monitoring
  nodes, structured the same way as `nodes/`. Currently on hold — see the
  golden-image note below.
- **`minecraft-node/`** — a single isolated node (own NAT segment, no
  access to the rest of the LAN) running a Minecraft server + playit.gg
  tunnel. Short-lived/situational by nature, not part of the core lab.

`poly-nodes/` clones from a second golden image (VM 9001) on `hdd-storage`
instead of the main `local-lvm` pool — that disk is currently flaky, so
9001/`poly-nodes` is WIP and bootstrapped by hand for now (same pattern as
`proxmox-init.sh` uses for 9000, just not yet scripted).

### State backend lives off both

Terraform state for both root modules (`environments/nodes/backend.tf` and
`environments/runner/backend.tf`, both S3-compatible) points at MinIO
running in **CT 200**, an LXC container on the Proxmox host — not a
Terraform-managed VM, not colocated with the runner. This is deliberate:
the backend must survive independently of anything a `terraform apply`
might do to the infrastructure it describes. MinIO used to run inside the
runner VM itself, which meant a runner self-destruct also took the state
backend down with it (`no route to host` on every subsequent
`terraform init`). See `scripts/minio-lxc-init.sh`.

LXC rather than a VM here is a deliberate trade-off in the *other*
direction from the runner: MinIO is trusted, self-authored code with no
exposure to arbitrary/untrusted input, so the lighter, faster, cheaper LXC
container is fine. The runner executes arbitrary workflow code and stays in
a full VM for the stronger KVM-level isolation — see the reasoning in the
troubleshooting notes.

**CT 200's network address is statically pinned, not DHCP** (`ip=<addr>/24,
gw=<gateway>` in `minio-lxc-init.sh`, the same approach nodes already use
via cloud-init) — see the DHCP-drift entry in Troubleshooting notes for why
this changed.

**The same MinIO bucket also doubles as an internal binary mirror.** A
`tools/` prefix in the `iac-proxmox-lab-tfstate` bucket (public-download,
`mc anonymous set download local/tools`) holds binaries that can't be
fetched directly from the runner due to regional blocks — currently the
Terraform CLI itself (`terraform_<version>_linux_amd64`, downloaded once
over a VPN and pushed via `mc cp`) and MinIO client. See the HashiCorp
distribution note in [Troubleshooting notes](#troubleshooting-notes-things-that-actually-broke)
below.

## Stack

- **Proxmox VE 8.4** — hypervisor
- **Terraform** + [`bpg/proxmox`](https://github.com/bpg/terraform-provider-proxmox)
  provider (chosen over `Telmate/proxmox` — more actively maintained, fuller
  API coverage)
- **cloud-init** — VM bootstrapping (user creation, SSH keys, package install)
- **Ubuntu 24.04 (Noble) cloud image** — golden template, cloned per VM
- **MinIO** (LXC, systemd daemon, no Docker) — S3-compatible Terraform state
  backend for both root modules, independent of the runner and the node
  VMs; also serves as an internal binary mirror for tools blocked by
  regional restrictions
- **Ansible** — post-provision configuration, delegated to
  [`swarm-lab`](../swarm-lab)'s playbook via a pinned git tag (see
  [CI/CD](#cicd) below)

## Repo layout

Standard `modules/` + `environments/` split. `modules/proxmox-vm` is the one
reusable building block — a single cloned VM with a cloud-init snippet — and
every root module (`environments/nodes`, `environments/runner`,
`environments/poly-nodes`, `environments/minecraft-node`) calls it. The
module owns no backend and no provider config; each environment configures
those independently, which is what actually enforces the state/lifecycle
separation described below (not just a folder convention).

```
modules/
└── proxmox-vm/                       # reusable module — no backend, no provider block
    ├── main.tf                       #   VM + cloud-init file resource
    ├── variables.tf                  #   name, sizing, ip_config (static|dhcp), ssh keys,
    │                                 #   extra_packages/extra_runcmd/write_files/docker_group
    ├── versions.tf                   #   required_version + required_providers
    ├── outputs.tf                    #   vm_id, ipv4_addresses
    ├── README.md
    └── templates/user-data.yml.tpl   #   cloud-init template (users, packages, guest agent,
                                       #   optional write_files/extra runcmd for environment-
                                       #   specific provisioning — see below)

environments/
├── nodes/                            # ROOT MODULE — prod/stage/dev nodes (in CI)
│   ├── main.tf                       #   for_each over var.nodes -> module "node"
│   ├── variables.tf                  #   incl. the "nodes" topology map
│   ├── outputs.tf                    #   node_ids, node_ips, inventory_path
│   ├── providers.tf
│   ├── backend.tf                    #   S3 (MinIO/CT 200)
│   ├── terraform.tfvars.example
│   └── templates/inventory.tpl       #   ansible inventory template (used only here)
├── runner/                           # ROOT MODULE — CI runner, own state/lifecycle
│   ├── main.tf                       #   single module "ci_runner" call, dhcp,
│   │                                 #   extra_packages/extra_runcmd/write_files for
│   │                                 #   runner-specific prerequisites (see below)
│   ├── variables.tf
│   ├── outputs.tf                    #   ci_runner_ip
│   ├── providers.tf
│   ├── backend.tf                    #   S3 (MinIO/CT 200) — migrated off local, see
│   │                                 #   Troubleshooting notes for why and how
│   └── terraform.tfvars.example
├── poly-nodes/                       # ROOT MODULE — infra for poly-ci, manual apply, WIP
│   └── ...                           #   same shape as nodes/; clones from VM 9001 on
│                                     #   hdd-storage (currently flaky — see "Other environments")
└── minecraft-node/                   # ROOT MODULE — isolated Minecraft node, manual apply
    ├── network.tf                    #   isolated vmbr1 bridge + NAT/DROP iptables rules
    └── ...                          #   short-lived/situational, not part of the core lab

.github/workflows/pipeline.yml        # provision (terraform, environments/nodes) + deploy (ansible)
scripts/
├── install-proxmox-with-libvirt.sh   # host-side: creates the nested Proxmox VM,
│                                     #   with guards/auto-fixes for both the br0/enp4s0
│                                     #   physical-NIC attachment and the VM's own vnet0
│                                     #   bridge port
├── proxmox-init.sh                   # Proxmox-side: terraform user/role/token, golden image,
│                                     #   thin-pool autoextend threshold
└── minio-lxc-init.sh                 # Proxmox-side: MinIO LXC (state backend), NOT terraform-managed,
                                       #   statically-addressed
```

**What changed vs. the original flat layout**, and why:

- `nodes.tf` + `runner/runner.tf`'s VM/cloud-init resources merged into one
  module, `modules/proxmox-vm` — they were near-identical resource blocks
  (VM + cloud-init file) with different inputs. Duplicating them was the
  actual blocker for the "reusable module, variable node count" item that
  used to sit in Status/TODO; now it's just `for_each` over the module.
- `cloud-init/user-data.yml.tpl` moved inside the module
  (`modules/proxmox-vm/templates/`) — it's an implementation detail of "how
  a VM is built," not something either environment should reach into
  directly.
- `templates/inventory.tpl` moved into `environments/nodes/` — only that
  one root module ever uses it; keeping it at the repo root implied it was
  shared, which it wasn't.
- Fixed a latent bug in the process: the old `runner/runner.tf` called
  `templatefile()` without a `hostname` value even though the template
  requires `${hostname}` — this would fail at apply time. The module now
  defaults `hostname` to the VM name.
- `environments/nodes/outputs.tf` is new — the old repo-root module had no
  outputs at all (`runner/` did). Now both expose `vm_id`/IP info instead
  of requiring a state-file grep to check what got provisioned.
- `backend.tf`'s S3 `key` changed from `terraform.tfstate` to
  `nodes/terraform.tfstate` to make room for other environments in the same
  bucket later — **this requires `terraform init -migrate-state` (or a
  manual state copy in MinIO) when adopting this layout on an existing
  state file**, it's not a no-op rename. Performed by hand on this repo's
  own state during PR #23. The same `nodes/` vs `runner/` key-namespacing
  later made it straightforward to migrate `environments/runner/`'s state
  into the same bucket too — see Troubleshooting notes, and to add
  `poly-nodes/` and `minecraft-node/` under their own keys later.
- Moving the VM/cloud-init resources into `modules/proxmox-vm` also meant
  they picked up new state addresses (`module.node["..."]....` instead of
  the old flat `proxmox_virtual_environment_vm.node["..."]`). Adopting this
  layout on existing state needs `moved` blocks mapping the old addresses
  to the new ones — otherwise Terraform reads the rename as
  destroy-old/create-new and will happily recreate every live VM. Add them
  temporarily, `apply` once, then they can be deleted. This is exactly what
  was done here — the blocks were added, applied once with no destroy/create
  in the plan, then removed.
- `modules/proxmox-vm` gained four optional inputs — `extra_packages`,
  `extra_runcmd`, `write_files`, `docker_group` — so environment-specific
  provisioning (currently only the runner and minecraft-node need any of
  this) stays out of the shared base template. `environments/nodes` never
  sets these, so node VMs are unaffected; see
  [Runner host prerequisites](#runner-host-prerequisites-automated-via-cloud-init)
  below for how the runner uses them.
- Both VM resources gained an explicit `serial_device`/`vga` block (matching
  what the golden image already had), so `qm terminal <vmid>` now shows a
  real console instead of a blank screen — closes a long-standing diagnosis
  gap; see Troubleshooting notes.
- `proxmox-init.sh` now also pins `activation { thin_pool_autoextend_threshold = 80 }`
  in `/etc/lvm/lvm.conf`, so a future host rebuild doesn't silently drop this
  guard — see the thin-pool exhaustion entries in Troubleshooting notes for
  why it's there.
- `minio-lxc-init.sh` now assigns CT 200 a static IP instead of DHCP — see
  the DHCP-drift entry in Troubleshooting notes for why.
- `modules/proxmox-vm` gained `network_bridge` (default `vmbr0`, overridable
  — e.g. `vmbr1` for `minecraft-node`'s isolated segment) and per-VM
  `datastore_id_disk`/`disk_size` inputs, to support `poly-nodes` and
  `minecraft-node` without forking the module.

## Quickstart

### 1. Stand up the nested Proxmox VM (on the physical host)

```bash
./scripts/install-proxmox-with-libvirt.sh
```

Checks KVM acceleration and nested virtualization are available, ensures the
`br0` bridge is up and has the physical NIC attached (auto-fixes it if a
previous VM teardown reverted `br0-port` to a standalone profile — see
Troubleshooting notes), ensures the VM's own `vnet0` bridge port is actually
attached to `br0` (auto-fixes and waits out STP forwarding delay if not —
see Troubleshooting notes), downloads the Proxmox VE ISO, and creates the VM
via `virt-install`. Idempotent — safe to re-run.

Complete the Proxmox installer manually via `virt-viewer` or the VNC console
(disk selection, root password, network — see the "Bridging to the LAN"
section below for why the network step matters).

### 2. Bridge the host network (one-time, physical host)

By default the nested VM sits on `virbr0` (libvirt NAT) and is only reachable
from the host itself. To reach it from other machines on the LAN, the
physical NIC needs to be bridged:

```bash
sudo nmcli connection add type bridge ifname br0 con-name br0 ipv4.method auto ipv6.method disabled
sudo nmcli connection modify <physical-nic-profile> master br0
sudo nmcli connection up br0
```

Then update the VM's libvirt XML (`virsh edit proxmox-lab`) to point
`<source bridge='...'/>` at `br0` instead of `virbr0`, and update Proxmox's
own `vmbr0` in `/etc/network/interfaces` (inside the VM) to a static address
on the LAN.

### 3. Initialize Proxmox for Terraform (inside the Proxmox VM)

```bash
ssh root@<proxmox-ip> 'bash -s' < scripts/proxmox-init.sh
```

Creates the `terraform@pve` user, a scoped `TerraformProv` role, an API
token, and the `ubuntu-cloud-template` (VM 9000) golden image. Also pins
`/etc/resolv.conf` (Proxmox's own DNS otherwise doesn't survive a fresh
install), enables the `snippets` content type on the `local` datastore
(needed for cloud-init user-data uploads), and sets
`activation { thin_pool_autoextend_threshold = 80 }` in `/etc/lvm/lvm.conf`
so a filling thin pool surfaces a warning well before it hits 100% and
starts throwing I/O errors at every VM on the host (see Troubleshooting
notes). Idempotent.

The API token secret is printed to `/root/terraform-token.json` on first
run — copy it into `terraform.tfvars`, then consider deleting that file from
the host. (Plaintext-on-disk is an acceptable trade-off for a local lab; a
production setup would push this into Vault or similar instead. The same
trade-off applies to any secret injected via cloud-init — e.g.
`minecraft-node`'s playit.gg key — since cloud-init snippets are readable
from the Proxmox datastore/API.)

**SSH key auth is required, not just API access.** The `bpg/proxmox`
provider uploads cloud-init snippets over SSH (not the REST API), so
`root@<proxmox-ip>` needs to accept your key, and that key needs to be
loaded in `ssh-agent` — a password-only root login (the Proxmox installer
default) will fail here even though everything else works over the API.

```bash
ssh-copy-id -i ~/.ssh/<your-key>.pub root@<proxmox-ip>
ssh-add ~/.ssh/<your-key>
```

### 4. Stand up the state backend (Proxmox host, before the first `terraform init`)

```bash
MINIO_ROOT_PASSWORD='<pick-a-password>' ssh root@<proxmox-ip> 'bash -s' < scripts/minio-lxc-init.sh
```

Creates CT 200, an unprivileged LXC container, and runs MinIO inside it as a
systemd service, on a statically-assigned IP (not DHCP — see Troubleshooting
notes for why). Not a Terraform resource by design — see
[Architecture](#state-backend-lives-off-both) above. Prints the S3 endpoint
and console URL on success.

Then, via the printed console URL, create a bucket named
`iac-proxmox-lab-tfstate` and confirm `endpoints.s3` in every environment's
`backend.tf` match the static IP set in `minio-lxc-init.sh`.

**Optional, one-time:** if the runner will need `terraform`/`mc` binaries
(it does — see [Runner host prerequisites](#runner-host-prerequisites-automated-via-cloud-init)
below), create a `tools/` prefix in the same bucket and make it
anonymously downloadable:

```bash
mc alias set local http://<minio-ip>:9000 <minio-user> <minio-password>
mc mb local/tools --ignore-existing
mc anonymous set download local/tools
```

### 5. Provision the nodes

```bash
cd environments/nodes/
cp terraform.tfvars.example terraform.tfvars   # fill in endpoint, token, SSH keys
export AWS_ACCESS_KEY_ID=<minio-user>
export AWS_SECRET_ACCESS_KEY=<minio-password>
terraform init
terraform apply -parallelism=1
```

`-parallelism=1` is not cosmetic — see the thin-pool/IO-contention entry in
troubleshooting notes below for why concurrent full-clones on this nested
setup are unreliable.

### 6. (Optional, manual, rare) Provision the CI runner

```bash
cd environments/runner/
cp terraform.tfvars.example terraform.tfvars   # same values as the nodes tfvars
export AWS_ACCESS_KEY_ID=<minio-user>
export AWS_SECRET_ACCESS_KEY=<minio-password>
terraform init
terraform apply
```

Always run this by hand, never from the self-hosted runner's own CI job —
that's the whole point of the split. See
[Architecture](#two-independent-root-modules-on-purpose). State lives in the
same MinIO bucket as the nodes' state, under a separate `runner/` key — see
Troubleshooting notes for why a local backend here turned out to still be a
single point of failure (laptop loss, not just Proxmox loss).

### 7. (Optional, manual, as-needed) poly-nodes / minecraft-node

Same pattern as steps 5/6 — `cd` into `environments/poly-nodes/` or
`environments/minecraft-node/`, copy the `.tfvars.example`, `terraform init`,
`terraform apply`. Neither is wired into `pipeline.yml`; both are meant to
be stood up, used, and torn down on demand rather than staying live like
`nodes/`. See [Other environments](#other-environments) above for what each
one is.

### Runner host prerequisites (automated via cloud-init)

Everything the CI job (`pipeline.yml`) needs on top of the golden image's
baseline (SSH user, `qemu-guest-agent`) is now provisioned automatically by
`environments/runner/main.tf`, via the module's `extra_packages`,
`extra_runcmd`, `write_files`, and `docker_group` inputs — no manual pass
after `terraform apply` is needed anymore. A runner recreate comes up ready
in one shot (roughly 3–4 minutes on this nested setup, most of it spent on
`apt-get install` for `docker.io`/`ansible` and their dependency trees).

What gets installed and why:

- **`~/.terraformrc` with a network mirror** — direct access to
  `registry.terraform.io` from this network isn't reliable enough for
  unattended CI runs, so provider installation goes through a mirror
  instead:

  ```hcl
  provider_installation {
    network_mirror {
      url     = "https://terraform-mirror.yandexcloud.net/"
      include = ["registry.terraform.io/*/*"]
    }
    direct {
      exclude = ["registry.terraform.io/*/*"]
    }
  }
  ```

  Written via `write_files`, owned by `root:root` at write time and
  `chown`'d to `ubuntu:ubuntu` afterward in `runcmd` — see the write_files
  ordering note in Troubleshooting notes for why it can't be owned by
  `ubuntu` directly at write time.

- **`terraform` CLI itself** — *not* installed via HashiCorp's apt repo or
  GitHub releases; both are unreachable from this network (regional
  distribution block — see Troubleshooting notes). Pulled instead from the
  self-hosted MinIO `tools/` bucket:

  ```bash
  curl -o /usr/local/bin/terraform http://<minio-ip>:9000/tools/terraform_<version>_linux_amd64
  chmod +x /usr/local/bin/terraform
  ```

  Getting a working binary into that bucket in the first place is a manual,
  one-time step (download over VPN, `mc cp` into `tools/` — see step 4
  above); bumping the Terraform version means repeating that upload and
  updating the filename in `environments/runner/main.tf`'s `extra_runcmd`.
  The MinIO IP baked into that URL is now the pinned static address, so it
  no longer needs re-syncing after every CT restart — see the DHCP-drift
  entry in Troubleshooting notes for the incident that made this necessary.

- **`docker.io`, `curl`, `jq`, `ansible`, `unzip`, `gnupg`,
  `software-properties-common`, `lsb-release`** — `docker.io` and `ansible`
  for the `deploy` job's playbook run against `swarm-lab`; the rest are
  general-purpose CI utilities.
- **MinIO client (`mc`)** — for poking at the state bucket (list objects,
  sanity checks) from the runner without going through the Proxmox host.
  Pulled from `https://dl.min.io/aistor/mc/release/linux-amd64/mc` — note
  the `aistor` path, not the older `client/mc/release/...` path, which now
  serves an HTML redirect instead of the binary (see Troubleshooting
  notes).

Quick check after any runner recreate:

```bash
ssh ubuntu@<runner-ip> 'which terraform ansible ansible-playbook ansible-galaxy docker mc'
```

All six should resolve immediately — no manual install pass required.

## CI/CD

`.github/workflows/pipeline.yml` runs two jobs on the self-hosted runner,
triggered on `workflow_dispatch` or a push to `main` touching
`environments/nodes/**` or `modules/**` (the latter because
`environments/nodes` depends on `modules/proxmox-vm` — a module change
needs the same `apply` as an environment change; see
[Architecture](#two-independent-root-modules-on-purpose)). Pushes under
`environments/runner/**`, `environments/poly-nodes/**`, and
`environments/minecraft-node/**` deliberately do **not** trigger this
workflow — the runner is applied by hand, never from its own CI job, and
`poly-nodes`/`minecraft-node` are spin-up/tear-down environments, not
persistent infra like `nodes/`.

1. **provision** — `terraform apply` against the `environments/nodes` root
   module, producing `environments/nodes/inventory.ini` via the `local_file`
   resource and uploading it as a build artifact.
2. **deploy** — checks out this repo (for `inventory.ini`) alongside a
   **pinned tag** of [`swarm-lab`](../swarm-lab) (currently `v0.3.3`, set via
   `ref:` in the `Checkout swarm-lab` step), waits for every node to finish
   booting (SSH reachable + `cloud-init status --wait`, see
   Troubleshooting notes for why this step exists), then runs
   `swarm-lab/ansible/site.yml` against the freshly provisioned nodes.

**Why a pinned tag instead of `main`:** the deploy job needs a stable,
reproducible target — bumping the pin is a deliberate, visible action (a
one-line diff in `pipeline.yml`) rather than silently picking up whatever
`swarm-lab`'s `main` happens to be at trigger time. Bump the tag whenever
`swarm-lab`'s `ansible/` tree (or anything else this pipeline depends on)
changes in a way you want reflected here — see
[swarm-lab's own README](../swarm-lab/README.md#cicd) for how its
*application* images (nginx/python/nodejs/go) are versioned and deployed
completely separately, by `swarm-lab`'s own CI, independent of this pin.

Required repo/environment secrets: `PROXMOX_ENDPOINT`, `PROXMOX_API_TOKEN`,
`VM_SSH_PUBLIC_KEY`, `CI_SSH_PUBLIC_KEY`, `CI_SSH_PRIVATE_KEY`,
`MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY`, `GH_RUNNER_PAT` (classic PAT with
`repo` scope, or fine-grained with `Administration: read/write` on
`swarm-lab` — used by the `github-runner` Ansible role to register a runner
on the freshly provisioned `prod-node`).

## The `TerraformProv` role, and why it needs what it needs

Proxmox's privilege model is granular enough that the "obvious" set of
privileges for VM management isn't sufficient for what Terraform actually
does end to end. Arrived at the following list through trial and error
against real `HTTP 403` responses, not from a single source of truth:

| Privilege | Needed for |
|---|---|
| `VM.Allocate`, `VM.Clone` | creating/cloning VMs |
| `VM.Config.*` | disk, CPU, memory, network, options, CD-ROM config |
| `VM.Config.Cloudinit` | **separate** from `VM.Config.Options` — cloud-init parameter changes on the clone |
| `VM.Config.HWType` | **separate** again — changing `vga`/`serial_device` (added when the serial console fix landed; without it, `apply` fails with `HTTP 403: Permission check failed (/vms/<id>, VM.Config.HWType)`) |
| `VM.PowerMgmt`, `VM.Audit`, `VM.Console`, `VM.Monitor` | start/stop, status, agent queries |
| `Datastore.AllocateSpace`, `Datastore.AllocateTemplate`, `Datastore.Audit` | disk provisioning |
| `Datastore.Allocate` | **separate** from `AllocateSpace` — managing the datastore resource itself, needed when the provider enables the `snippets` content type on first file upload |
| `SDN.Use` | cloning a VM with a network device attached to an SDN-managed bridge (introduced in Proxmox 8.x) |

## Troubleshooting notes (things that actually broke)

- **The self-hosted runner destroyed itself mid-`apply`.** Runner and nodes
  originally lived in one root module. A change to the shared cloud-init
  SSH-key template forced `# forces replacement` on every
  `proxmox_virtual_environment_file`/`proxmox_virtual_environment_vm`
  resource — including the runner VM the job was executing on. Terraform
  began destroying the runner's own VM; the job got a shutdown signal
  mid-destroy and never completed the recreate. Fixed by splitting the
  runner into its own root module (`environments/runner/`, own state, own
  backend, applied manually — see
  [Architecture](#two-independent-root-modules-on-purpose)).

- **State backend became unreachable after the above.** MinIO was running
  *inside* the runner VM. Once the runner destroyed itself, every
  subsequent `terraform init`/`plan`/`apply` failed with
  `dial tcp ...: connect: no route to host` — the state backend and the
  infrastructure it describes shared a single point of failure. Fixed by
  moving MinIO to a standalone LXC container (CT 200) outside any
  Terraform lifecycle — see [Architecture](#state-backend-lives-off-both)
  and `scripts/minio-lxc-init.sh`. Considered running MinIO in Docker on
  the Proxmox host directly, but Docker on the PVE host itself is not
  recommended (interferes with Proxmox's own iptables/firewall management)
  — an LXC container was the right level of isolation without that
  conflict.

- **Backend migration between S3 endpoints needs `-migrate-state` /
  `-reconfigure`, and it *still* tries to reach the old endpoint first.**
  Moving `backend.tf` from one MinIO endpoint to another isn't just an edit
  and `terraform init` — the first `init` after the endpoint changes still
  attempts to read the *previous* backend to figure out what needs
  migrating, so if the old endpoint is dead (as after the incident above),
  `-migrate-state` fails too on the first attempt. It only succeeds once
  Terraform gives up trying to reach the dead old backend and falls back to
  treating it as a fresh `-reconfigure`. Expect to run `terraform init`
  more than once when changing backend endpoints under failure conditions.

- **The runner's local backend was still a single point of failure — just a
  different one than Proxmox dying.** `environments/runner/` originally
  used `backend "local"` on the reasoning that it's applied rarely, by
  hand, from a laptop. That's true, but the actual risk isn't "Proxmox
  disappears" (in that case state is moot regardless of backend — the VMs
  are gone too) — it's losing the laptop (or just its disk) while the
  runner VM keeps running fine. The next `terraform apply` from a fresh
  machine wouldn't see the existing runner in state and would attempt to
  create a second one on top of it (MAC/name collision at best). Migrated
  `environments/runner/backend.tf` to the same S3 (MinIO) bucket the nodes
  already use, under a separate `runner/terraform.tfstate` key (mirroring
  the `nodes/` key-namespacing from PR #23) — `terraform init
  -migrate-state`, confirm "copy existing state to new backend" — so the
  runner's state survives independently of any single laptop, matching why
  MinIO itself was pulled out of the runner VM in the first place.
  (A local backend does remain the *only* correct choice if MinIO itself
  ever becomes a Terraform-managed resource in this same environment — a
  bootstrap/chicken-and-egg problem, since state can't live in a bucket
  the same `apply` is creating. Not the current setup; noted in case that
  changes.)

- **`terraform init -migrate-state` for the runner failed with `no route to
  host` reaching MinIO — turned out to be an unrelated host-level network
  incident, not a backend/credentials problem.** A hard power loss (dead
  laptop battery, no UPS) took the whole nested Proxmox VM down; `dial tcp
  ...: connect: no route to host` on the MinIO bucket was a downstream
  symptom of the VM being unreachable, not anything wrong with the S3
  backend config itself. See the next two entries for the actual root
  cause and fix; `-migrate-state` succeeded cleanly once the underlying
  network path was restored.

- **LVM thin pool exhaustion (`lvcreate` / `Cannot create new thin volume`)
  during a clone.** Sum of virtual disk sizes across nodes, runner, and the
  MinIO container comfortably exceeds the actual thin-pool size on this
  nested setup — `pvesm status` showed `local-lvm` at 100% before this hit.
  An orphaned VM from the runner self-destruct incident (disk never
  cleaned up because the destroy never completed) was eating 20GB it no
  longer needed. Fixed by removing the orphan (`qm destroy <id> --purge`)
  and extending the thin pool into the volume group's free space
  (`lvextend -l +100%FREE pve/data`). Worth periodically checking `lvs pve`
  against `qm list` for orphaned disks whenever a `destroy`/`apply` gets
  interrupted.

- **Thin pool exhaustion recurred from natural growth, not an orphan this
  time — and took down every VM plus the state backend simultaneously.**
  With no orphaned disk left to blame, ordinary data growth across the
  four thin volumes eventually refilled `pve/data` to 100% again. Unlike
  the earlier incident, this hit the pool while everything was live and
  running unattended overnight: `dmesg` showed `EXT4-fs` write errors on
  every VM's disk simultaneously (`I/O error 3 writing to inode ...`), and
  `qm`/`pct` reboots issued in response all failed with
  `VM quit/powerdown failed - got timeout` because the guest agent itself
  couldn't respond over a filesystem that could no longer write. CT 200
  (MinIO) took the worst of it — its journal aborted
  (`EXT4-fs error: Journal has aborted`) badly enough that
  `pct exec 200 -- systemctl status minio` failed outright with
  `lxc-attach: Input/output error`, since even `exec`-ing a command
  requires a working root filesystem. Recovered by: stopping every
  VM/CT (`qm stop <id>`, `pct stop 200`) to halt further writes,
  `lvextend -l +100%FREE pve/data` (there was still ~7GB of free space in
  the volume group itself — `vgs pve`'s `VFree` — that the pool had never
  been extended into), `pct fsck 200` to repair the aborted journal (ran
  clean on the second pass), then starting everything back up. **Two
  follow-ups landed as a direct result:** `scripts/proxmox-init.sh` now
  sets `activation { thin_pool_autoextend_threshold = 80 }` in
  `/etc/lvm/lvm.conf` so this surfaces as an early LVM warning instead of
  a silent slide into I/O errors at 100%; and the underlying overcommit is
  still real — `lvextend`'s own output after this incident
  (`Sum of all thin volume sizes (<61.52 GiB) exceeds the size of thin
  pool pve/data and the size of whole volume group (<59.50 GiB)`) means
  the *ceiling* the pool can be extended to is now the actual bottleneck,
  not a one-off cleanup. Recurs whenever real usage catches up again;
  `pvesm status` / `lvs pve` should be the first thing checked on any
  simultaneous multi-VM `io-error`, ahead of anything guest-side.

- **Concurrent full-clones on the nested setup are unreliable.**
  `terraform apply` with default parallelism clones all node VMs at once;
  on this nested single-disk setup that meant heavy I/O contention — one
  clone finished in ~2 minutes while a sibling clone took 15+ minutes and
  ultimately timed out waiting for the QEMU guest agent (the VM was still
  mid-clone/mid-boot, agent never got a chance to start). Fixed by using
  `terraform apply -parallelism=1` for node provisioning — slower overall,
  but each clone gets the disk to itself.

- **`qemu-guest-agent` not running → 15-minute `apply` timeout.** The Ubuntu
  cloud image ships the agent package but doesn't enable it by default.
  Fixed by pushing a cloud-init snippet (now
  `modules/proxmox-vm/templates/user-data.yml.tpl`) that installs and
  enables it via `runcmd`, instead of relying on the base image.

- **A heavy `packages:` list delays guest-agent startup enough to blow the
  apply timeout anyway.** Once the runner started installing `docker.io`,
  `ansible`, and friends via cloud-init's `packages:` list, the guest agent
  (also only enabled via `runcmd`, which runs *after* the `packages:`
  stage completes) didn't come up until the whole apt run finished —
  10+ minutes on this nested setup, well past what looked like a hang.
  Fixed by never putting heavy packages in `packages:` at all: only
  `qemu-guest-agent` is installed there (fast, and gets the agent up within
  the first ~30 seconds of boot), everything else (`docker.io`, `ansible`,
  etc.) moves to `runcmd` as an explicit `apt-get install`, which runs
  after the agent is already live and reporting to Terraform.

- **`write_files` failed silently with `KeyError: getpwnam(): name not
  found: 'ubuntu'`.** cloud-init's `write_files` module runs in the
  `init-network` stage, which happens *before* the `users` module creates
  any configured users — so `owner: ubuntu:ubuntu` on a `write_files` entry
  fails to `chown` a user that doesn't exist yet, and the whole module
  aborts (the file is never written, only a warning is logged — easy to
  miss). Fixed by always writing `write_files` entries as `root:root`, then
  `chown`ing them to the real target owner in `runcmd` (which *does* run
  after user creation) — see the `write_files`/`chown` pairing in
  `modules/proxmox-vm/templates/user-data.yml.tpl`.

- **`packages: None is not of type 'array'` — cloud-init schema validation
  failure when `extra_packages` is empty.** Rendering `packages:` with the
  Terraform `for` loop but zero items produces a bare `packages:` key with
  nothing under it, which YAML reads as `null`, not an empty list — cloud-init's
  schema requires an array. This affects any VM with `extra_packages = []`
  (i.e. every node, since only the runner and minecraft-node set packages).
  Fixed by wrapping the whole `packages:` block in
  `%{ if length(extra_packages) > 0 ~}`, so the key is omitted entirely
  rather than emitted empty.

- **Multi-line `write_files` content breaks YAML if the block literal's
  first line isn't indented.** Terraform's `indent(n, string)` indents every
  line of a string *except the first* — so `content: |` followed directly by
  `${indent(6, f.content)}` put the first line of the content at column 0
  instead of the block's indent level, which either corrupts the whole
  cloud-config parse (`could not find expected ':'`, with everything after
  silently dropped as `empty cloud config`) or, in a milder case, just fails
  schema validation for that one `write_files` entry. Fixed by adding the
  indent manually before the interpolation: `      ${indent(6, f.content)}`
  (6 literal spaces, since `indent()` only covers lines 2+).

- **HashiCorp's Terraform CLI distribution (both
  `apt.releases.hashicorp.com` and `releases.hashicorp.com`, which GitHub
  Releases pages for Terraform link back to) is blocked for RU/BY IPs since
  2022.** The `.terraformrc` network mirror already in use only covers
  *provider* downloads via `terraform init`, not the CLI binary itself —
  installing `terraform` via HashiCorp's apt repo or a direct GitHub
  Releases URL both fail outright from this network. Worked around by
  downloading the binary once over a VPN and re-hosting it on the
  self-hosted MinIO instance (`tools/` prefix, anonymous-download bucket
  policy); the runner's `extra_runcmd` pulls it from there instead. See
  [Runner host prerequisites](#runner-host-prerequisites-automated-via-cloud-init).

- **MinIO client's old download path
  (`dl.min.io/client/mc/release/linux-amd64/mc`) now serves a small HTML
  page instead of the binary**, following MinIO's AIStor rebrand — a plain
  `curl -o mc <url>` without `-L` silently saves the HTML as if it were the
  binary (141 bytes, `file` reports `HTML document`), and the resulting
  "binary" fails with a bash parse error when executed. Fixed by switching
  to the current path, `https://dl.min.io/aistor/mc/release/linux-amd64/mc`.

- **Node VMs (and, before the serial console fix, the runner) had no usable
  serial console.** The Terraform-managed VM resources didn't set an
  explicit `serial_device`/`vga` block, unlike the golden image (VM 9000,
  provisioned with `--serial0 socket --vga serial0` in `proxmox-init.sh`),
  so `qm terminal <vmid>` connected but showed nothing useful — diagnosis
  had to go through the Proxmox web UI's VNC console instead. Fixed by
  adding the same `serial_device`/`vga` blocks to `modules/proxmox-vm`
  (requires the `VM.Config.HWType` privilege — see the role table above).
  Two remaining quirks worth knowing, not bugs:
  - `qm terminal <vmid>` needs a real TTY on the client side — `ssh
    proxmox-lab 'qm terminal <vmid>'` fails with `tcgetattr: Inappropriate
    ioctl for device`; `ssh -t proxmox-lab 'qm terminal <vmid>'` works.
  - Console login always rejects any password, by design — cloud-init only
    sets `ssh_authorized_keys` for `ubuntu`, never a password, so the
    account is locked for password auth. `Login incorrect` on the serial
    console is expected; use SSH with the key instead. Reaching this login
    prompt at all is actually a *good* sign — it means the VM booted fully
    past init/network/multi-user.target.

- **`user_account` block vs `user_data_file_id`.** These both generate
  cloud-init user-data; setting `user_data_file_id` takes over entirely, so
  the SSH user/key need to live in the snippet template, not in a separate
  `user_account` block — leaving both in caused silent conflicts.

- **Nested-bridge network jitter.** Pinging the nested Proxmox VM from a
  machine two hops away (over Wi-Fi → router → host) showed heavy jitter
  (single-digit ms up to ~3s). Confirmed as a Wi-Fi hop issue, not the
  bridge/nested-KVM setup — pinging from the physical host itself was
  consistently sub-millisecond.

- **`br0` loses its physical-NIC attachment after a nested-VM
  teardown/host reboot.** `enp4s0` reverts to a standalone `auto` NM
  profile, leaving `br0` up but carrier-less (`NO-CARRIER`) and the nested
  Proxmox VM completely unreachable (`no route to host`, even though the VM
  itself boots fine — its `vnet` interface just has nowhere to send
  traffic). Fixed with a guard in `install-proxmox-with-libvirt.sh` that
  checks `br0`'s state and `br0-port`'s attachment before every run and
  reattaches `enp4s0` if needed — see the script for the exact `nmcli`
  checks. Running it may briefly drop the current SSH session (expected,
  since `enp4s0` is being reparented); just reconnect and re-run.

- **`deploy` job hit a `dpkg` lock race and an intermittently unreachable
  node, both traced to the same root cause: node VMs report "provisioned"
  before cloud-init has actually finished.** `wait_for_ip_disabled = true`
  on the node module means `terraform apply` returns as soon as the VM is
  cloned, without waiting for SSH or cloud-init completion. On one run,
  `dev-node` (cloned last) wasn't SSH-reachable yet when Ansible connected;
  on another, the `docker` role's `apt-get install docker.io` collided
  with cloud-init's own `apt-get install qemu-guest-agent` running
  concurrently on the same node, and the loser failed on
  `dpkg`'s lock-frontend. Manually checking the "unreachable" node moments
  later showed it fully up — the pipeline just hadn't waited the extra
  seconds cloud-init needed. Fixed by adding a `Wait for nodes to finish
  booting` step in `pipeline.yml`'s `deploy` job, between installing
  Ansible collections and running the playbook: polls each host's SSH port
  first, then blocks on `cloud-init status --wait` over SSH, so `apt` on
  the node is guaranteed free before the `docker`/`github-runner` Ansible
  roles touch it.

- **`deploy` job's `github-runner` Ansible role failed silently on a
  registration-token 404, because the workflow never set `GITHUB_REPO`.**
  The role reads both `GITHUB_REPO` and `GITHUB_PAT` from the environment
  (`lookup('env', ...)`), but `pipeline.yml`'s `env:` block only ever had
  `BASE_REGISTRY`. With `github_repo` empty, the registration-token request
  went to `.../repos//actions/runners/registration-token`, GitHub returned a
  non-201 status, and the `uri` module failed the task — but the actual
  response body was hidden because the *whole task* (not just the token
  taskss) had `no_log: true`. Fixed by adding `GITHUB_REPO:
  Tsuyakashi/swarm-lab` alongside `GITHUB_PAT` in `pipeline.yml`'s `env:`
  block. Lesson: when a `no_log: true` task fails opaquely, temporarily
  register the result and drop `no_log` on that one task rather than
  guessing — two earlier guesses here (missing runner dependencies) were
  both wrong.

- **`Configure runner` failed with `Permission denied:
  '/root/actions-runner'` even though the files were downloaded to
  `/home/<user>/actions-runner`.** The `Setup GitHub Actions runner` play
  in `swarm-lab/ansible/site.yml` runs with `become: true` at the play
  level, which applies to `Gathering Facts` too — so
  `ansible_env.HOME` resolves to `/root`, not the SSH user's home. A
  `runner_dir` default built from `ansible_env.HOME` therefore pointed at
  `/root/actions-runner` for the `become_user: <ssh-user>` task, even
  though the directory-creation tasks (running as root, then chowned)
  had populated `/home/<user>/actions-runner`. Fixed by building
  `runner_dir` explicitly as `/home/{{ ansible_user }}/actions-runner`
  in `github-runner/defaults/main.yml` instead of trusting
  `ansible_env.HOME` inside a `become: true` play.

- **The `docker` and `github-runner` Ansible roles hardcoded the `vagrant`
  user**, a leftover from the original `vagrant up` flow (Vagrant boxes
  auto-provision a `vagrant` system user). Nodes provisioned by this repo's
  Terraform + cloud-init use `ubuntu` instead (see
  `modules/proxmox-vm/templates/user-data.yml.tpl`), and `vagrant` only
  existed on them as an *accidental* side effect of the `user:` task in the
  `docker` role (which happened to create it, since it wasn't
  `state: absent`). Fixed by parameterizing both roles on `ansible_user`
  (already correctly populated per-host by both the Vagrant provisioner
  and `templates/inventory.tpl`), so neither role assumes a specific
  provisioning flow anymore.

- **`vnet0` (the VM's own libvirt bridge port) doesn't reattach to `br0`
  automatically after a hard power loss.** Different failure from the
  `br0`/`enp4s0` case above — the physical NIC stayed correctly attached
  throughout, but `virsh domiflist` still reported `vnet0` as belonging to
  `br0` while `brctl show br0` didn't list it as an actual port. Symptom:
  `ip neigh show <proxmox-ip>` stuck on `FAILED`, `arp -n` showed
  `(incomplete)`, and `arping` got zero responses — all pointing at an L2
  problem between host and VM, even though both `br0` and `vmbr0` (inside
  the VM) showed `state UP` with correct addresses. Confirmed the VM's own
  network was fine via `tcpdump -i vmbr0 -n arp` from inside the VM's
  console (still saw ARP traffic from the guest VMs/CTs). Fixed with
  `brctl addif br0 vnet0` — but a newly added bridge port starts in STP
  `listening`/`learning` state and doesn't forward traffic until it reaches
  `forwarding` (~15-30s with default timers, check via `brctl showstp br0`),
  so don't assume the fix failed just because ping still fails immediately
  after `addif`. `install-proxmox-with-libvirt.sh`'s existing guard only
  checked the physical-NIC side of the bridge; extended it to also check
  and reattach `vnet0`.

- **MinIO CT's DHCP address isn't stable across restarts.** Unlike nodes,
  which pin their address via cloud-init static config (a specific
  `mac_address` + `ip_config`), `minio-lxc-init.sh` originally created CT
  200 with `ip=dhcp`. The address drifted at least twice
  (`192.168.100.13` → `192.168.100.10` → `192.168.100.100`), surfacing
  indirectly and unhelpfully each time: `backend.tf` in every environment
  silently pointed at a dead IP (`no route to host` on `terraform init`),
  and the hardcoded MinIO URL in `environments/runner/main.tf`'s
  `extra_runcmd` (for pulling the `terraform`/`mc` binaries) went stale
  right along with it — three separate places that had to be manually
  re-synced by hand after noticing, with no single point that would have
  caught the drift earlier. Root cause was almost certainly one of the
  hard-power-loss incidents on the host (see the `vnet0` and thin-pool
  entries above) restarting CT 200 and having the DHCP lease land
  differently. Fixed by pinning a static IP for CT 200 in
  `minio-lxc-init.sh` (`ip=<addr>/24,gw=<gateway>` on `net0`, same pattern
  nodes already use), with an idempotent guard so re-running the script
  against an already-existing CT on a stale DHCP config corrects it
  (`pct set` + reboot) instead of silently doing nothing. Now standardized
  on `192.168.100.100` across all environments' `backend.tf`.

## Status

- [x] Nested Proxmox VE running, reachable on the LAN
- [x] `bpg/proxmox` provider authenticated (API token + SSH key)
- [x] Golden image template (cloud-init–ready Ubuntu 24.04)
- [x] End-to-end `terraform apply` — clone, cloud-init, guest agent, IP
      assignment all working
- [x] Runner split into an independent root module with its own backend
- [x] State backend (MinIO/CT 200) moved off both the runner and the node
      VMs it describes, and pinned to a static IP (`192.168.100.100`) so it
      doesn't drift on restart
- [x] Runner state migrated from a local backend onto the same MinIO
      bucket as the nodes (separate `runner/` key) — protects against
      laptop/disk loss while the runner VM itself keeps running, distinct
      from the Proxmox-loss case a local backend never protected against
      anyway
- [x] Full `provision` → `deploy` pipeline green end-to-end: Terraform
      provisions nodes, Ansible (pinned `swarm-lab` tag) bootstraps Docker,
      Swarm, stack deploy, and self-hosted runner registration, all
      unattended — including an explicit wait for node boot/cloud-init
      completion before Ansible touches a node (see Troubleshooting notes)
- [x] `docker`/`github-runner` Ansible roles are provisioning-flow
      agnostic (`ansible_user`-driven), no more hardcoded `vagrant`
- [x] Node/runner VM provisioning extracted into a reusable module
      (`modules/proxmox-vm`) shared by every root module — no more
      duplicated resource blocks between environments.
      Node *count* is still driven by each environment's `var.nodes` map
      default (not yet parameterized from outside the module/environment),
      so adding a node today still means editing that default rather than
      passing in a wholly external topology.
- [x] Node/runner VMs have an explicit serial console (`serial_device`/`vga`
      blocks, matching the golden image), so `qm terminal <vmid>` is a
      reliable diagnosis path instead of a blank screen — closed alongside
      the `VM.Config.HWType` privilege it requires.
- [x] Runner host prerequisites folded into `runner/`'s cloud-init via the
      module's `extra_packages`/`extra_runcmd`/`write_files`/`docker_group`
      inputs — a runner recreate needs no manual dependency pass anymore.
      Working around the regional block on HashiCorp's Terraform CLI
      distribution required re-hosting the binary on the self-hosted MinIO
      instance (`tools/` bucket) rather than fetching it directly.
- [x] `scripts/register-github-runner.sh` installs/re-registers the
      GitHub Actions runner agent itself on `ci-runner` — kept as a
      separate, manually-run step (not cloud-init) because GitHub's
      registration token is one-time-use and expires in ~1 hour, so it
      can't be baked into a template that might apply at an unknown
      later time.
- [x] LVM thin pool exhaustion on the host is now caught early —
      `proxmox-init.sh` sets `thin_pool_autoextend_threshold = 80` — but
      the underlying overcommit (sum of thin volumes vs. actual VG size)
      is structural, not fully resolved; recurs whenever real disk usage
      catches up. Revisit node/runner `disk_size` sizing, or add another
      physical disk to the thin pool, before this needs a third manual
      recovery.
- [x] `environments/minecraft-node` added — isolated node (own NAT
      segment, no LAN access), manually applied, short-lived by design.
- [x] `environments/poly-nodes` added — infra for
      [`poly-ci`](https://github.com/tsuyakashi/poly-ci), same shape as
      `nodes/`. Blocked on the second golden image (VM 9001), which lives
      on a currently-flaky HDD (`hdd-storage`) — verified working when
      pointed at SSD storage instead, so this is WIP pending a decision on
      that disk.
- [ ] Migrate onto dedicated hardware once available
- [x] `swarm-lab`'s `Vagrantfile` stays — deliberately kept so `swarm-lab`
      remains a fully independent, self-contained project that can be spun
      up on its own hardware without this repo. This repo is a separate,
      Proxmox-specific provisioning path, not a replacement for it.
