variable "node_name" {
  description = "Node for the segment AND the VM."
  type        = string
}

variable "name" {
  description = "VM name / hostname; also prefixes the image and snippet file names on the node."
  type        = string
}

variable "vm_id" {
  description = "Fixed VMID from the registry; null = next free."
  type        = number
  default     = null
}

variable "tags" {
  type    = list(string)
  default = []
}

variable "segment" {
  description = "Own SNAT segment. IDs: 1-8 lowercase alnum. host: the VM's host number in the CIDR (gateway is .1)."
  type = object({
    zone_id = string
    vnet_id = string
    cidr    = string
    host    = optional(number, 10)
  })
}

variable "mac_address" {
  description = "null = Proxmox generates one (macfilter uses the configured MAC either way)."
  type        = string
  default     = null
}

variable "cpu" {
  type = object({
    cores   = optional(number, 2)
    sockets = optional(number, 1)
    type    = optional(string, "x86-64-v2-AES")
  })
  default = {}
}

variable "memory" {
  type    = number
  default = 2048
}

variable "disk" {
  type = object({
    datastore_id = optional(string, "local-lvm")
    size         = optional(number, 20)
  })
  default = {}
}

variable "secure_boot" {
  type    = bool
  default = true
}

variable "image" {
  description = "Cloud image. file_name null = <name>-<url basename>.qcow2 (unique per project on the node)."
  type = object({
    url       = optional(string, "https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img")
    file_name = optional(string)
  })
  default = {}
}

variable "admin_user" {
  type    = string
  default = "deploy"
}

variable "ssh_public_keys" {
  type = list(string)
}

variable "dns_servers" {
  description = "Required in practice: the node's resolver (MagicDNS) is not reachable from the segment."
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

variable "cloud_init" {
  description = "Passed to the cloud-init module (see its variables)."
  type = object({
    docker = optional(object({
      enabled = optional(bool, false)
      rootless = optional(object({
        username = optional(string, "agent")
        uid      = optional(number, 1500)
      }))
    }), {})
    packages    = optional(list(string), [])
    apt_sources = optional(any, {})
    write_files = optional(any, [])
    runcmd      = optional(any, [])
    bootcmd     = optional(any, [])
    extra       = optional(any, {})
  })
  default = {}
}

variable "hostpci" {
  description = "PCI passthrough by mapping name (see pve-vm)."
  type = list(object({
    mapping  = string
    pcie     = optional(bool, true)
    rombar   = optional(bool, true)
    rom_file = optional(string)
    xvga     = optional(bool, false)
  }))
  default = []
}

variable "firewall_rules" {
  description = "Extra firewall rules placed first (see guest-firewall)."
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
