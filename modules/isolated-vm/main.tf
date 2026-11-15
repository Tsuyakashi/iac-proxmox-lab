# The common case: one VM in its own SNAT segment, cut off from LAN, other
# segments and the tailnet, internet open.
#
#   sdn (one routed vnet) + pve-image + cloud-init + pve-vm + guest-firewall
#
# Segment and VM live on the same node (Simple zone = node-local gateway/SNAT).
# Anything that does not fit (several VMs, pure-L2 vnets, LXC) — compose the
# building blocks directly.

locals {
  prefix  = split("/", var.segment.cidr)[1]
  gateway = cidrhost(var.segment.cidr, 1)
  address = "${cidrhost(var.segment.cidr, var.segment.host)}/${local.prefix}"
}

module "net" {
  source = "../sdn"

  node_name = var.node_name
  zone_id   = var.segment.zone_id
  vnets = {
    (var.segment.vnet_id) = {
      subnet = {
        cidr    = var.segment.cidr
        gateway = local.gateway
        snat    = true
      }
    }
  }
}

module "image" {
  source = "../pve-image"

  node_name = var.node_name
  file_name = coalesce(var.image.file_name, "${var.name}-${trimsuffix(basename(var.image.url), ".img")}.qcow2")
  url       = var.image.url
}

module "cloud_init" {
  source = "../cloud-init"

  node_name   = var.node_name
  file_name   = "${var.name}-vendor-data.yaml"
  admin_user  = var.admin_user
  docker      = var.cloud_init.docker
  packages    = var.cloud_init.packages
  apt_sources = var.cloud_init.apt_sources
  write_files = var.cloud_init.write_files
  runcmd      = var.cloud_init.runcmd
  bootcmd     = var.cloud_init.bootcmd
  extra       = var.cloud_init.extra
}

module "vm" {
  source = "../pve-vm"

  node_name = var.node_name
  vm_id     = var.vm_id
  name      = var.name
  tags      = var.tags

  cpu         = var.cpu
  memory      = var.memory
  secure_boot = var.secure_boot
  disk = {
    datastore_id = var.disk.datastore_id
    size         = var.disk.size
    image_id     = module.image.id
  }

  networks = [{
    bridge      = module.net.vnet_ids[var.segment.vnet_id]
    mac_address = var.mac_address
    ipv4 = {
      address = local.address
      gateway = local.gateway
    }
  }]

  cloud_init = {
    username            = var.admin_user
    ssh_public_keys     = var.ssh_public_keys
    dns_servers         = var.dns_servers
    vendor_data_file_id = module.cloud_init.file_id
  }

  agent   = { wait_for_ipv4 = true }
  hostpci = var.hostpci

  # SDN applied and snippet on the node before the VM boots.
  depends_on = [module.net, module.cloud_init]
}

module "firewall" {
  source = "../guest-firewall"

  node_name = var.node_name
  guest = {
    vm_id       = module.vm.vm_id
    instance_id = module.vm.instance_id
  }

  ssh_from = [local.gateway]
  rules    = var.firewall_rules
}
