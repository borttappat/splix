#!/run/current-system/sw/bin/bash
# vm-setup-generator.sh - Generate VM router setup with passthrough and recovery

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIG_DIR="$SCRIPT_DIR/generated-configs"

# Function to detect OVMF firmware paths - now always uses auto-detection
detect_ovmf_paths() {
    # Always prefer auto-detection for better compatibility
    echo "Using OVMF auto-detection for maximum compatibility"
    export USE_FIRMWARE_AUTO="true"
    export OVMF_CODE_PATH=""
    export OVMF_VARS_PATH=""
}

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

# Detect OVMF firmware paths
echo "Detecting OVMF firmware paths..."
detect_ovmf_paths

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

# 2. Generate VM domain XML with dynamic OVMF paths
echo "2. Generating VM configuration (passthrough)..."

# Parse PCI address for XML
IFS=':' read -r pci_domain pci_bus pci_slot_func <<< "$PRIMARY_PCI"
IFS='.' read -r pci_slot pci_func <<< "$pci_slot_func"

# Convert to hex format for XML
pci_bus_hex="0x$(printf "%02x" $((16#$pci_bus)))"
pci_slot_hex="0x$(printf "%02x" $((16#$pci_slot)))"
pci_func_hex="0x$pci_func"

cat > "$CONFIG_DIR/router-vm-passthrough.xml" << EOF
<domain type='kvm'>
  <n>router-vm</n>
  <memory unit='KiB'>2097152</memory>
  <currentMemory unit='KiB'>2097152</currentMemory>
  <vcpu placement='static'>2</vcpu>
  <os>
    <type arch='x86_64' machine='pc-q35-6.2'>hvm</type>
    <firmware>efi</firmware>
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
        <address domain='0x0000' bus='$pci_bus_hex' slot='$pci_slot_hex' function='$pci_func_hex'/>
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

echo "   ✓ VM passthrough configuration: $CONFIG_DIR/router-vm-passthrough.xml"

# 3. Generate testing VM configuration (virtio networking)
echo "3. Generating VM test configuration (virtio)..."

cat > "$CONFIG_DIR/router-vm-virtio.xml" << EOF
<domain type='kvm'>
  <n>router-vm-virtio</n>
  <memory unit='KiB'>2097152</memory>
  <currentMemory unit='KiB'>2097152</currentMemory>
  <vcpu placement='static'>2</vcpu>
  <os>
    <type arch='x86_64' machine='pc-q35-6.2'>hvm</type>
    <firmware>efi</firmware>
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
  <devices>
    <emulator>/run/current-system/sw/bin/qemu-system-x86_64</emulator>
    
    <!-- Virtual disk -->
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='/var/lib/libvirt/images/router-vm.qcow2'/>
      <target dev='vda' bus='virtio'/>
      <boot order='1'/>
    </disk>
    
    <!-- WAN interface - virtio connected to default network -->
    <interface type='network'>
      <source network='default'/>
      <model type='virtio'/>
      <address type='pci' domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
    </interface>
    
    <!-- LAN interface - virtio connected to default network (for testing) -->
    <interface type='network'>
      <source network='default'/>
      <model type='virtio'/>
      <address type='pci' domain='0x0000' bus='0x02' slot='0x00' function='0x0'/>
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

echo "   ✓ VM virtio test configuration: $CONFIG_DIR/router-vm-virtio.xml"

# 4. Generate router VM NixOS configuration
echo "4. Generating router VM NixOS configuration..."

cat > "$CONFIG_DIR/router-vm-config.nix" << EOF
# Router VM NixOS Configuration
# Generated for hardware: $PRIMARY_INTERFACE ($PRIMARY_ID)

{ config, lib, pkgs, ... }:

{
  imports = [ ];

  # Boot configuration
  boot.loader.grub = {
    enable = true;
    device = "/dev/vda";
  };

  # Basic system settings
  networking.hostName = "router-vm";
  time.timeZone = "Europe/Stockholm";
  
  # Enable networking and routing
  networking = {
    networkmanager.enable = false;
    useNetworkd = true;
    useDHCP = false;
    
    # Configure interfaces
    interfaces = {
      # WAN interface (will be WiFi card in passthrough mode)
      eth0 = {
        useDHCP = true;  # Get internet from upstream
      };
      
      # LAN interface for guest VMs
      eth1 = {
        ipv4.addresses = [{
          address = "192.168.100.1";
          prefixLength = 24;
        }];
      };
    };
    
    # Enable IP forwarding for routing
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 53 67 80 443 ];
      allowedUDPPorts = [ 53 67 68 ];
    };
    
    # NAT configuration
    nat = {
      enable = true;
      externalInterface = "eth0";
      internalInterfaces = [ "eth1" ];
    };
  };

  # Enable IP forwarding
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.forwarding" = 1;
  };

  # DHCP server for guest VMs
  services.dhcpd4 = {
    enable = true;
    interfaces = [ "eth1" ];
    extraConfig = ''
      subnet 192.168.100.0 netmask 255.255.255.0 {
        range 192.168.100.10 192.168.100.100;
        option routers 192.168.100.1;
        option domain-name-servers 1.1.1.1, 8.8.8.8;
        default-lease-time 86400;
        max-lease-time 604800;
      }
    '';
  };

  # DNS server
  services.dnsmasq = {
    enable = true;
    settings = {
      server = [ "1.1.1.1" "8.8.8.8" ];
      interface = "eth1";
      dhcp-range = [ "192.168.100.10,192.168.100.100,24h" ];
      dhcp-option = [
        "option:router,192.168.100.1"
        "option:dns-server,192.168.100.1"
      ];
    };
  };

  # SSH for management
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;
      PermitRootLogin = "yes";
    };
  };

  # System packages
  environment.systemPackages = with pkgs; [
    vim wget curl htop iftop tcpdump
    iw wireless-tools iproute2
  ];

  # Create admin user
  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    password = "admin";  # Change this!
  };

  # Allow passwordless sudo for admin user
  security.sudo.extraRules = [{
    users = [ "admin" ];
    commands = [{
      command = "ALL";
      options = [ "NOPASSWD" ];
    }];
  }];

  system.stateVersion = "24.05";
}
EOF

