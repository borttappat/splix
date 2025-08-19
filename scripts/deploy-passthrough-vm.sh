#!/usr/bin/env bash
set -euo pipefail

# Build the VM
cd ~/splix
nix build .#router-vm-qcow --print-build-logs

# Copy image
sudo cp result/nixos.qcow2 /var/lib/libvirt/images/router-vm.qcow2
sudo chmod 644 /var/lib/libvirt/images/router-vm.qcow2

# Deploy with passthrough
sudo virt-install \
  --connect qemu:///system \
  --name="router-vm" \
  --memory=2048 \
  --vcpus=2 \
  --disk /var/lib/libvirt/images/router-vm.qcow2,device=disk,bus=virtio \
  --os-variant=nixos-unstable \
  --boot=hd \
  --nographics \
  --console pty,target_type=virtio \
  --hostdev pci_0000_00_14_3 \
  --network bridge=virbr1,model=virtio \
  --noautoconsole \
  --import

echo "VM deployed. Connect with: sudo virsh console router-vm"
