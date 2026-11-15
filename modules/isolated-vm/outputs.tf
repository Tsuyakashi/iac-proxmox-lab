output "vm_id" {
  value = module.vm.vm_id
}

output "ipv4" {
  description = "VM address in the segment, without the mask."
  value       = module.vm.ipv4
}

output "gateway" {
  description = "Segment gateway (on the node)."
  value       = local.gateway
}

output "vnet_id" {
  value = module.net.vnet_ids[var.segment.vnet_id]
}

output "docker_socket" {
  description = "Rootless docker socket, if enabled."
  value       = module.cloud_init.docker_socket
}

output "vendor_data" {
  description = "Rendered vendor-data, for review."
  value       = module.cloud_init.rendered
}
