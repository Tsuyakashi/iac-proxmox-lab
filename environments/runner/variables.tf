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
    "ci-node" = { tag_name = "ci", memory = 2028, cores = 2, mac = "BC:24:11:13:83:51", ip = "192.168.100.50/24" }
  }
}
