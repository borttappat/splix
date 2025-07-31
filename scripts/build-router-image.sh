#!/usr/bin/env bash
# scripts/build-router-image.sh

set -euo pipefail

echo "Building router VM qcow2 image..."
nix build .#router-vm-image --impure

if [[ -f result/nixos.qcow ]]; then
    echo "✓ Router VM image built successfully"
    echo "  Image: $(realpath result/nixos.qcow)"
    echo "  Size: $(du -h result/nixos.qcow | cut -f1)"
    
    # Copy to expected location for libvirt
    sudo mkdir -p /var/lib/libvirt/images
    sudo cp result/nixos.qcow /var/lib/libvirt/images/router-vm.qcow
    sudo chown qemu:qemu /var/lib/libvirt/images/router-vm.qcow
    echo "✓ Image copied to /var/lib/libvirt/images/router-vm.qcow"
else
    echo "✗ Failed to build router VM image"
    exit 1
fi
