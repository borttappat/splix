#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SPLIX_DIR="$(dirname "$SCRIPT_DIR")"

log() { echo "[$(date +%H:%M:%S)] $*"; }

ensure_libvirt_setup() {
log "Ensuring libvirt is properly configured..."

if ! sudo systemctl is-active --quiet libvirtd; then
log "Starting libvirtd..."
sudo systemctl start libvirtd
fi

if ! sudo virsh --connect qemu:///system net-info default >/dev/null 2>&1; then
log "Creating default network..."
sudo virsh --connect qemu:///system net-define /dev/stdin << EOF_NET
<network>
<name>default</name>
<forward mode=nat>
<nat>
<port start=1024 end=65535/>
</nat>
</forward>
<bridge name=virbr0 stp=on delay=0/>
<ip address=192.168.122.1 netmask=255.255.255.0>
<dhcp>
<range start=192.168.122.2 end=192.168.122.254/>
</dhcp>
</ip>
</network>
EOF_NET
fi

# Check if network is active using net-list instead of net-info
if ! sudo virsh --connect qemu:///system net-list | grep -q "default.*active"; then
log "Starting default network..."
sudo virsh --connect qemu:///system net-start default 2>/dev/null || {
log "Network already active or failed to start"
}
fi

# Check autostart setting
if ! sudo virsh --connect qemu:///system net-list --all | grep -q "default.*yes.*yes"; then
log "Setting default network to autostart..."
sudo virsh --connect qemu:///system net-autostart default 2>/dev/null || true
fi
}

build_minimal_vm() {
log "Building minimal virsh-compatible VM..."

cd "$SPLIX_DIR"

if ! nix build .#minimal-vm-qcow --print-build-logs; then
log "❌ VM build failed!"
return 1
fi

local qcow_path="$SPLIX_DIR/result/nixos.qcow2"

if [[ ! -f "$qcow_path" ]]; then
log "❌ No qcow2 file found at $qcow_path"
return 1
fi

log "✓ VM built successfully: $qcow_path"

local vm_name="splix-minimal-vm"
local target_path="/var/lib/libvirt/images/${vm_name}.qcow2"

log "Copying VM to libvirt images directory..."
sudo cp "$qcow_path" "$target_path"

if id "libvirt-qemu" >/dev/null 2>&1; then
sudo chown libvirt-qemu:kvm "$target_path"
else
sudo chmod 644 "$target_path"
fi

log "✓ VM copied to $target_path"

if sudo virsh --connect qemu:///system list --all | grep -q "$vm_name"; then
log "Removing existing VM definition..."
sudo virsh --connect qemu:///system destroy "$vm_name" 2>/dev/null || true
sudo virsh --connect qemu:///system undefine "$vm_name" --nvram 2>/dev/null || true
fi

log "Creating VM definition..."
sudo virt-install \
        --connect qemu:///system \
        --name="$vm_name" \
        --memory=2048 \
        --vcpus=2 \
        --disk "$target_path,device=disk,bus=virtio" \
        --os-variant=nixos-unstable \
        --boot=hd \
        --nographics \
        --console pty,target_type=virtio \
        --network network=default,model=virtio \
        --noautoconsole \
        --import

log "✅ VM created successfully!"
log ""
log "Waiting for VM to fully boot..."
sleep 45
log "✅ VM should be ready for console access"
log "Next steps:"
log "  Check status:  sudo virsh --connect qemu:///system list"
log "  Console:       sudo virsh --connect qemu:///system console $vm_name"
log "  Stop VM:       sudo virsh --connect qemu:///system destroy $vm_name"
log ""
log "VM should be running. Connect with:"
echo "  sudo virsh --connect qemu:///system console $vm_name"
log "Exit console: Ctrl+] then Enter"
log "Login: nixos/nixos or root/nixos"
}

test_vm() {
local vm_name="splix-minimal-vm"

log "Testing VM connectivity..."

if ! sudo virsh --connect qemu:///system list | grep -q "$vm_name.*running"; then
log "Starting VM..."
sudo virsh --connect qemu:///system start "$vm_name"
sleep 5
fi

log "VM should be running. Connect with:"
echo "  sudo virsh --connect qemu:///system console $vm_name"
log ""
log "Exit console: Ctrl+] then Enter"
log "Login: nixos/nixos (or root/nixos)"
}

show_status() {
local vm_name="splix-minimal-vm"

log "=== VM Status ==="
sudo virsh --connect qemu:///system list --all | grep -E "($vm_name|Id.*Name)" || echo "No VMs found"

log ""
log "=== Default Network Status ==="
sudo virsh --connect qemu:///system net-list --all | grep -E "(default|Name)"

log ""
log "=== Libvirt Images ==="
ls -lh /var/lib/libvirt/images/ | grep -E "(splix|total)" || echo "No splix images found"
}

main() {
ensure_libvirt_setup

case "${1:-build}" in
build)
build_minimal_vm
;;
test)
test_vm
;;
status)
show_status
;;
console)
sudo virsh --connect qemu:///system console splix-minimal-vm
;;
clean)
log "Cleaning up VM..."
sudo virsh --connect qemu:///system destroy splix-minimal-vm 2>/dev/null || true
sudo virsh --connect qemu:///system undefine splix-minimal-vm --nvram 2>/dev/null || true
sudo rm -f /var/lib/libvirt/images/splix-minimal-vm.qcow2
log "✓ Cleanup complete"
;;
*)
echo "Usage: $0 {build|test|console|status|clean}"
echo ""
echo "  build    - Build and deploy minimal VM"
echo "  test     - Start VM and show connection info"  
echo "  console  - Connect to VM console"
echo "  status   - Show VM and network status"
echo "  clean    - Remove VM and files"
exit 1
;;
esac
}

main "$@"
