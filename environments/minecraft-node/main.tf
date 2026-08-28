# environments/minecraft-node
#
# Изолированный node на своём NAT-сегменте (vmbr1). Раньше template_node был
# захардкожен на "bare-pve", хотя сама VM клонируется на pve-rog (через
# each.value.proxmox_node) — рабочий кросс-нодовый клон, но именно он был
# причиной бага "unable to find configuration file for VM 9000 on node
# 'pve-rog'" (см. docs/troubleshooting.md). Теперь template_node и
# template_vm_id всегда резолвятся из той же ноды, что и сам apply —
# кросс-нодовый клон больше не нужен в принципе (у каждой ноды свой local
# golden image, 9000 на bare-pve / 9001 на pve-rog).

module "node" {
  source   = "../../modules/proxmox-vm"
  for_each = var.nodes

  name              = each.key
  template_node     = coalesce(each.value.proxmox_node, var.proxmox_node)
  template_vm_id    = local.proxmox_nodes[coalesce(each.value.proxmox_node, var.proxmox_node)].template_vm_id
  tags              = [each.value.tag_name]
  cores             = each.value.cores
  memory            = each.value.memory
  mac_address       = each.value.mac
  datastore_id_disk = each.value.datastore_id_disk

  proxmox_node = coalesce(each.value.proxmox_node, var.proxmox_node)
  migrate      = true # временно, на время миграции

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

  extra_packages = ["openjdk-25-jre-headless", "curl"]

  write_files = [
    {
      path        = "/home/ubuntu/minecraft/eula.txt"
      owner       = "ubuntu:ubuntu"
      permissions = "0644"
      content     = "eula=true"
    },
    {
      path        = "/etc/systemd/system/minecraft.service"
      owner       = "root:root"
      permissions = "0644"
      content     = <<-EOT
        [Unit]
        Description=Minecraft Server
        After=network.target

        [Service]
        User=ubuntu
        WorkingDirectory=/home/ubuntu/minecraft
        ExecStart=/usr/bin/java -Xmx3584M -Xms3584M -jar server.jar nogui
        Restart=on-failure
        RestartSec=5

        [Install]
        WantedBy=multi-user.target
      EOT
    }
  ]

  extra_runcmd = [
    "mkdir -p /home/ubuntu/minecraft",
    "curl -o /home/ubuntu/minecraft/server.jar ${var.server_jar_url}",
    "chown -R ubuntu:ubuntu /home/ubuntu/minecraft",
    "apt-get install -y gnupg",
    "curl -SsL https://playit-cloud.github.io/ppa/key.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/playit.gpg",
    "echo 'deb [signed-by=/etc/apt/trusted.gpg.d/playit.gpg] https://playit-cloud.github.io/ppa/data ./' > /etc/apt/sources.list.d/playit-cloud.list",
    "apt-get update",
    "apt-get install -y playit",
    "mkdir -p /etc/playit",
    "echo 'secret_key = \"${var.playit_secret_key}\"' > /etc/playit/playit.toml",
    "chown playit:playit /etc/playit/playit.toml",
    "chmod 600 /etc/playit/playit.toml",
    "systemctl daemon-reload",
    "systemctl enable --now minecraft.service",
    "systemctl enable playit",
    "systemctl restart playit",
  ]
}
