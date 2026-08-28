# Node placement is now the single source of truth: proxmox_node decides
# both the API endpoint and the golden image to clone from. Add a node here
# once, when it's actually added to the cluster — environments reference it
# by name (var.proxmox_node or a per-entry override), never re-state the
# endpoint/image pair in tfvars.
locals {
  proxmox_nodes = {
    "bare-pve" = {
      endpoint       = "https://192.168.100.30:8006/"
      template_vm_id = 9000
    }
    "pve-rog" = {
      endpoint       = "https://192.168.100.20:8006/"
      template_vm_id = 9001
    }
  }

  proxmox_endpoint = local.proxmox_nodes[var.proxmox_node].endpoint
  template_vm_id   = local.proxmox_nodes[var.proxmox_node].template_vm_id
}
