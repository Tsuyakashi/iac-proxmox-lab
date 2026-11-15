output "vm_id" {
  description = "Proxmox VMID."
  value       = proxmox_virtual_environment_vm.this.vm_id
}

output "name" {
  value = proxmox_virtual_environment_vm.this.name
}

output "instance_id" {
  description = "Changes on every (re)create of the VM. Feed it to guest-firewall."
  value       = terraform_data.instance.id
}

output "ipv4" {
  description = "Static address of the first NIC without the mask; null if it is dhcp or there is no cloud-init."
  value       = var.cloud_init != null && var.networks[0].ipv4 != null ? split("/", var.networks[0].ipv4.address)[0] : null
}

output "addresses" {
  description = "Static addresses of all NICs in order (null for dhcp)."
  value       = [for n in var.networks : n.ipv4 == null ? null : split("/", n.ipv4.address)[0]]
}
