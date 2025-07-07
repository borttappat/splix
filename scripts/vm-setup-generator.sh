#!/run/current-system/sw/bin/bash
# vm-setup-generator.sh - Generate VM router setup with passthrough and recovery

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIG_DIR="$SCRIPT_DIR/generated-configs"

# Check if hardware results exist
if [[ ! -f "$SCRIPT_DIR/hardware-results.env" ]]; then
    echo "ERROR: hardware-results.env not found. Run hardware-identify.sh first."
    exit 1
fi

# Load hardware results
source "$SCRIPT_DIR/hardware-results.env"

# Validate we have the minimum required info
if [[ -z "${PRIMARY_INTERFACE:-}" || -z "${PRIMARY_PCI:-}" || -z "${PRIMARY_ID:-}" || -z "${PRIMARY_DRIVER:-}" ]]; then
    echo "ERROR: Missing required hardware information. Re-run hardware identification."
    exit 1
fi

if [[ "$RECOMMENDATION" == "REDESIGN_REQUIRED" ]]; then
    echo "ERROR: Hardware compatibility too low. Score: $COMPATIBILITY_SCORE/10"
    echo "Consider alternative approaches or hardware upgrades."
    exit 1
fi

echo "=== VM Router Setup Generator ==="
echo "Using hardware profile:"
echo "  Interface: $PRIMARY_INTERFACE"
echo "  PCI Slot: $PRIMARY_PCI" 
echo "  Device ID: $PRIMARY_ID"
echo "  Driver: $PRIMARY_DRIVER"
echo "  Compatibility: $COMPATIBILITY_SCORE/10"
echo

# Create output directory
mkdir -p "$CONFIG_DIR"

# 1. Generate NixOS host configuration for passthrough
echo "1. Generating NixOS host configuration..."

cat > "$CONFIG_DIR/host-passthrough.nix" << EOF
# Generated NixOS configuration for VM router passthrough
# Generated on $(date)
# Hardware: $PRIMARY_INTERFACE ($PRIMARY_ID) using $PRIMARY_DRIVER driver

{ config, lib, pkgs, ... }:

{
  # Enable IOMMU and VFIO for device passthrough
  boot.kernelParams = [ 
    "intel_iommu=on" 
    "iommu=pt"
    "vfio-pci.ids=$PRIMARY_ID"
  ];

  # Load VFIO modules early
  boot.kernelModules = [ "vfio" "vfio_iommu_type1" "vfio_pci" ];
  
  # Blacklist the network driver on host to prevent conflicts
  boot.blacklistedKernelModules = [ "$PRIMARY_DRIVER" ];

  # Enable virtualization
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu;
      ovmf = {
        enable = true;
        packages = [ pkgs.OVMF ];
      };
      swtpm.enable = true;
    };
  };

  # Network configuration for VM bridge
  networking = {
    # Disable NetworkManager on host since primary interface will be passed through
    networkmanager.enable = lib.mkForce false;
    useNetworkd = true;
    
    # Create bridge for VM networking
    bridges.virbr1 = {
      interfaces = [];
    };
    
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 16509 ];  # SSH and libvirt
      allowedUDPPorts = [ 67 68 ];     # DHCP
      trustedInterfaces = [ "virbr1" ];
    };
  };

  # Enable IP forwarding
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.forwarding" = 1;
  };

  # System packages for VM management
  environment.systemPackages = with pkgs; [
    virt-manager
    virt-viewer
    bridge-utils
    iptables
    netcat
  ];

  # Emergency network recovery service
  systemd.services.network-emergency = {
    description = "Emergency network recovery";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = false;
      ExecStart = pkgs.writeScript "network-emergency" ''
        #!/bin/bash
        echo "=== EMERGENCY NETWORK RECOVERY ==="
        
        # Stop router VM
        /run/current-system/sw/bin/virsh destroy router-vm 2>/dev/null || true
        
        # Remove device from VFIO
        echo "$PRIMARY_ID" > /sys/bus/pci/drivers/vfio-pci/remove_id 2>/dev/null || true
        echo "$PRIMARY_PCI" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
        
        # Rebind to original driver
        echo "$PRIMARY_PCI" > /sys/bus/pci/drivers_probe 2>/dev/null || true
        
        # Load network module
        /run/current-system/sw/bin/modprobe $PRIMARY_DRIVER
        
        # Start NetworkManager
        /run/current-system/sw/bin/systemctl start NetworkManager
        
        echo "Emergency recovery completed"
        echo "You should now have network access"
      '';
    };
  };
}
EOF

