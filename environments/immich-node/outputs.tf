output "node_ids" {
  value = { for k, m in module.node : k => m.vm_id }
}

output "node_ips" {
  value = { for k, v in var.nodes : k => split("/", v.ip)[0] }
}
