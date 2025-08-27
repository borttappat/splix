#!/usr/bin/env bash
# vm-setup-generator.sh - Generate VM router setup using detected hardware

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
readonly CONFIG_DIR="$SCRIPT_DIR/generated-configs"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# Check if hardware results exist
if [[ ! -f "$PROJECT_DIR/hardware-results.env" ]]; then
echo "ERROR: hardware-results.env not found. Run hardware-identify.sh first."
exit 1
fi

# Load hardware results
source "$PROJECT_DIR/hardware-results.env"

# Validate required hardware information
if [[ -z "${PRIMARY_INTERFACE:-}" || -z "${PRIMARY_PCI:-}" || -z "${PRIMARY_ID:-}" || -z "${PRIMARY_DRIVER:-}" ]]; then
echo "ERROR: Missing required hardware information. Re-run hardware identification."
exit 1
fi

if [[ "$RECOMMENDATION" == "REDESIGN_REQUIRED" ]]; then
echo "ERROR: Hardware compatibility too low. Score: $COMPATIBILITY_SCORE/10"
exit 1
fi

log "=== VM Router Setup Generator ==="
log "Using detected hardware:"
log "  Interface: $PRIMARY_INTERFACE"
log "  PCI Slot: $PRIMARY_PCI" 
log "  Device ID: $PRIMARY_ID"
log "  Driver: $PRIMARY_DRIVER"
log "  Compatibility: $COMPATIBILITY_SCORE/10"

# Create output directory
mkdir -p "$CONFIG_DIR"

log "1. Generating host passthrough configuration..."

# Generate NixOS host configuration using detected values
cat > "$CONFIG_DIR/host-passthrough.nix" << EOH
{ config, lib, pkgs, ... }:

{
# Enable IOMMU for passthrough
boot.kernelParams = [ 
"intel_iommu=on" 
"iommu=pt" 
"vfio-pci.ids=$PRIMARY_ID"
];

# Load VFIO modules
boot.kernelModules = [ "vfio" "vfio_iommu_type1" "vfio_pci" "vfio_virqfd" ];
boot.blacklistedKernelModules = [ "$PRIMARY_DRIVER" ];

# Ensure libvirtd has access to VFIO devices
virtualisation.libvirtd = {
enable = true;
qemu = {
package = lib.mkForce pkgs.qemu_kvm;
runAsRoot = true;
swtpm.enable = true;
ovmf = {
enable = true;
packages = [ pkgs.OVMF.fd ];
};
};
};

# Create network bridge for VM communication
networking.bridges.virbr1.interfaces = [];
networking.interfaces.virbr1.ipv4.addresses = [{
address = "192.168.100.1";
prefixLength = 24;
}];

# Allow forwarding for VM network
networking.firewall = {
extraCommands = ''
iptables -A FORWARD -i virbr1 -j ACCEPT
iptables -A FORWARD -o virbr1 -j ACCEPT
iptables -t nat -A POSTROUTING -s 192.168.100.0/24 ! -d 192.168.100.0/24 -j MASQUERADE
'';
trustedInterfaces = [ "virbr1" ];
};

# Emergency recovery service
systemd.services.network-emergency = {
description = "Emergency network recovery";
serviceConfig = {
Type = "oneshot";
ExecStart = "$CONFIG_DIR/emergency-recovery.sh";
RemainAfterExit = false;
};
};
}
EOH

log "2. Building router VM..."
cd "$PROJECT_DIR"
if ! nix build .#router-vm-qcow --print-build-logs; then
log "   ✗ Router VM build failed"
exit 1
fi
log "   ✓ Router VM built successfully"

log "3. Generating deployment scripts..."

# Generate deployment script using detected values
cat > "$CONFIG_DIR/deploy-router-vm.sh" << EOS
#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date +%H:%M:%S)] \$*"; }

if ! sudo systemctl is-active --quiet libvirtd; then
log "Starting libvirtd..."
sudo systemctl start libvirtd
fi

