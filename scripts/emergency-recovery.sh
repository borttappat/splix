#!/usr/bin/env bash

echo "=== EMERGENCY NETWORK RECOVERY ==="

# Stop all VMs
sudo virsh destroy router-vm 2>/dev/null || true
sudo virsh undefine router-vm --nvram 2>/dev/null || true

# Unbind from VFIO
echo "0000:00:14.3" | sudo tee /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
echo "8086:a370" | sudo tee /sys/bus/pci/drivers/vfio-pci/remove_id 2>/dev/null || true

# Load WiFi driver
sudo modprobe -r iwlwifi 2>/dev/null || true
sudo modprobe iwlwifi

# Bind to iwlwifi
echo "0000:00:14.3" | sudo tee /sys/bus/pci/drivers/iwlwifi/bind 2>/dev/null || true

# Restart networking
sudo systemctl restart NetworkManager
sleep 5

# Test
if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
echo "✅ Network restored!"
else
echo "❌ Manual intervention needed:"
echo "nmcli device connect wlo1"
fi
