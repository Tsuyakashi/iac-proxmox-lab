output "node_ids" {
  description = "Proxmox VM ID по каждой desktop VM."
  value       = { for k, v in proxmox_virtual_environment_vm.workstation : k => v.vm_id }
}

output "note" {
  description = "IP не выводится — нет cloud-init/static-конфига, адрес видно после установки (DHCP-лог роутера, или что задашь вручную в инсталляторе)."
  value       = "no static IP tracked — set/observe it during manual install"
}
