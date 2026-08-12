
# Изолированный внутренний мост под minecraft-node: без физического порта
# (bridge_ports = []), NAT наружу через vmbr0, явный DROP на домашнюю
# подсеть 192.168.100.0/24. См. README "почему изолируем" — VM торчит
# наружу через (в будущем) туннель, компрометация не должна давать доступ
# к MinIO/runner/остальной LAN.

resource "proxmox_virtual_environment_network_linux_bridge" "isolated" {
  node_name = var.proxmox_node
  name      = "vmbr1"
  address   = "${var.isolated_gateway}/24"
  autostart = true
  comment   = "Managed by terraform (environments/minecraft-node) - isolated NAT segment"
}

resource "null_resource" "isolated_nat" {
  # Пересоздаём правила при смене подсети/шлюза
  triggers = {
    subnet  = var.isolated_subnet
    gateway = var.isolated_gateway
  }

  connection {
    type  = "ssh"
    host  = regex("https://([^:/]+)", var.proxmox_endpoint)[0]
    user  = "root"
    agent = true
  }

  provisioner "remote-exec" {
    inline = [
      "sysctl -w net.ipv4.ip_forward=1",
      "grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf",

      "iptables -t nat -C POSTROUTING -s ${var.isolated_subnet} -o vmbr0 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${var.isolated_subnet} -o vmbr0 -j MASQUERADE",
      "iptables -C FORWARD -i vmbr1 -o vmbr0 -d 192.168.100.0/24 -j DROP 2>/dev/null || iptables -A FORWARD -i vmbr1 -o vmbr0 -d 192.168.100.0/24 -j DROP",
      "iptables -C FORWARD -i vmbr1 -o vmbr0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i vmbr1 -o vmbr0 -j ACCEPT",
      "iptables -C FORWARD -i vmbr0 -o vmbr1 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i vmbr0 -o vmbr1 -m state --state ESTABLISHED,RELATED -j ACCEPT",

      # persist через iptables-persistent, если стоит; если нет - правила
      # переживут только до reboot хоста, не забудьте netfilter-persistent save
      "which netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save || echo 'netfilter-persistent not installed - rules are NOT persisted across reboot, install it or add to proxmox-init.sh'"
    ]
  }

  depends_on = [proxmox_virtual_environment_network_linux_bridge.isolated]
}
