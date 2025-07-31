#!/usr/bin/env bash
# scripts/build-router-image.sh

set -euo pipefail

echo "Building router VM qcow2 image..."
nix build .#router-vm-image --impure

if [[ -f result/nixos.qcow2 ]]; then
    echo "✓ Router VM image built successfully"
    echo "  Image: $(realpath result/nixos.qcow2)"
    echo "  Size: $(du -h result/nixos.qcow2 | cut -f1)"
    
    # Copy to expected location for libvirt
    sudo mkdir -p /var/lib/libvirt/images
    sudo cp result/nixos.qcow2 /var/lib/libvirt/images/router-vm.qcow2
    sudo chown qemu:qemu /var/lib/libvirt/images/router-vm.qcow2
    echo "✓ Image copied to /var/lib/libvirt/images/router-vm.qcow2"
else
    echo "✗ Failed to build router VM image"
    exit 1
fi
