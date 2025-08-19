#!/usr/bin/env bash
# vm-setup-generator.sh - Generate VM router setup using proven nix-generators approach

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
echo "Consider alternative approaches or hardware upgrades."
exit 1
fi

log "=== VM Router Setup Generator ==="
log "Using hardware profile:"
log "  Interface: $PRIMARY_INTERFACE"
log "  PCI Slot: $PRIMARY_PCI" 
log "  Device ID: $PRIMARY_ID"
log "  Driver: $PRIMARY_DRIVER"
log "  Compatibility: $COMPATIBILITY_SCORE/10"

# Create output directory
mkdir -p "$CONFIG_DIR"

log "1. Generating host passthrough configuration..."

# Generate NixOS host configuration for passthrough
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

# Automatic route to router VM
networking.routes = [
  {
    address = "0.0.0.0";
    prefixLength = 0;
    via = "192.168.100.253";
    options = { dev = "virbr1"; };
  }
];

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

log "   ✓ Host passthrough config: $CONFIG_DIR/host-passthrough.nix"

log "2. Building router VM using nix-generators approach..."

# Build router VM using the proven approach
cd "$PROJECT_DIR"
if ! nix build .#router-vm-qcow --print-build-logs; then
log "   ✗ Router VM build failed"
exit 1
fi

log "   ✓ Router VM built successfully using nix-generators"

log "3. Generating router VM deployment scripts..."

# Parse PCI address for passthrough configuration
IFS=: read -r pci_domain pci_bus pci_slot_func <<< "$PRIMARY_PCI"
IFS=. read -r pci_slot pci_func <<< "$pci_slot_func"

# Convert to hex format
pci_bus_hex="0x$(printf "%02x" $((16#$pci_bus)))"
pci_slot_hex="0x$(printf "%02x" $((16#$pci_slot)))"
pci_func_hex="0x$pci_func"

# Generate deployment script for passthrough router VM
cat > "$CONFIG_DIR/deploy-router-vm.sh" << EOS
#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date +%H:%M:%S)] \$*"; }

# Ensure libvirt is running
if ! sudo systemctl is-active --quiet libvirtd; then
log "Starting libvirtd..."
sudo systemctl start libvirtd
fi

# Copy router VM to libvirt images
log "Deploying router VM with WiFi passthrough..."
readonly VM_NAME="router-vm-passthrough"
readonly SOURCE_IMAGE="$PROJECT_DIR/result/nixos.qcow2"
readonly TARGET_IMAGE="/var/lib/libvirt/images/\$VM_NAME.qcow2"

if [[ ! -f "\$SOURCE_IMAGE" ]]; then
log "ERROR: Router VM image not found. Run vm-setup-generator.sh first."
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
sudo virt-install \
--connect qemu:///system \
--name="\$VM_NAME" \
--memory=2048 \
--vcpus=2 \
--disk "\$TARGET_IMAGE,device=disk,bus=virtio" \
--os-variant=nixos-unstable \
--boot=hd \
--nographics \
--console pty,target_type=virtio \
--network bridge=virbr1,model=virtio \
--hostdev $pci_domain:$pci_bus:$pci_slot.$pci_func \
--noautoconsole \
--import

log "✅ Router VM deployed with WiFi passthrough!"
log "Connect with: sudo virsh --connect qemu:///system console \$VM_NAME"
EOS

chmod +x "$CONFIG_DIR/deploy-router-vm.sh"
log "   ✓ Router VM deployment script: $CONFIG_DIR/deploy-router-vm.sh"

log "4. Generating test router VM deployment (safe virtio networking)..."

# Generate safe testing deployment script  
cat > "$CONFIG_DIR/test-router-vm.sh" << EOT
#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date +%H:%M:%S)] \$*"; }

# Ensure libvirt is running
if ! sudo systemctl is-active --quiet libvirtd; then
log "Starting libvirtd..."
sudo systemctl start libvirtd
fi

log "Deploying router VM for safe testing (virtio networking)..."
readonly VM_NAME="router-vm-test"
readonly SOURCE_IMAGE="$PROJECT_DIR/result/nixos.qcow2"
readonly TARGET_IMAGE="/var/lib/libvirt/images/\$VM_NAME.qcow2"

if [[ ! -f "\$SOURCE_IMAGE" ]]; then
log "ERROR: Router VM image not found. Run vm-setup-generator.sh first."
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

# Create test router VM with virtio networking
log "Creating test router VM with safe virtio networking..."
sudo virt-install \
--connect qemu:///system \
--name="\$VM_NAME" \
--memory=2048 \
--vcpus=2 \
--disk "\$TARGET_IMAGE,device=disk,bus=virtio" \
--os-variant=nixos-unstable \
--boot=hd \
--nographics \
--console pty,target_type=virtio \
--network network=default,model=virtio \
--noautoconsole \
--import

log "✅ Test router VM deployed with safe virtio networking!"
log "Connect with: sudo virsh --connect qemu:///system console \$VM_NAME"
log "Test internet: ping 8.8.8.8"
EOT

chmod +x "$CONFIG_DIR/test-router-vm.sh"
log "   ✓ Test router VM script: $CONFIG_DIR/test-router-vm.sh"

log "5. Generating bulletproof emergency recovery script..."

# Generate bulletproof emergency recovery script
cat > "$CONFIG_DIR/emergency-recovery.sh" << 'EOR'
#!/bin/bash
# BULLETPROOF Emergency Network Recovery Script
set -euo pipefail

echo "=== EMERGENCY NETWORK RECOVERY ==="
echo "Creating bulletproof network restoration..."

