variable "nodes" {
  description = "Nodes topology, mirrors NODES-hash from Tsuyakashi/swarm-lab/Vagrantfile. mac is pinned explicitly and reserved on the router's DHCP server; ip is the address the router hands out for that reservation — not agent-discovered."
  type = map(object({
    tag_name = string
    memory   = number
    cores    = number
    mac      = string
    ip       = string
  }))
  default = {
    "prod-node"  = { tag_name = "prod", memory = 2048, cores = 2, mac = "BC:24:11:B4:5A:47", ip = "192.168.100.101" }
    "stage-node" = { tag_name = "stage", memory = 1024, cores = 1, mac = "BC:24:11:25:44:C6", ip = "192.168.100.102" }
    "dev-node"   = { tag_name = "dev", memory = 1024, cores = 1, mac = "BC:24:11:86:AB:E2", ip = "192.168.100.103" }
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

    # We no longer resolve IPs from the agent (see network_device/mac_address
    # below + router-side DHCP reservation) — skip the lookup entirely so
    # apply/refresh never blocks on or drifts because of agent timing.
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
        address = "dhcp" # still DHCP — just a reserved lease for this MAC on the router
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.cloud_init_user_data[each.key].id
  }

  operating_system {
    type = "l26"
  }
}

output "node_ips" {
  description = "Reserved IPs from var.nodes — must match the DHCP reservations configured on the router for each node's mac"
  value       = { for k, v in var.nodes : k => v.ip }
}

resource "local_file" "ansible_inventory" {
  filename = "${path.module}/inventory.ini"
  content = templatefile("${path.module}/templates/inventory.tpl", {
    nodes = {
      for k, v in var.nodes : k => {
        ip       = v.ip
        tag_name = v.tag_name
      }
    }
  })
}
