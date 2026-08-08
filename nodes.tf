variable "nodes" {
  description = "Nodes topology, mirrors NODES-hash from Tsuyakashi/swarm-lab/Vagrantfile"
  type = map(object({
    tag_name = string
    memory   = number
    cores    = number
  }))
  default = {
    "prod-node"  = { tag_name = "prod", memory = 2048, cores = 2 }
    "stage-node" = { tag_name = "stage", memory = 1024, cores = 1 }
    "dev-node"   = { tag_name = "dev", memory = 1024, cores = 1 }
  }
}

resource "proxmox_virtual_environment_file" "cloud_init_user_data" {
  for_each = var.nodes

  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_node

  source_raw {
    data = templatefile("${path.module}/cloud-init/user-data.yml.tpl", {
      ssh_public_key    = var.vm_ssh_public_key
      ci_ssh_public_key = var.ci_ssh_public_key
      hostname          = each.key
    })
    file_name = "${each.key}-user-data.yml"
  }
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = var.nodes

  name      = each.key
  node_name = var.proxmox_node
  tags      = [each.value.tag_name]

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  agent {
    enabled = true
  }

  cpu {
    cores = each.value.cores
  }

  memory {
    dedicated = each.value.memory
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

    user_data_file_id = proxmox_virtual_environment_file.cloud_init_user_data[each.key].id
  }

  operating_system {
    type = "l26"
  }
}

output "node_ips" {
  description = "Real IP from DHCP (with qemu-guest-agent)"
  value = {
    for k, v in proxmox_virtual_environment_vm.node :
    k => try(
      [for ip in v.ipv4_addresses : ip if !startswith(ip[0], "127.")][0][0],
      "unknown"
    )
  }
}

resource "local_file" "ansible_inventory" {
  filename = "${path.module}/inventory.ini"
  content = templatefile("${path.module}/templates/inventory.tpl", {
    nodes = {
      for k, v in proxmox_virtual_environment_vm.node : k => {
        ip       = [for ip in v.ipv4_addresses : ip if !startswith(ip[0], "127.")][0][0]
        tag_name = var.nodes[k].tag_name
      }
    }
  })
}
