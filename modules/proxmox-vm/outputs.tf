output "vm_id" {
  description = "Proxmox VM ID созданной VM."
  value       = proxmox_virtual_environment_vm.this.vm_id
}

output "name" {
  description = "Имя VM (= var.name)."
  value       = proxmox_virtual_environment_vm.this.name
}

output "ipv4_addresses" {
  description = <<-EOT
    Сырой список интерфейс -> [адреса], как его репортит QEMU guest agent.
    Пусто, пока agent не поднялся и не отчитался (актуально в первую очередь
    для dhcp-режима — при static IP уже известен вызывающей стороне заранее
    из var.ip_config.address).
  EOT
  value       = proxmox_virtual_environment_vm.this.ipv4_addresses
}
