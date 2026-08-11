#cloud-config
hostname: ${hostname}
fqdn: ${hostname}
preserve_hostname: false
package_update: true
packages:
%{ for pkg in extra_packages ~}
  - ${pkg}
%{ endfor ~}
users:
  - name: ubuntu
    ssh_authorized_keys:
      - ${ssh_public_key}
      - ${ci_ssh_public_key}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
%{ if docker_group ~}
    groups: [docker]
%{ endif ~}
%{ if length(write_files) > 0 ~}
write_files:
%{ for f in write_files ~}
  - path: ${f.path}
    owner: ${f.owner}
    permissions: '${f.permissions}'
    content: |
${indent(6, f.content)}
%{ endfor ~}
%{ endif ~}
runcmd:
  - apt-get install -y qemu-guest-agent
  - systemctl enable --now qemu-guest-agent
  - hostnamectl set-hostname ${hostname}
  - sed -i "s/^127.0.1.1.*/127.0.1.1\t${hostname}/" /etc/hosts || echo "127.0.1.1\t${hostname}" >> /etc/hosts
%{ for cmd in extra_runcmd ~}
  - ${cmd}
%{ endfor ~}