log "Deploying router VM with WiFi passthrough..."
readonly VM_NAME="router-vm-passthrough"
readonly SOURCE_IMAGE="$PROJECT_DIR/result/nixos.qcow2"
readonly TARGET_IMAGE="/var/lib/libvirt/images/\$VM_NAME.qcow2"

if [[ ! -f "\$SOURCE_IMAGE" ]]; then
log "ERROR: Router VM image not found."
exit 1
fi

# Clean up existing VM
if sudo virsh --connect qemu:///system list --all | grep -q "\$VM_NAME"; then
log "Removing existing router VM..."
sudo virsh --connect qemu:///system destroy "\$VM_NAME" 2>/dev/null || true
sudo virsh --connect qemu:///system undefine "\$VM_NAME" --nvram 2>/dev/null || true
fi

# Copy VM image
sudo cp "\$SOURCE_IMAGE" "\$TARGET_IMAGE"
if id "libvirt-qemu" >/dev/null 2>&1; then
sudo chown libvirt-qemu:kvm "\$TARGET_IMAGE"
else
sudo chmod 644 "\$TARGET_IMAGE"
fi

# Create router VM with WiFi passthrough
log "Creating router VM with WiFi card passthrough..."
sudo virt-install \\
--connect qemu:///system \\
--name="\$VM_NAME" \\
--memory=2048 \\
--vcpus=2 \\
--disk "\$TARGET_IMAGE,device=disk,bus=virtio" \\
--os-variant=nixos-unstable \\
--boot=hd \\
--nographics \\
--console pty,target_type=virtio \\
--network bridge=virbr1,model=virtio \\
--hostdev $PRIMARY_PCI \\
--noautoconsole \\
--import

log "✅ Router VM deployed with WiFi passthrough!"
log "Connect with: sudo virsh --connect qemu:///system console \$VM_NAME"
EOS

chmod +x "$CONFIG_DIR/deploy-router-vm.sh"

log "4. Generating test deployment script..."

# Generate safe testing script
cat > "$CONFIG_DIR/test-router-vm.sh" << EOT
#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date +%H:%M:%S)] \$*"; }

if ! sudo systemctl is-active --quiet libvirtd; then
log "Starting libvirtd..."
sudo systemctl start libvirtd
fi

log "Deploying router VM for safe testing (virtio networking)..."
readonly VM_NAME="router-vm-test"
readonly SOURCE_IMAGE="$PROJECT_DIR/result/nixos.qcow2"
readonly TARGET_IMAGE="/var/lib/libvirt/images/\$VM_NAME.qcow2"

if [[ ! -f "\$SOURCE_IMAGE" ]]; then
log "ERROR: Router VM image not found."
exit 1
fi

# Clean up existing test VM
if sudo virsh --connect qemu:///system list --all | grep -q "\$VM_NAME"; then
log "Removing existing test VM..."
sudo virsh --connect qemu:///system destroy "\$VM_NAME" 2>/dev/null || true
sudo virsh --connect qemu:///system undefine "\$VM_NAME" --nvram 2>/dev/null || true
fi

# Copy VM image
sudo cp "\$SOURCE_IMAGE" "\$TARGET_IMAGE"
if id "libvirt-qemu" >/dev/null 2>&1; then
sudo chown libvirt-qemu:kvm "\$TARGET_IMAGE"
else
sudo chmod 644 "\$TARGET_IMAGE"
fi

# Create test router VM with safe networking
log "Creating test router VM with safe virtio networking..."
sudo virt-install \\
--connect qemu:///system \\
--name="\$VM_NAME" \\
--memory=2048 \\
--vcpus=2 \\
--disk "\$TARGET_IMAGE,device=disk,bus=virtio" \\
--os-variant=nixos-unstable \\
--boot=hd \\
--nographics \\
--console pty,target_type=virtio \\
--network network=default,model=virtio \\
--noautoconsole \\
--import

log "✅ Test router VM deployed with safe networking!"
log "Connect with: sudo virsh --connect qemu:///system console \$VM_NAME"
EOT

chmod +x "$CONFIG_DIR/test-router-vm.sh"

log "5. Generating emergency recovery script..."

