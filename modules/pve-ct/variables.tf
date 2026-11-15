variable "node_name" {
  description = "Node the CT runs on."
  type        = string
}

variable "name" {
  description = "Hostname / CT name."
  type        = string
}

variable "vm_id" {
  description = "Fixed CTID (see the registry); null = next free."
  type        = number
  default     = null
}

variable "tags" {
  description = "Extra tags; \"terraform\" is always added."
  type        = list(string)
  default     = []
}

variable "unprivileged" {
  description = "Keep true. false only for a CT that needs a real logind seat/udev (GPU desktop); needs Sys.Modify on / for the token."
  type        = bool
  default     = true
}

variable "start_on_boot" {
  type    = bool
  default = true
}

variable "started" {
  description = "Start after create. Create-time only. false when the node script must run before the first start."
  type        = bool
  default     = true
}

variable "startup_order" {
  type    = number
  default = null
}

variable "template_file_id" {
  description = "LXC template volume ID (local:vztmpl/<file>), NOT a cloud image. Read at create only."
  type        = string
}

variable "os_type" {
  type    = string
  default = "ubuntu"
}

variable "cores" {
  type    = number
  default = 1
}

variable "memory" {
  description = "RAM in MiB."
  type        = number
  default     = 1024
}

variable "swap" {
  description = "Swap in MiB."
  type        = number
  default     = 512
}

variable "disk" {
  description = "rootfs."
  type = object({
    datastore_id = optional(string, "local-lvm")
    size         = optional(number, 8)
  })
  default = {}
}

variable "network" {
  description = "eth0. ipv4_address: \"dhcp\" or a CIDR."
  type = object({
    bridge       = optional(string, "vmbr0")
    mac_address  = optional(string)
    firewall     = optional(bool, true)
    ipv4_address = optional(string, "dhcp")
    ipv4_gateway = optional(string)
  })
  default = {}

  validation {
    condition     = var.network.ipv4_address == "dhcp" || can(cidrhost(var.network.ipv4_address, 0))
    error_message = "network.ipv4_address must be \"dhcp\" or a CIDR."
  }
}

variable "nameservers" {
  description = "Resolvers. null = inherit the node's (MagicDNS on these nodes — broken in the CT)."
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

variable "search_domain" {
  type    = string
  default = null
}

variable "ssh_public_keys" {
  description = "root authorized_keys in the CT."
  type        = list(string)
  default     = []
}

variable "password" {
  type      = string
  default   = null
  sensitive = true
}

variable "nesting" {
  description = "features.nesting (systemd needs it). Sent only for unprivileged CTs."
  type        = bool
  default     = true
}

variable "mount_points" {
  description = "Datastore-backed mount points. CREATE-TIME ONLY (mount_point is ignored afterwards). Host bind mounts are root@pam — node script."
  type = list(object({
    volume    = string
    path      = string
    size      = optional(string)
    read_only = optional(bool, false)
    backup    = optional(bool, true)
  }))
  default = []
}
