# Single source of truth for cluster nodes. Pure data, no resources and no
# provider: a root module can feed its outputs straight into the provider
# block, because every value here is known at plan time.
#
#   module "nodes" {
#     source = "git::https://github.com/Tsuyakashi/iac-proxmox-lab.git//modules/pve-nodes?ref=modules/v0.1.0"
#     node   = var.proxmox_node
#   }
#
#   provider "proxmox" {
#     endpoint  = module.nodes.endpoint
#     api_token = var.proxmox_api_token
#     ssh {
#       agent    = true
#       username = "root"
#       dynamic "node" {
#         for_each = module.nodes.ssh_nodes
#         content {
#           name    = node.key
#           address = node.value
#         }
#       }
#     }
#   }

variable "node" {
  description = "Node this root module talks to. Picks the API endpoint; must be a key of var.nodes."
  type        = string
}

variable "nodes" {
  description = <<-EOT
    Cluster nodes. endpoint: API URL; ssh_address: what the provider SSHes to
    for snippet uploads (without it the provider uses the node IP the API
    reports). Override per machine with a *_override.tf, not in git.
  EOT
  type = map(object({
    endpoint    = string
    ssh_address = string
  }))
  default = {
    "bare-pve" = {
      endpoint    = "https://lxc-bare-pve.tail65829d.ts.net:8006/"
      ssh_address = "bare-pve.tail65829d.ts.net"
    }
    "pve-rog" = {
      endpoint    = "https://lxc-pve-rog.tail65829d.ts.net:8006/"
      ssh_address = "pve-rog.tail65829d.ts.net"
    }
    "amd-pve" = {
      endpoint    = "https://lxc-amd-pve.tail65829d.ts.net:8006/"
      ssh_address = "amd-pve.tail65829d.ts.net"
    }
  }
}

check "node_known" {
  assert {
    condition     = contains(keys(var.nodes), var.node)
    error_message = "node \"${var.node}\" is not in var.nodes (${join(", ", keys(var.nodes))})."
  }
}

output "node" {
  description = "The selected node name."
  value       = var.node
}

output "endpoint" {
  description = "API endpoint of the selected node."
  value       = var.nodes[var.node].endpoint
}

output "ssh_address" {
  description = "SSH address of the selected node (jump host for guests in its SDN segments)."
  value       = var.nodes[var.node].ssh_address
}

output "ssh_nodes" {
  description = "node name => SSH address, for the provider's ssh { node {} } blocks."
  value       = { for k, v in var.nodes : k => v.ssh_address }
}

output "all" {
  description = "The full node map."
  value       = var.nodes
}
