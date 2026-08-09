# environments/runner
#
# Отдельный root-модуль для CI runner. Собственный (локальный) backend,
# применяется вручную с ноутбука — НИКОГДА из CI-джобы самого раннера.
# Причина см. в корневом README ("Two independent root modules, on purpose").

module "ci_runner" {
  source = "../../modules/proxmox-vm"

  name           = "ci-runner"
  proxmox_node   = var.proxmox_node
  template_vm_id = var.template_vm_id
  tags           = ["ci"]
  cores          = 1
  memory         = 1536
  disk_size      = 20

  ip_config = { mode = "dhcp" }

  vm_ssh_public_key = var.vm_ssh_public_key
  ci_ssh_public_key = var.ci_ssh_public_key
}
