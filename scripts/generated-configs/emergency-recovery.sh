#!/bin/bash
# BULLETPROOF Emergency Network Recovery Script
set -euo pipefail

echo "=== EMERGENCY NETWORK RECOVERY ==="
echo "Creating bulletproof network restoration..."

PCI_ADDR="0000:00:14.3"
DEVICE_ID="8086:a370"

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
