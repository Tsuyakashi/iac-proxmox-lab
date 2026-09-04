# Architecture

Full reasoning behind the cluster topology, the environment split, the
state backend, and the two passthrough patterns used across environments.
See [../README.md](../README.md) for the high-level diagram and quickstart,
and [history.md](history.md) for how this topology was arrived at (nested
→ bare metal, flat layout → modules).

## Architecture in depth

**Physical LAN topology, one level below the root diagram:** `bare-pve`
and `.3` (a Keenetic router) both uplink independently into `.1` — a
Промсвязь MT-PON-AT-4 GPON ONT acting as the L2 hub between them. The
Zenbook (`.12`) sits behind `.3`, not behind `bare-pve`. This matters for
new-host reachability — see the
[MT-PON-AT-4 entry](troubleshooting.md#the-ct-200-unreachable-until-pinged-behavior-generalizes-to-every-new-host)
in troubleshooting.md.

**Storage headroom differs by node, not a coincidence.** `pve-rog`'s
`local-lvm` thin pool has historically run close to its ceiling — the sum
of the nominal sizes of every thin volume on it has, more than once,
exceeded the pool's actual capacity, which is exactly the kind of thing
thin provisioning lets slide until real usage catches up. See the
[LVM thin pool entries](troubleshooting.md#lvm-thin-pool-exhaustion) in
troubleshooting.md for what happens when it does, and what's in place to
catch it early. `bare-pve` doesn't share this constraint (465GB SSD,
comfortably ahead of current usage) — it's also where the NFS
shared-storage export lives (`scripts/shared-storage-creation.sh`), for
exactly that reason.

`pve-rog` used to host `workstation` — a GUI-installed Ubuntu Desktop VM
driven from a local SPICE kiosk. That environment was removed from this
repo; GPU-passthrough desktop VMs now live in the dedicated
[`proxmox-hosted-workstation`](../../proxmox-hosted-workstation) repo
(`bare-pve` + GTX 950, whole-device passthrough via
`proxmox_hardware_mapping_pci`). The USB/hookscript/`qxl2` mechanics it
exercised are kept in [troubleshooting.md](troubleshooting.md) as reference.

The Zenbook runs `corosync-qnetd` and nothing else — no VMs, just a quorum
vote so the two real nodes survive either one going down without a
stuck-at-1-vote cluster. Note that the QDevice arbiter needs to be
reachable from `bare-pve` for its vote to count — if the arbiter isn't on
the LAN (e.g. travelling), it's reachable over Tailscale instead; see the
[QDevice/Tailscale entry](troubleshooting.md#recovering-a-lost-qdevice-arbiter-mid-cluster)
in troubleshooting.md for the mechanics and the chicken-and-egg gotcha it
has with a cluster that's already lost quorum.

## Two independent root modules, on purpose

`environments/nodes/` and `environments/runner/` are **two separate
Terraform root modules**, each with its own backend, state, and lifecycle,
both built from the same shared `modules/proxmox-vm`. This is not
incidental structure — it's the fix for an actual incident: the CI runner
used to live in the same state/config as the nodes it provisions. A routine
change to the shared cloud-init template forced a replace on every resource
in one `apply`, including the runner VM — which destroyed itself mid-job
while running that very `apply`. See
[troubleshooting.md](troubleshooting.md#the-self-hosted-runner-destroyed-itself-mid-apply)
for the full story.

Consequences of the split:
- `terraform apply` in `environments/nodes/` never touches the runner, and
  vice versa — no shared blast radius.
- The runner is applied **manually, from a laptop**, never from CI on
  itself. Both `environments/nodes/` and `environments/runner/` now use an
  S3 (MinIO) backend — the runner's state was migrated off `local` onto the
  same bucket (separate `key`), since the actual risk with a local backend
  wasn't Proxmox dying (in that case state is moot either way — the VMs
  are gone), but losing the laptop the runner is applied from while the
  runner VM itself keeps running. See the S3-migration
  [troubleshooting entries](troubleshooting.md#state-backend-became-unreachable-after-the-above)
  for the mechanics of that move.
- `pipeline.yml`'s `paths: ['environments/nodes/**', 'modules/**']` filter
  means pushes under `environments/runner/**` don't trigger the CI job on
  the nodes — this was true before the split too, but now it's structurally
  reinforced rather than accidental. Changes under `modules/**` *do*
  trigger it, since `environments/nodes` depends on that module.

## Other environments

Three more root modules live under `environments/`, all built on the same
`modules/proxmox-vm` as `nodes/`, none wired into `pipeline.yml` — all
applied manually, on demand:

- **`poly-nodes/`** — infra for a separate project,
  [`poly-ci`](https://github.com/tsuyakashi/poly-ci): runner/prod/monitoring
  nodes, structured the same way as `nodes/`. Node placement (API endpoint
  + golden image) resolves through `locals.tf` exactly like every other
  environment — `bare-pve` → template 9000, `pve-rog` → template 9001, both
  on that node's own `local-lvm`. There is no separate `hdd-storage`
  datastore anymore: an earlier iteration of this environment cloned VM
  9001 from a physical HDD in the pre-cluster nested setup, and that disk
  was flaky enough to keep this environment WIP for a while — that HDD has
  since been wiped and repurposed onto different hardware entirely, and
  9001 is just `pve-rog`'s regular golden image now, same as every other
  environment that clones from it. The remaining reasons this stays a
  separate, manually-applied environment are organizational, not
  infrastructural: it's `poly-ci`'s own topology/state, not part of
  `swarm-lab`'s always-up infra, and it follows a "spin up, test, tear
  down" workflow rather than staying persistently live — same as
  `minecraft-node` below, and why neither is wired into `pipeline.yml`.
- **`minecraft-node/`** — a single isolated node (own NAT segment, no
  access to the rest of the LAN) running a Minecraft server + playit.gg
  tunnel. Short-lived/situational by nature, not part of the core lab.
- **`immich-node/`** — a single VM (`bare-pve`, `local-lvm`) running Immich
  via plain `docker compose` (deliberately not swarm — `env_file`/
  `depends_on` don't survive `docker stack deploy`, and the whole workload
  is bind-mount/stateful, so swarm's node-portability doesn't apply here
  anyway). Migrated over from an ad-hoc `docker compose` setup on a
  non-Proxmox host after a disk-exhaustion incident there took down a
  cluster node in the process (see the
  [QDevice/Tailscale troubleshooting entry](troubleshooting.md#recovering-a-lost-qdevice-arbiter-mid-cluster)).
  Two things about this environment are worth knowing before touching it,
  both detailed in its own
  [`environments/immich-node/README.md`](../environments/immich-node/README.md)
  rather than duplicated here:
  - `cpu_type = "host"` is required, not cosmetic — the default module
    baseline (`kvm64`) lacks CPU flags (`sse4_2`/`popcnt`/`avx2`) that
    Immich's machine-learning container needs, and it restart-loops
    without them.
  - The photo library lives on a physical exFAT disk passed through to the
    VM as a raw block device (`qm set ... -scsi1 <device>,ro=1`), not a
    Terraform-managed datastore volume — `bpg/proxmox` has no declarative
    way to bind an existing physical device, so this goes through a
    `null_resource` + `local-exec` workaround. See
    [The raw-disk-passthrough pattern](#the-raw-disk-passthrough-pattern-null_resource--local-exec)
    below for why this exists and its limits.

> **Removed: `workstation/`.** A GUI-installed Ubuntu Desktop VM on
> `pve-rog` (standalone `proxmox_virtual_environment_vm`, no
> `modules/proxmox-vm`; `vga_type = "qxl2"` + a local SPICE kiosk on the
> host; USB peripherals and the mutex hookscript bound via the same
> `null_resource` + SSH pattern as the raw disk below). GPU passthrough was
> rejected there — Kepler VFIO reset bug, 470.xxx EOL. That whole area moved
> to the dedicated [`proxmox-hosted-workstation`](../../proxmox-hosted-workstation)
> repo, which does the opposite: `bare-pve` + a desktop-class GTX 950,
> whole-device passthrough (GPU + all USB controllers + onboard audio) via
> `proxmox_hardware_mapping_pci`, `x-vga` primary output straight to the
> monitors. The SPICE/`qxl2`/kiosk troubleshooting notes stay in
> [troubleshooting.md](troubleshooting.md).

## The raw-disk-passthrough pattern (`null_resource` + `local-exec`)

Introduced for `immich-node`'s recovery disk, but general enough to note
here rather than only in that environment's own README, since it's a
pattern any future environment needing the same thing (an existing
physical disk, not a Terraform-managed datastore volume) would reuse. The
same underlying restriction — the Proxmox API rejecting non-root access to
"real device" config — also applies to USB (`usbN`), hostpci (`hostpciN`)
and `hookscript` config, all worked around with the identical
`null_resource` + SSH pattern (the now-removed `workstation/` env used it
for keyboard/mouse/webcam and its mutex hookscript).

`bpg/proxmox` only supports datastore-backed disks declaratively (the
`disk { ... }` block). Binding an already-existing physical block device
to a VM has no first-class resource — the only path is `qm set <vmid>
-scsiN <device>,ro=1` run directly against the Proxmox host, wrapped here
in a `null_resource`:

```hcl
resource "null_resource" "recovery_ro_bind" {
  for_each = { for k, v in var.nodes : k => v if v.recovery_ro_device != null }

  triggers = {
    vm_id  = module.node[each.key].vm_id
    device = each.value.recovery_ro_device
  }

  provisioner "local-exec" {
    command = "ssh root@${var.proxmox_host_ip} qm set ${module.node[each.key].vm_id} -scsi1 ${each.value.recovery_ro_device},ro=1"
  }

  depends_on = [module.node]
}
```

**Known limitations, accepted rather than solved:**
- `triggers` only reacts to `vm_id` (VM recreated) or the device path
  changing — a disk detached by hand outside Terraform won't be noticed or
  restored on the next `apply`. This is drift-tolerant by omission, not
  drift-corrected.
- The `scsiN` index is hardcoded per environment, not derived from existing
  disk config — adding another disk to the same VM on the same index later
  would collide.
- `local-exec` runs wherever `apply` runs, not on a fixed CI host — it
  needs working SSH access to `root@<proxmox_host_ip>` from that exact
  machine. Currently fine (applied from the same laptop that already has
  that access for everything else); would need attention if this
  environment's `apply` ever moved to the self-hosted runner.
- Proxmox passes through the whole device, not the specific partition
  requested — `/dev/sdb1` on the host shows up as raw `/dev/sdb` inside the
  guest.
- The USB variant, as the removed `workstation/` env used it, had one more
  wrinkle: `usb_devices` was a positional `list(string)`, not keyed by
  device, so editing the list in the middle shifted every later
  `null_resource` index and forced their recreation.

## State backend lives off both

Terraform state for both root modules (`environments/nodes/backend.tf` and
`environments/runner/backend.tf`, both S3-compatible) points at MinIO
running in **CT 200**, an LXC container — pinned to `bare-pve` — not a
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
a full VM for the stronger KVM-level isolation — see the reasoning in
[troubleshooting.md](troubleshooting.md).

**CT 200's network address is statically pinned, not DHCP** (`ip=<addr>/24,
gw=<gateway>` in `minio-lxc-init.sh`, the same approach nodes already use
via cloud-init) — see the
[DHCP-drift entry](troubleshooting.md#minio-cts-dhcp-address-isnt-stable-across-restarts)
in troubleshooting.md for why this changed.

**The same MinIO bucket also doubles as an internal binary mirror.** A
`tools/` prefix in the `iac-proxmox-lab-tfstate` bucket (public-download,
`mc anonymous set download local/tools`) holds binaries that can't be
fetched directly from the runner due to regional blocks — currently the
Terraform CLI itself (`terraform_<version>_linux_amd64`, downloaded once
over a VPN and pushed via `mc cp`) and MinIO client. See the
[HashiCorp distribution note](troubleshooting.md#hashicorps-terraform-cli-distribution-is-blocked-for-rube-ips)
in troubleshooting.md.

## Shared storage (`bare-pve`, NFS)

`scripts/shared-storage-creation.sh` sets up an NFS export
(`/srv/shared-storage`) on `bare-pve` for ISO/template/backup content that
both cluster nodes should see identically, without copying files between
them by hand. Since `nexus-cluster`'s `/etc/pve/storage.cfg` is a
cluster-wide file, `pvesm add` only needs to run once (from either node) to
register it on both:

```bash
pvesm add nfs shared-storage \
  --server 192.168.100.30 \
  --export /srv/shared-storage \
  --content iso,vztmpl,backup,snippets,images
```

This is a separate, manual step from the script on purpose — the script
only prepares the NFS server side (per-node action), while `pvesm add` is a
cluster-wide action that only makes sense to run once, not per-node.

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
| `VM.PowerMgmt`, `VM.Audit`, `VM.Console` | start/stop, status, agent queries |
| `Datastore.AllocateSpace`, `Datastore.AllocateTemplate`, `Datastore.Audit` | disk provisioning |
| `Datastore.Allocate` | **separate** from `AllocateSpace` — managing the datastore resource itself, needed when the provider enables the `snippets` content type on first file upload |
| `SDN.Use` | cloning a VM with a network device attached to an SDN-managed bridge (introduced in Proxmox 8.x) |

**`VM.Monitor` was removed in Proxmox VE 9.0** and no longer exists as a
privilege — `pveum role add/modify` with it in the list now fails with
`invalid privilege 'VM.Monitor'`. It isn't needed by anything this repo's
Terraform does (VM creation/config/power/agent queries all use the
privileges above); QEMU HMP monitor access, if ever needed, now goes
through `Sys.Audit` (read-only commands) or `Sys.Modify` (state-changing
ones) instead, and guest-agent-specific access has its own new
`VM.GuestAgent.*` privileges. See the role-table diff in the git history
for exactly what was dropped.

Note that `qm set -scsiN <device>,ro=1` (used by `immich-node`'s raw-disk
passthrough — see [above](#the-raw-disk-passthrough-pattern-null_resource--local-exec)),
and `qm set -usbN`/`-hostpciN`/`-hookscript` more generally, all run as
`root` over plain SSH, not through the Terraform provider's API token — so
none is bound by `TerraformProv`'s privilege list, and none needs any
addition to the table above.
