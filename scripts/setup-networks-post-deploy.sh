#!/usr/bin/env bash
set -euo pipefail

log() { echo "[Networks] $*"; }

log "=== Post-Deployment Network Setup ==="

# Ensure router VM is running
if ! sudo virsh list | grep -q "router-vm-passthrough.*running"; then
log "ERROR: Router VM not running. Start it first."
exit 1
fi

log "Setting up libvirt guest networks..."

# Define all networks
bash -c 'cat > /tmp/router-net1.xml << XMLEOF
<network>
<name>router-net1</name>
<bridge name="virbr2"/>
<forward mode="bridge"/>
</network>
XMLEOF'

bash -c 'cat > /tmp/router-net2.xml << XMLEOF
<network>
<name>router-net2</name>
<bridge name="virbr3"/>
<forward mode="bridge"/>
</network>
XMLEOF'

bash -c 'cat > /tmp/router-net3.xml << XMLEOF
<network>
<name>router-net3</name>
<bridge name="virbr4"/>
<forward mode="bridge"/>
</network>
XMLEOF'

bash -c 'cat > /tmp/router-net4.xml << XMLEOF
<network>
<name>router-net4</name>
<bridge name="virbr5"/>
<forward mode="bridge"/>
</network>
XMLEOF'

# Create/update all networks
for net in router-net1 router-net2 router-net3 router-net4; do
if sudo virsh net-list --all | grep -q "$net"; then
log "Network $net already exists, updating..."
sudo virsh net-destroy "$net" 2>/dev/null || true
sudo virsh net-undefine "$net" 2>/dev/null || true
fi

log "Creating network: $net"
sudo virsh net-define "/tmp/${net}.xml"
sudo virsh net-start "$net"
sudo virsh net-autostart "$net"
done

# Clean up temp files
rm -f /tmp/router-net*.xml

log "=== Network Setup Complete ==="
log ""
log "Available networks for VMs:"
log "  router-net1 (virbr2) → 192.168.101.x"
log "  router-net2 (virbr3) → 192.168.102.x"
log "  router-net3 (virbr4) → 192.168.103.x (isolated)"
log "  router-net4 (virbr5) → 192.168.104.x (isolated)"