echo "   ✓ Router VM config: $CONFIG_DIR/router-vm-config.nix"

# 5. Generate emergency recovery script
echo "5. Generating emergency recovery script..."

cat > "$CONFIG_DIR/emergency-recovery.sh" << 'EOF'
#!/bin/bash
# Emergency network recovery script
# Generated automatically - do not edit manually

set -euo pipefail

echo "=== EMERGENCY NETWORK RECOVERY ==="
echo "This script will restore host network connectivity"
echo

# Stop router VM
echo "1. Stopping router VM..."
virsh destroy router-vm 2>/dev/null || true
virsh destroy router-vm-virtio 2>/dev/null || true
echo "   ✓ VMs stopped"

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

# 6. Generate deployment-ready README
echo "6. Generating deployment instructions..."

cat > "$CONFIG_DIR/README.md" << EOF
# VM Router Setup - Generated Configuration

Generated on $(date) for hardware:
- Interface: $PRIMARY_INTERFACE ($PRIMARY_ID) 
- Driver: $PRIMARY_DRIVER
- PCI Address: $PRIMARY_PCI
- Compatibility Score: $COMPATIBILITY_SCORE/10

## OVMF Configuration
- Auto-detection: $USE_FIRMWARE_AUTO (always enabled for compatibility)

## Quick Testing (Safe)

1. **Test router VM with virtio networking:**
   \`\`\`bash
   sudo virsh define router-vm-virtio.xml
   sudo virsh start router-vm-virtio
   sudo virsh console router-vm-virtio
   \`\`\`

2. **Test emergency recovery:**
   \`\`\`bash
   sudo ./emergency-recovery.sh
   \`\`\`

## Production Deployment (Point of No Return)

1. **Apply host passthrough configuration:**
   \`\`\`bash
   # Add to your NixOS configuration
   sudo cp host-passthrough.nix /etc/nixos/
   # Import in configuration.nix and rebuild
   sudo nixos-rebuild boot && sudo reboot
   \`\`\`

2. **Deploy router VM with passthrough:**
   \`\`\`bash
   sudo virsh define router-vm-passthrough.xml
   sudo virsh start router-vm
   \`\`\`

## Files Generated

- \`host-passthrough.nix\` - Host VFIO passthrough config
- \`router-vm-passthrough.xml\` - Production VM with WiFi passthrough
- \`router-vm-virtio.xml\` - Safe testing VM with virtio networking
- \`router-vm-config.nix\` - NixOS configuration for router VM
- \`emergency-recovery.sh\` - Network recovery script

## Emergency Recovery

If network is lost: \`sudo ./emergency-recovery.sh\`

This restores host networking by stopping the router VM and rebinding the WiFi card to the original driver.
EOF

echo "   ✓ Instructions: $CONFIG_DIR/README.md"

echo
echo "=== Setup Generation Complete ==="
echo
echo "Generated files in: $CONFIG_DIR/"
echo "  - host-passthrough.nix          (Host NixOS config)"
echo "  - router-vm-passthrough.xml     (Production VM definition)"  
echo "  - router-vm-virtio.xml          (Safe testing VM definition)"
echo "  - router-vm-config.nix          (Router VM NixOS config)"
echo "  - emergency-recovery.sh         (Network recovery)"
echo "  - README.md                     (Usage instructions)"
echo
echo "Hardware-specific details:"
echo "  - PCI Address: $PRIMARY_PCI (parsed as bus=$pci_bus_hex slot=$pci_slot_hex func=$pci_func_hex)"
echo "  - OVMF Detection: $USE_FIRMWARE_AUTO (auto-detection for maximum compatibility)"
echo
echo "Next steps:"
echo "1. Test with virtio networking: sudo virsh define $CONFIG_DIR/router-vm-virtio.xml"
echo "2. Test emergency recovery: sudo $CONFIG_DIR/emergency-recovery.sh"  
echo "3. If tests pass, proceed to passthrough deployment"
echo
echo "⚠ IMPORTANT: Always test emergency recovery before deploying passthrough!"
