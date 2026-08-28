# Тот же принцип, что и у остальных environments — endpoint выводится из
# proxmox_node, не задаётся отдельной переменной. golden image здесь не
# нужен вообще (workstation не использует modules/proxmox-vm / clone{}).
locals {
  proxmox_endpoints = {
    "bare-pve" = "https://192.168.100.30:8006/"
    "pve-rog"  = "https://192.168.100.20:8006/"
  }

  proxmox_endpoint = local.proxmox_endpoints[var.proxmox_node]
}
