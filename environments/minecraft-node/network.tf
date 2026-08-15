
# Изолированный внутренний мост под minecraft-node: без физического порта
# (bridge_ports = []), NAT наружу через vmbr0, явный DROP на домашнюю
# подсеть 192.168.100.0/24. См. README "почему изолируем" — VM торчит
# наружу через (в будущем) туннель, компрометация не должна давать доступ
# к MinIO/runner/остальной LAN.

resource "proxmox_network_linux_bridge" "isolated" {
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

      "iptables -D FORWARD -i vmbr1 -j FORWARD-VMBR1 2>/dev/null || true",
      "iptables -F FORWARD-VMBR1 2>/dev/null || true",
      "iptables -X FORWARD-VMBR1 2>/dev/null || true",

      "iptables -N FORWARD-VMBR1",
      "iptables -A FORWARD-VMBR1 -m state --state ESTABLISHED,RELATED -j ACCEPT",
      "iptables -A FORWARD-VMBR1 -o vmbr0 -j ACCEPT",
      "iptables -A FORWARD-VMBR1 -j DROP",
      "iptables -A FORWARD -i vmbr1 -j FORWARD-VMBR1",

      "iptables -D INPUT -i vmbr1 -j DROP 2>/dev/null || true",
      "iptables -C INPUT -i vmbr1 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i vmbr1 -m state --state ESTABLISHED,RELATED -j ACCEPT",
      "iptables -A INPUT -i vmbr1 -j DROP",

      "which netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save || echo 'netfilter-persistent not installed - rules are NOT persisted across reboot, install it or add to proxmox-init.sh'"
    ]
  }

  depends_on = [proxmox_network_linux_bridge.isolated]
}
