# proxmox-hosted-workstation shape: no SDN, plain vmbr0, installed OS.
#   - Windows VM: ISO install, whole-device passthrough by mapping name,
#     started/run state owned by the GPU arbiter, no firewall.
#   - Privileged desktop LXC: created stopped, the node script adds the rest.
# Mappings themselves live in iac-proxmox-lab/environments/hardware.

module "windows" {
  source = "../../modules/pve-vm"

  node_name = "bare-pve"
  vm_id     = 700
  name      = "windows-workstation"
  tags      = ["workstation", "gpu"]
  os_type   = "win10"
  on_boot   = false
  started   = false

  cpu    = { cores = 4, type = "host" }
  memory = 12288
  disk   = { size = 60, interface = "sata0", file_format = "raw" }
  cdrom  = { file_id = "none", interface = "ide2" }

  networks = [{ bridge = "vmbr0", mac_address = "BC:24:11:F9:5D:82", model = "e1000", firewall = false }]
  agent    = { enabled = false }

  hostpci = [
    { mapping = "gtx1660s", xvga = true },
    { mapping = "usb-xhci" },
    { mapping = "onboard-audio" },
  ]
}

module "ubuntu_desktop" {
  source = "../../modules/pve-ct"

  node_name        = "bare-pve"
  vm_id            = 701
  name             = "ubuntu-workstation"
  tags             = ["workstation", "gpu"]
  unprivileged     = false
  start_on_boot    = false
  started          = false
  template_file_id = "local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst"
  cores            = 4
  memory           = 12288
  swap             = 0
  disk             = { size = 64 }
  network          = { mac_address = "BC:24:11:AB:CD:01", firewall = false }
}
