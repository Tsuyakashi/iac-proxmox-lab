variable "node_name" {
  description = "Node the guest runs on."
  type        = string
}

variable "guest" {
  description = "Exactly one of vm_id / container_id, plus instance_id from pve-vm / pve-ct."
  type = object({
    vm_id        = optional(number)
    container_id = optional(number)
    instance_id  = string
  })

  validation {
    condition     = (var.guest.vm_id == null) != (var.guest.container_id == null)
    error_message = "Set exactly one of guest.vm_id or guest.container_id."
  }
}

variable "input_policy" {
  type    = string
  default = "DROP"
}

variable "allow_dhcp" {
  description = "Let the guest do DHCP. false for static addressing (SDN segments)."
  type        = bool
  default     = false
}

variable "allow_ndp" {
  description = "IPv6 neighbor discovery. Off — the segments are IPv4-only."
  type        = bool
  default     = false
}

variable "rules" {
  description = "Rules placed first, as-is."
  type = list(object({
    type    = string
    action  = string
    proto   = optional(string)
    dport   = optional(string)
    sport   = optional(string)
    source  = optional(string)
    dest    = optional(string)
    macro   = optional(string)
    comment = optional(string)
  }))
  default = []
}

variable "ssh_from" {
  description = "Sources allowed to tcp/22 in. For an SDN guest: the segment gateway (ssh -J root@<node>)."
  type        = list(string)
  default     = []
}

variable "allow_cidrs" {
  description = "Networks allowed both ways, before the blocks (e.g. lab segments the guest is attached to)."
  type        = list(string)
  default     = []
}

variable "blocked_ranges" {
  description = "Out DROP. Default: every private range + the tailnet CGNAT range. [] for a guest that should see the LAN."
  type        = list(string)
  default     = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10"]
}
