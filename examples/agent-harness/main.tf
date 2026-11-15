# agent-harness / azart-bsuir-vm / distributor shape: one isolated Docker VM.
# In a consumer repo the source is
#   git::https://github.com/Tsuyakashi/iac-proxmox-lab.git//modules/isolated-vm?ref=modules/v0.1.0

variable "ssh_public_keys" {
  type    = list(string)
  default = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExam deploy"]
}

module "sandbox" {
  source = "../../modules/isolated-vm"

  node_name = var.proxmox_node
  name      = "agent-harness-sandbox"
  vm_id     = 610
  tags      = ["agent-harness", "sandbox"]

  segment = {
    zone_id = "agsbx"
    vnet_id = "agsbxv"
    cidr    = "10.62.0.0/24"
  }

  cpu    = { cores = 2 }
  memory = 4096
  disk   = { size = 40 }

  ssh_public_keys = var.ssh_public_keys

  cloud_init = {
    docker = {
      enabled  = true
      rootless = { username = "agent", uid = 1500 }
    }
  }
}

output "ssh" {
  value = "ssh -J root@${module.nodes.ssh_address} deploy@${module.sandbox.ipv4}"
}

output "agent_docker_socket" {
  value = module.sandbox.docker_socket
}

output "vendor_data" {
  value = module.sandbox.vendor_data
}
