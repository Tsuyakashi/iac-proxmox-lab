# Cloud-init vendor-data snippet. Vendor data is merged on top of the user-data
# Proxmox generates from pve-vm's cloud_init block, so the native user, keys,
# IPs and hostname keep working.
#
# The config is built as an HCL object and yamlencode'd — no YAML templates,
# so no indentation bugs in multi-line write_files content.
#
# Snippets go over SSH (the API cannot upload them, bpg#2112 wontfix):
# the provider needs root SSH to the node.
#
# Vendor data runs on FIRST boot only. A changed snippet is re-uploaded, but an
# existing VM ignores it — recreate the VM to apply it.

locals {
  docker   = var.docker.enabled
  rootless = var.docker.enabled && var.docker.rootless != null
  agent    = local.rootless ? var.docker.rootless : { username = "", uid = 0 }

  daemon_json = jsonencode({
    "log-driver" = "json-file"
    "log-opts"   = { "max-size" = "10m", "max-file" = "3" }
  })

  apt_sources = merge(
    local.docker ? {
      "docker.list" = {
        source = "deb [arch=amd64 signed-by=$KEY_FILE] https://download.docker.com/linux/ubuntu $RELEASE stable"
        keyid  = "9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
      }
    } : {},
    var.apt_sources,
  )

  packages = distinct(concat(
    ["qemu-guest-agent"],
    local.docker ? ["docker-ce", "docker-ce-cli", "containerd.io", "docker-buildx-plugin", "docker-compose-plugin"] : [],
    local.rootless ? ["docker-ce-rootless-extras", "uidmap", "dbus-user-session", "slirp4netns"] : [],
    var.packages,
  ))

  write_files = concat(
    # Written before packages are installed, so dockerd reads it on first start.
    local.docker ? [{ path = "/etc/docker/daemon.json", permissions = "0644", content = local.daemon_json }] : [],
    # User managers get only memory+pids by default; without the rest CPU/IO
    # limits on rootless containers are silently ignored.
    local.rootless ? [{
      path        = "/etc/systemd/system/user@.service.d/delegate.conf"
      permissions = "0644"
      content     = "[Service]\nDelegate=cpu cpuset io memory pids\n"
    }] : [],
    var.write_files,
  )

  # No AppArmor profile for rootlesskit: Ubuntu ships /etc/apparmor.d/rootlesskit,
  # a second profile on the same path makes AppArmor apply neither.
  rootless_runcmd = local.rootless ? [
    "id ${local.agent.username} || useradd --create-home --uid ${local.agent.uid} --shell /usr/sbin/nologin ${local.agent.username}",
    "grep -q '^${local.agent.username}:' /etc/subuid || usermod --add-subuids 300000-365535 --add-subgids 300000-365535 ${local.agent.username}",
    "systemctl daemon-reload",
    "install -d -o ${local.agent.username} -g ${local.agent.username} /home/${local.agent.username}/.config /home/${local.agent.username}/.config/docker",
    "install -o ${local.agent.username} -g ${local.agent.username} -m 0644 /etc/docker/daemon.json /home/${local.agent.username}/.config/docker/daemon.json",
    "loginctl enable-linger ${local.agent.username}",
    "timeout 30 sh -c 'until [ -S /run/user/${local.agent.uid}/bus ]; do sleep 1; done'",
    "runuser -u ${local.agent.username} -- env HOME=/home/${local.agent.username} XDG_RUNTIME_DIR=/run/user/${local.agent.uid} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${local.agent.uid}/bus dockerd-rootless-setuptool.sh install",
  ] : []

  runcmd = concat(
    ["systemctl enable --now qemu-guest-agent"],
    local.docker ? ["usermod -aG docker ${var.admin_user}"] : [],
    local.rootless_runcmd,
    var.runcmd,
  )

  config = merge(
    # A new instance-id (any initialization change) would otherwise regenerate
    # the SSH host keys and break known_hosts.
    { ssh_deletekeys = false },
    length(local.apt_sources) > 0 ? { apt = { sources = local.apt_sources } } : {},
    length(var.bootcmd) > 0 ? { bootcmd = var.bootcmd } : {},
    { packages = local.packages },
    length(local.write_files) > 0 ? { write_files = local.write_files } : {},
    { runcmd = local.runcmd },
    var.extra,
  )

  rendered = "#cloud-config\n${yamlencode(local.config)}"
}

resource "proxmox_virtual_environment_file" "this" {
  node_name    = var.node_name
  datastore_id = var.datastore_id
  content_type = "snippets"

  source_raw {
    file_name = var.file_name
    data      = local.rendered
  }
}
