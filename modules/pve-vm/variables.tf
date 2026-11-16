variable "node_name" {
  description = "Node the VM runs on."
  type        = string
}

variable "name" {
  description = "VM name, also the guest hostname under cloud-init."
  type        = string
}

variable "vm_id" {
  description = <<-EOT
    Fixed VMID (see the registry); null = next free. Set it for anything
    long-lived: if create fails after Proxmox made the VM (API timeout under
    IO load), the retry fails with "already exists" instead of creating an
    untracked duplicate.
  EOT
  type        = number
  default     = null
}

variable "description" {
  type    = string
  default = "Managed by Terraform"
}

variable "tags" {
  description = "Extra tags; \"terraform\" is always added."
  type        = list(string)
  default     = []
}

variable "on_boot" {
  description = "Start with the node. false for guests started by something else (GPU arbiter)."
  type        = bool
  default     = true
}

variable "started" {
  description = "Start after create. Create-time only (ignored afterwards)."
  type        = bool
  default     = true
}

variable "os_type" {
  description = "l26 for Linux, win10/win11 for Windows (Proxmox then adds the Hyper-V enlightenments)."
  type        = string
  default     = "l26"
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
  description = "RAM in MiB. With PCI passthrough all of it is pinned on the host."
  type        = number
  default     = 2048
}

variable "secure_boot" {
  description = "Pre-enrolled Secure Boot keys on the EFI disk. Signed in-tree modules load; out-of-tree (nvidia 470 dkms) don't."
  type        = bool
  default     = true
}

variable "disk" {
  description = <<-EOT
    Boot disk. image_id = cloud image file ID (pve-image) imported at create;
    null = empty disk (install from cdrom). interface: virtio0 for Linux,
    sata0 for an installer without virtio drivers.
  EOT
  type = object({
    datastore_id = optional(string, "local-lvm")
    size         = optional(number, 20)
    interface    = optional(string, "virtio0")
    image_id     = optional(string)
    file_format  = optional(string)
  })
  default = {}
}

variable "cdrom" {
  description = "ISO drive; file_id \"none\" keeps an empty drive. When set, boot order is cdrom then disk. Verify the actual slot with `qm config` — the provider may pick another IDE slot."
  type = object({
    file_id   = optional(string, "none")
    interface = optional(string, "ide2")
  })
  default = null
}

variable "networks" {
  description = <<-EOT
    NICs in order (net0, net1, ...). ipv4 is used only with cloud_init;
    null there = dhcp. Only the first NIC may carry a gateway.
  EOT
  type = list(object({
    bridge      = string
    mac_address = optional(string)
    model       = optional(string, "virtio")
    firewall    = optional(bool, true)
    ipv4 = optional(object({
      address = string
      gateway = optional(string)
    }))
  }))

  validation {
    condition     = length(var.networks) >= 1
    error_message = "At least one NIC is required."
  }

  validation {
    condition     = alltrue([for i, n in var.networks : i == 0 || n.ipv4 == null || try(n.ipv4.gateway, null) == null])
    error_message = "Only the first NIC may have a gateway; a second default route breaks routing."
  }
}

variable "cloud_init" {
  description = "Cloud-init drive. null = none (installed OS). vendor_data_file_id from the cloud-init module."
  type = object({
    datastore_id        = optional(string, "local-lvm")
    username            = optional(string, "deploy")
    ssh_public_keys     = list(string)
    dns_servers         = optional(list(string), ["1.1.1.1", "8.8.8.8"])
    vendor_data_file_id = optional(string)
    user_data_file_id   = optional(string)
  })
  default = null
}

variable "agent" {
  description = "QEMU guest agent. Off for an installed OS until the agent is in the guest. wait_for_ipv4 blocks apply until the agent reports an address."
  type = object({
    enabled       = optional(bool, true)
    wait_for_ipv4 = optional(bool, false)
  })
  default = {}
}

variable "hostpci" {
  description = "Whole PCI devices by cluster mapping name -> hostpci0..N in list order. xvga = primary GPU (output to the monitor, web console goes serial)."
  type = list(object({
    mapping  = string
    pcie     = optional(bool, true)
    rombar   = optional(bool, true)
    rom_file = optional(string)
    xvga     = optional(bool, false)
  }))
  default = []
}

variable "usb" {
  description = "Single USB devices (host = vendor:product or bus-port) or USB mappings. Whole controllers go through hostpci instead."
  type = list(object({
    host    = optional(string)
    mapping = optional(string)
    usb3    = optional(bool, false)
  }))
  default = []
}

variable "vga_type" {
  description = "Display type (std, serial0, ...). null = provider default."
  type        = string
  default     = null
}

variable "extra_disks" {
  description = <<-EOT
    Data disks besides the boot disk, created empty. Grow one by raising
    size (in place); never shrink. interface must be unique and differ from
    disk.interface (e.g. sata1, scsi1, virtio1).
  EOT
  type = list(object({
    interface    = string
    size         = number
    datastore_id = optional(string, "local-lvm")
    file_format  = optional(string)
    ssd          = optional(bool, false)
    backup       = optional(bool, true)
  }))
  default = []

  validation {
    condition = (
      length(distinct([for d in var.extra_disks : d.interface])) == length(var.extra_disks) &&
      !contains([for d in var.extra_disks : d.interface], var.disk.interface)
    )
    error_message = "extra_disks interfaces must be unique and differ from disk.interface."
  }
}

variable "protection" {
  description = "Proxmox protection flag: the VM and its disks cannot be removed (incl. terraform destroy) until it is cleared."
  type        = bool
  default     = false
}
