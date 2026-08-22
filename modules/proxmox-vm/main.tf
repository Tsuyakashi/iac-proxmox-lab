# modules/proxmox-vm
#
# Единица провижининга: одна VM, клонированная из golden image, с cloud-init
# снипетом (пользователь + guest agent + hostname) и либо статическим, либо
# dhcp-адресом. Используется обоими root-модулями (environments/nodes,
# environments/runner) — единственный источник правды для "как выглядит VM
# в этом Proxmox-кластере".
#
# Модуль намеренно НЕ содержит:
#   - backend { }        — решает root-модуль
#   - provider "proxmox"  — конфигурация провайдера (endpoint/token/ssh)
#                            тоже решает root-модуль
# Это стандартное правило: модуль описывает "что" создавать, а не "куда
# катить state" и "с каким аккаунтом ходить в API".

locals {
  # Хостнейм внутри гостя по умолчанию = имя ресурса, но можно переопределить
  hostname = coalesce(var.hostname, var.name)
}

resource "proxmox_virtual_environment_file" "cloud_init_user_data" {
  content_type = "snippets"
  datastore_id = var.datastore_id_snippet
  node_name    = var.proxmox_node

  source_raw {
    data = templatefile("${path.module}/templates/user-data.yml.tpl", {
      ssh_public_key    = var.vm_ssh_public_key
      ci_ssh_public_key = var.ci_ssh_public_key
      hostname          = local.hostname
      extra_packages    = var.extra_packages
      extra_runcmd      = var.extra_runcmd
      write_files       = var.write_files
      docker_group      = var.docker_group
    })
    file_name = "${var.name}-user-data.yml"
  }
}

resource "proxmox_virtual_environment_vm" "this" {
  name      = var.name
  node_name = var.proxmox_node
  tags      = var.tags

  migrate = var.migrate

  clone {
    vm_id     = var.template_vm_id
    node_name = coalesce(var.template_node, var.proxmox_node)
    full      = true
  }

  agent {
    enabled = true

    wait_for_ip {
      disabled = var.wait_for_ip_disabled
    }
  }

  cpu {
    cores = var.cores
    type  = var.cpu_type
  }

  memory {
    dedicated = var.memory
  }

  disk {
    datastore_id = var.datastore_id_disk
    interface    = "scsi0"
    size         = var.disk_size
  }

  network_device {
    bridge      = var.network_bridge
    mac_address = var.mac_address
  }

  serial_device {
    device = "socket"
  }

  vga {
    type = "serial0"
  }

  initialization {
    datastore_id = var.datastore_id_disk
    dns {
      servers = ["1.1.1.1", "8.8.8.8"]
    }

    ip_config {
      ipv4 {
        address = var.ip_config.mode == "static" ? var.ip_config.address : "dhcp"
        gateway = var.ip_config.mode == "static" ? var.ip_config.gateway : null
      }
    }
    user_data_file_id = proxmox_virtual_environment_file.cloud_init_user_data.id
  }

  operating_system {
    type = "l26"
  }
}
