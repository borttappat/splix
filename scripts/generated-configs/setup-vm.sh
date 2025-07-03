#!/bin/bash
# Setup router VM with passthrough

set -euo pipefail

echo "=== Setting up Router VM ==="

# Check if we're ready
if ! systemctl is-active --quiet libvirtd; then
    echo "ERROR: libvirtd not running. Apply host-passthrough.nix first and reboot."
    exit 1
fi

# Create VM disk
echo "1. Creating VM disk..."
mkdir -p /var/lib/libvirt/images
if [[ ! -f /var/lib/libvirt/images/router-vm.qcow2 ]]; then
    qemu-img create -f qcow2 /var/lib/libvirt/images/router-vm.qcow2 10G
    echo "   ✓ Created 10GB disk"
else
    echo "   ⚠ Disk already exists"
fi

# Define VM
echo "2. Defining VM in libvirt..."
virsh define router-vm.xml
echo "   ✓ VM defined"

# Check device availability
echo "3. Checking device availability..."
if lspci -s 0000:00:14.3 | grep -q "Kernel driver in use: vfio-pci"; then
    echo "   ✓ Device bound to VFIO"
elif lspci -s 0000:00:14.3 | grep -q "Kernel driver in use: iwlwifi"; then
    echo "   ⚠ Device still bound to iwlwifi - reboot required"
    echo "   Apply host-passthrough.nix and reboot first"
    exit 1
else
    echo "   ⚠ Device driver status unclear"
fi

echo
echo "VM setup complete!"
echo
echo "Next steps:"
echo "1. Start VM: virsh start router-vm"
echo "2. Connect console: virsh console router-vm"
echo "3. Install NixOS using router-vm-config.nix"
echo "4. Configure WiFi credentials in the VM"
echo
echo "Emergency recovery: ./emergency-recovery.sh"
