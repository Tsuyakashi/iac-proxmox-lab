# One VM: q35 + OVMF, Secure Boot keys pre-enrolled by default.
#
# Covers both shapes used across the repos:
#   - cloud guest: disk.image_id (cloud image via import_from) + cloud_init
#   - installed guest (Windows): empty disk + cdrom ISO, cloud_init = null
# plus whole-device PCI passthrough through cluster hardware mappings
# (Mapping.Use + VM.Config.HWType; a raw PCI address is root@pam-only).
#
# NOT here, root@pam-only, applied on the node and ignored below:
# hookscript (qm set --hookscript), args (qm set --args).
#
# ignore_changes is static, so it is the union of what every consumer needs:
#   started             run state belongs to whoever starts the guest (arbiter, you)
#   hook_script_file_id set on the node, must not be ripped off by an apply
#   kvm_arguments       same
#   machine             Windows pins pc-q35-X.Y at create; resetting it to "q35"
#                       = chipset change for the guest (re-activation)

locals {
  boot_order = var.cdrom == null ? null : [var.cdrom.interface, var.disk.interface]
}

resource "proxmox_virtual_environment_vm" "this" {
  node_name   = var.node_name
  vm_id       = var.vm_id
  name        = var.name
  description = var.description
  tags        = sort(distinct(concat(["terraform"], var.tags)))
  on_boot     = var.on_boot
  protection  = var.protection
  started     = var.started

  machine       = "q35"
  bios          = "ovmf"
  scsi_hardware = "virtio-scsi-single"

  operating_system {
    type = var.os_type
  }

  agent {
    enabled = var.agent.enabled
    trim    = var.agent.enabled

    wait_for_ip {
      # Without this block the provider waits for any address up to the
      # timeout — 15 minutes when the agent is not in the guest yet.
      ipv4     = var.agent.wait_for_ipv4 ? true : null
      disabled = !var.agent.wait_for_ipv4
    }
  }

  cpu {
    cores   = var.cpu.cores
    sockets = var.cpu.sockets
    type    = var.cpu.type
  }

  memory {
    dedicated = var.memory
  }

  efi_disk {
    datastore_id      = var.disk.datastore_id
    type              = "4m"
    pre_enrolled_keys = var.secure_boot
  }

  disk {
    datastore_id = var.disk.datastore_id
    interface    = var.disk.interface
    import_from  = var.disk.image_id
    size         = var.disk.size
    file_format  = var.disk.file_format
    iothread     = startswith(var.disk.interface, "virtio") || startswith(var.disk.interface, "scsi")
    discard      = "on"
  }

  # Data disks next to the boot disk (empty, not imported). Order is not
  # significant: the provider keys them by interface.
  dynamic "disk" {
    for_each = var.extra_disks
    content {
      datastore_id = disk.value.datastore_id
      interface    = disk.value.interface
      size         = disk.value.size
      file_format  = disk.value.file_format
      ssd          = disk.value.ssd
      backup       = disk.value.backup
      iothread     = startswith(disk.value.interface, "virtio") || startswith(disk.value.interface, "scsi")
      discard      = "on"
    }
  }

  dynamic "cdrom" {
    for_each = var.cdrom == null ? [] : [var.cdrom]
    content {
      file_id   = cdrom.value.file_id
      interface = cdrom.value.interface
    }
  }

  boot_order = local.boot_order

  # NIC order = net0, net1, ...; ip_config below follows the same order.
  dynamic "network_device" {
    for_each = var.networks
    content {
      bridge      = network_device.value.bridge
      mac_address = network_device.value.mac_address
      model       = network_device.value.model
      firewall    = network_device.value.firewall
    }
  }

  dynamic "hostpci" {
    for_each = { for i, d in var.hostpci : i => d }
    content {
      device   = "hostpci${hostpci.key}"
      mapping  = hostpci.value.mapping
      pcie     = hostpci.value.pcie
      rombar   = hostpci.value.rombar
      rom_file = hostpci.value.rom_file
      xvga     = hostpci.value.xvga
    }
  }

  dynamic "usb" {
    for_each = var.usb
    content {
      host    = usb.value.host
      mapping = usb.value.mapping
      usb3    = usb.value.usb3
    }
  }

  dynamic "vga" {
    for_each = var.vga_type == null ? [] : [var.vga_type]
    content {
      type = vga.value
    }
  }

  # Cloud images log to the serial console; with an x-vga GPU the web console
  # falls back to it too.
  serial_device {}

  dynamic "initialization" {
    for_each = var.cloud_init == null ? [] : [var.cloud_init]
    content {
      datastore_id = initialization.value.datastore_id

      dynamic "ip_config" {
        for_each = var.networks
        content {
          ipv4 {
            address = ip_config.value.ipv4 == null ? "dhcp" : ip_config.value.ipv4.address
            gateway = ip_config.value.ipv4 == null ? null : ip_config.value.ipv4.gateway
          }
        }
      }

      dns {
        servers = initialization.value.dns_servers
      }

      user_account {
        username = initialization.value.username
        keys     = [for k in initialization.value.ssh_public_keys : trimspace(k)]
      }

      vendor_data_file_id = initialization.value.vendor_data_file_id
      user_data_file_id   = initialization.value.user_data_file_id
    }
  }

  lifecycle {
    ignore_changes = [started, hook_script_file_id, kvm_arguments, machine]
  }
}

# A fresh UUID every time the VM is (re)created: guest-firewall keys its own
# replacement off this, because Proxmox deletes <vmid>.fw together with the VM
# and a fixed vm_id alone would not change across a recreate. The VM's id is
# unknown while it is planned for replacement, which replaces this too.
resource "terraform_data" "instance" {
  triggers_replace = proxmox_virtual_environment_vm.this.id
}
