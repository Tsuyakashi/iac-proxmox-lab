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
  type    = string
  default = "pve"
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
