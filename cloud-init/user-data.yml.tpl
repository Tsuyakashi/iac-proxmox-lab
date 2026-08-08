hostname: ${hostname}
fqdn: ${hostname}
preserve_hostname: false
package_update: true
packages:
  - qemu-guest-agent
users:
  - name: ubuntu
    ssh_authorized_keys:
      - ${ssh_public_key}
      - ${ci_ssh_public_key}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
runcmd:
  - systemctl enable --now qemu-guest-agent
  - hostnamectl set-hostname ${hostname}
  - sed -i "s/^127.0.1.1.*/127.0.1.1\t${hostname}/" /etc/hosts || echo "127.0.1.1\t${hostname}" >> /etc/hosts
