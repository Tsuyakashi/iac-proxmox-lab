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

resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/templates/inventory.tpl", {
    nodes = { for k, v in var.nodes : k => {
      tag_name = v.tag_name
      ip       = split("/", v.ip)[0] # без /24 для inventory
    } }
  })
  filename = "${path.module}/inventory.ini"
}
