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

  docker_group = true
  extra_packages = [
    "docker.io",
    "curl",
    "jq",
    "ansible",
    "unzip",
    "gnupg",
    "software-properties-common",
    "lsb-release",
  ]

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
    "systemctl enable --now docker",
    "wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg",
    "echo \"deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main\" > /etc/apt/sources.list.d/hashicorp.list",
    "apt-get update",
    "apt-get install -y terraform",
    "curl -o /usr/local/bin/mc https://dl.min.io/client/mc/release/linux-amd64/mc",
    "chmod +x /usr/local/bin/mc",
  ]
}
