#!/bin/bash
# Emergency Network Recovery Script - Hardware Specific
set -euo pipefail

echo "=== EMERGENCY NETWORK RECOVERY ==="
echo "Restoring network connectivity..."

PCI_ADDR="0000:00:14.3"
DEVICE_ID="8086:a840"
DRIVER="iwlwifi"

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
