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
│               └── Terraform-managed guest VMs (cloned from 9000)│
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

## Stack

- **Proxmox VE 8.4** — hypervisor
- **Terraform** + [`bpg/proxmox`](https://github.com/bpg/terraform-provider-proxmox)
  provider (chosen over `Telmate/proxmox` — more actively maintained, fuller
  API coverage)
- **cloud-init** — VM bootstrapping (user creation, SSH keys, package install)
- **Ubuntu 24.04 (Noble) cloud image** — golden template, cloned per VM

## Repo layout

```
providers.tf                          # Terraform + Proxmox provider config
variables.tf                          # input variable declarations
vm.tf                                 # cloud-init snippet upload + VM resource
terraform.tfvars.example              # copy to terraform.tfvars, fill in secrets
cloud-init/user-data.yml.tpl          # cloud-init template (users, packages, guest agent)
scripts/install-proxmox-with-libvirt.sh  # host-side: creates the nested Proxmox VM
scripts/proxmox-init.sh               # Proxmox-side: terraform user/role/token, golden image
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

### 4. Provision

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in endpoint, token, SSH key
terraform init
terraform apply
```

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
      assignment all working (~80s)
- [ ] Move from a single test VM to a reusable module (variable count,
      per-VM naming/IP)
- [ ] Migrate onto dedicated hardware once available
- [ ] Consider using this as the provisioning layer for `swarm-lab` /
      `poly-ci` node VMs, replacing their current Vagrant setup
