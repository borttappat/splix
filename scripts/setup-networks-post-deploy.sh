#!/usr/bin/env bash
set -euo pipefail

log() { echo "[Networks] $*"; }

log "=== Post-Deployment Network Setup ==="

# Ensure router VM is running
if ! sudo virsh list | grep -q "router-vm-passthrough.*running"; then
log "ERROR: Router VM not running. Run deploy-router.sh first."
exit 1
fi

log "Setting up libvirt guest networks..."

# Router network 1 (pentesting/work) - bridge mode, no DHCP
bash -c 'cat > /tmp/router-net1.xml << XMLEOF
<network>
<name>router-net1</name>
<bridge name="virbr2"/>
<forward mode="bridge"/>
</network>
XMLEOF'

# Router network 2 (gaming/leisure) - bridge mode, no DHCP  
bash -c 'cat > /tmp/router-net2.xml << XMLEOF
<network>
<name>router-net2</name>
<bridge name="virbr3"/>
<forward mode="bridge"/>
</network>
XMLEOF'

# Clean up existing networks
for net in router-net1 router-net2; do
if sudo virsh net-list --all | grep -q "$net"; then
log "Cleaning up existing $net..."
sudo virsh net-destroy "$net" 2>/dev/null || true
sudo virsh net-undefine "$net" 2>/dev/null || true
fi
done

# Create networks
for net in router-net1 router-net2; do
log "Creating network: $net"
sudo virsh net-define "/tmp/${net}.xml"
sudo virsh net-start "$net"
sudo virsh net-autostart "$net"
done

# Verify network setup
log "Verifying network configuration..."

# Check bridges exist with correct IPs
for bridge in virbr1 virbr2 virbr3; do
if ip addr show "$bridge" >/dev/null 2>&1; then
ip=$(ip addr show "$bridge" | grep "inet " | awk '{print $2}' || echo "no-ip")
log "✓ $bridge: $ip"
else
log "✗ $bridge: missing"
fi
done

# Check libvirt networks
log "Libvirt networks:"
sudo virsh net-list --all

# Test router VM dnsmasq
log "Testing router VM DHCP service..."
if sudo virsh console router-vm-passthrough --force --safe >/dev/null 2>&1 <<< "sudo ss -ulnp | grep :67 && exit"; then
log "✓ Router VM DHCP service running"
else
log "⚠ Could not verify router VM DHCP"
fi

# Clean up temp files
rm -f /tmp/router-net*.xml

log "=== Network Setup Complete ==="
log ""
log "Available networks for VMs:"
log "  router-net1 (virbr2) → 192.168.101.x → pentesting/work"
log "  router-net2 (virbr3) → 192.168.102.x → gaming/leisure"
log "  default (virbr0) → 192.168.122.x → direct host"
log ""
log "Test with: sudo virt-install --network network=router-net1 ..."
