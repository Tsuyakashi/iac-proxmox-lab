output "file_id" {
  description = <<-EOT
    Snippet ID for pve-vm's cloud_init.vendor_data_file_id. Built as a string,
    not read from the resource: editing the snippet must not recreate the VM.
    So ordering is on the caller — depends_on = [module.<this>] on the VM.
  EOT
  value       = "${var.datastore_id}:snippets/${var.file_name}"
}

output "rendered" {
  description = "Rendered cloud-config, for review in plan."
  value       = local.rendered
}

output "docker_socket" {
  description = "Rootless daemon socket, or null when rootless is off."
  value       = local.rootless ? "/run/user/${local.agent.uid}/docker.sock" : null
}
