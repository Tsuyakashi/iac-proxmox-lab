variable "node_name" {
  description = "Node the snippet is uploaded to (same node as the VM)."
  type        = string
}

variable "file_name" {
  description = "Snippet file name, unique per node (e.g. <vm-name>-vendor-data.yaml)."
  type        = string
}

variable "datastore_id" {
  description = "Datastore with the `snippets` content type."
  type        = string
  default     = "local"
}

variable "admin_user" {
  description = "Admin account created by pve-vm's cloud_init.user; added to the docker group when docker is on."
  type        = string
  default     = "deploy"
}

variable "docker" {
  description = <<-EOT
    Docker from download.docker.com (key pinned by fingerprint) with json-file
    log rotation. rootless != null adds a rootless daemon owned by an
    unprivileged nologin user (fixed uid -> socket at /run/user/<uid>/docker.sock),
    with cgroup v2 delegation and linger. amd64 only.
  EOT
  type = object({
    enabled = optional(bool, false)
    rootless = optional(object({
      username = optional(string, "agent")
      uid      = optional(number, 1500)
    }))
  })
  default = {}
}

variable "packages" {
  description = "Extra apt packages (qemu-guest-agent is always there)."
  type        = list(string)
  default     = []
}

variable "apt_sources" {
  description = "Extra cloud-init apt.sources entries, merged with the docker one."
  type        = any
  default     = {}
}

variable "write_files" {
  description = "Extra cloud-init write_files entries, passed through as-is (path, content, owner, permissions, defer, ...)."
  type        = any
  default     = []
}

variable "runcmd" {
  description = "Extra runcmd entries, run after the built-in ones."
  type        = any
  default     = []
}

variable "bootcmd" {
  description = "bootcmd entries (every boot, early)."
  type        = any
  default     = []
}

variable "extra" {
  description = "Any other top-level cloud-config keys (timezone, users, ...). Merged last — a key here REPLACES the built-in one."
  type        = any
  default     = {}
}
