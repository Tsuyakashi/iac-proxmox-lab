variable "node_name" {
  description = "Node the zone lives on. Gateways and SNAT of routed vnets come up here; guests using the vnets must run here too."
  type        = string
}

variable "zone_id" {
  description = "SDN zone ID: 1-8 lowercase alphanumerics, starting with a letter."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{0,7}$", var.zone_id))
    error_message = "zone_id must be 1-8 lowercase alphanumeric chars, starting with a letter."
  }
}

variable "vnets" {
  description = <<-EOT
    Vnets keyed by ID (same naming rule as zone_id; the ID is also the bridge
    name guests attach to). subnet = null -> pure L2.
  EOT
  type = map(object({
    subnet = optional(object({
      cidr    = string
      gateway = optional(string)
      snat    = optional(bool, false)
    }))
  }))

  validation {
    condition     = alltrue([for id in keys(var.vnets) : can(regex("^[a-z][a-z0-9]{0,7}$", id))])
    error_message = "Every vnet ID must be 1-8 lowercase alphanumeric chars, starting with a letter."
  }

  validation {
    condition     = alltrue([for v in values(var.vnets) : v.subnet == null || can(cidrhost(v.subnet.cidr, 0))])
    error_message = "subnet.cidr must be a valid CIDR."
  }
}

variable "mtu" {
  description = "Zone MTU. Simple zone is plain bridging, so 1500 is fine."
  type        = number
  default     = 1500
}
