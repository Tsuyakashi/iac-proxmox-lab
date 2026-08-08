# IAC Proxmox Lab

Infrastructure-as-Code lab for provisioning VMs on Proxmox VE using Terraform.
Built as a bare-metal/self-hosted counterpart to cloud-focused IaC work —
replaces Vagrant (dev-grade local provisioning) with a Proxmox + Terraform
stack closer to how bare-metal infrastructure is actually managed.

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
│               ├── VM: ci-runner (root module: runner/)          │
│               │     — GitHub Actions self-hosted runner         │
│               └── VM: prod-node / stage-node / dev-node         │
│                     (root module: repo root, nodes.tf)          │
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

The repo root (`nodes.tf`) and `runner/` are **two separate Terraform root
modules**, each with its own backend, state, and lifecycle. This is not
incidental structure — it's the fix for an actual incident: the CI runner
used to live in the same state/config as the nodes it provisions. A routine
change to the shared cloud-init template forced a replace on every resource
in one `apply`, including the runner VM — which destroyed itself mid-job
while running that very `apply`. See
[Troubleshooting notes](#troubleshooting-notes-things-that-actually-broke)
below for the full story.

Consequences of the split:
- `terraform apply` in the repo root never touches the runner, and vice
  versa — no shared blast radius.
- The runner is applied **manually, from a laptop**, never from CI on
  itself. `runner/` uses a local backend (state file committed to the
  runner's own lifecycle, not S3) since it's touched rarely and by hand.
- `pipeline.yml`'s `paths: ['*.tf', ...]` filter is non-recursive, so pushes
  under `runner/**` don't trigger the CI job on the nodes — this was true
  before the split too, but now it's structurally reinforced rather than
  accidental.

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

## Repo layout

```
nodes.tf                              # node VMs (prod/stage/dev) + ansible inventory generation
providers.tf                          # Terraform + Proxmox provider config (repo-root module)
variables.tf                          # input variable declarations (repo-root module)
backend.tf                            # S3 (MinIO/CT 200) backend config
terraform.tfvars.example              # copy to terraform.tfvars, fill in secrets
cloud-init/user-data.yml.tpl          # shared cloud-init template (users, packages, guest agent)
templates/inventory.tpl               # ansible inventory template
runner/                               # SEPARATE root module — own state, own backend, own lifecycle
├── runner.tf                         #   ci-runner VM + its cloud-init file resource
├── providers.tf                      #   copy of the root provider config
├── variables.tf                      #   only the vars runner.tf actually needs
├── backend.tf                        #   local backend — applied manually, not from CI
└── terraform.tfvars.example
scripts/
├── install-proxmox-with-libvirt.sh   # host-side: creates the nested Proxmox VM
├── proxmox-init.sh                   # Proxmox-side: terraform user/role/token, golden image
└── minio-lxc-init.sh                 # Proxmox-side: MinIO LXC (state backend), NOT terraform-managed
```

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
`iac-proxmox-lab-tfstate` and update `endpoints.s3` in `backend.tf` to match
the printed IP if it differs from what's currently committed.

### 5. Provision the nodes

```bash
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
cd runner/
cp terraform.tfvars.example terraform.tfvars   # same values as the root tfvars
terraform init
terraform apply
```

Always run this by hand, never from the self-hosted runner's own CI job —
that's the whole point of the split. See
[Architecture](#two-independent-root-modules-on-purpose).

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
  runner into its own root module (`runner/`, own state, own backend,
  applied manually — see [Architecture](#two-independent-root-modules-on-purpose)).

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
  Fixed by pushing a cloud-init snippet (`cloud-init/user-data.yml.tpl`) that
  installs and enables it via `runcmd`, instead of relying on the base image.

- **`user_account` block vs `user_data_file_id`.** These both generate
  cloud-init user-data; setting `user_data_file_id` takes over entirely, so
  the SSH user/key need to live in the snippet template, not in a separate
  `user_account` block — leaving both in caused silent conflicts.

- **Nested-bridge network jitter.** Pinging the nested Proxmox VM from a
  machine two hops away (over Wi-Fi → router → host) showed heavy jitter
  (single-digit ms up to ~3s). Confirmed as a Wi-Fi hop issue, not the
  bridge/nested-KVM setup — pinging from the physical host itself was
  consistently sub-millisecond.

## Status

- [x] Nested Proxmox VE running, reachable on the LAN
- [x] `bpg/proxmox` provider authenticated (API token + SSH key)
- [x] Golden image template (cloud-init–ready Ubuntu 24.04)
- [x] End-to-end `terraform apply` — clone, cloud-init, guest agent, IP
      assignment all working
- [x] Runner split into an independent root module with its own backend
- [x] State backend (MinIO/CT 200) moved off both the runner and the node
      VMs it describes
- [ ] Move from a fixed node map to a reusable module (variable count,
      per-VM naming/IP)
- [ ] Migrate onto dedicated hardware once available
- [ ] Consider using this as the provisioning layer for `swarm-lab` /
      `poly-ci` node VMs, replacing their current Vagrant setup
- [ ] Give node/runner VMs an explicit serial console for consistency with
      the golden image and easier diagnosis when the guest agent is
      unreachable
