# environments/nodes
#
# Root-модуль prod/stage/dev нод. Отдельный state (S3/MinIO, см. backend.tf),
# отдельный lifecycle от environments/runner — так, чтобы terraform apply
# здесь никогда не мог задеть CI runner (и наоборот). Подробности инцидента,
# из-за которого это разделение появилось — см. корневой README.

module "node" {
  source   = "../../modules/proxmox-vm"
  for_each = var.nodes

  name           = each.key
  proxmox_node   = var.proxmox_node
  template_vm_id = var.template_vm_id
  tags           = [each.value.tag_name]
  cores          = each.value.cores
  memory         = each.value.memory
  mac_address    = each.value.mac

  network_bridge = "vmbr1"


  ip_config = {
    mode    = "static"
    address = each.value.ip
    gateway = var.isolated_gateway
  }
  wait_for_ip_disabled = true

  vm_ssh_public_key = var.vm_ssh_public_key
  ci_ssh_public_key = var.ci_ssh_public_key

  # явно зависим от готовности моста/NAT, иначе VM может стартовать раньше
  depends_on = [proxmox_network_linux_bridge.isolated]
}
