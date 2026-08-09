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
┌─────────────────────────────────────────────────────────────────┐
│ G750JX (physical host, 24GB RAM / 8 cores)                      │
│                                                                 │
│  br0 (NetworkManager bridge, bound to enp4s0 → LAN)             │
│   │                                                             │
│   └── proxmox-lab (KVM/libvirt VM, nested virtualization)       │
│         18GB RAM / 6 vCPU, host-passthrough CPU                 │
│         Proxmox VE 8.4, reachable at 192.168.100.20:8006        │
│          │                                                      │
│          └── vmbr0 (Proxmox-internal bridge, port: enp1s0)      │
│               │                                                 │
│               ├── VM 9000: ubuntu-cloud-template (golden image) │
│               ├── CT 200: minio (LXC, systemd daemon)           │
│               │     — Terraform state backend, NOT managed      │
│               │       by Terraform itself                       │
│               ├── VM: ci-runner (root module: environments/runner/) │
│               │     — GitHub Actions self-hosted runner         │
│               └── VM: prod-node / stage-node / dev-node         │
│                     (root module: environments/nodes/)          │
└─────────────────────────────────────────────────────────────────┘
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
  itself. `environments/runner/` uses a local backend (state file lives
  with the runner's own lifecycle, not S3) since it's touched rarely and by
  hand.
- `pipeline.yml`'s `paths: ['environments/nodes/**', 'modules/**']` filter
  means pushes under `environments/runner/**` don't trigger the CI job on
  the nodes — this was true before the split too, but now it's structurally
  reinforced rather than accidental. Changes under `modules/**` *do*
  trigger it, since `environments/nodes` depends on that module.

### State backend lives off both

Terraform state for the node module (`backend.tf`, S3-compatible) points at
MinIO running in **CT 200**, an LXC container on the Proxmox host — not a
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

## Stack

- **Proxmox VE 8.4** — hypervisor
- **Terraform** + [`bpg/proxmox`](https://github.com/bpg/terraform-provider-proxmox)
  provider (chosen over `Telmate/proxmox` — more actively maintained, fuller
  API coverage)
- **cloud-init** — VM bootstrapping (user creation, SSH keys, package install)
- **Ubuntu 24.04 (Noble) cloud image** — golden template, cloned per VM
- **MinIO** (LXC, systemd daemon, no Docker) — S3-compatible Terraform state
  backend, independent of both the runner and the node VMs
- **Ansible** — post-provision configuration, delegated to
  [`swarm-lab`](../swarm-lab)'s playbook via a pinned git tag (see
  [CI/CD](#cicd) below)

## Repo layout

Standard `modules/` + `environments/` split. `modules/proxmox-vm` is the one
reusable building block — a single cloned VM with a cloud-init snippet — and
both root modules (`environments/nodes`, `environments/runner`) call it. The
module owns no backend and no provider config; each environment configures
those independently, which is what actually enforces the state/lifecycle
separation described below (not just a folder convention).

```
modules/
└── proxmox-vm/                       # reusable module — no backend, no provider block
    ├── main.tf                       #   VM + cloud-init file resource
    ├── variables.tf                  #   name, sizing, ip_config (static|dhcp), ssh keys...
    ├── versions.tf                   #   required_version + required_providers
    ├── outputs.tf                    #   vm_id, ipv4_addresses
    ├── README.md
    └── templates/user-data.yml.tpl   #   cloud-init template (users, packages, guest agent)

environments/
├── nodes/                            # ROOT MODULE — prod/stage/dev nodes
│   ├── main.tf                       #   for_each over var.nodes -> module "node"
│   ├── variables.tf                  #   incl. the "nodes" topology map
│   ├── outputs.tf                    #   node_ids, node_ips, inventory_path
│   ├── providers.tf
│   ├── backend.tf                    #   S3 (MinIO/CT 200)
│   ├── terraform.tfvars.example
│   └── templates/inventory.tpl       #   ansible inventory template (used only here)
└── runner/                           # ROOT MODULE — CI runner, own state/lifecycle
    ├── main.tf                       #   single module "ci_runner" call, dhcp
    ├── variables.tf
    ├── outputs.tf                    #   ci_runner_ip
    ├── providers.tf
    ├── backend.tf                    #   local backend — applied manually, not from CI
    └── terraform.tfvars.example

.github/workflows/pipeline.yml        # provision (terraform, environments/nodes) + deploy (ansible)
scripts/
├── install-proxmox-with-libvirt.sh   # host-side: creates the nested Proxmox VM
├── proxmox-init.sh                   # Proxmox-side: terraform user/role/token, golden image
└── minio-lxc-init.sh                 # Proxmox-side: MinIO LXC (state backend), NOT terraform-managed
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
  state file**, it's not a no-op rename. Performed by hand on this repo's own state during PR #23.
- Moving the VM/cloud-init resources into `modules/proxmox-vm` also meant
  they picked up new state addresses (`module.node["..."]....` instead of
  the old flat `proxmox_virtual_environment_vm.node["..."]`). Adopting this
  layout on existing state needs `moved` blocks mapping the old addresses
  to the new ones — otherwise Terraform reads the rename as
  destroy-old/create-new and will happily recreate every live VM. Add them
  temporarily, `apply` once, then they can be deleted. This is exactly what was done here — the blocks were added, applied once with no destroy/create in the plan, then removed.

## Quickstart

### 1. Stand up the nested Proxmox VM (on the physical host)

```bash
./scripts/install-proxmox-with-libvirt.sh
```

Checks KVM acceleration and nested virtualization are available, downloads
the Proxmox VE ISO, and creates the VM via `virt-install`. Idempotent — safe
to re-run.

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
token, and the `ubuntu-cloud-template` (VM 9000) golden image. Idempotent.

The API token secret is printed to `/root/terraform-token.json` on first
run — copy it into `terraform.tfvars`, then consider deleting that file from
the host. (Plaintext-on-disk is an acceptable trade-off for a local lab; a
production setup would push this into Vault or similar instead.)

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
systemd service. Not a Terraform resource by design — see
[Architecture](#state-backend-lives-off-both) above. Prints the S3 endpoint
and console URL on success.

Then, via the printed console URL, create a bucket named
`iac-proxmox-lab-tfstate` and update `endpoints.s3` in
`environments/nodes/backend.tf` to match the printed IP if it differs from
what's currently committed.

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
terraform init
terraform apply
```

Always run this by hand, never from the self-hosted runner's own CI job —
that's the whole point of the split. See
[Architecture](#two-independent-root-modules-on-purpose).

### 7. Runner host prerequisites (manual, not yet automated)

The golden image / cloud-init only sets up the SSH user and
`qemu-guest-agent` — everything the CI job (`pipeline.yml`) actually needs
to run has to be installed by hand on the runner VM after every
`terraform apply` in `runner/`. Forgetting a step here is what actually
burned a handful of pipeline re-runs, so: check this list before assuming
the pipeline itself is broken.

Required on the runner VM:

- **`terraform`** — plus a `~/.terraformrc` with a network mirror, since
  direct access to `registry.terraform.io` from this network isn't
  reliable enough for unattended CI runs:

  ```hcl
  # ~/.terraformrc
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

- **`docker.io`** — the GitHub Actions runner binary itself doesn't need
  it, but nothing in the job currently does either; kept installed as a
  baseline for anything Docker-adjacent added later.
- **`curl`**, **`jq`** — used by the GitHub Actions runner scripts and
  handy for ad-hoc debugging inside jobs.
- **`ansible`** (`ansible-playbook`, `ansible-galaxy`) — runs the `deploy`
  job's playbook from `swarm-lab`.
- **MinIO client** — for poking at the state bucket (list objects, sanity
  checks) from the runner without going through the Proxmox host.

Quick check after any runner recreate:

```bash
which terraform ansible ansible-playbook ansible-galaxy docker
```

All five should resolve. If any are missing, the `pipeline.yml` job will
fail well into the run (often after checkout/artifact steps already
succeeded), which reads like a pipeline bug rather than a missing package —
check this list first.

This isn't scripted yet — see [Status](#status) — a natural next step is
folding these into `runner/`'s cloud-init template or a small
provisioning script run once per runner recreate.

## CI/CD

`.github/workflows/pipeline.yml` runs two jobs on the self-hosted runner,
triggered on `workflow_dispatch` or a push to `main` touching
`environments/nodes/**` or `modules/**` (the latter because
`environments/nodes` depends on `modules/proxmox-vm` — a module change
needs the same `apply` as an environment change; see
[Architecture](#two-independent-root-modules-on-purpose)). Pushes under
`environments/runner/**` deliberately do **not** trigger this workflow —
the runner is applied by hand, never from its own CI job.

1. **provision** — `terraform apply` against the `environments/nodes` root
   module, producing `environments/nodes/inventory.ini` via the `local_file`
   resource and uploading it as a build artifact.
2. **deploy** — checks out this repo (for `inventory.ini`) alongside a
   **pinned tag** of [`swarm-lab`](../swarm-lab) (currently `v0.3.3`, set via
   `ref:` in the `Checkout swarm-lab` step), then runs
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

- **Concurrent full-clones on the nested setup are unreliable.**
  `terraform apply` with default parallelism clones all node VMs at once;
  on this nested single-disk setup that meant heavy I/O contention — one
  clone finished in ~2 minutes while a sibling clone took 15+ minutes and
  ultimately timed out waiting for the QEMU guest agent (the VM was still
  mid-clone/mid-boot, agent never got a chance to start). Fixed by using
  `terraform apply -parallelism=1` for node provisioning — slower overall,
  but each clone gets the disk to itself.

- **Node VMs have no usable serial console.** Unlike the golden image (VM
  9000, provisioned with `--serial0 socket --vga serial0` in
  `proxmox-init.sh`), the Terraform-managed node/runner VM resources don't
  set an explicit `serial_device`/`vga` block, so `qm terminal <vmid>`
  connects but shows nothing useful. When a guest fails to come up (dead
  network, cloud-init stuck) and the QEMU agent is unreachable, diagnosis
  has to go through the Proxmox web UI's VNC console instead of
  `qm terminal` over SSH.

- **`qemu-guest-agent` not running → 15-minute `apply` timeout.** The Ubuntu
  cloud image ships the agent package but doesn't enable it by default.
  Fixed by pushing a cloud-init snippet (now
  `modules/proxmox-vm/templates/user-data.yml.tpl`) that installs and
  enables it via `runcmd`, instead of relying on the base image.

- **`user_account` block vs `user_data_file_id`.** These both generate
  cloud-init user-data; setting `user_data_file_id` takes over entirely, so
  the SSH user/key need to live in the snippet template, not in a separate
  `user_account` block — leaving both in caused silent conflicts.

- **Nested-bridge network jitter.** Pinging the nested Proxmox VM from a
  machine two hops away (over Wi-Fi → router → host) showed heavy jitter
  (single-digit ms up to ~3s). Confirmed as a Wi-Fi hop issue, not the
  bridge/nested-KVM setup — pinging from the physical host itself was
  consistently sub-millisecond.

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

## Status

- [x] Nested Proxmox VE running, reachable on the LAN
- [x] `bpg/proxmox` provider authenticated (API token + SSH key)
- [x] Golden image template (cloud-init–ready Ubuntu 24.04)
- [x] End-to-end `terraform apply` — clone, cloud-init, guest agent, IP
      assignment all working
- [x] Runner split into an independent root module with its own backend
- [x] State backend (MinIO/CT 200) moved off both the runner and the node
      VMs it describes
- [x] Full `provision` → `deploy` pipeline green end-to-end: Terraform
      provisions nodes, Ansible (pinned `swarm-lab` tag) bootstraps Docker,
      Swarm, stack deploy, and self-hosted runner registration, all
      unattended
- [x] `docker`/`github-runner` Ansible roles are provisioning-flow
      agnostic (`ansible_user`-driven), no more hardcoded `vagrant`
- [x] Node/runner VM provisioning extracted into a reusable module
      (`modules/proxmox-vm`) shared by both root modules — no more
      duplicated resource blocks between `nodes.tf` and `runner/runner.tf`.
      Node *count* is still driven by the `var.nodes` map's default value
      (not yet parameterized from outside the module/environment), so
      adding a node today still means editing that default rather than
      passing in a wholly external topology.
- [ ] Migrate onto dedicated hardware once available
- [x] `swarm-lab`'s `Vagrantfile` stays — deliberately kept so `swarm-lab`
      remains a fully independent, self-contained project that can be spun
      up on its own hardware without this repo. This repo is a separate,
      Proxmox-specific provisioning path, not a replacement for it.
- [ ] Give node/runner VMs an explicit serial console for consistency with
      the golden image and easier diagnosis when the guest agent is
      unreachable
- [ ] Fold runner host prerequisites (§7) into `runner/`'s cloud-init or a
      provisioning script, so a runner recreate doesn't need a manual
      dependency pass