PCI_ADDR="PRIMARY_PCI_PLACEHOLDER"
DEVICE_ID="PRIMARY_ID_PLACEHOLDER"

# Function to check current driver
check_current_driver() {
if [[ -e "/sys/bus/pci/devices/$PCI_ADDR/driver" ]]; then
readlink /sys/bus/pci/devices/$PCI_ADDR/driver | sed 's/.*\///'
else
echo "none"
fi
}

# Function to force unbind from any driver
force_unbind() {
local current_driver=$(check_current_driver)
echo "Current driver: $current_driver"

if [[ "$current_driver" != "none" ]]; then
echo "Unbinding from $current_driver..."
echo "$PCI_ADDR" > "/sys/bus/pci/drivers/$current_driver/unbind" 2>/dev/null || true
sleep 2

# Verify unbind worked
if [[ $(check_current_driver) == "none" ]]; then
echo "   ✓ Successfully unbound from $current_driver"
else
echo "   ⚠ Failed to unbind, trying aggressive method..."
# Force unbind using multiple methods
echo "$PCI_ADDR" > /sys/bus/pci/devices/$PCI_ADDR/driver/unbind 2>/dev/null || true
sleep 1
fi
fi
}

# Function to force bind to iwlwifi
force_bind_iwlwifi() {
echo "Loading iwlwifi driver..."
modprobe -r iwlwifi 2>/dev/null || true
sleep 1
modprobe iwlwifi 2>/dev/null || true
sleep 2

echo "Binding to iwlwifi..."
# Multiple binding attempts
echo "$DEVICE_ID" > /sys/bus/pci/drivers/iwlwifi/new_id 2>/dev/null || true
sleep 1
echo "$PCI_ADDR" > /sys/bus/pci/drivers/iwlwifi/bind 2>/dev/null || true
sleep 2

# Verify binding
local current_driver=$(check_current_driver)
if [[ "$current_driver" == "iwlwifi" ]]; then
echo "   ✓ Successfully bound to iwlwifi"
return 0
else
echo "   ⚠ Failed to bind to iwlwifi"
return 1
fi
}

# 1. Stop all VMs aggressively
echo "1. Stopping all router VMs..."
for vm in router-vm router-vm-test router-vm-passthrough splix-minimal-vm; do
if virsh list --state-running 2>/dev/null | grep -q "$vm"; then
echo "   Stopping $vm..."
virsh destroy "$vm" 2>/dev/null || true
fi
done
sleep 2

# 2. Remove device from VFIO if present
echo "2. Removing device from VFIO..."
if [[ -w "/sys/bus/pci/drivers/vfio-pci/remove_id" ]]; then
echo "$DEVICE_ID" > /sys/bus/pci/drivers/vfio-pci/remove_id 2>/dev/null || true
fi

# 3. Force unbind from current driver
echo "3. Force unbinding from current driver..."
force_unbind

# 4. Force bind to iwlwifi with retries
echo "4. Force binding to iwlwifi..."
for attempt in {1..3}; do
echo "   Attempt $attempt/3..."
if force_bind_iwlwifi; then
break
fi
if [[ $attempt -lt 3 ]]; then
echo "   Retrying in 3 seconds..."
sleep 3
fi
done

# 5. Restart NetworkManager aggressively
echo "5. Restarting network services..."
for i in {1..3}; do
echo "   NetworkManager restart $i/3..."
systemctl stop NetworkManager 2>/dev/null || true
sleep 2
systemctl start NetworkManager 2>/dev/null || true
sleep 5

# Quick connectivity check
if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
echo "   ✓ Network restored on attempt $i"
break
fi
done

# 6. Extended connectivity testing
echo "6. Testing connectivity with retry loop..."
for attempt in {1..10}; do
if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
echo "   ✓ Internet connectivity confirmed!"
echo "   ✓ Emergency recovery successful"
exit 0
fi
echo "   Attempt $attempt/10 failed, retrying..."
sleep 3
done

# 7. Manual recovery instructions
echo
echo "❌ Automatic recovery failed. Manual steps:"
echo "1. sudo systemctl restart NetworkManager"
echo "2. sudo nmcli connection up <your-wifi-name>"
echo "3. Check with: nmcli device status"
echo
echo "Device status:"
echo "Current driver: $(check_current_driver)"
lspci -nnk -s $PCI_ADDR
echo
echo "If still no connectivity, reboot may be required."
EOR

# Replace placeholders with actual hardware values
sed -i "s/PRIMARY_PCI_PLACEHOLDER/$PRIMARY_PCI/g" "$CONFIG_DIR/emergency-recovery.sh"
sed -i "s/PRIMARY_ID_PLACEHOLDER/$PRIMARY_ID/g" "$CONFIG_DIR/emergency-recovery.sh"

chmod +x "$CONFIG_DIR/emergency-recovery.sh"
log "   ✓ Bulletproof emergency recovery script: $CONFIG_DIR/emergency-recovery.sh"

log ""
log "=== Configuration Generation Complete ==="
log "Generated files:"
log "  • Host passthrough config: $CONFIG_DIR/host-passthrough.nix"
log "  • Router VM deployment: $CONFIG_DIR/deploy-router-vm.sh"
log "  • Test router VM: $CONFIG_DIR/test-router-vm.sh"
log "  • Emergency recovery: $CONFIG_DIR/emergency-recovery.sh"
log ""
log "Next steps:"
log "  1. Test router VM: $CONFIG_DIR/test-router-vm.sh"
log "  2. Deploy with passthrough: $CONFIG_DIR/deploy-router-vm.sh"
log "  3. Emergency recovery if needed: $CONFIG_DIR/emergency-recovery.sh"
