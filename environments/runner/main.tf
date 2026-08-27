# environments/runner
#
# Отдельный root-модуль для CI runner. Собственный (локальный) backend,
# применяется вручную с ноутбука — НИКОГДА из CI-джобы самого раннера.
# Причина см. в корневом README ("Two independent root modules, on purpose").

module "ci_runner" {
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

  docker_group   = true
  extra_packages = []

  write_files = [
    {
      path        = "/home/ubuntu/.terraformrc"
      owner       = "ubuntu:ubuntu"
      permissions = "0644"
      content     = <<-EOT
        provider_installation {
          network_mirror {
            url     = "https://terraform-mirror.yandexcloud.net/"
            include = ["registry.terraform.io/*/*"]
          }
          direct {
            exclude = ["registry.terraform.io/*/*"]
          }
        }
      EOT
    }
  ]

  extra_runcmd = [
    "apt-get install -y docker.io curl jq ansible unzip gnupg software-properties-common lsb-release",
    "systemctl enable --now docker",
    "curl -o /usr/local/bin/terraform http://192.168.100.100:9000/tools/terraform_1.15.8_linux_amd64",
    "chmod +x /usr/local/bin/terraform",
    "curl -o /usr/local/bin/vault http://192.168.100.100:9000/tools/vault_1.19.0_linux_amd64",
    "chmod +x /usr/local/bin/vault",
    "curl -o /usr/local/bin/mc https://dl.min.io/aistor/mc/release/linux-amd64/mc",
    "chmod +x /usr/local/bin/mc",
    "for i in 1 2 3; do ping -c1 -W2 192.168.100.3 && break || sleep 2; done || true"
  ]
}
