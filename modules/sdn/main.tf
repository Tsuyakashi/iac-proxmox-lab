# One Simple SDN zone on one node, with any number of vnets. A vnet with a
# subnet gets a gateway on the node (optionally SNAT out); a vnet without one
# is pure L2 — the node has no address in it, nothing is routed into it.
#
# Apply order: finalizer -> zone -> vnets -> subnets -> applier. On destroy it
# runs backwards and the finalizer goes last, so its apply commits the
# deletions. Every SDN apply does `ifreload` on ALL cluster nodes.

locals {
  subnets = { for k, v in var.vnets : k => v.subnet if v.subnet != null }
}

resource "proxmox_sdn_applier" "finalizer" {}

resource "proxmox_sdn_zone_simple" "this" {
  id    = var.zone_id
  nodes = [var.node_name]
  mtu   = var.mtu

  depends_on = [proxmox_sdn_applier.finalizer]
}

resource "proxmox_sdn_vnet" "this" {
  for_each = var.vnets

  id   = each.key
  zone = proxmox_sdn_zone_simple.this.id

  # The provider can move a vnet to another zone in place, but then Terraform
  # deletes the old zone first and Proxmox refuses ("zone is used by vnet").
  # Replacing vnets together with the zone deletes them before it.
  lifecycle {
    replace_triggered_by = [proxmox_sdn_zone_simple.this]
  }
}

resource "proxmox_sdn_subnet" "this" {
  for_each = local.subnets

  vnet    = proxmox_sdn_vnet.this[each.key].id
  cidr    = each.value.cidr
  gateway = each.value.gateway
  snat    = each.value.snat

  # The subnet ID embeds the zone (<zone>-<cidr>) and must go before its vnet.
  lifecycle {
    replace_triggered_by = [proxmox_sdn_vnet.this[each.key]]
  }
}

resource "proxmox_sdn_applier" "applier" {
  lifecycle {
    replace_triggered_by = [
      proxmox_sdn_zone_simple.this,
      proxmox_sdn_vnet.this,
      proxmox_sdn_subnet.this,
    ]
  }

  depends_on = [
    proxmox_sdn_zone_simple.this,
    proxmox_sdn_vnet.this,
    proxmox_sdn_subnet.this,
  ]
}
