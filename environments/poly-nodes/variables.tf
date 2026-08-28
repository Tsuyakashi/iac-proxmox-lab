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

variable "gateway" {
  description = "LAN gateway for statically-addressed nodes"
  type        = string
  default     = "192.168.100.1"
}

variable "nodes" {
  description = "Nodes topology. mac + ip are both pinned — ip is applied via cloud-init static config, not DHCP, so Proxmox/router never gets a say in which address a node ends up with."
  type = map(object({
    tag_name          = string
    memory            = number
    cores             = number
    mac               = string
    ip                = string # CIDR, e.g. "192.168.100.21/24"
    datastore_id_disk = optional(string, "local-lvm")
    disk_size         = optional(number, 10)
  }))
  default = {
    "runner-node"     = { tag_name = "runner", memory = 2048, cores = 2, mac = "BC:24:11:0F:A0:B3", ip = "192.168.100.110/24" }
    "prod-node"       = { tag_name = "prod", memory = 1024, cores = 1, mac = "BC:24:11:7B:D1:46", ip = "192.168.100.111/24" }
    "monitoring-node" = { tag_name = "monitoring", memory = 2048, cores = 2, mac = "BC:24:11:0B:21:33", ip = "192.168.100.112/24" }
  }
}
