terraform {
  backend "s3" {
    bucket                      = "iac-proxmox-lab-tfstate"
    key                         = "terraform.tfstate"
    region                      = "us-east-1"
    endpoints                   = { s3 = "http://192.168.100.15:9000" }
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
    skip_region_validation      = true
    use_path_style              = true
  }
}
