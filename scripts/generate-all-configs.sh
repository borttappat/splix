#!/run/current-system/sw/bin/bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
readonly TEMPLATES_DIR="$PROJECT_DIR/templates"
readonly GENERATED_DIR="$PROJECT_DIR/generated"

log() { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

check_dependencies() {
    log "Checking required dependencies..."
    local missing=()
    
    for cmd in nix virsh openssl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing dependencies: ${missing[*]}"
    fi
    
    log "All dependencies verified"
}

run_hardware_detection() {
    log "=== Step 1: Hardware Detection ==="
    
    if [[ ! -f "$SCRIPT_DIR/hardware-identify.sh" ]]; then
        error "hardware-identify.sh not found"
    fi
    
    cd "$PROJECT_DIR"
    ./scripts/hardware-identify.sh
    
    if [[ ! -f "hardware-results.env" ]]; then
        error "Hardware detection failed - no results generated"
    fi
    
    source hardware-results.env
    if [[ "${COMPATIBILITY_SCORE:-0}" -lt 6 ]]; then
        error "Hardware compatibility too low ($COMPATIBILITY_SCORE/10)"
    fi
    
    log "Hardware detection complete: $COMPATIBILITY_SCORE/10"
}

generate_router_credentials() {
    log "=== Generating Router Credentials ==="
    
    # Get current user
    ROUTER_USER="${USER:-traum}"
    log "Router user: $ROUTER_USER"
    
    # Generate secure password
    ROUTER_PASSWORD=$(openssl rand -base64 12 | tr -d "=+/" | cut -c1-12)
    log "Generated router password: $ROUTER_PASSWORD"
    
    # Check for SSH key
    if [[ -f "$HOME/.ssh/id_rsa.pub" ]] || [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then
        SSH_KEY_PATH=$(find "$HOME/.ssh" -name "*.pub" -type f | head -1)
        SSH_KEY_CONTENT=$(cat "$SSH_KEY_PATH")
        SSH_PASSWORD_AUTH="false"
        log "Found SSH key: $SSH_KEY_PATH"
    else
        SSH_KEY_CONTENT=""
        SSH_PASSWORD_AUTH="true"
        log "No SSH key found, using password auth"
    fi
    
    # Save credentials
    cat > "$PROJECT_DIR/router-credentials.env" << EOF
ROUTER_USER=$ROUTER_USER
ROUTER_PASSWORD=$ROUTER_PASSWORD
SSH_KEY_CONTENT=$SSH_KEY_CONTENT
SSH_PASSWORD_AUTH=$SSH_PASSWORD_AUTH
EOF
    
    chmod 600 "$PROJECT_DIR/router-credentials.env"
}

build_router_vm() {
    log "=== Step 2: Build Router VM with Dynamic Config ==="
    
    source "$PROJECT_DIR/hardware-results.env"
    source "$PROJECT_DIR/router-credentials.env"
    
    # WiFi interface will be dynamically detected by the router VM service
    
    # Template the router VM config
    local router_config="$PROJECT_DIR/modules/router-vm-config.nix"
    
    # Create router config from template with all substitutions
    cat > "$router_config" << 'ROUTEREOF'
{ config, lib, pkgs, modulesPath, ... }:
{
  nixpkgs.config.allowUnfree = true;

  imports = [ 
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  boot.initrd.availableKernelModules = [
    "virtio_balloon" "virtio_blk" "virtio_pci" "virtio_ring"
    "virtio_net" "virtio_scsi"
  ];

  boot.kernelParams = [ 
    "console=tty1" 
    "console=ttyS0,115200n8" 
  ];

  system.stateVersion = "25.05";

  networking = {
    hostName = "router-vm";
    useDHCP = false;
    enableIPv6 = false;
    
    networkmanager.enable = true;
    wireless.enable = false;
    
    # Management bridge interface
    interfaces.enp1s0 = {
      ipv4.addresses = [{
        address = "192.168.100.253";
        prefixLength = 24;
      }];
    };
    
    # Guest network interfaces
    interfaces.enp2s0 = {
      ipv4.addresses = [{
        address = "192.168.101.253";
        prefixLength = 24;
      }];
    };
    
    interfaces.enp3s0 = {
      ipv4.addresses = [{
        address = "192.168.102.253";
        prefixLength = 24;
      }];
    };

    interfaces.enp4s0 = {
      ipv4.addresses = [{
        address = "192.168.103.253";
        prefixLength = 24;
      }];
    };

    interfaces.enp5s0 = {
      ipv4.addresses = [{
        address = "192.168.104.253";
        prefixLength = 24;
      }];
    };
    
    nat = {
      enable = true;
      externalInterface = "";
      internalInterfaces = [ "enp1s0" "enp2s0" "enp3s0" "enp4s0" "enp5s0" ];
    };
    
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 53 ];
      allowedUDPPorts = [ 53 67 68 ];
    };
  };

  systemd.services.wifi-detect-and-configure = {
    description = "Detect WiFi interface and configure NAT";
    after = [ "network.target" ];
    before = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      WIFI_IFACE=$(ls /sys/class/net/ | grep -E '^wl' | head -1)
      if [ -z "$WIFI_IFACE" ]; then
        echo "ERROR: No WiFi interface found!"
        exit 1
      fi
      echo "Found WiFi interface: $WIFI_IFACE"
      
      ${pkgs.iptables}/bin/iptables -t nat -F POSTROUTING
      ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s 192.168.100.0/24 -o "$WIFI_IFACE" -j MASQUERADE
      ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s 192.168.101.0/24 -o "$WIFI_IFACE" -j MASQUERADE
      ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s 192.168.102.0/24 -o "$WIFI_IFACE" -j MASQUERADE
      ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s 192.168.103.0/24 -o "$WIFI_IFACE" -j MASQUERADE
      ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s 192.168.104.0/24 -o "$WIFI_IFACE" -j MASQUERADE
      
      ${pkgs.iptables}/bin/iptables -A FORWARD -i enp1s0 -o "$WIFI_IFACE" -j ACCEPT
      ${pkgs.iptables}/bin/iptables -A FORWARD -i enp2s0 -o "$WIFI_IFACE" -j ACCEPT
      ${pkgs.iptables}/bin/iptables -A FORWARD -i enp3s0 -o "$WIFI_IFACE" -j ACCEPT
      ${pkgs.iptables}/bin/iptables -A FORWARD -i enp4s0 -o "$WIFI_IFACE" -j ACCEPT
      ${pkgs.iptables}/bin/iptables -A FORWARD -i enp5s0 -o "$WIFI_IFACE" -j ACCEPT
      ${pkgs.iptables}/bin/iptables -A FORWARD -i "$WIFI_IFACE" -o enp1s0 -m state --state RELATED,ESTABLISHED -j ACCEPT
      ${pkgs.iptables}/bin/iptables -A FORWARD -i "$WIFI_IFACE" -o enp2s0 -m state --state RELATED,ESTABLISHED -j ACCEPT
      ${pkgs.iptables}/bin/iptables -A FORWARD -i "$WIFI_IFACE" -o enp3s0 -m state --state RELATED,ESTABLISHED -j ACCEPT
      ${pkgs.iptables}/bin/iptables -A FORWARD -i "$WIFI_IFACE" -o enp4s0 -m state --state RELATED,ESTABLISHED -j ACCEPT
      ${pkgs.iptables}/bin/iptables -A FORWARD -i "$WIFI_IFACE" -o enp5s0 -m state --state RELATED,ESTABLISHED -j ACCEPT
    '';
  };

  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.forwarding" = 1;
  };

  boot.kernelPackages = pkgs.linuxPackages_latest;

  hardware.enableAllFirmware = true;
  hardware.enableRedistributableFirmware = true;

  environment.systemPackages = with pkgs; [
    pciutils usbutils iw wirelesstools networkmanager
    dhcpcd iptables bridge-utils tcpdump nettools nano
    dnsmasq
  ];

  services.qemuGuest.enable = true;
  services.spice-vdagentd.enable = true;

  services.dnsmasq = {
    enable = true;
    settings = {
      interface = ["enp2s0" "enp3s0" "enp4s0" "enp5s0"];
      dhcp-range = [
        "enp2s0,192.168.101.10,192.168.101.100,24h"
        "enp3s0,192.168.102.10,192.168.102.100,24h"
        "enp4s0,192.168.103.10,192.168.103.100,24h"
        "enp5s0,192.168.104.10,192.168.104.100,24h"
      ];
      dhcp-option = [
        "enp2s0,option:router,192.168.101.253"
        "enp2s0,option:dns-server,192.168.101.253"
        "enp3s0,option:router,192.168.102.253"
        "enp3s0,option:dns-server,192.168.102.253"
        "enp4s0,option:router,192.168.103.253"
        "enp4s0,option:dns-server,192.168.103.253"
        "enp5s0,option:router,192.168.104.253"
        "enp5s0,option:dns-server,192.168.104.253"
      ];
      server = ["8.8.8.8" "1.1.1.1"];
      bind-interfaces = true;
      log-dhcp = true;
      log-queries = true;
    };
  };

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = __SSH_PASSWORD_AUTH__;
  };

  services.getty.autologinUser = "__ROUTER_USER__";

  users.users.__ROUTER_USER__ = {
    isNormalUser = true;
    password = "__ROUTER_PASSWORD__";
    extraGroups = [ "wheel" "networkmanager" ];
    __SSH_KEYS__
  };
}
ROUTEREOF
    
    # Now perform all the substitutions
    # Note: WiFi interface detection is now handled dynamically by systemd service
    sed -i "s|__SSH_PASSWORD_AUTH__|$SSH_PASSWORD_AUTH|g" "$router_config"
    sed -i "s|__ROUTER_USER__|$ROUTER_USER|g" "$router_config"
    sed -i "s|__ROUTER_PASSWORD__|$ROUTER_PASSWORD|g" "$router_config"
    
    # Handle SSH keys - this needs special care
    if [[ -n "$SSH_KEY_CONTENT" ]]; then
        # Escape special characters in SSH key for sed
        SSH_KEY_ESCAPED=$(echo "$SSH_KEY_CONTENT" | sed 's/[\/&]/\\&/g')
        sed -i "s|__SSH_KEYS__|openssh.authorizedKeys.keys = [ \"$SSH_KEY_ESCAPED\" ];|" "$router_config"
    else
        sed -i "s|__SSH_KEYS__|# No SSH keys configured|" "$router_config"
    fi
    
    log "Router config templated successfully"
    
    cd "$PROJECT_DIR"
    if ! nix build .#router-vm-qcow --print-build-logs; then
        error "Router VM build failed"
    fi

    if [[ -f "result/nixos.qcow2" ]]; then
        log "Router VM built successfully: $(du -h result/nixos.qcow2 | cut -f1)"
    else
        error "VM image not found after build"
    fi
}

