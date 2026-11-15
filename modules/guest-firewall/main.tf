# Per-guest Proxmox firewall (VM or CT). Enforced on the host tap/veth, out
# of reach of root in the guest — but ONLY with the datacenter firewall on
# (pvesh get /cluster/firewall/options -> enable: 1) and firewall = true on
# the NIC (pve-vm / pve-ct default).
#
# Rule order, first match wins:
#   1. var.rules            arbitrary, e.g. UDP 41641 in for direct tailscale
#   2. ssh_from             tcp/22 in from these sources (usually the segment gateway)
#   3. allow_cidrs          in+out ACCEPT for these networks (lab segments)
#   4. blocked_ranges       out DROP — the node routes an SNAT segment into
#                           everything it can reach itself: LAN, other SDN
#                           segments, the node, the tailnet with ITS identity
#
# Tailscale traffic inside the guest is in WireGuard — invisible here;
# the tailnet ACL is the boundary for that.
#
# Proxmox deletes <vmid>.fw with the guest; replacing these resources with the
# guest (via instance_id) avoids a stale in-place update after a recreate.

locals {
  target_vm = var.guest.vm_id
  target_ct = var.guest.container_id
}

resource "terraform_data" "guest" {
  input = var.guest.instance_id
}

resource "proxmox_virtual_environment_firewall_options" "this" {
  node_name    = var.node_name
  vm_id        = local.target_vm
  container_id = local.target_ct

  enabled       = true
  input_policy  = var.input_policy
  output_policy = "ACCEPT"
  macfilter     = true
  dhcp          = var.allow_dhcp
  # Provider default for radv is true: a guest could send IPv6 RAs into the segment.
  radv = false
  ndp  = var.allow_ndp

  lifecycle {
    replace_triggered_by = [terraform_data.guest]
  }
}

resource "proxmox_virtual_environment_firewall_rules" "this" {
  node_name    = var.node_name
  vm_id        = local.target_vm
  container_id = local.target_ct

  dynamic "rule" {
    for_each = var.rules
    content {
      type    = rule.value.type
      action  = rule.value.action
      proto   = rule.value.proto
      dport   = rule.value.dport
      sport   = rule.value.sport
      source  = rule.value.source
      dest    = rule.value.dest
      macro   = rule.value.macro
      comment = rule.value.comment
    }
  }

  dynamic "rule" {
    for_each = var.ssh_from
    content {
      type    = "in"
      action  = "ACCEPT"
      proto   = "tcp"
      dport   = "22"
      source  = rule.value
      comment = "ssh from ${rule.value}"
    }
  }

  dynamic "rule" {
    for_each = var.allow_cidrs
    content {
      type    = "in"
      action  = "ACCEPT"
      source  = rule.value
      comment = "allow in ${rule.value}"
    }
  }

  dynamic "rule" {
    for_each = var.allow_cidrs
    content {
      type    = "out"
      action  = "ACCEPT"
      dest    = rule.value
      comment = "allow out ${rule.value}"
    }
  }

  dynamic "rule" {
    for_each = var.blocked_ranges
    content {
      type    = "out"
      action  = "DROP"
      dest    = rule.value
      comment = "isolation ${rule.value}"
    }
  }

  depends_on = [proxmox_virtual_environment_firewall_options.this]

  lifecycle {
    replace_triggered_by = [terraform_data.guest]
  }
}
