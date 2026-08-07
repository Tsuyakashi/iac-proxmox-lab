resource "proxmox_virtual_environment_file" "cloud_init_user_data" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_node

  source_raw {
    data = templatefile("${path.module}/cloud-init/user-data.yml.tpl", {
      ssh_public_key = var.vm_ssh_public_key
    })
    file_name = "tf-test-01-user-data.yml"
  }
}

resource "proxmox_virtual_environment_vm" "test_vm" {
  name      = "tf-test-01"
  node_name = var.proxmox_node

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  agent {
    enabled = true
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 2048
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = 10
  }

  network_device {
    bridge = "vmbr0"
  }

  initialization {
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.cloud_init_user_data.id
  }

  operating_system {
    type = "l26"
  }
}

output "test_vm_ipv4" {
  value = proxmox_virtual_environment_vm.test_vm.ipv4_addresses
}
