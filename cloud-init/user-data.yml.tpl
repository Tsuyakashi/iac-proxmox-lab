#cloud-config
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
