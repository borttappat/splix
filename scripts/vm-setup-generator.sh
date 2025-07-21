#!/usr/bin/env bash
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
if [[ ! -f "$SCRIPT_DIR/../hardware-results.env" ]]; then
    echo "ERROR: hardware-results.env not found. Run hardware-identify.sh first."
    exit 1
fi

# Load hardware results
source "$SCRIPT_DIR/../hardware-results.env"

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
echo "1. Generating host passthrough configuration..."

cat > "$CONFIG_DIR/host-passthrough.nix" << EOF
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
      package = pkgs.qemu_kvm;
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
EOF

echo "   ✓ Host passthrough config: $CONFIG_DIR/host-passthrough.nix"

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
  <name>router-vm</name>
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
  <name>router-vm-virtio</name>
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

cat > "$CONFIG_DIR/router-vm-config.nix" << 'EOF'
{ config, pkgs, lib, ... }:

{
  imports = [ ];

  # Basic system configuration
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/vda";
  boot.loader.timeout = 1;

  # Kernel modules for networking
  boot.kernelModules = [ "af_packet" ];

  # File systems
  fileSystems."/" = {
    device = "/dev/vda1";
    fsType = "ext4";
    autoResize = true;
  };

  # Network configuration - Router mode
  networking = {
    hostName = "router-vm";
    useDHCP = false;
    
    # WAN interface (gets internet from host via passthrough WiFi)
    interfaces.wlan0 = {
      useDHCP = true;
    };
    
    # LAN interface (provides internet to host)
    interfaces.eth0 = {
      ipv4.addresses = [{
        address = "192.168.100.2";
        prefixLength = 24;
      }];
    };

    # Enable forwarding and NAT
    nat = {
      enable = true;
      externalInterface = "wlan0";
      internalInterfaces = [ "eth0" ];
    };
    
    firewall = {
      enable = true;
      trustedInterfaces = [ "eth0" ];
      allowPing = true;
    };
  };

  # DHCP and DNS services
  services.dnsmasq = {
    enable = true;
    settings = {
      interface = "eth0";
      dhcp-range = "192.168.100.50,192.168.100.150,12h";
      dhcp-option = [
        "option:router,192.168.100.2"
        "option:dns-server,192.168.100.2"
      ];
      server = [ "8.8.8.8" "8.8.4.4" ];
      cache-size = 1000;
    };
  };

  # Basic system packages
  environment.systemPackages = with pkgs; [
    vim
    tmux
    htop
    tcpdump
    iptables
    iproute2
    networkmanager
    dnsmasq
  ];

  # Enable NetworkManager for WiFi management
  networking.networkmanager = {
    enable = true;
    unmanaged = [ "eth0" ];
  };

  # User configuration
  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    password = "admin";
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

# 4.5 Copy router VM config to modules directory
echo "4.5 Copying router VM config to modules..."
mkdir -p "$SCRIPT_DIR/../modules"
cp "$CONFIG_DIR/router-vm-config.nix" "$SCRIPT_DIR/../modules/"
echo "   ✓ Router VM config copied to modules/router-vm-config.nix"

# 5. Generate emergency recovery script
echo "5. Generating emergency recovery script..."

cat > "$CONFIG_DIR/emergency-recovery.sh" << 'RECOVERY_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

echo "=== EMERGENCY NETWORK RECOVERY ==="
echo "This script will restore host network connectivity"
echo

echo "1. Stopping router VMs..."
for vm in router-vm router-vm-virtio router-vm-passthrough; do
    if sudo virsh list | grep -q "$vm"; then
        sudo virsh destroy "$vm" 2>/dev/null || true
        echo "   Stopped $vm"
    fi
done

echo "2. Unloading VFIO modules..."
for mod in vfio_pci vfio_iommu_type1 vfio; do
    if lsmod | grep -q "^$mod"; then
        sudo modprobe -r "$mod" 2>/dev/null || true
        echo "   Unloaded $mod"
    fi
done

echo "3. Loading WiFi driver..."
RECOVERY_SCRIPT

cat >> "$CONFIG_DIR/emergency-recovery.sh" << EOF
sudo modprobe $PRIMARY_DRIVER 2>/dev/null || true
echo "   Loaded $PRIMARY_DRIVER"

echo "4. Rebinding device..."
if [[ -e "/sys/bus/pci/devices/$PRIMARY_PCI/driver/unbind" ]]; then
    echo "$PRIMARY_PCI" | sudo tee "/sys/bus/pci/devices/$PRIMARY_PCI/driver/unbind" >/dev/null 2>&1 || true
fi
echo "$PRIMARY_PCI" | sudo tee /sys/bus/pci/drivers_probe >/dev/null 2>&1 || true

echo "5. Restarting NetworkManager..."
sudo systemctl restart NetworkManager

echo "6. Waiting for network..."
for i in {1..10}; do
    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        echo
        echo "✓ Network connectivity restored!"
        exit 0
    fi
    echo -n "."
    sleep 1
done

echo
echo "⚠ Network not immediately available"
echo "Try: sudo systemctl restart NetworkManager"
echo "Or wait a moment and check: ip link"
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

1. **Apply host configuration:**
   \`\`\`bash
   sudo nixos-rebuild switch --flake /path/to/flake#hostname
   sudo reboot
   \`\`\`

2. **Deploy router VM:**
   \`\`\`bash
   sudo virsh define router-vm-passthrough.xml
   sudo virsh start router-vm
   \`\`\`

3. **Verify connectivity:**
   - Host should get DHCP from 192.168.100.0/24
   - Router VM manages internet via WiFi passthrough
   - Emergency recovery available if needed

## Emergency Recovery

If network is lost:
\`\`\`bash
sudo ./emergency-recovery.sh
\`\`\`

This will:
- Stop all VMs
- Unbind WiFi from VFIO
- Restore normal driver
- Restart networking
EOF

echo "   ✓ Deployment guide: $CONFIG_DIR/README.md"

echo
echo "=== Configuration Generation Complete ==="
echo
echo "Generated files in $CONFIG_DIR/:"
echo "  - host-passthrough.nix    : Host VFIO configuration"
echo "  - router-vm-config.nix    : Router VM NixOS configuration"
echo "  - router-vm-passthrough.xml : Production VM (with passthrough)"
echo "  - router-vm-virtio.xml    : Test VM (safe networking)"
echo "  - emergency-recovery.sh   : Network recovery script"
echo "  - README.md              : Deployment instructions"
echo
echo "Router VM config also copied to: modules/router-vm-config.nix"
echo
echo "Next steps:"
echo "  1. Test with: nix build .#nixosConfigurations.router-vm.config.system.build.vm --impure"
echo "  2. Run VM: ./result/bin/run-router-vm-vm"
echo "  3. For passthrough: ./scripts/deploy-router.sh passthrough"