generate_machine_configs() {
    log "=== Step 3: Machine-Specific Config Generation ==="
    
    source "$PROJECT_DIR/hardware-results.env"
    
    local vendor=$(hostnamectl | grep -i "Hardware Vendor" | awk -F': ' '{print $2}' | xargs)
    local model=$(hostnamectl | grep -i "Hardware Model" | awk -F': ' '{print $2}' | xargs)
    local model_lower=$(echo "$model" | tr '[:upper:]' '[:lower:]')
    
    if echo "$model_lower" | grep -q "zenbook"; then
        MACHINE_NAME="zenbook"
    elif echo "$model_lower" | grep -q "zephyrus"; then
        MACHINE_NAME="zephyrus" 
    elif echo "$model_lower" | grep -q "razer"; then
        MACHINE_NAME="razer"
    elif echo "$vendor" | grep -qi "schenker"; then
        MACHINE_NAME="xmg"
    elif echo "$vendor" | grep -qi "asus"; then
        MACHINE_NAME="asus"
    else
        MACHINE_NAME=$(echo "$model_lower" | sed 's/[^a-z0-9]//g' | cut -c1-10)
    fi
    
    log "Machine: $MACHINE_NAME"
    
    mkdir -p "$GENERATED_DIR"/{modules,scripts}
    
    # Generate passthrough config (hardware only)
    sed "s|{{DEVICE_ID}}|$PRIMARY_ID|g; s|{{PRIMARY_DRIVER}}|$PRIMARY_DRIVER|g; s|{{MACHINE_NAME}}|$MACHINE_NAME|g" \
        "$TEMPLATES_DIR/machine-passthrough.nix.template" > \
        "$GENERATED_DIR/modules/${MACHINE_NAME}-passthrough.nix"
    
    # Generate router services config (software only)
    CURRENT_USER="${USER:-$(whoami)}"
    log "User: $CURRENT_USER"
    
    sed "s|{{MACHINE_NAME}}|$MACHINE_NAME|g; s|{{USERNAME}}|$CURRENT_USER|g" \
        "$TEMPLATES_DIR/router-services.nix.template" > \
        "$GENERATED_DIR/modules/${MACHINE_NAME}-router.nix"
    
    # Also generate the legacy combined config for backward compatibility
    sed "s|{{MACHINE_NAME}}|$MACHINE_NAME|g; s|{{USERNAME}}|$CURRENT_USER|g" \
        "$TEMPLATES_DIR/specialisation-block.template" > \
        "$GENERATED_DIR/modules/${MACHINE_NAME}-legacy.nix"
    
    log "Generated modular configs for $MACHINE_NAME:"
    log "  - ${MACHINE_NAME}-passthrough.nix (hardware/VFIO)"  
    log "  - ${MACHINE_NAME}-router.nix (services/specialization)"
    log "  - ${MACHINE_NAME}-legacy.nix (backward compatibility)"
}

