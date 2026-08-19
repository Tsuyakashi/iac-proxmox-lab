output "node_ids" {
  description = "Proxmox VM ID по каждой ноде."
  value       = { for k, m in module.ci_runner : k => m.vm_id }
}

output "node_ips" {
  description = "Статические IP нод (из var.nodes — известны заранее, не нужно запрашивать у guest agent)."
  value       = { for k, v in var.nodes : k => split("/", v.ip)[0] }
}
