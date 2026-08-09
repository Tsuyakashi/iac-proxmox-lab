variable "nodes" {
  description = "Nodes topology, mirrors NODES-hash from Tsuyakashi/swarm-lab/Vagrantfile. mac is pinned so Proxmox never regenerates it on unrelated applies."
  type = map(object({
    tag_name = string
    memory   = number
    cores    = number
    mac      = string
  }))
  default = {
    "prod-node"  = { tag_name = "prod", memory = 2048, cores = 2, mac = "BC:24:11:B4:5A:47" }
    "stage-node" = { tag_name = "stage", memory = 1024, cores = 1, mac = "BC:24:11:25:44:C6" }
    "dev-node"   = { tag_name = "dev", memory = 1024, cores = 1, mac = "BC:24:11:86:AB:E2" }
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

    # IP resolution no longer happens through Terraform at all — it's
    # resolved live by Ansible's community.proxmox.proxmox dynamic
    # inventory at deploy time (see ansible-inventory/proxmox.proxmox.yml).
    # Terraform's job here ends at "VM exists, tagged correctly".
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
        address = "dhcp"
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.cloud_init_user_data[each.key].id
  }

  operating_system {
    type = "l26"
  }
}
