#!/bin/bash

set -e

if ! pveum user list | grep -q "terraform@pve"; then
    pveum user add terraform@pve
fi

if ! pveum role list | grep -q "TerraformProv"; then
    pveum role modify TerraformProv -privs "VM.Allocate VM.Clone VM.Config.Disk VM.Config.CPU VM.Config.Memory VM.Config.Network VM.Config.Options VM.Config.CDROM VM.Config.Cloudinit VM.PowerMgmt VM.Audit VM.Console VM.Monitor Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit SDN.Use"
fi

pveum aclmod / -user terraform@pve -role TerraformProv

if ! pveum user token list terraform@pve | grep -q "provider-token"; then
    pveum user token add terraform@pve provider-token --privsep 0 --output-format json > /root/terraform-token.json
    echo "Token secret saved to /root/terraform-token.json — copy it to terraform.tfvars, then consider deleting this file."
fi

if [ ! -f "noble-server-cloudimg-amd64.img" ]; then
    wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
fi

if ! qm status 9000 &>/dev/null; then
    qm create 9000 --name ubuntu-cloud-template --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0
    qm importdisk 9000 noble-server-cloudimg-amd64.img local-lvm
    qm set 9000 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9000-disk-0
    qm set 9000 --ide2 local-lvm:cloudinit
    qm set 9000 --boot c --bootdisk scsi0
    qm set 9000 --serial0 socket --vga serial0
    qm template 9000
fi
