variable "proxmox_endpoint" {
  description = "Proxmox API endpoint, e.g. https://192.168.100.20:8006/"
  type        = string
}

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
  default     = "pve"
}

variable "template_vm_id" {
  description = "VM ID of the cloud-init template to clone from"
  type        = number
  default     = 9000
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
    tag_name = string
    memory   = number
    cores    = number
    mac      = string
    ip       = string # CIDR, e.g. "192.168.100.21/24"
  }))
  default = {
    "prod-node"  = { tag_name = "prod", memory = 2048, cores = 2, mac = "BC:24:11:B4:5A:47", ip = "192.168.100.101/24" }
    "stage-node" = { tag_name = "stage", memory = 1024, cores = 1, mac = "BC:24:11:25:44:C6", ip = "192.168.100.102/24" }
    "dev-node"   = { tag_name = "dev", memory = 1024, cores = 1, mac = "BC:24:11:86:AB:E2", ip = "192.168.100.103/24" }
  }
}
