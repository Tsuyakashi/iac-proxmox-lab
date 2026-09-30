# environments/runner/backend.tf
terraform {
  backend "s3" {
    bucket                      = "iac-proxmox-lab-tfstate"
    key                         = "runner/terraform.tfstate"
    region                      = "auto"
    endpoints                   = { s3 = "https://lxc-bare-pve.tail65829d.ts.net:9000" }
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
    skip_region_validation      = true
    use_path_style              = true
  }
}
