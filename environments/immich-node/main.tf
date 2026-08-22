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
