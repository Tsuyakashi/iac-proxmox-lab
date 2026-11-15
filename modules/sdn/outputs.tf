output "zone_id" {
  description = "SDN zone ID."
  value       = proxmox_sdn_zone_simple.this.id
}

output "vnet_ids" {
  description = "Vnet key => vnet ID (the bridge name for network devices). Depends on the applier, so guests wait for the SDN apply."
  value       = { for k, v in proxmox_sdn_vnet.this : k => v.id }

  depends_on = [proxmox_sdn_applier.applier]
}

output "gateways" {
  description = "Vnet key => gateway IP, for routed vnets only."
  value       = { for k, v in local.subnets : k => v.gateway if v.gateway != null }
}
