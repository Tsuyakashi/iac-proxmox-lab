# Troubleshooting notes (things that actually broke)

Every entry below is a real incident, in no particular order beyond roughly
following the shape of [../README.md](../README.md) and
[architecture.md](architecture.md). See [history.md](history.md) for the
nested-Proxmox era this predates in several entries.

> Several entries below (the `br0`/`enp4s0` bridging, `vnet0`
> reattachment, and nested-bridge jitter entries in particular) describe
> issues specific to `pve-rog`'s earlier life as a nested Proxmox instance
> on the G750JX. `pve-rog` has since been rebuilt onto bare metal and no
> longer has that libvirt/KVM layer — these entries are kept for the
> historical record and in case nesting is ever used again for a future
> node, but they don't describe the cluster's current state.

<a id="runner-self-destruct"></a>
## The self-hosted runner destroyed itself mid-`apply`

Runner and nodes originally lived in one root module. A change to the
shared cloud-init SSH-key template forced `# forces replacement` on every
`proxmox_virtual_environment_file`/`proxmox_virtual_environment_vm`
resource — including the runner VM the job was executing on. Terraform
began destroying the runner's own VM; the job got a shutdown signal
mid-destroy and never completed the recreate. Fixed by splitting the
runner into its own root module (`environments/runner/`, own state, own
backend, applied manually — see
[architecture.md#two-independent-root-modules](architecture.md#two-independent-root-modules)).

<a id="state-backend-unreachable"></a>
## State backend became unreachable after the above

MinIO was running *inside* the runner VM. Once the runner destroyed itself,
every subsequent `terraform init`/`plan`/`apply` failed with
`dial tcp ...: connect: no route to host` — the state backend and the
infrastructure it describes shared a single point of failure. Fixed by
moving MinIO to a standalone LXC container (CT 200) outside any Terraform
lifecycle — see
[architecture.md#state-backend-lives-off-both](architecture.md#state-backend-lives-off-both)
and `scripts/minio-lxc-init.sh`. Considered running MinIO in Docker on the
Proxmox host directly, but Docker on the PVE host itself is not
recommended (interferes with Proxmox's own iptables/firewall management)
— an LXC container was the right level of isolation without that
conflict.

<a id="migrate-state-reconfigure"></a>
## Backend migration between S3 endpoints needs `-migrate-state` / `-reconfigure`, and it *still* tries to reach the old endpoint first

Moving `backend.tf` from one MinIO endpoint to another isn't just an edit
and `terraform init` — the first `init` after the endpoint changes still
attempts to read the *previous* backend to figure out what needs
migrating, so if the old endpoint is dead (as after the incident above),
`-migrate-state` fails too on the first attempt. It only succeeds once
Terraform gives up trying to reach the dead old backend and falls back to
treating it as a fresh `-reconfigure`. Expect to run `terraform init`
more than once when changing backend endpoints under failure conditions.

<a id="runner-local-backend-spof"></a>
## The runner's local backend was still a single point of failure — just a different one than Proxmox dying

`environments/runner/` originally used `backend "local"` on the reasoning
that it's applied rarely, by hand, from a laptop. That's true, but the
actual risk isn't "Proxmox disappears" (in that case state is moot
regardless of backend — the VMs are gone too) — it's losing the laptop
(or just its disk) while the runner VM keeps running fine. The next
`terraform apply` from a fresh machine wouldn't see the existing runner in
state and would attempt to create a second one on top of it (MAC/name
collision at best). Migrated `environments/runner/backend.tf` to the same
S3 (MinIO) bucket the nodes already use, under a separate
`runner/terraform.tfstate` key (mirroring the `nodes/` key-namespacing
from PR #23) — `terraform init -migrate-state`, confirm "copy existing
state to new backend" — so the runner's state survives independently of
any single laptop, matching why MinIO itself was pulled out of the runner
VM in the first place.

(A local backend does remain the *only* correct choice if MinIO itself
ever becomes a Terraform-managed resource in this same environment — a
bootstrap/chicken-and-egg problem, since state can't live in a bucket the
same `apply` is creating. Not the current setup; noted in case that
changes.)

## `terraform init -migrate-state` for the runner failed with `no route to host` reaching MinIO — turned out to be an unrelated host-level network incident, not a backend/credentials problem

*(Historical — from `pve-rog`'s nested-VM era.)* A hard power loss (dead
laptop battery, no UPS) took the whole nested Proxmox VM down; `dial tcp
...: connect: no route to host` on the MinIO bucket was a downstream
symptom of the VM being unreachable, not anything wrong with the S3
backend config itself. `-migrate-state` succeeded cleanly once the
underlying network path was restored.

<a id="lvm-thin-pool-exhaustion"></a>
## LVM thin pool exhaustion (`lvcreate` / `Cannot create new thin volume`) during a clone

Sum of virtual disk sizes across nodes, runner, and the MinIO container
comfortably exceeds the actual thin-pool size on `pve-rog` — `pvesm
status` showed `local-lvm` at 100% before this hit. An orphaned VM from
the runner self-destruct incident (disk never cleaned up because the
destroy never completed) was eating 20GB it no longer needed. Fixed by
removing the orphan (`qm destroy <id> --purge`) and extending the thin
pool into the volume group's free space (`lvextend -l +100%FREE
pve/data`). Worth periodically checking `lvs pve` against `qm list` for
orphaned disks whenever a `destroy`/`apply` gets interrupted.

<a id="lvm-thin-pool-exhaustion-recurred"></a>
## Thin pool exhaustion recurred from natural growth, not an orphan this time — and took down every VM plus the state backend simultaneously

With no orphaned disk left to blame, ordinary data growth across the four
thin volumes eventually refilled `pve/data` to 100% again on `pve-rog`.
This hit the pool while everything was live and running unattended
overnight: `dmesg` showed `EXT4-fs` write errors on every VM's disk
simultaneously (`I/O error 3 writing to inode ...`), and `qm`/`pct`
reboots issued in response all failed with `VM quit/powerdown failed -
got timeout` because the guest agent itself couldn't respond over a
filesystem that could no longer write. CT 200 (MinIO) took the worst of
it — its journal aborted (`EXT4-fs error: Journal has aborted`) badly
enough that `pct exec 200 -- systemctl status minio` failed outright with
`lxc-attach: Input/output error`, since even `exec`-ing a command requires
a working root filesystem. Recovered by: stopping every VM/CT (`qm stop
<id>`, `pct stop 200`) to halt further writes, `lvextend -l +100%FREE
pve/data` (there was still ~7GB of free space in the volume group itself
— `vgs pve`'s `VFree` — that the pool had never been extended into),
`pct fsck 200` to repair the aborted journal (ran clean on the second
pass), then starting everything back up.

**Two follow-ups landed as a direct result:** `scripts/proxmox-init.sh`
now sets `activation { thin_pool_autoextend_threshold = 80 }` in
`/etc/lvm/lvm.conf` so this surfaces as an early LVM warning instead of a
silent slide into I/O errors at 100%; and the underlying overcommit is
still real — `lvextend`'s own output after this incident (`Sum of all
thin volume sizes (<61.52 GiB) exceeds the size of thin pool pve/data and
the size of whole volume group (<59.50 GiB)`) means the *ceiling* the pool
can be extended to is now the actual bottleneck, not a one-off cleanup.
Recurs whenever real usage catches up again; `pvesm status` / `lvs pve`
should be the first thing checked on any simultaneous multi-VM `io-error`,
ahead of anything guest-side.

## A guest-side disk fill (not the hypervisor's thin pool) paused a VM instead of crashing it, which looked like a crash at first

*(Historical — from `pve-rog`'s nested-VM era.)* A `docker compose`
workload (Immich, pre-`immich-node`, running directly on a physical
Ubuntu host, not a Proxmox guest) filled that host's own disk overnight;
the nested Proxmox VM (`pve-rog`, at the time still running inside
libvirt/KVM) whose qcow2 disk image lived on that same physical disk got
paused by libvirt/QEMU (not crashed) once the underlying filesystem had
no space left — `virsh list --all` showed it as `paused`, not `shut off`,
and `virsh resume proxmox-lab` brought it straight back with no data loss
or corosync resync needed. This cascaded into a real quorum loss on
`nexus-cluster` (the paused node's vote dropped out, leaving `Expected
votes: 2` / `Total votes: 1` on the remaining node — `pvecm status`
reported `Quorate: No`) — recovering the paused VM was the actual fix,
not anything cluster-config-side. Two lessons: (1) `paused`, not
`shut off` or absent from `virsh list --all`, is the first thing to check
when a guest is unexpectedly unreachable after a disk-full event nearby —
`virsh resume` is a much smaller hammer than assuming a rebuild is
needed; (2) this is the incident that motivated moving the Immich
workload onto its own dedicated, Proxmox-managed VM
(`environments/immich-node`) instead of a physical host's local disk
shared with unrelated guests — see
[architecture.md#other-environments](architecture.md#other-environments).

<a id="qdevice-recovery"></a>
## Recovering a lost QDevice arbiter mid-cluster required the arbiter to join the tailnet, and `qdevice remove`/`setup` both refuse to run with any node offline — a real chicken-and-egg

With the QDevice arbiter (normally on the LAN) reachable only over
Tailscale at the time (away from home), and one cluster node down for
unrelated reasons (paused, see the entry above), `pvecm qdevice remove`
failed outright with `All nodes must be online! Node <name> is offline,
aborting` — re-registering the arbiter's new address is *cluster-wide*
config, so Proxmox refuses to touch it while any member is unreachable.
The paused-VM fix above had to land first, purely by coincidence of both
problems existing at once; if the paused VM had instead been the one
needed to reach the arbiter, this would've been unrecoverable without
fixing that first regardless. Once quorum was back: `ssh
<tailscale-ip-of-arbiter>` from the bare-metal node failed outright (`100%
packet loss`) until that node *itself* joined the tailnet — a
subnet-router advertising the LAN range from a different machine doesn't
help here, since the arbiter needs to be dialed *from* the Proxmox host
for `qdevice setup`'s SSH step, not the other way around. `tailscale up`
accepting `--accept-routes=false` by default was correct to leave alone —
the bare-metal node already sits natively on the LAN range some other
tailnet member was also advertising, and accepting that route in addition
would just create a second, less predictable path to the same subnet.
Once the Proxmox host had its own tailnet identity, `pvecm qdevice setup
<tailscale-ip> --force` worked normally — the `--force` was needed only
because stale cert/config state from the arbiter's previous LAN-based
registration was still present.

<a id="concurrent-clones-unreliable"></a>
## Concurrent full-clones on `pve-rog` are unreliable

*(Root cause was disk contention, not specifically nesting — worth
re-checking now that `pve-rog` is bare metal, but not yet revisited.)*
`terraform apply` with default parallelism clones all node VMs at once;
on `pve-rog`'s single-disk setup that meant heavy I/O contention — one
clone finished in ~2 minutes while a sibling clone took 15+ minutes and
ultimately timed out waiting for the QEMU guest agent (the VM was still
mid-clone/mid-boot, agent never got a chance to start). Fixed by using
`terraform apply -parallelism=1` for node provisioning — slower overall,
but each clone gets the disk to itself.

## `qemu-guest-agent` not running → 15-minute `apply` timeout

The Ubuntu cloud image ships the agent package but doesn't enable it by
default. Fixed by pushing a cloud-init snippet (now
`modules/proxmox-vm/templates/user-data.yml.tpl`) that installs and
enables it via `runcmd`, instead of relying on the base image.

## A heavy `packages:` list delays guest-agent startup enough to blow the apply timeout anyway

Once the runner started installing `docker.io`, `ansible`, and friends via
cloud-init's `packages:` list, the guest agent (also only enabled via
`runcmd`, which runs *after* the `packages:` stage completes) didn't come
up until the whole apt run finished — 10+ minutes, well past what looked
like a hang. Fixed by never putting heavy packages in `packages:` at all:
only `qemu-guest-agent` is installed there (fast, and gets the agent up
within the first ~30 seconds of boot), everything else (`docker.io`,
`ansible`, etc.) moves to `runcmd` as an explicit `apt-get install`, which
runs after the agent is already live and reporting to Terraform.

## `write_files` failed silently with `KeyError: getpwnam(): name not found: 'ubuntu'`

cloud-init's `write_files` module runs in the `init-network` stage, which
happens *before* the `users` module creates any configured users — so
`owner: ubuntu:ubuntu` on a `write_files` entry fails to `chown` a user
that doesn't exist yet, and the whole module aborts (the file is never
written, only a warning is logged — easy to miss). Fixed by always
writing `write_files` entries as `root:root`, then `chown`ing them to the
real target owner in `runcmd` (which *does* run after user creation) —
see the `write_files`/`chown` pairing in
`modules/proxmox-vm/templates/user-data.yml.tpl`.

## `packages: None is not of type 'array'` — cloud-init schema validation failure when `extra_packages` is empty

Rendering `packages:` with the Terraform `for` loop but zero items
produces a bare `packages:` key with nothing under it, which YAML reads as
`null`, not an empty list — cloud-init's schema requires an array. This
affects any VM with `extra_packages = []` (i.e. every node, since only
the runner, minecraft-node, and immich-node set packages). Fixed by
wrapping the whole `packages:` block in `%{ if length(extra_packages) > 0
~}`, so the key is omitted entirely rather than emitted empty.

## Multi-line `write_files` content breaks YAML if the block literal's first line isn't indented

Terraform's `indent(n, string)` indents every line of a string *except the
first* — so `content: |` followed directly by `${indent(6, f.content)}`
put the first line of the content at column 0 instead of the block's
indent level, which either corrupts the whole cloud-config parse (`could
not find expected ':'`, with everything after silently dropped as `empty
cloud config`) or, in a milder case, just fails schema validation for that
one `write_files` entry. Fixed by adding the indent manually before the
interpolation: `      ${indent(6, f.content)}` (6 literal spaces, since
`indent()` only covers lines 2+).

<a id="hashicorp-cli-blocked"></a>
## HashiCorp's Terraform CLI distribution is blocked for RU/BY IPs since 2022

Both `apt.releases.hashicorp.com` and `releases.hashicorp.com` (which
GitHub Releases pages for Terraform link back to) are unreachable. The
`.terraformrc` network mirror already in use only covers *provider*
downloads via `terraform init`, not the CLI binary itself — installing
`terraform` via HashiCorp's apt repo or a direct GitHub Releases URL both
fail outright from this network. Worked around by downloading the binary
once over a VPN and re-hosting it on the self-hosted MinIO instance
(`tools/` prefix, anonymous-download bucket policy); the runner's
`extra_runcmd` pulls it from there instead. See
[architecture.md#state-backend-lives-off-both](architecture.md#state-backend-lives-off-both).
The same `tools/` mirror is later reused for the Vault binary too — see
[the mlock entry below](#vault-mlock-enomem-in-unprivileged-lxc).

## MinIO client's old download path (`dl.min.io/client/mc/release/linux-amd64/mc`) now serves a small HTML page instead of the binary

Following MinIO's AIStor rebrand — a plain `curl -o mc <url>` without `-L`
silently saves the HTML as if it were the binary (141 bytes, `file`
reports `HTML document`), and the resulting "binary" fails with a bash
parse error when executed. Fixed by switching to the current path,
`https://dl.min.io/aistor/mc/release/linux-amd64/mc`.

<a id="kvm64-cpu-baseline"></a>
## Default `kvm64` CPU baseline silently breaks workloads compiled against a newer instruction-set floor

`modules/proxmox-vm` never explicitly set `cpu.type` until `immich-node`
needed it — meaning every VM had implicitly been running `kvm64`
(Proxmox's own default), a baseline narrow enough to exclude
`sse4_2`/`popcnt`/`avx2`. This went unnoticed until Immich's
machine-learning container (numpy/onnxruntime, built against x86-64-v2)
hit it and restart-looped with `RuntimeError: NumPy was built with
baseline optimizations: (X86_V2) but your machine doesn't support`.
Confirmed via `cat /proc/cpuinfo | grep flags` inside the guest —
genuinely absent, not just unreported. Fixed by exposing `cpu_type` as a
module input (`modules/proxmox-vm/variables.tf`, still defaulting to
`kvm64` for every existing environment) and setting it to `host`
specifically for `immich-node`, which never migrates between hosts by
design (bind-mounts to a specific physical disk — see
[`../environments/immich-node/README.md`](../environments/immich-node/README.md)),
so the usual migration-portability argument for a conservative baseline
doesn't apply there. **Not hot-pluggable** — a VM already running needs an
explicit `qm stop && qm start` (not a guest-side `reboot`) before a
changed `cpu.type` actually takes effect; `terraform apply` alone
rewrites the config but doesn't force this. Worth checking `cpu.type` on
any future VM whose workload turns out to depend on specific CPU features
(AES-NI, AVX, etc.) — the default here has always been the conservative
one, and it's opt-in per environment, not automatic.
`environments/workstation` hit the same non-hot-pluggable behavior for a
different field (`vga` type, not `cpu.type`) — see
[the `virtio-gl`/`qxl2` entry](#virtio-gl-single-head) below.

<a id="no-serial-console"></a>
## Node VMs (and, before the serial console fix, the runner) had no usable serial console

The Terraform-managed VM resources didn't set an explicit
`serial_device`/`vga` block, unlike the golden image (VM 9000, provisioned
with `--serial0 socket --vga serial0` in `proxmox-init.sh`), so `qm
terminal <vmid>` connected but showed nothing useful — diagnosis had to go
through the Proxmox web UI's VNC console instead. Fixed by adding the
same `serial_device`/`vga` blocks to `modules/proxmox-vm` (requires the
`VM.Config.HWType` privilege — see
[architecture.md#terraformprov-role](architecture.md#terraformprov-role)).
Two remaining quirks worth knowing, not bugs:
- `qm terminal <vmid>` needs a real TTY on the client side — `ssh <node>
  'qm terminal <vmid>'` fails with `tcgetattr: Inappropriate ioctl for
  device`; `ssh -t <node> 'qm terminal <vmid>'` works.
- Console login always rejects any password, by design — cloud-init only
  sets `ssh_authorized_keys` for `ubuntu`, never a password, so the
  account is locked for password auth. `Login incorrect` on the serial
  console is expected; use SSH with the key instead. Reaching this login
  prompt at all is actually a *good* sign — it means the VM booted fully
  past init/network/multi-user.target.

## `user_account` block vs `user_data_file_id`

These both generate cloud-init user-data; setting `user_data_file_id`
takes over entirely, so the SSH user/key need to live in the snippet
template, not in a separate `user_account` block — leaving both in caused
silent conflicts.

## Nested-bridge network jitter

*(Historical — from `pve-rog`'s nested-VM era; not applicable now that
it's bare metal.)* Pinging the nested Proxmox VM from a machine two hops
away (over Wi-Fi → router → host) showed heavy jitter (single-digit ms up
to ~3s). Confirmed as a Wi-Fi hop issue, not the bridge/nested-KVM setup —
pinging from the physical host itself was consistently sub-millisecond.

## `br0` loses its physical-NIC attachment after a nested-VM teardown/host reboot

*(Historical — from `pve-rog`'s nested-VM era.)* `enp4s0` reverts to a
standalone `auto` NM profile, leaving `br0` up but carrier-less
(`NO-CARRIER`) and the nested Proxmox VM completely unreachable (`no
route to host`, even though the VM itself boots fine — its `vnet`
interface just has nowhere to send traffic). Fixed with a guard in
`install-proxmox-with-libvirt.sh` that checks `br0`'s state and
`br0-port`'s attachment before every run and reattaches `enp4s0` if
needed — see the script for the exact `nmcli` checks. Running it may
briefly drop the current SSH session (expected, since `enp4s0` is being
reparented); just reconnect and re-run. Kept for reference in case
nesting is used again for a future node.

## `deploy` job hit a `dpkg` lock race and an intermittently unreachable node, both traced to the same root cause: node VMs report "provisioned" before cloud-init has actually finished

`wait_for_ip_disabled = true` on the node module means `terraform apply`
returns as soon as the VM is cloned, without waiting for SSH or cloud-init
completion. On one run, `dev-node` (cloned last) wasn't SSH-reachable yet
when Ansible connected; on another, the `docker` role's `apt-get install
docker.io` collided with cloud-init's own `apt-get install
qemu-guest-agent` running concurrently on the same node, and the loser
failed on `dpkg`'s lock-frontend. Manually checking the "unreachable" node
moments later showed it fully up — the pipeline just hadn't waited the
extra seconds cloud-init needed. Fixed by adding a `Wait for nodes to
finish booting` step in `pipeline.yml`'s `deploy` job, between installing
Ansible collections and running the playbook: polls each host's SSH port
first, then blocks on `cloud-init status --wait` over SSH, so `apt` on the
node is guaranteed free before the `docker`/`github-runner` Ansible roles
touch it.

## `deploy` job's `github-runner` Ansible role failed silently on a registration-token 404, because the workflow never set `GITHUB_REPO`

The role reads both `GITHUB_REPO` and `GITHUB_PAT` from the environment
(`lookup('env', ...)`), but `pipeline.yml`'s `env:` block only ever had
`BASE_REGISTRY`. With `github_repo` empty, the registration-token request
went to `.../repos//actions/runners/registration-token`, GitHub returned a
non-201 status, and the `uri` module failed the task — but the actual
response body was hidden because the *whole task* (not just the token
task) had `no_log: true`. Fixed by adding `GITHUB_REPO:
Tsuyakashi/swarm-lab` alongside `GITHUB_PAT` in `pipeline.yml`'s `env:`
block. Lesson: when a `no_log: true` task fails opaquely, temporarily
register the result and drop `no_log` on that one task rather than
guessing — two earlier guesses here (missing runner dependencies) were
both wrong.

## `Configure runner` failed with `Permission denied: '/root/actions-runner'` even though the files were downloaded to `/home/<user>/actions-runner`

The `Setup GitHub Actions runner` play in `swarm-lab/ansible/site.yml`
runs with `become: true` at the play level, which applies to `Gathering
Facts` too — so `ansible_env.HOME` resolves to `/root`, not the SSH user's
home. A `runner_dir` default built from `ansible_env.HOME` therefore
pointed at `/root/actions-runner` for the `become_user: <ssh-user>` task,
even though the directory-creation tasks (running as root, then chowned)
had populated `/home/<user>/actions-runner`. Fixed by building
`runner_dir` explicitly as `/home/{{ ansible_user }}/actions-runner` in
`github-runner/defaults/main.yml` instead of trusting `ansible_env.HOME`
inside a `become: true` play.

## The `docker` and `github-runner` Ansible roles hardcoded the `vagrant` user

A leftover from the original `vagrant up` flow (Vagrant boxes
auto-provision a `vagrant` system user). Nodes provisioned by this repo's
Terraform + cloud-init use `ubuntu` instead (see
`modules/proxmox-vm/templates/user-data.yml.tpl`), and `vagrant` only
existed on them as an *accidental* side effect of the `user:` task in the
`docker` role (which happened to create it, since it wasn't `state:
absent`). Fixed by parameterizing both roles on `ansible_user` (already
correctly populated per-host by both the Vagrant provisioner and
`templates/inventory.tpl`), so neither role assumes a specific
provisioning flow anymore.

## `vnet0` (the nested VM's own libvirt bridge port) doesn't reattach to `br0` automatically after a hard power loss

*(Historical — from `pve-rog`'s nested-VM era.)* Different failure from
the `br0`/`enp4s0` case above — the physical NIC stayed correctly
attached throughout, but `virsh domiflist` still reported `vnet0` as
belonging to `br0` while `brctl show br0` didn't list it as an actual
port. Symptom: `ip neigh show <proxmox-ip>` stuck on `FAILED`, `arp -n`
showed `(incomplete)`, and `arping` got zero responses — all pointing at
an L2 problem between host and VM, even though both `br0` and `vmbr0`
(inside the VM) showed `state UP` with correct addresses. Confirmed the
VM's own network was fine via `tcpdump -i vmbr0 -n arp` from inside the
VM's console (still saw ARP traffic from the guest VMs/CTs). Fixed with
`brctl addif br0 vnet0` — but a newly added bridge port starts in STP
`listening`/`learning` state and doesn't forward traffic until it reaches
`forwarding` (~15-30s with default timers, check via `brctl showstp
br0`), so don't assume the fix failed just because ping still fails
immediately after `addif`. `install-proxmox-with-libvirt.sh`'s existing
guard only checked the physical-NIC side of the bridge; extended it to
also check and reattach `vnet0`. Kept for reference in case nesting is
used again.

<a id="minio-ct-dhcp-drift"></a>
## MinIO CT's DHCP address isn't stable across restarts

Unlike nodes, which pin their address via cloud-init static config (a
specific `mac_address` + `ip_config`), `minio-lxc-init.sh` originally
created CT 200 with `ip=dhcp`. The address drifted at least twice
(`192.168.100.13` → `192.168.100.10` → `192.168.100.100`), surfacing
indirectly and unhelpfully each time: `backend.tf` in every environment
silently pointed at a dead IP (`no route to host` on `terraform init`),
and the hardcoded MinIO URL in `environments/runner/main.tf`'s
`extra_runcmd` (for pulling the `terraform`/`mc` binaries) went stale
right along with it — three separate places that had to be manually
re-synced by hand after noticing, with no single point that would have
caught the drift earlier. Root cause was almost certainly one of the
hard-power-loss incidents restarting CT 200 and having the DHCP lease
land differently. Fixed by pinning a static IP for CT 200 in
`minio-lxc-init.sh` (`ip=<addr>/24,gw=<gateway>` on `net0`, same pattern
nodes already use), with an idempotent guard so re-running the script
against an already-existing CT on a stale DHCP config corrects it (`pct
set` + reboot) instead of silently doing nothing. Now standardized on
`192.168.100.100` across all environments' `backend.tf`.

## A newly created CT on `bare-pve` was completely unreachable from the rest of the LAN — `Destination Host Unreachable` from every other host, including the CT's own gateway — despite the CT's own network config being entirely correct

`pct config`, `ip a`/`ip route` inside the CT, and even `ping` *from the
Proxmox host itself* to the CT's IP all looked fine — but that last check
is a false positive: host↔guest traffic on the same Linux bridge doesn't
have to leave the bridge or touch the physical NIC at all, so it proves
nothing about external reachability. `tcpdump -i vmbr0 -n arp` on the
host, run *simultaneously* with a ping attempt from another LAN host,
showed literally nothing — the ARP request for the CT's IP never reached
the bridge's physical side. A single outbound ping *from inside the CT*
(`pct exec <id> -- ping <any-external-ip>`) put the CT's MAC on the wire
as a *source* address, and external ping worked immediately afterward
with no other change. At the time this looked like ordinary
forwarding-table aging on an upstream switch (entries age out after ~5
minutes of silence on most gear). It turned out to be more specific than
that — see [the MT-PON-AT-4 entry](#mt-pon-at-4-quirk) below, which
generalizes this to every new host on `bare-pve`, not just CTs. Two
diagnostic dead ends worth flagging so they don't eat time on a repeat:
(1) the *client's* `ip neigh` table can cache a stale `FAILED` entry for
the target IP and short-circuit further `ping` attempts locally without
ever generating a new ARP request — `ip neigh del <ip> dev <iface>` clears
it, but the entry can silently reappear as `FAILED` on the very next
attempt if the root cause isn't fixed yet, which looks like the flush
didn't work but did; (2) prefer `arping` (raw L2 ARP request, ignores the
routing/neighbor cache entirely) over repeated plain `ping` when
diagnosing this class of problem — it gives a clean, uncached signal of
whether the L2 path actually works.

<a id="mt-pon-at-4-quirk"></a>
## The CT 200 unreachable-until-pinged behavior above turned out to be a general MT-PON-AT-4 quirk, not CT-specific — newly created node VMs showed the identical symptom, and it's not simple forwarding-table aging

After the CT 200 incident, `prod-node`/`stage-node`/`dev-node` (freshly
cloned via `terraform apply`, all static-IP with `wait_for_ip_disabled =
true`) were unreachable from both the Zenbook and `pve-rog` immediately
after provisioning — `Destination Host Unreachable` — while `ssh bare-pve
ping <node-ip>` (same-bridge traffic, proves nothing about external
reachability, see the entry above) worked instantly. The physical
topology explains it: `bare-pve` and `.3` (the Keenetic) both uplink
independently into `.1` — a Промсвязь MT-PON-AT-4 GPON ONT acting as the
L2 hub between them (see
[architecture.md#architecture-in-depth](architecture.md#architecture-in-depth))
— so a device behind `.3` (e.g. the Zenbook at `.12`) can only learn a new
host's MAC once traffic for it has actually transited `.1`. A single
outbound ping from inside the new VM (over `ssh -J bare-pve`) sometimes
needed two or three attempts before external ping succeeded, and the
first successful replies showed unusually high, *decaying* RTT (thousands
of ms down to single-digit ms) rather than a clean instant fix — this
isn't packet loss, it's the ONT's own L2/forwarding state catching up
over a couple of seconds. Confirmed via search that
unreachable-until-pinged is a known MT-PON-AT-4 behavior independent of
this LAN or Proxmox — other users of this exact model report the same
workaround (pinging devices to each other to "wake" the network). Setting
a static DNS server on the Keenetic's WAN/broadband page does **not**
help — DNS resolution and L2/ARP forwarding are unrelated, and every
reachability check here already targets raw IPs, not hostnames. Fixed at
the source instead of relying on a manual `ssh -J` after every provision:
the base cloud-init `runcmd` (shared by every environment via
`modules/proxmox-vm/templates/user-data.yml.tpl`) now retries a ping to
`192.168.100.3` a few times right after the network stage, so every new
VM "wakes up" the L2 path on its own during boot, before anything tries
to reach it from outside `bare-pve`. Harmless no-op on `minecraft-node`
(isolated `vmbr1` segment has no route to `.3`; wrapped so the failure
doesn't block the rest of `runcmd`). Worth remembering this also means
`pipeline.yml`'s `Wait for nodes to finish booting` step could
theoretically hit the same wall if the self-hosted runner ever ends up
behind `.3` instead of `bare-pve` — not the current setup, but worth
revisiting if the runner's network placement changes.

<a id="apt-enterprise-401"></a>
## Bare-metal node's `apt update` failed on `enterprise.proxmox.com` with `401 Unauthorized` for both `pve` and `ceph-squid`

A fresh Proxmox VE install points at the subscription-only enterprise
repos by default, which 401 without a paid subscription. On Proxmox VE
9.x the repo config moved to `deb822` format —
`/etc/apt/sources.list.d/*.sources`, not the old `*.list` files a stale
guide/muscle-memory might reach for first (the old-format commands are
silent no-ops here: `sed` on a `.list` file that doesn't exist just
errors `No such file or directory`, which is easy to miss in a longer
command chain). Fixed by removing (or disabling)
`pve-enterprise.sources`/`ceph.sources` and adding a `pve-no-subscription`
entry in the same `deb822` format:
```
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
```

<a id="pvecm-add-link0-split"></a>
## `pvecm add` without an explicit `--link0` silently wrote the wrong address into `corosync.conf`, splitting the cluster in two

Joining a second node with plain `pvecm add <first-node-ip>` printed "No
cluster network links passed explicitly, fallback to local node IP" and
then put that *same* fallback address into **both** nodelist entries —
including the one for the node that already had a different, correct IP.
Result: `corosync-cfgtool -s` on each node showed only itself (`nodeid: 1:
localhost`), `pvecm status` reported `Nodes: 1` on both sides despite a
bumped `Config Version`, and each node ended up running its own
single-node "cluster" under the same cluster name — a real split-brain,
not just an unsynced join. Symptom is easy to misdiagnose as a firewall or
latency problem first (both were ruled out here — `pve-firewall status`
showed `disabled`, and `ping` between nodes was sub-millisecond) before
the actual cause (`cat /etc/pve/corosync.conf`, compare `ring0_addr`
across `nodelist` entries) becomes obvious. Fixed by always passing
`--link0 <joining-node-ip>` explicitly on `pvecm add`, never relying on
the fallback.

## An interrupted `pvecm add` (Ctrl+C during "waiting for quorum...") leaves the node stuck between standalone and clustered — `rm`ing `/etc/pve/corosync.conf` normally then does nothing

`/etc/pve` is a FUSE mount (`pmxcfs`); while `pve-cluster` is stopped,
that mountpoint is just an empty local directory, so `rm -f
/etc/pve/corosync.conf` while the service is down is a silent no-op — the
file is still inside `pmxcfs`'s own database and reappears the moment the
service restarts. While the service *is* running, the same file is
mounted read-only (`-r--r-----`, `meant to be read-only`) and a plain `rm`
fails with `Permission denied`. The only way to actually remove or
hand-edit it is `pmxcfs -l` (forces local mode, bypassing both the FUSE
read-only guard and the corosync/quorum requirement), edit or `rm` while
in that mode, then `killall pmxcfs` and `systemctl start pve-cluster` to
return to normal. Retrying `pvecm add` without this produces `cluster
config '/etc/pve/corosync.conf' already exists` even though `rm`
"succeeded" moments earlier.

## CT/VM disks and running processes survive a botched `pvecm add` — only `/etc/pve`'s config tree does not

The first (interrupted) cluster join wiped `/etc/pve/qemu-server/*.conf`
and `/etc/pve/lxc/*.conf` on the joining node (`qm list`/`pct list` came
back empty), which looked like data loss at first. It wasn't: `pmxcfs`
had backed up the pre-join database to
`/var/lib/pve-cluster/backup/config-<timestamp>.sql.gz` before rewriting
itself for the new cluster, and the actual guest processes (checked via
`pct status`/`qm status` bypassing the missing config, and confirmed the
LVM volumes were untouched in `lsblk`) had never stopped running.
Recovered the configs without a reboot: `zcat` the backup, load it into a
scratch SQLite db (`sqlite3 restore.db < dump.sql`), find the right
`inode` for each `<vmid>.conf`/`user.cfg` under the `tree` table, dump
each `data` blob back out to a file, then copy those into
`/etc/pve/qemu-server/<id>.conf` / `/etc/pve/lxc/<id>.conf`. `qm
list`/`pct list` picked them back up immediately, `STATUS running`
unchanged the whole time — no VM/CT restart needed. (In this instance,
the recovered state ended up unused anyway — see the next entry — but
the extraction path is worth keeping in mind before assuming a
config-loss scare means an actual rebuild is necessary.)

## After a genuinely split cluster (see the `--link0` entry above), a clean node rebuild beat trying to reconcile two divergent single-node "clusters" by hand

Once it was clear the join had actually split, not just failed to sync,
and the guest workloads on the affected node (`ci-runner`, `minio`) were
disposable/recreatable rather than precious, destroying and reinstalling
that node (fresh Proxmox VE 9.2 ISO) was faster and less error-prone than
trying to merge corosync state or manually reconcile two out-of-sync
`/etc/pve` trees. Decide this case-by-case — if a node's guests aren't
easily recreated, the `pmxcfs -l` manual-edit path in the entry above is
the one to use instead.

## `pmxcfs -l`'s "force local mode" banner is expected, not a new problem

Every time `pmxcfs -l` runs against a node that already has a
`corosync.conf` on disk, it prints `forcing local mode (although
corosync.conf exists)` — this is the tool telling you it's doing exactly
what was asked (ignore cluster state, mount `/etc/pve` writable and
local-only), not a warning that something is already broken.

<a id="usbn-scsin-root-only"></a>
## Proxmox's API rejects any non-root request to set real-device config on `usbN`/`scsiN`, including a fully-privileged API token — surfaces as `only root can set 'usbN' config for real devices`

Hit first for `immich-node`'s raw exFAT-disk passthrough (`scsiN`), and
again for `environments/workstation`'s keyboard/mouse/webcam (`usbN`) —
same root cause both times: this class of config bypasses Proxmox's own
privilege model entirely and requires `root@pam`, no matter what the API
token's ACL grants. There's no fix on the Terraform-provider side; the
working pattern in both environments is a `null_resource` + `local-exec`
running `qm set` directly over SSH as root, with `lifecycle {
ignore_changes = [usb] }` (or the disk-equivalent) on the VM resource
itself — otherwise the provider's own `refresh`/`plan` sees the
out-of-band device as drift and tries to "fix" it through the API token,
hitting the exact same error. See
[architecture.md#raw-disk-passthrough-pattern](architecture.md#raw-disk-passthrough-pattern)
and [`../environments/workstation/README.md`](../environments/workstation/README.md)
for the USB-specific version, including the positional-list
index-shifting caveat that comes with it.

<a id="virtio-gl-single-head"></a>
## `virtio-gl` is single-head only in Proxmox's QEMU build — multi-monitor needs `qxl2` instead, at the cost of GPU acceleration

Tried `vga_type = "virtio-gl"` first for `environments/workstation`
(GPU-accelerated 2D/desktop compositing via Venus/virgl through the
host's i915), which worked fine on one monitor but never showed a second
output no matter how the *host*-side X session was laid out with
`xrandr` — the raw device only exposes one video head, confirmed as a
known Proxmox limitation (not a config mistake) via the Proxmox forum.
Switched to `vga_type = "qxl2"` — QXL's SPICE-native multi-monitor
support is the only officially-supported path to more than one head,
trading away GPU offload (rendering becomes CPU-side) for it. Acceptable
here since the actual workload (browser/office/casual 2D games) doesn't
need hardware 3D anyway. **Changing `vga_type` on an existing VM is not
hot-pluggable** — same class of gotcha as `cpu_type` in the
[kvm64 entry](#kvm64-cpu-baseline)
above — a guest-side `reboot` keeps using the old QEMU display device;
only a full `qm stop && qm start` picks up the new one.

## A `qxl2` VM only activated one virtual head even with the right `vga_type` set — because the SPICE client, not the guest, decides how many heads to use

`xrandr --query` inside the guest showed a single `connected` output and
three `disconnected` ones despite `vga: qxl2` being correctly in the VM
config — because `remote-viewer` was started with plain `--full-screen`
(occupies exactly one physical monitor on the client side, so it only
ever told the guest about one). `spice-vdagent` activates additional QXL
heads in response to what the SPICE client reports about the client's own
display layout, not proactively. Fixed by using `remote-viewer
--full-screen=all` instead, which reports every physical monitor on the
client (here, the two external monitors plugged into the same host
running the viewer — see `scripts/desktop-kiosk-setup.sh`) and gets both
QXL heads activated in the guest as a result.

## SPICE draws no mouse cursor at all when the mouse is passed through to the guest as a raw USB device instead of going through the SPICE input channel — looks like a rendering bug, isn't one

On `environments/workstation`, the physical mouse moved the pointer and
clicked correctly inside the guest, but no cursor was ever visually drawn
on screen (forcing Tab+Enter navigation through the Ubuntu installer).
Root cause: SPICE only renders a cursor overlay when mouse input arrives
over its own input channel; a raw `usbN host=vendorid:productid`
passthrough sends the device straight to the guest, bypassing that
channel entirely, so SPICE has no idea a pointer exists to draw. Normally
this would be an unavoidable trade-off of USB passthrough — but on this
particular setup the SPICE client (`remote-viewer`) and the Proxmox host
run on the very same physical machine (see the kiosk pattern above), so
there was never a latency reason to route the mouse around the host in
the first place. Fixed by removing the mouse from `usb_devices` and
letting the host's own X session handle it normally — SPICE picks the
cursor back up via its input channel as soon as the mouse isn't being
passed through anymore. The keyboard and webcam are unaffected — this is
specifically a mouse/SPICE-cursor interaction, not a general problem with
USB passthrough.

<a id="vault-mlock-enomem-in-unprivileged-lxc"></a>
## Vault (CT 300) failed to start with `Failed to lock memory: cannot allocate memory` even with `setcap cap_ipc_lock=+ep` correctly applied inside an unprivileged LXC

`vault-lxc-init.sh` follows the same `setcap`-on-the-binary pattern
decided on for `mlock` (rather than `disable_mlock = true`, to keep the
protection live regardless of host swap state — see the script header).
`getcap /usr/local/bin/vault` confirmed the capability was present
(`cap_ipc_lock=ep`), and `whoami` inside the CT was `root` — so the usual
"capability missing" or "wrong user" explanations didn't fit. `systemctl
status vault` showed a restart loop (`auto-restart`, restart counter
climbing into the hundreds), and `journalctl -u vault` gave the actual
error on every attempt:

```
Error initializing core: Failed to lock memory: cannot allocate memory
This usually means that the mlock syscall is not available.
```

The key diagnostic detail: this is `ENOMEM`, not `EPERM`. `EPERM` would
mean the process lacks permission to call `mlockall()` at all (the
capability-missing case); `ENOMEM` means the call is permitted but the
kernel refuses because the process has hit its `RLIMIT_MEMLOCK` ceiling.
A file capability (`cap_ipc_lock=+ep` via `setcap`) grants the
*permission* to attempt the lock — it does **not** raise the *limit* on
how much memory can be locked. In an unprivileged LXC, that limit is
enforced one layer below systemd's own `LimitMEMLOCK=infinity` (which
only governs the resource limit systemd hands to the process it starts,
not the ceiling the *container itself* is allowed by the host) — it's
the host-side LXC config, `lxc.prlimit.memlock` in
`/etc/pve/lxc/<CTID>.conf`, that ultimately caps this for anything
running inside the container, and it defaults far too low for Vault's
default lock size on a fresh unprivileged CT.

**Fix:** set `lxc.prlimit.memlock: unlimited` directly in the container's
Proxmox-side config file (`/etc/pve/lxc/<CTID>.conf`) — not something
`pct set`/any CLI flag exposes, has to be appended to the raw conf file.
Requires a full CT restart (not a `vault.service` restart) to take
effect, since the limit is applied at container-start time from the host
netns/cgroup setup, not something a running container can pick up live.
`vault-lxc-init.sh` now does this as an idempotent guard alongside the
`net0`/nameserver guards already in the script — checks for the line in
`/etc/pve/lxc/${CTID}.conf`, appends and reboots the CT if missing,
no-ops otherwise:

```bash
CONF_FILE="/etc/pve/lxc/${CTID}.conf"
if ! grep -q "lxc.prlimit.memlock" "$CONF_FILE"; then
    echo "lxc.prlimit.memlock: unlimited" >> "$CONF_FILE"
    if [ "$(pct status "${CTID}" | awk '{print $2}')" == "running" ]; then
        pct reboot "${CTID}" 2>/dev/null || true
        sleep 5
    fi
fi
```

After this landed, `vault server` started cleanly on the first attempt —
`setcap` alone was necessary but not sufficient; both the capability
*and* the host-side `prlimit` needed to line up. Worth remembering for
any future service in this repo that wants real `mlock()` semantics
inside an unprivileged LXC (not just Vault) — the same two-part
requirement (file capability + `lxc.prlimit.memlock`) applies generally,
this just happened to be the first workload in the lab that actually
exercises `mlock`.

<a id="vault-add-mask-inline-corrupts-token"></a>
## `::add-mask::` embedded inside a variable assignment silently corrupted the Vault token, not just failed to mask it

While wiring `pipeline.yml`'s `Fetch secrets from Vault` step, an early
draft wrote `VAULT_TOKEN=::add-mask::$VAULT_TOKEN vault kv get ...`,
intending `::add-mask::` to hide the token in the job log. It doesn't
work that way — `::add-mask::<value>` is a GitHub Actions workflow
command, parsed only when it's the literal content of a step's `echo`
output, not when it appears inside a shell variable assignment on the
same line as another command. The actual effect: `VAULT_TOKEN` was set
to the literal string `::add-mask::<token>` (prefix included) for the
`vault kv get` invocation, which is not a valid token, so the call failed
authentication outright. Masking a value that's about to be *used*, not
just logged, has to happen as its own step: `echo "::add-mask::$VALUE"`
on its own line, before the value is referenced anywhere else. Fixed by
splitting the masking into a separate `echo` immediately after each
secret is captured, before it's used in any subsequent command.

<a id="vault-addr-defaults-to-localhost"></a>
## `vault` CLI silently defaults `VAULT_ADDR` to `https://127.0.0.1:8200` when unset, producing a `connection refused` that looks like Vault itself is down

Running `scripts/vault-approle-init.sh` without first exporting
`VAULT_ADDR` failed every `vault` call with `dial tcp 127.0.0.1:8200:
connect: connection refused` and a `WARNING! VAULT_ADDR and -address
unset. Defaulting to https://127.0.0.1:8200.` — easy to misread as "Vault
(CT 300) isn't running" rather than "the CLI is pointed at the wrong
host entirely" (CT 300's actual address is `192.168.100.200:8200`, not
localhost on whatever machine is running the script). The warning line
is printed but easy to miss above the error. Fixed the script itself to
fail fast with a clear message instead of silently trying localhost:
`: "${VAULT_ADDR:?set VAULT_ADDR before running (e.g.
http://192.168.100.200:8200)}"` at the top of
`scripts/vault-approle-init.sh`. Worth remembering for any future
one-off `vault` CLI invocation from the laptop or the runner — always
export `VAULT_ADDR` explicitly first, don't rely on remembering to pass
`-address` per-command.
