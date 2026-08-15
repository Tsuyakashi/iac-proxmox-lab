# environments/poly-nodes
#
# Root-модуль runner/prod/monitoring нод. Отдельный state (S3/MinIO, см. backend.tf),

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

  datastore_id_disk = each.value.datastore_id_disk
  disk_size         = each.value.disk_size

  ip_config = {
    mode    = "static"
    address = each.value.ip
    gateway = var.gateway
  }
  # IP известен заранее (static), нет смысла ждать guest agent на apply
  wait_for_ip_disabled = true

  vm_ssh_public_key = var.vm_ssh_public_key
  ci_ssh_public_key = var.ci_ssh_public_key
}