generate_nixbuild_entry() {
    log "=== Step 3.5: Generate nixbuild script entry ==="
    
    source "$PROJECT_DIR/hardware-results.env"
    
    local vendor=$(hostnamectl | grep -i "Hardware Vendor" | awk -F': ' '{print $2}' | xargs)
    local model=$(hostnamectl | grep -i "Hardware Model" | awk -F': ' '{print $2}' | xargs)
    local model_lower=$(echo "$model" | tr '[:upper:]' '[:lower:]')
    
    # Determine model match string for grep
    if echo "$model_lower" | grep -q "zenbook"; then
        MODEL_MATCH="zenbook"
    elif echo "$model_lower" | grep -q "zephyrus"; then
        MODEL_MATCH="zephyrus"
    elif echo "$model_lower" | grep -q "razer"; then
        MODEL_MATCH="razer"
    else
        # Use first distinctive part of model name
        MODEL_MATCH=$(echo "$model" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
    fi
    
    # Generate nixbuild entry
    mkdir -p "$GENERATED_DIR/nixbuild-entries"
    
    sed "s|{{VENDOR}}|$vendor|g; s|{{MODEL}}|$model|g; s|{{MODEL_MATCH}}|$MODEL_MATCH|g; s|{{MACHINE_NAME}}|$MACHINE_NAME|g" \
        "$TEMPLATES_DIR/nixbuild-router-machine-block.template" > \
        "$GENERATED_DIR/nixbuild-entries/${MACHINE_NAME}-nixbuild-entry.sh"
    
    log "Generated nixbuild entry for $MACHINE_NAME (model match: $MODEL_MATCH)"
    log "Entry saved to: $GENERATED_DIR/nixbuild-entries/${MACHINE_NAME}-nixbuild-entry.sh"
}

generate_deployment_scripts() {
    log "=== Step 4: Generate Deployment Scripts ==="
    
    source "$PROJECT_DIR/hardware-results.env"
    
    cat > "$GENERATED_DIR/scripts/deploy-router-vm.sh" << 'DEPLOYEOF'
#!/run/current-system/sw/bin/bash
set -euo pipefail

log() { echo "[$(date +%H:%M:%S)] $*"; }

if ! sudo systemctl is-active --quiet libvirtd; then
    log "Starting libvirtd..."
    sudo systemctl start libvirtd
fi

log "Deploying router VM with WiFi passthrough..."
readonly VM_NAME="router-vm-passthrough"
readonly SOURCE_IMAGE="PROJECT_DIR_PLACEHOLDER/result/nixos.qcow2"
readonly TARGET_IMAGE="/var/lib/libvirt/images/$VM_NAME.qcow2"

if [[ ! -f "$SOURCE_IMAGE" ]]; then
    log "ERROR: Router VM image not found."
    exit 1
fi

if sudo virsh --connect qemu:///system list --all | grep -q "$VM_NAME"; then
    log "Removing existing router VM..."
    sudo virsh --connect qemu:///system destroy "$VM_NAME" 2>/dev/null || true
    sudo virsh --connect qemu:///system undefine "$VM_NAME" --nvram 2>/dev/null || true
fi

sudo mkdir -p /var/lib/libvirt/images

sudo cp "$SOURCE_IMAGE" "$TARGET_IMAGE"
if id "libvirt-qemu" >/dev/null 2>&1; then
    sudo chown libvirt-qemu:kvm "$TARGET_IMAGE"
else
    sudo chmod 644 "$TARGET_IMAGE"
fi

log "Creating router VM with WiFi card passthrough..."
sudo virt-install \
    --connect qemu:///system \
    --name="$VM_NAME" \
    --memory=2048 \
    --vcpus=2 \
    --disk "$TARGET_IMAGE,device=disk,bus=virtio" \
    --os-variant=nixos-unstable \
    --boot=hd \
    --nographics \
    --network bridge=virbr1,model=virtio \
    --network bridge=virbr2,model=virtio \
    --network bridge=virbr3,model=virtio \
    --network bridge=virbr4,model=virtio \
    --network bridge=virbr5,model=virtio \
    --hostdev PCI_DEVICE_PLACEHOLDER \
    --noautoconsole \
    --import

log "Router VM deployed with WiFi passthrough!"
log "Connect with: sudo virsh --connect qemu:///system console $VM_NAME"
DEPLOYEOF

    cat > "$GENERATED_DIR/scripts/start-router-vm.sh" << 'STARTEOF'
#!/run/current-system/sw/bin/bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[Router VM] $*"; }

log "Starting router VM with WiFi passthrough..."
"$SCRIPT_DIR/deploy-router-vm.sh"

if sudo virsh --connect qemu:///system list | grep -q "router-vm.*running"; then
    vm_name=$(sudo virsh --connect qemu:///system list | grep "router-vm.*running" | awk '{print $2}' | head -1)
    log "Router VM started: $vm_name"
    log "Connect with: sudo virsh --connect qemu:///system console $vm_name"
else
    log "VM failed to start"
    exit 1
fi
STARTEOF

    sed -i "s|PROJECT_DIR_PLACEHOLDER|$PROJECT_DIR|g; s|PCI_DEVICE_PLACEHOLDER|$PRIMARY_PCI|g" \
        "$GENERATED_DIR/scripts/deploy-router-vm.sh"
    
    cat > "$GENERATED_DIR/scripts/autostart-router-vm.sh" << 'AUTOSTARTEOF'
#!/run/current-system/sw/bin/bash
set -euo pipefail

readonly VM_NAME="router-vm-passthrough"
log() { echo "[$(date +%H:%M:%S)] Router Autostart: $*"; }

# Use full paths since systemd has limited PATH
VIRSH="/run/current-system/sw/bin/virsh"
SYSTEMCTL="/run/current-system/sw/bin/systemctl"

log "Starting router VM autostart process..."

# Check if libvirtd is running (no sudo needed - already root)
if ! $SYSTEMCTL is-active --quiet libvirtd; then
    log "Starting libvirtd service..."
    $SYSTEMCTL start libvirtd
    sleep 3
    log "Libvirtd started"
fi

# Wait a bit more for libvirtd to be fully ready
sleep 2

# Check if VM exists
if ! $VIRSH --connect qemu:///system list --all | grep -q "$VM_NAME"; then
    log "ERROR: Router VM '$VM_NAME' not found"
    log "Please run deploy-router-vm.sh first to create the VM"
    exit 1
fi

# Check current VM state
vm_state=$($VIRSH --connect qemu:///system list --all | grep "$VM_NAME" | awk '{print $3}' || echo "unknown")
log "Router VM current state: $vm_state"

case "$vm_state" in
    "running")
        log "Router VM is already running - nothing to do"
        ;;
    "shut"|"shutoff")
        log "Starting router VM..."
        if $VIRSH --connect qemu:///system start "$VM_NAME"; then
            log "Router VM started successfully"
            sleep 3
        else
            log "ERROR: Failed to start router VM"
            exit 1
        fi
        ;;
    *)
        log "Router VM in unexpected state: $vm_state"
        log "Attempting to start anyway..."
        if $VIRSH --connect qemu:///system start "$VM_NAME"; then
            log "Router VM started despite unexpected state"
            sleep 3
        else
            log "ERROR: Failed to start router VM"
            exit 1
        fi
        ;;
esac

# Final verification
if $VIRSH --connect qemu:///system list | grep -q "$VM_NAME.*running"; then
    log "✅ Router VM is running and ready"
    log "✅ WiFi credentials preserved (VM not recreated)"
    log "✅ Management interface: 192.168.100.253"
else
    log "❌ Router VM startup verification failed"
    exit 1
fi

log "Router VM autostart completed successfully"
AUTOSTARTEOF

    chmod +x "$GENERATED_DIR/scripts/deploy-router-vm.sh"
    chmod +x "$GENERATED_DIR/scripts/start-router-vm.sh"
    chmod +x "$GENERATED_DIR/scripts/autostart-router-vm.sh"
    
    log "Generated deployment scripts (including autostart)"
}