echo "   ✓ Host configuration: $CONFIG_DIR/host-passthrough.nix"

# 2. Generate VM domain XML
echo "2. Generating VM configuration..."

cat > "$CONFIG_DIR/router-vm.xml" << EOF
<domain type='kvm'>
  <name>router-vm</name>
  <memory unit='KiB'>2097152</memory>  <!-- 2GB RAM -->
  <currentMemory unit='KiB'>2097152</currentMemory>
  <vcpu placement='static'>2</vcpu>
  <os>
    <type arch='x86_64' machine='pc-q35-6.2'>hvm</type>
    <loader readonly='yes' type='pflash'>/run/libvirt/nix-ovmf/OVMF_CODE.fd</loader>
    <nvram>/var/lib/libvirt/qemu/nvram/router-vm_VARS.fd</nvram>
    <bootmenu enable='yes'/>
  </os>
  <features>
    <acpi/>
    <apic/>
    <vmport state='off'/>
  </features>
  <cpu mode='host-model' check='partial'/>
  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <pm>
    <suspend-to-mem enabled='no'/>
    <suspend-to-disk enabled='no'/>
  </pm>
  <devices>
    <emulator>/run/current-system/sw/bin/qemu-system-x86_64</emulator>
    
    <!-- Virtual disk -->
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='/var/lib/libvirt/images/router-vm.qcow2'/>
      <target dev='vda' bus='virtio'/>
      <boot order='1'/>
    </disk>
    
    <!-- WiFi card passthrough -->
    <hostdev mode='subsystem' type='pci' managed='yes'>
      <source>
        <address domain='0x0000' bus='0x$(echo $PRIMARY_PCI | cut -d: -f2)' slot='0x$(echo $PRIMARY_PCI | cut -d: -f3 | cut -d. -f1)' function='0x$(echo $PRIMARY_PCI | cut -d. -f2)'/>
      </source>
      <address type='pci' domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
    </hostdev>
    
    <!-- Virtual network for management -->
    <interface type='bridge'>
      <source bridge='virbr1'/>
      <model type='virtio'/>
    </interface>
    
    <!-- Console access -->
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    
    <!-- VNC for graphical access -->
    <graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1'/>
    
    <!-- Input devices -->
    <input type='tablet' bus='usb'/>
    <input type='mouse' bus='ps2'/>
    <input type='keyboard' bus='ps2'/>
  </devices>
</domain>
EOF

echo "   ✓ VM configuration: $CONFIG_DIR/router-vm.xml"

# 3. Generate router VM NixOS configuration
echo "3. Generating router VM NixOS configuration..."

cat > "$CONFIG_DIR/router-vm-config.nix" << EOF
# Router VM NixOS Configuration
# This will run inside the VM with the passed-through WiFi card

{ config, pkgs, ... }:

