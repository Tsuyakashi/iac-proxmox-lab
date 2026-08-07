resource "proxmox_virtual_environment_file" "runner_user_data" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_node

  source_raw {
    data = templatefile("${path.module}/cloud-init/user-data.yml.tpl", {
      ssh_public_key = var.vm_ssh_public_key
    })
    file_name = "ci-runner-user-data.yml"
  }
}

resource "proxmox_virtual_environment_vm" "ci_runner" {
  name      = "ci-runner"
  node_name = var.proxmox_node
  tags      = ["ci"]

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  agent {
    enabled = true
  }

  cpu {
    cores = 1
  }

  memory {
    dedicated = 1536
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = 20
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

    user_data_file_id = proxmox_virtual_environment_file.runner_user_data.id
  }

  operating_system {
    type = "l26"
  }
}

output "ci_runner_ip" {
  value = try(
    [for ip in proxmox_virtual_environment_vm.ci_runner.ipv4_addresses :
      ip[0] if length(ip) > 0 && startswith(ip[0], "192.168.100.")
    ][0],
    null
  )
}
