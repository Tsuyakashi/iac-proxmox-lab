variable "name" {
  description = "Имя VM в Proxmox и имя file_name для cloud-init снипета."
  type        = string
}

variable "hostname" {
  description = "Hostname внутри гостя (cloud-init). По умолчанию = var.name."
  type        = string
  default     = null
}

variable "proxmox_node" {
  description = "Целевая Proxmox-нода (кластерный узел, не имя VM)."
  type        = string
}

variable "template_vm_id" {
  description = "VM ID golden image, из которого клонируется VM."
  type        = number
}

variable "tags" {
  description = "Теги Proxmox VM (например [\"prod\"], [\"ci\"])."
  type        = list(string)
  default     = []
}

variable "cores" {
  description = "Количество vCPU."
  type        = number
}

variable "memory" {
  description = "Выделенная память, MB."
  type        = number
}

variable "disk_size" {
  description = "Размер системного диска, GB."
  type        = number
  default     = 10
}

variable "datastore_id_disk" {
  description = "Datastore для диска VM."
  type        = string
  default     = "local-lvm"
}

variable "datastore_id_snippet" {
  description = "Datastore, в который загружается cloud-init снипет (должен поддерживать content type 'snippets')."
  type        = string
  default     = "local"
}

variable "mac_address" {
  description = "Пиновать MAC-адрес сетевого интерфейса. null = Proxmox назначит сам."
  type        = string
  default     = null
}

variable "ip_config" {
  description = <<-EOT
    Сетевая конфигурация, применяемая через cloud-init:
      mode    = "static" | "dhcp"
      address = CIDR-адрес, обязателен при mode = "static" (например "192.168.100.101/24")
      gateway = обязателен при mode = "static"
  EOT
  type = object({
    mode    = string
    address = optional(string)
    gateway = optional(string)
  })

  validation {
    condition     = contains(["static", "dhcp"], var.ip_config.mode)
    error_message = "ip_config.mode должен быть \"static\" или \"dhcp\"."
  }

  validation {
    condition     = var.ip_config.mode != "static" || (var.ip_config.address != null && var.ip_config.gateway != null)
    error_message = "При ip_config.mode = \"static\" обязательны address и gateway."
  }
}

variable "wait_for_ip_disabled" {
  description = "Не ждать guest agent для получения IP (актуально для static — адрес и так известен заранее)."
  type        = bool
  default     = false
}

variable "vm_ssh_public_key" {
  description = "SSH-ключ пользователя, инжектится через cloud-init."
  type        = string
}

variable "ci_ssh_public_key" {
  description = "SSH-ключ для CI/CD-доступа (без passphrase, отдельный от пользовательского)."
  type        = string
}

variable "extra_packages" {
  description = "Additional apt packages to install via cloud-init (on top of qemu-guest-agent)."
  type        = list(string)
  default     = []
}

variable "extra_runcmd" {
  description = "Additional shell commands to run via cloud-init runcmd, after the base setup."
  type        = list(string)
  default     = []
}

variable "write_files" {
  description = "Additional files to write via cloud-init write_files (e.g. ~/.terraformrc)."
  type = list(object({
    path        = string
    owner       = optional(string, "root:root")
    permissions = optional(string, "0644")
    content     = string
  }))
  default = []
}

variable "docker_group" {
  description = "Add the ubuntu user to the docker group (only meaningful if docker.io is in extra_packages)."
  type        = bool
  default     = false
}

variable "network_bridge" {
  type    = string
  default = "vmbr0"
}
