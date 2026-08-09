#!/bin/bash

set -e

if ! kvm-ok | grep -q "KVM acceleration can be used"; then
    echo "error: KVM acceleration not available"
    exit 1
fi

if ! cat /sys/module/kvm_intel/parameters/nested | grep -q "Y"; then
    echo "error: nested virtualization not enabled"
    exit 1
fi

# Download binary if not exist yet
if [ ! -f "proxmox-ve_8.4-1.iso" ]; then
    wget "https://enterprise.proxmox.com/iso/proxmox-ve_8.4-1.iso"
fi

# Start VM if not exist yet
if ! virsh list --all | grep -q "proxmox-lab"; then
    virt-install \
        --name proxmox-lab \
        --memory 18432 --vcpus 6 \
        --cpu host-passthrough \
        --disk size=60,bus=virtio \
        --cdrom proxmox-ve_8.4-1.iso \
        --network bridge=br0,model=virtio \
        --graphics vnc,listen=0.0.0.0 \
        --os-variant debian12 \
        --virt-type kvm
fi
