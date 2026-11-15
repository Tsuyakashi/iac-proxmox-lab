output "vm_id" {
  description = "CTID."
  value       = proxmox_virtual_environment_container.this.vm_id
}

output "instance_id" {
  description = "Changes on every (re)create of the CT. Feed it to guest-firewall."
  value       = terraform_data.instance.id
}

output "ipv4" {
  description = "Static address without the mask; null for dhcp."
  value       = var.network.ipv4_address == "dhcp" ? null : split("/", var.network.ipv4_address)[0]
}