{
  # Basic system configuration
  system.stateVersion = "24.05";
  
  # Enable WiFi and networking
  networking = {
    hostName = "router-vm";
    wireless.enable = true;
    wireless.networks = {
      # Configure your WiFi network here
      # "YourNetworkName" = {
      #   psk = "your-password";
      # };
    };
    
    # Enable IP forwarding for routing
    enableIPv6 = false;  # Simplify for now
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 53 ];
      allowedUDPPorts = [ 53 67 68 ];
    };
  };

  # DHCP server for guest VMs
  services.dhcpd4 = {
    enable = true;
    interfaces = [ "enp2s0" ];  # Management interface
    extraConfig = ''
      subnet 192.168.100.0 netmask 255.255.255.0 {
        range 192.168.100.10 192.168.100.50;
        option routers 192.168.100.1;
        option domain-name-servers 8.8.8.8, 1.1.1.1;
      }
    '';
  };

  # DNS server
  services.dnsmasq = {
    enable = true;
    settings = {
      server = [ "8.8.8.8" "1.1.1.1" ];
      interface = [ "enp2s0" ];
    };
  };

  # NAT configuration
  networking.nat = {
    enable = true;
    internalInterfaces = [ "enp2s0" ];
    externalInterface = "wlan0";  # WiFi interface from passthrough
  };

  # SSH for management
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };

  # Essential packages
  environment.systemPackages = with pkgs; [
    wireless-tools
    iw
    tcpdump
    netcat
    iptables
  ];

  # Auto-login for console access
  services.getty.autologinUser = "router";
  
  # Create router user
  users.users.router = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    # Add your SSH keys here
    # openssh.authorizedKeys.keys = [ "ssh-ed25519 ..." ];
  };
}
EOF

echo "   ✓ Router VM config: $CONFIG_DIR/router-vm-config.nix"

# 4. Generate emergency recovery scripts
echo "4. Generating emergency recovery scripts..."

cat > "$CONFIG_DIR/emergency-recovery.sh" << 'EOF'
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
EOF

cat >> "$CONFIG_DIR/emergency-recovery.sh" << EOF
if [[ -w "/sys/bus/pci/drivers/vfio-pci/unbind" ]]; then
    echo "$PRIMARY_PCI" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
    echo "   ✓ Device unbound from VFIO"
fi

# Remove device ID from VFIO
if [[ -w "/sys/bus/pci/drivers/vfio-pci/remove_id" ]]; then
    echo "$PRIMARY_ID" > /sys/bus/pci/drivers/vfio-pci/remove_id 2>/dev/null || true
    echo "   ✓ Device ID removed from VFIO"
fi

# Rebind to original driver
echo "3. Restoring network driver..."
modprobe $PRIMARY_DRIVER 2>/dev/null || true
echo "$PRIMARY_PCI" > /sys/bus/pci/drivers_probe 2>/dev/null || true

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
EOF

chmod +x "$CONFIG_DIR/emergency-recovery.sh"

echo "   ✓ Emergency recovery: $CONFIG_DIR/emergency-recovery.sh"

# 5. Generate setup script
echo "5. Generating VM setup script..."

cat > "$CONFIG_DIR/setup-vm.sh" << EOF
#!/bin/bash
# Setup router VM with passthrough

set -euo pipefail

echo "=== Setting up Router VM ==="

# Check if we're ready
if ! systemctl is-active --quiet libvirtd; then
    echo "ERROR: libvirtd not running. Apply host-passthrough.nix first and reboot."
    exit 1
fi

# Create VM disk
echo "1. Creating VM disk..."
mkdir -p /var/lib/libvirt/images
if [[ ! -f /var/lib/libvirt/images/router-vm.qcow2 ]]; then
    qemu-img create -f qcow2 /var/lib/libvirt/images/router-vm.qcow2 10G
    echo "   ✓ Created 10GB disk"
else
    echo "   ⚠ Disk already exists"
fi

# Define VM
echo "2. Defining VM in libvirt..."
virsh define router-vm.xml
echo "   ✓ VM defined"

# Check device availability
echo "3. Checking device availability..."
if lspci -s $PRIMARY_PCI | grep -q "Kernel driver in use: vfio-pci"; then
    echo "   ✓ Device bound to VFIO"
