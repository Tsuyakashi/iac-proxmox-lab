variable "nodes" {
  description = "Nodes topology. mac + ip are both pinned — ip is applied via cloud-init static config, not DHCP, so Proxmox/router never gets a say in which address a node ends up with."
  type = map(object({
    tag_name = string
    memory   = number
    cores    = number
    mac      = string
    ip       = string # CIDR, e.g. "192.168.100.21/24"
  }))
  default = {
    "prod-node"  = { tag_name = "prod", memory = 2048, cores = 2, mac = "BC:24:11:B4:5A:47", ip = "192.168.100.101/24" }
    "stage-node" = { tag_name = "stage", memory = 1024, cores = 1, mac = "BC:24:11:25:44:C6", ip = "192.168.100.102/24" }
    "dev-node"   = { tag_name = "dev", memory = 1024, cores = 1, mac = "BC:24:11:86:AB:E2", ip = "192.168.100.103/24" }
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

    # Terraform assigns the IP statically via ip_config below — no need
    # to wait for the guest agent to report it back.
    wait_for_ip {
      disabled = true
    }
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
    bridge      = "vmbr0"
    mac_address = each.value.mac
  }

  initialization {
    ip_config {
      ipv4 {
        address = each.value.ip
        gateway = var.gateway
      }
    }
    user_data_file_id = proxmox_virtual_environment_file.cloud_init_user_data[each.key].id
  }

  operating_system {
    type = "l26"
  }
}

resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/templates/inventory.tpl", {
    nodes = { for k, v in var.nodes : k => {
      tag_name = v.tag_name
      ip       = split("/", v.ip)[0] # без /24 для inventory
    } }
  })
  filename = "${path.module}/inventory.ini"
}
