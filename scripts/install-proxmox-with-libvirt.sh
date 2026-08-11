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

# Ensure br0 is up and has enp4s0 attached (br0-port sometimes reverts to standalone
# 'auto' profile after VM teardown/host reboot)
if ! nmcli -t -f DEVICE,STATE connection show --active | grep -q "^enp4s0:activated" 2>/dev/null; then
    if ! nmcli -g GENERAL.STATE device show br0 2>/dev/null | grep -q "^100"; then
        echo "br0 not up, attempting to bring it up..."
        nmcli connection up br0 || { echo "error: failed to bring up br0"; exit 1; }
    fi
fi

if ! nmcli -t -f DEVICE connection show --active | grep -q "^br0-port$"; then
    echo "enp4s0 not attached to br0, reattaching..."
    nmcli connection modify br0-port master br0
    nmcli connection up br0-port || { echo "error: failed to attach enp4s0 to br0 — check SSH session survives"; exit 1; }
fi

if ! ip -4 addr show br0 | grep -q "inet "; then
    echo "error: br0 has no IPv4 address, network setup incomplete"
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
