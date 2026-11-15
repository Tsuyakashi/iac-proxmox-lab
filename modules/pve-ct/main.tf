# One LXC container, with only what an API token may set.
#
# root@pam-only in pve-container (check_ct_modify_config_perm, no privilege
# grants it): dev[n] passthrough, hookscript, every feature flag except
# `nesting`, and any feature flag at all on a privileged CT; raw lxc.* lines
# are not settable through the API whatsoever. All of that is done on the
# node by a project script after apply — and ignored below, so an apply never
# strips it (removing a mount_point forces a full CT recreate).
#
# Privileged CT creation needs Sys.Modify on / for the token.
#
# ignore_changes (static, union of every consumer):
#   template_file_id   a newer tarball under the same name must not recreate a live CT
#   started            run state is not Terraform's after create
#   features           node script sets keyctl/fuse/...; privileged CT: all flags
#   device_passthrough node script (root@pam)
#   mount_point        node script bind mounts; mount_points var is create-time only
#   hook_script_file_id, description   node script (raw lxc.* comments surface as description)
#   console            pct create stamps tty/cmode defaults
#   initialization dns domain   searchdomain drift

resource "proxmox_virtual_environment_container" "this" {
  node_name     = var.node_name
  vm_id         = var.vm_id
  unprivileged  = var.unprivileged
  start_on_boot = var.start_on_boot
  started       = var.started
  tags          = sort(distinct(concat(["terraform"], var.tags)))

  operating_system {
    template_file_id = var.template_file_id
    type             = var.os_type
  }

  cpu {
    cores = var.cores
  }

  memory {
    dedicated = var.memory
    swap      = var.swap
  }

  disk {
    datastore_id = var.disk.datastore_id
    size         = var.disk.size
  }

  network_interface {
    name        = "eth0"
    bridge      = var.network.bridge
    mac_address = var.network.mac_address
    firewall    = var.network.firewall
  }

  initialization {
    hostname = var.name

    ip_config {
      ipv4 {
        address = var.network.ipv4_address
        gateway = var.network.ipv4_address == "dhcp" ? null : var.network.ipv4_gateway
      }
    }

    # Pinned by default: a fresh CT copies the node's resolv.conf, which on
    # these nodes is MagicDNS (100.100.100.100) — unreachable from the CT's netns.
    dynamic "dns" {
      for_each = var.nameservers == null && var.search_domain == null ? [] : [1]
      content {
        domain  = var.search_domain
        servers = var.nameservers
      }
    }

    dynamic "user_account" {
      for_each = length(var.ssh_public_keys) > 0 || var.password != null ? [1] : []
      content {
        keys     = [for k in var.ssh_public_keys : trimspace(k)]
        password = var.password
      }
    }
  }

  # A token may send only `nesting`, and only on an unprivileged CT; on a
  # privileged one any features block 403s the whole create.
  dynamic "features" {
    for_each = var.unprivileged ? [1] : []
    content {
      nesting = var.nesting
    }
  }

  dynamic "startup" {
    for_each = var.startup_order == null ? [] : [var.startup_order]
    content {
      order = startup.value
    }
  }

  dynamic "mount_point" {
    for_each = { for m in var.mount_points : m.path => m }
    content {
      volume    = mount_point.value.volume
      path      = mount_point.value.path
      size      = mount_point.value.size
      read_only = mount_point.value.read_only
      backup    = mount_point.value.backup
    }
  }

  lifecycle {
    ignore_changes = [
      operating_system[0].template_file_id,
      started,
      features,
      device_passthrough,
      mount_point,
      hook_script_file_id,
      description,
      console,
      initialization[0].dns[0].domain,
    ]
  }
}

# Changes on every (re)create — see pve-vm.
resource "terraform_data" "instance" {
  triggers_replace = proxmox_virtual_environment_container.this.id
}
