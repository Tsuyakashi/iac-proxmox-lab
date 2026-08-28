variable "proxmox_api_token" {
  type      = string
  sensitive = true
}

variable "proxmox_insecure" {
  type    = bool
  default = true
}

variable "proxmox_node" {
  description = "Target Proxmox node name — VM 101 живёт на pve-rog по факту (см. Datacenter tree), не bare-pve, как было раньше в дефолте."
  type        = string
  default     = "pve-rog"
}

variable "vm_ssh_public_key" {
  type = string
}

variable "ci_ssh_public_key" {
  type = string
}

variable "gateway" {
  type    = string
  default = "192.168.100.1"
}

variable "proxmox_host_ip" {
  description = "IP хоста для ssh qm set (raw disk passthrough не заводится через provider). Синхронизирован с var.proxmox_node — если поменяешь ноду размещения, поменяй и этот IP."
  type        = string
  default     = "192.168.100.20"
}

variable "nodes" {
  description = "immich-node topology. Стартовые ресурсы минимальные — 4 vCPU/4GB/50GB, докидываем по ситуации."
  type = map(object({
    tag_name           = string
    memory             = number
    cores              = number
    ip                 = string # CIDR
    datastore_id_disk  = optional(string, "local-lvm")
    disk_size          = optional(number, 50)
    cpu_type           = optional(string, "host")
    recovery_ro_device = optional(string, null)
  }))
  default = {
    "immich-node" = {
      tag_name           = "immich",
      memory             = 4096,
      cores              = 2,
      disk_size          = 100,
      ip                 = "192.168.100.60/24"
      cpu_type           = "host",
      recovery_ro_device = "/dev/sdb1"
    }
  }
}
