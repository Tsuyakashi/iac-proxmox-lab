terraform {
  backend "s3" {
    bucket                      = "iac-proxmox-lab-tfstate"
    key                         = "minecraft-node/terraform.tfstate"
    region                      = "auto"
    endpoints                   = { s3 = "http://192.168.100.100:9000" }
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
    skip_region_validation      = true
    use_path_style              = true
  }
}
