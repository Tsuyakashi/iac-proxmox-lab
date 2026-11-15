# Cloud image downloaded by the node itself into an `import` datastore.
#
# The resource OWNS the file: `terraform destroy` deletes it from the node,
# and a file with the same name from another state fails with
# "already exists". Hence file_name is required and must be project-prefixed.
#
# Without a checksum a `current` URL is fetched once and never re-checked
# (overwrite = false). New image on purpose: -replace this resource.

variable "node_name" {
  description = "Node that downloads and stores the image. Guests importing it must be on the same node."
  type        = string
}

variable "file_name" {
  description = "Target file name, project-prefixed (e.g. agent-harness-resolute-amd64.qcow2). Must end in .qcow2/.raw/.img."
  type        = string

  validation {
    condition     = can(regex("\\.(qcow2|raw|img)$", var.file_name))
    error_message = "file_name must end in .qcow2, .raw or .img (the import content type requires it)."
  }
}

variable "url" {
  description = "Image URL."
  type        = string
  default     = "https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img"
}

variable "datastore_id" {
  description = "Datastore with the `import` content type."
  type        = string
  default     = "local"
}

variable "checksum" {
  description = "Optional checksum (pin it for a versioned URL, leave null for `current`)."
  type = object({
    value     = string
    algorithm = optional(string, "sha256")
  })
  default = null
}

resource "proxmox_download_file" "this" {
  node_name    = var.node_name
  datastore_id = var.datastore_id
  content_type = "import"
  url          = var.url
  file_name    = var.file_name

  checksum           = try(var.checksum.value, null)
  checksum_algorithm = try(var.checksum.algorithm, null)

  overwrite = false
}

output "id" {
  description = "File ID (<datastore>:import/<file_name>) for pve-vm's disk.image_id."
  value       = proxmox_download_file.this.id
}
