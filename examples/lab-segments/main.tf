# liusia-lab8 shape: several VMs, one routed SNAT segment + pure-L2 segments,
# one shared image and snippet — composed from the building blocks.

variable "ssh_public_keys" {
  type    = list(string)
  default = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExam deploy"]
}

locals {
  project = "lab8"
  segments = {
    lab8nat = { cidr = "10.66.0.0/24", routed = true }
    lab8h56 = { cidr = "192.168.56.0/24", routed = false }
    lab8h57 = { cidr = "192.168.57.0/24", routed = false }
  }
  gateway = cidrhost(local.segments.lab8nat.cidr, 1)

  vms = {
    hacker = { vm_id = 801, nics = [["lab8nat", 11], ["lab8h56", 102]] }
    server = { vm_id = 802, nics = [["lab8nat", 12], ["lab8h56", 101], ["lab8h57", 101]] }
  }
}

module "net" {
  source = "../../modules/sdn"

  node_name = var.proxmox_node
  zone_id   = "lab8"
  vnets = { for k, s in local.segments : k => {
    subnet = s.routed ? { cidr = s.cidr, gateway = local.gateway, snat = true } : null
  } }
}

module "image" {
  source    = "../../modules/pve-image"
  node_name = var.proxmox_node
  file_name = "${local.project}-resolute-amd64.qcow2"
}

module "cloud_init" {
  source    = "../../modules/cloud-init"
  node_name = var.proxmox_node
  file_name = "${local.project}-vendor-data.yaml"
  packages  = ["net-tools"]
}

module "vm" {
  source   = "../../modules/pve-vm"
  for_each = local.vms

  node_name = var.proxmox_node
  vm_id     = each.value.vm_id
  name      = "${local.project}-${each.key}"
  tags      = [local.project]
  cpu       = { cores = 1 }
  memory    = 1024
  disk      = { size = 10, image_id = module.image.id }

  networks = [for i, n in each.value.nics : {
    bridge = module.net.vnet_ids[n[0]]
    ipv4 = {
      address = "${cidrhost(local.segments[n[0]].cidr, n[1])}/24"
      gateway = i == 0 ? local.gateway : null
    }
  }]

  cloud_init = {
    ssh_public_keys     = var.ssh_public_keys
    vendor_data_file_id = module.cloud_init.file_id
  }

  depends_on = [module.net, module.cloud_init]
}

module "firewall" {
  source   = "../../modules/guest-firewall"
  for_each = local.vms

  node_name = var.proxmox_node
  guest = {
    vm_id       = module.vm[each.key].vm_id
    instance_id = module.vm[each.key].instance_id
  }
  ssh_from    = [local.gateway]
  allow_cidrs = [for n in each.value.nics : local.segments[n[0]].cidr if n[0] != "lab8nat"]
}
