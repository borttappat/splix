#!/bin/bash
# Emergency network recovery script

set -euo pipefail

echo "=== EMERGENCY NETWORK RECOVERY ==="
echo "This will stop the router VM and restore host network access"
echo

# Stop router VM immediately
echo "1. Stopping router VM..."
if virsh list --state-running | grep -q router-vm; then
    virsh destroy router-vm
    echo "   ✓ Router VM stopped"
else
    echo "   ⚠ Router VM was not running"
fi

# Unbind device from VFIO
echo "2. Releasing network device from passthrough..."
if [[ -w "/sys/bus/pci/drivers/vfio-pci/unbind" ]]; then
    echo "0000:00:14.3" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
    echo "   ✓ Device unbound from VFIO"
fi

# Remove device ID from VFIO
if [[ -w "/sys/bus/pci/drivers/vfio-pci/remove_id" ]]; then
    echo "8086:a840" > /sys/bus/pci/drivers/vfio-pci/remove_id 2>/dev/null || true
    echo "   ✓ Device ID removed from VFIO"
fi

# Rebind to original driver
echo "3. Restoring network driver..."
modprobe iwlwifi 2>/dev/null || true
echo "0000:00:14.3" > /sys/bus/pci/drivers_probe 2>/dev/null || true

# Start NetworkManager
echo "4. Starting network services..."
systemctl start NetworkManager

# Wait a moment for connection
echo "5. Testing connectivity..."
sleep 5

if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    echo "   ✓ Internet connectivity restored!"
else
    echo "   ⚠ No connectivity yet. Try: systemctl restart NetworkManager"
fi

echo
echo "Emergency recovery completed."
echo "Your host should now have network access."
