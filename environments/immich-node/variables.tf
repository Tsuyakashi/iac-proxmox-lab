variable "proxmox_endpoint" {
  type = string
}

variable "proxmox_api_token" {
  type      = string
  sensitive = true
}

variable "proxmox_insecure" {
  type    = bool
  default = true
}

variable "proxmox_node" {
  description = "Target Proxmox node name"
  type        = string
  default     = "pve"
}

variable "template_vm_id" {
  type    = number
  default = 9000
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

variable "nodes" {
  description = "immich-node topology. Стартовые ресурсы минимальные — 4 vCPU/4GB/50GB, докидываем по ситуации."
  type = map(object({
    tag_name          = string
    memory            = number
    cores             = number
    ip                = string # CIDR
    datastore_id_disk = optional(string, "local-lvm")
    disk_size         = optional(number, 50)
  }))
  default = {
    "immich-node" = {
      tag_name  = "immich",
      memory    = 4096,
      cores     = 4,
      disk_size = 70,
      ip        = "192.168.100.60/24"
    }
  }
}
