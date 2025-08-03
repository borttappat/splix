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

# Allow forwarding for VM network
networking.firewall = {
extraCommands = '
iptables -A FORWARD -i virbr1 -j ACCEPT
iptables -A FORWARD -o virbr1 -j ACCEPT
iptables -t nat -A POSTROUTING -s 192.168.100.0/24 ! -d 192.168.100.0/24 -j MASQUERADE
';
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
--network bridge=virbr1,model=virtio \
--noautoconsole \
--import

log "✅ Test router VM deployed with safe virtio networking!"
log "Connect with: sudo virsh --connect qemu:///system console \$VM_NAME"
log "Test internet: ping 8.8.8.8"
EOT

chmod +x "$CONFIG_DIR/test-router-vm.sh"
log "   ✓ Test router VM script: $CONFIG_DIR/test-router-vm.sh"

log "5. Generating emergency recovery script..."

# Generate emergency recovery script
cat > "$CONFIG_DIR/emergency-recovery.sh" << EOR
#!/usr/bin/env bash
# Emergency network recovery for $PRIMARY_INTERFACE ($PRIMARY_PCI)

set -euo pipefail

log() { echo "[RECOVERY] \$*"; }

log "Starting emergency network recovery..."

# Stop router VMs
log "Stopping router VMs..."
for vm in router-vm-passthrough router-vm-test; do
if sudo virsh --connect qemu:///system list | grep -q "\$vm"; then
sudo virsh --connect qemu:///system destroy "\$vm" 2>/dev/null || true
log "Stopped \$vm"
fi
done

# Unbind WiFi card from VFIO
log "Unbinding WiFi card from VFIO..."
if [[ -e "/sys/bus/pci/drivers/vfio-pci/$PRIMARY_PCI" ]]; then
echo "$PRIMARY_PCI" | sudo tee /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
fi

# Rebind to original driver
log "Rebinding to $PRIMARY_DRIVER driver..."
if [[ ! -e "/sys/bus/pci/drivers/$PRIMARY_DRIVER/$PRIMARY_PCI" ]]; then
echo "$PRIMARY_PCI" | sudo tee /sys/bus/pci/drivers/$PRIMARY_DRIVER/bind 2>/dev/null || true
fi

# Restart NetworkManager
log "Restarting NetworkManager..."
sudo systemctl restart NetworkManager

# Wait for network to come up
log "Waiting for network connectivity..."
for i in {1..30}; do
if ping -c 1 8.8.8.8 &>/dev/null; then
log "✅ Network connectivity restored!"
break
fi
sleep 1
done

log "Emergency recovery complete!"
EOR

chmod +x "$CONFIG_DIR/emergency-recovery.sh"
log "   ✓ Emergency recovery script: $CONFIG_DIR/emergency-recovery.sh"

log "6. Copying router VM config to modules..."

# Copy the generated router VM config to modules directory
mkdir -p "$PROJECT_DIR/modules"
if [[ -f "$CONFIG_DIR/router-vm-config.nix" ]]; then
cp "$CONFIG_DIR/router-vm-config.nix" "$PROJECT_DIR/modules/"
log "   ✓ Router VM config copied to modules/"
else
log "   ! Router VM config not found, using existing modules/router-vm-config.nix"
fi

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