# Generate emergency recovery using detected values
cat > "$CONFIG_DIR/emergency-recovery.sh" << 'EOR'
#!/bin/bash
# Emergency Network Recovery Script - Hardware Specific
set -euo pipefail

echo "=== EMERGENCY NETWORK RECOVERY ==="
echo "Restoring network connectivity..."

PCI_ADDR="PRIMARY_PCI_PLACEHOLDER"
DEVICE_ID="PRIMARY_ID_PLACEHOLDER"
DRIVER="PRIMARY_DRIVER_PLACEHOLDER"

# Function to check current driver
check_current_driver() {
if [[ -e "/sys/bus/pci/devices/$PCI_ADDR/driver" ]]; then
readlink /sys/bus/pci/devices/$PCI_ADDR/driver | sed 's/.*\///'
else
echo "none"
fi
}

# 1. Stop all VMs
echo "1. Stopping all router VMs..."
for vm in router-vm router-vm-test router-vm-passthrough; do
if virsh list --state-running 2>/dev/null | grep -q "$vm"; then
echo "   Stopping $vm..."
virsh destroy "$vm" 2>/dev/null || true
fi
done
sleep 2

# 2. Remove device from VFIO
echo "2. Removing device from VFIO..."
if [[ -w "/sys/bus/pci/drivers/vfio-pci/remove_id" ]]; then
echo "$DEVICE_ID" > /sys/bus/pci/drivers/vfio-pci/remove_id 2>/dev/null || true
fi

# 3. Unbind from current driver
echo "3. Unbinding from current driver..."
current_driver=\$(check_current_driver)
if [[ "\$current_driver" != "none" ]]; then
echo "$PCI_ADDR" > "/sys/bus/pci/drivers/\$current_driver/unbind" 2>/dev/null || true
sleep 2
fi

# 4. Bind to original driver
echo "4. Binding to $DRIVER..."
modprobe -r $DRIVER 2>/dev/null || true
sleep 1
modprobe $DRIVER 2>/dev/null || true
sleep 2
echo "$DEVICE_ID" > /sys/bus/pci/drivers/$DRIVER/new_id 2>/dev/null || true
echo "$PCI_ADDR" > /sys/bus/pci/drivers/$DRIVER/bind 2>/dev/null || true

# 5. Restart NetworkManager
echo "5. Restarting NetworkManager..."
systemctl restart NetworkManager
sleep 10

# 6. Test connectivity
echo "6. Testing connectivity..."
for attempt in {1..5}; do
if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
echo "   ✓ Internet connectivity restored!"
exit 0
fi
echo "   Attempt $attempt/5 failed, retrying..."
sleep 3
done

echo "❌ Recovery failed. Try manually:"
echo "sudo systemctl restart NetworkManager"
echo "sudo nmcli device connect $PRIMARY_INTERFACE"
EOR

# Replace placeholders with actual values
sed -i "s/PRIMARY_PCI_PLACEHOLDER/$PRIMARY_PCI/g" "$CONFIG_DIR/emergency-recovery.sh"
sed -i "s/PRIMARY_ID_PLACEHOLDER/$PRIMARY_ID/g" "$CONFIG_DIR/emergency-recovery.sh"
sed -i "s/PRIMARY_DRIVER_PLACEHOLDER/$PRIMARY_DRIVER/g" "$CONFIG_DIR/emergency-recovery.sh"

chmod +x "$CONFIG_DIR/emergency-recovery.sh"

log ""
log "=== Configuration Generation Complete ==="
log "Hardware-specific files generated:"
log "  • Host config: $CONFIG_DIR/host-passthrough.nix"
log "  • VM deployment: $CONFIG_DIR/deploy-router-vm.sh"
log "  • VM testing: $CONFIG_DIR/test-router-vm.sh"
log "  • Emergency recovery: $CONFIG_DIR/emergency-recovery.sh"
log ""
log "Next steps:"
log "  1. Test VM: $CONFIG_DIR/test-router-vm.sh"
log "  2. Deploy with passthrough: $CONFIG_DIR/deploy-router-vm.sh"
log "  3. Emergency recovery: $CONFIG_DIR/emergency-recovery.sh"
