terraform {
  required_version = ">= 1.9"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.115.0"
    }
  }

  # backend "s3" { ... }  — per project, see template/
}

variable "proxmox_node" {
  type    = string
  default = "pve-rog"
}

variable "proxmox_api_token" {
  type      = string
  sensitive = true
}

module "nodes" {
  source = "../../modules/pve-nodes"
  node   = var.proxmox_node
}

provider "proxmox" {
  endpoint  = module.nodes.endpoint
  api_token = var.proxmox_api_token

  # Snippets go over SSH; the API cannot upload them.
  ssh {
    agent    = true
    username = "root"

    dynamic "node" {
      for_each = module.nodes.ssh_nodes
      content {
        name    = node.key
        address = node.value
      }
    }
  }
}
