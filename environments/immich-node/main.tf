# environments/immich-node
#
# Отдельная VM под immich (docker-compose) на .30/local-lvm — 337G свободно
# в thin pool, места достаточно. Не изолирована (в отличие от minecraft-node),
# т.к. immich не выставляется наружу.

module "node" {
  source   = "../../modules/proxmox-vm"
  for_each = var.nodes

  name           = each.key
  proxmox_node   = var.proxmox_node
  template_vm_id = var.template_vm_id
  tags           = [each.value.tag_name]
  cores          = each.value.cores
  memory         = each.value.memory
  cpu_type       = each.value.cpu_type

  datastore_id_disk = each.value.datastore_id_disk
  disk_size         = each.value.disk_size

  ip_config = {
    mode    = "static"
    address = each.value.ip
    gateway = var.gateway
  }
  wait_for_ip_disabled = true

  vm_ssh_public_key = var.vm_ssh_public_key
  ci_ssh_public_key = var.ci_ssh_public_key

  docker_group   = true
  extra_packages = ["docker.io", "docker-compose-v2"]
}

# Raw block-device passthrough (/dev/sdb1 -> scsi1, ro).
# bpg/proxmox не умеет декларативно цеплять физическое устройство хоста
# как disk-ресурс (только datastore-volumes) — идёт через qm set напрямую.
# Идемпотентно (повторный qm set с теми же параметрами — no-op), но при
# пересоздании VM индекс scsi1 нужно перепроверить на коллизии с другими дисками.
resource "null_resource" "recovery_ro_bind" {
  for_each = { for k, v in var.nodes : k => v if v.recovery_ro_device != null }

  triggers = {
    vm_id  = module.node[each.key].vm_id
    device = each.value.recovery_ro_device
  }

  provisioner "local-exec" {
    command = "ssh root@${var.proxmox_host_ip} qm set ${module.node[each.key].vm_id} -scsi1 ${each.value.recovery_ro_device},ro=1"
  }

  depends_on = [module.node]
}
