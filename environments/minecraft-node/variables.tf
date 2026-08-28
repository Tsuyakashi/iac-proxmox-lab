variable "proxmox_api_token" {
  description = "Proxmox API token, format: user@realm!token-name=uuid-secret"
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification (needed for self-signed Proxmox cert)"
  type        = bool
  default     = true
}

variable "proxmox_node" {
  description = "Target Proxmox node name"
  type        = string
  default     = "bare-pve"
}

variable "vm_ssh_public_key" {
  description = "SSH public key to inject into the VM via cloud-init"
  type        = string
}

variable "ci_ssh_public_key" {
  description = "Public key for CI/CD deploy access (no passphrase, dedicated to automation)"
  type        = string
}

variable "nodes" {
  description = "Nodes topology. mac + ip are both pinned — ip is applied via cloud-init static config, not DHCP, so Proxmox/router never gets a say in which address a node ends up with."
  type = map(object({
    tag_name = string
    memory   = number
    cores    = number
    mac      = string
    ip       = string # CIDR, e.g. "192.168.100.21/24"

    proxmox_node      = optional(string)
    datastore_id_disk = optional(string, "local-lvm")
  }))
  default = {
    "minecraft-node" = {
      tag_name          = "mc",
      memory            = 4096,
      cores             = 4,
      mac               = "BC:24:11:4E:74:3B",
      ip                = "10.10.10.50/24",
      proxmox_node      = "pve-rog",
      datastore_id_disk = "shared-storage"
    }
  }
}

variable "isolated_subnet" {
  description = "Подсеть изолированного сегмента minecraft-node."
  type        = string
  default     = "10.10.10.0/24"
}

variable "isolated_gateway" {
  description = "Gateway (адрес vmbr1 на хосте) для изолированного сегмента."
  type        = string
  default     = "10.10.10.1"
}

variable "playit_secret_key" {
  description = "playit.gg agent secret key (создать заранее на playit.gg/account/agents)"
  type        = string
  sensitive   = true
}

variable "server_jar_url" {
  type    = string
  default = "https://piston-data.mojang.com/v1/objects/823e2250d24b3ddac457a60c92a6a941943fcd6a/server.jar"
}