create_summary_readme() {
    source "$PROJECT_DIR/hardware-results.env"
    source "$PROJECT_DIR/router-credentials.env"
    
    cat > "$GENERATED_DIR/README.md" << READMEEOF
# Generated Configuration for $MACHINE_NAME

**Machine**: $(hostnamectl | grep -i "Hardware Model" | awk -F': ' '{print $2}' | xargs)
**WiFi Device**: $PRIMARY_INTERFACE ($PRIMARY_ID)
**PCI Device**: $PRIMARY_PCI  
**Compatibility**: ${COMPATIBILITY_SCORE}/10

## Router Credentials

**Username**: $ROUTER_USER
**Password**: $ROUTER_PASSWORD
**SSH**: Password auth is $(if [[ "$SSH_PASSWORD_AUTH" == "true" ]]; then echo "enabled"; else echo "disabled (key-based)"; fi)

## Generated Files

### Modules (Modular Architecture)
- \`modules/${MACHINE_NAME}-passthrough.nix\` - Hardware/VFIO configuration only
- \`modules/${MACHINE_NAME}-router.nix\` - Router services and specialization only

### Legacy Module (Backward Compatibility)
- \`modules/${MACHINE_NAME}-legacy.nix\` - Combined configuration (old approach)

### Scripts
- \`scripts/deploy-router-vm.sh\` - Production deployment with $PRIMARY_PCI passthrough
- \`scripts/start-router-vm.sh\` - Router VM startup wrapper

### Nixbuild Integration
- \`nixbuild-entries/${MACHINE_NAME}-nixbuild-entry.sh\` - Ready-to-integrate nixbuild script block

## Network Layout

- **virbr1**: 192.168.100.0/24 - Host management
- **virbr2**: 192.168.101.0/24 - Guest VMs network 1  
- **virbr3**: 192.168.102.0/24 - Guest VMs network 2
- **virbr4**: 192.168.103.0/24 - Guest VMs network 3 (isolated)
- **virbr5**: 192.168.104.0/24 - Guest VMs network 4 (isolated)

All networks route through router VM to WiFi.

## Next Steps

### For New Modular Approach (Recommended):
1. Copy modular configs to dotfiles
2. Add these imports to your machine.nix:
   \`\`\`
   imports = [ 
     ./router-generated/${MACHINE_NAME}-passthrough.nix
     ./router-generated/${MACHINE_NAME}-router.nix
   ];
   \`\`\`
3. Add machine to flake.nix  
4. Build with nixbuild

### For Legacy Approach:
1. Use \`${MACHINE_NAME}-legacy.nix\` instead (contains everything)
2. Import as before

Generated: $(date)
Hardware: $PRIMARY_INTERFACE ($PRIMARY_ID), Driver: $PRIMARY_DRIVER
Router VM: $PROJECT_DIR/result/nixos.qcow2
READMEEOF

    log "Created: README.md with credentials"
}

integrate_nixbuild() {
    log "=== Step 5: Automatic nixbuild Integration ==="
    
    if [[ ! -f "$PROJECT_DIR/scripts/integrate-nixbuild-entries.sh" ]]; then
        log "ERROR: Integration script not found"
        return 1
    fi
    
    # Run integration script to add new machine to nixbuild.sh
    log "Integrating new machine into nixbuild.sh..."
    if "$PROJECT_DIR/scripts/integrate-nixbuild-entries.sh"; then
        log "Successfully integrated $MACHINE_NAME into nixbuild.sh"
        
        # Verify integration worked
        if grep -q "$MACHINE_NAME" "$PROJECT_DIR/nixbuild.sh"; then
            log "Verified: $MACHINE_NAME found in nixbuild.sh"
        else
            log "Warning: $MACHINE_NAME not found in nixbuild.sh after integration"
        fi
    else
        log "ERROR: Failed to integrate into nixbuild.sh"
        log "Manual integration available with: ./scripts/integrate-nixbuild-entries.sh"
        return 1
    fi
    
    # Test that nixbuild can detect the new machine
    log "Testing nixbuild detection..."
    cd "$PROJECT_DIR"
    if ./nixbuild.sh --help >/dev/null 2>&1; then
        log "nixbuild.sh is functional"
    else
        log "Warning: nixbuild.sh may have syntax issues after integration"
    fi
}

finalize_setup() {
    log "=== Setup Complete ==="
    
    log "New machine '$MACHINE_NAME' is fully integrated!"
    log ""
    log "Generated configs:"
    log "  - Hardware: ${MACHINE_NAME}-passthrough.nix"
    log "  - Services: ${MACHINE_NAME}-router.nix"
    log "  - Scripts: deploy-router-vm.sh, autostart-router-vm.sh"
    log ""
    log "Integrated into nixbuild.sh"
    log "Router VM built and ready"
    log ""
    log "Ready to use:"
    log "  ./nixbuild.sh                    # Build in current mode"
    log "  ./nixbuild.sh router-switch      # Build and switch to router mode"
    log "  ./nixbuild.sh base-switch        # Build and stay in base mode"
    log ""
    log "All files in: $GENERATED_DIR"
    log "Router credentials: router-credentials.env"
}

main() {
    log "=== Complete Machine Setup and Integration ==="

    check_dependencies
    run_hardware_detection
    generate_router_credentials
    build_router_vm
    generate_machine_configs
    generate_nixbuild_entry
    generate_deployment_scripts
    integrate_nixbuild
    create_summary_readme
    finalize_setup
}

main "$@"