elif lspci -s $PRIMARY_PCI | grep -q "Kernel driver in use: $PRIMARY_DRIVER"; then
    echo "   ⚠ Device still bound to $PRIMARY_DRIVER - reboot required"
    echo "   Apply host-passthrough.nix and reboot first"
    exit 1
else
    echo "   ⚠ Device driver status unclear"
fi

echo
echo "VM setup complete!"
echo
echo "Next steps:"
echo "1. Start VM: virsh start router-vm"
echo "2. Connect console: virsh console router-vm"
echo "3. Install NixOS using router-vm-config.nix"
echo "4. Configure WiFi credentials in the VM"
echo
echo "Emergency recovery: ./emergency-recovery.sh"
EOF

chmod +x "$CONFIG_DIR/setup-vm.sh"

echo "   ✓ VM setup script: $CONFIG_DIR/setup-vm.sh"

# 6. Generate usage instructions
echo "6. Generating usage instructions..."

cat > "$CONFIG_DIR/README.md" << EOF
# VM Router Setup - Usage Instructions

Generated for hardware: $PRIMARY_INTERFACE ($PRIMARY_ID) driver: $PRIMARY_DRIVER
Compatibility score: $COMPATIBILITY_SCORE/10

## Quick Start

1. **Apply host configuration:**
   \`\`\`bash
   # Copy to your NixOS configuration
   sudo cp host-passthrough.nix /etc/nixos/
   
   # Import in configuration.nix:
   # imports = [ ./host-passthrough.nix ];
   
   # Rebuild and reboot
   sudo nixos-rebuild boot
   sudo reboot
   \`\`\`

2. **Setup VM:**
   \`\`\`bash
   cd $CONFIG_DIR
   sudo ./setup-vm.sh
   \`\`\`

3. **Start VM and install NixOS:**
   \`\`\`bash
   sudo virsh start router-vm
   sudo virsh console router-vm
   # Install NixOS using router-vm-config.nix
   \`\`\`

## Emergency Recovery

If something goes wrong and you lose network:

\`\`\`bash
sudo ./emergency-recovery.sh
\`\`\`

This will:
- Stop the router VM
- Release the WiFi card from passthrough  
- Restore normal host networking

## Files Generated

- \`host-passthrough.nix\` - NixOS host configuration
- \`router-vm.xml\` - VM definition for libvirt
- \`router-vm-config.nix\` - NixOS config for inside the VM
- \`emergency-recovery.sh\` - Network recovery script
- \`setup-vm.sh\` - VM setup automation

## Testing

Before deploying:
1. Test emergency recovery works
2. Verify VM can start with passthrough
3. Confirm router VM can connect to WiFi
4. Test guest VMs can route through router

## Hardware Details

- Primary Interface: $PRIMARY_INTERFACE
- PCI Slot: $PRIMARY_PCI
- Device ID: $PRIMARY_ID
- Driver: $PRIMARY_DRIVER
- IOMMU Group: Isolated (good for passthrough)
- Alternative Interfaces: ${ALT_INTERFACES:-false}
EOF

echo "   ✓ Instructions: $CONFIG_DIR/README.md"

echo
echo "=== Setup Generation Complete ==="
echo
echo "Generated files in: $CONFIG_DIR/"
echo "  - host-passthrough.nix     (Host NixOS config)"
echo "  - router-vm.xml            (VM definition)"  
echo "  - router-vm-config.nix     (Router VM NixOS config)"
echo "  - emergency-recovery.sh    (Network recovery)"
echo "  - setup-vm.sh              (VM setup automation)"
echo "  - README.md                (Usage instructions)"
echo
echo "Next steps:"
echo "1. Review the generated configurations"
echo "2. Apply host-passthrough.nix to your system"
echo "3. Reboot to enable passthrough"
echo "4. Run setup-vm.sh to create the router VM"
echo
echo "⚠ IMPORTANT: Test emergency recovery BEFORE deploying!"
