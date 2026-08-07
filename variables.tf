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
