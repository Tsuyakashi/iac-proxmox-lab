[swarm_managers]
%{ for name, node in nodes ~}
%{ if node.tag_name == "prod" ~}
${name} ansible_host=${node.ip} tag_name=${node.tag_name}
%{ endif ~}
%{ endfor ~}

[swarm_workers]
%{ for name, node in nodes ~}
%{ if node.tag_name != "prod" ~}
${name} ansible_host=${node.ip} tag_name=${node.tag_name}
%{ endif ~}
%{ endfor ~}

[all:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_user=ubuntu
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
