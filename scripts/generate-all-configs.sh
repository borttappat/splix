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
    
    # Detect WiFi interface name in the VM (this will be different from host)
    # Usually wlp followed by bus id. For 00:14.3, it will likely be wlp9s0 or similar
    # We'll use a common pattern
    WIFI_INTERFACE="wlp9s0"
    
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
      externalInterface = "__WIFI_INTERFACE__";
      internalInterfaces = [ "enp1s0" "enp2s0" "enp3s0" "enp4s0" "enp5s0" ];
    };
    
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 53 ];
      allowedUDPPorts = [ 53 67 68 ];
      extraCommands = ''
        iptables -t nat -A POSTROUTING -s 192.168.100.0/24 -o __WIFI_INTERFACE__ -j MASQUERADE
        iptables -t nat -A POSTROUTING -s 192.168.101.0/24 -o __WIFI_INTERFACE__ -j MASQUERADE
        iptables -t nat -A POSTROUTING -s 192.168.102.0/24 -o __WIFI_INTERFACE__ -j MASQUERADE
        iptables -t nat -A POSTROUTING -s 192.168.103.0/24 -o __WIFI_INTERFACE__ -j MASQUERADE
        iptables -t nat -A POSTROUTING -s 192.168.104.0/24 -o __WIFI_INTERFACE__ -j MASQUERADE
        iptables -A FORWARD -i enp1s0 -o __WIFI_INTERFACE__ -j ACCEPT
        iptables -A FORWARD -i enp2s0 -o __WIFI_INTERFACE__ -j ACCEPT
        iptables -A FORWARD -i enp3s0 -o __WIFI_INTERFACE__ -j ACCEPT
        iptables -A FORWARD -i enp4s0 -o __WIFI_INTERFACE__ -j ACCEPT
        iptables -A FORWARD -i enp5s0 -o __WIFI_INTERFACE__ -j ACCEPT
        iptables -A FORWARD -i __WIFI_INTERFACE__ -o enp1s0 -m state --state RELATED,ESTABLISHED -j ACCEPT
        iptables -A FORWARD -i __WIFI_INTERFACE__ -o enp2s0 -m state --state RELATED,ESTABLISHED -j ACCEPT
        iptables -A FORWARD -i __WIFI_INTERFACE__ -o enp3s0 -m state --state RELATED,ESTABLISHED -j ACCEPT
        iptables -A FORWARD -i __WIFI_INTERFACE__ -o enp4s0 -m state --state RELATED,ESTABLISHED -j ACCEPT
        iptables -A FORWARD -i __WIFI_INTERFACE__ -o enp5s0 -m state --state RELATED,ESTABLISHED -j ACCEPT
      '';
    };
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
    sed -i "s|__WIFI_INTERFACE__|$WIFI_INTERFACE|g" "$router_config"
    sed -i "s|__SSH_PASSWORD_AUTH__|$SSH_PASSWORD_AUTH|g" "$router_config"
    sed -i "s|__ROUTER_USER__|$ROUTER_USER|g" "$router_config"
    sed -i "s|__ROUTER_PASSWORD__|$ROUTER_PASSWORD|g" "$router_config"
    
    # Handle SSH keys - this needs special care
    if [[ -n "$SSH_KEY_CONTENT" ]]; then
        # Escape special characters in SSH key for sed
        SSH_KEY_ESCAPED=$(echo "$SSH_KEY_CONTENT" | sed 's/[\/&]/\\&/g')
        sed -i "s|__SSH_KEYS__|openssh.authorizedKeys.keys = [ \"$SSH_KEY_ESCAPED\" ];|" "$router_config"
    else
        sed -i "s|__SSH_KEYS__||" "$router_config"
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
    
    # Generate passthrough config
    sed "s|{{DEVICE_ID}}|$PRIMARY_ID|g; s|{{PRIMARY_DRIVER}}|$PRIMARY_DRIVER|g; s|{{MACHINE_NAME}}|$MACHINE_NAME|g" \
        "$TEMPLATES_DIR/machine-passthrough.nix.template" > \
        "$GENERATED_DIR/modules/${MACHINE_NAME}-passthrough.nix"
    
    # Generate machine spec config
    sed "s|{{MACHINE_NAME}}|$MACHINE_NAME|g" \
        "$TEMPLATES_DIR/specialisation-block.template" > \
        "$GENERATED_DIR/modules/${MACHINE_NAME}.nix"
    
    log "Generated machine configs for $MACHINE_NAME"
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
    --console pty,target_type=virtio \
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
    
    chmod +x "$GENERATED_DIR/scripts/deploy-router-vm.sh"
    chmod +x "$GENERATED_DIR/scripts/start-router-vm.sh"
    
    log "Generated deployment scripts"
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

### Modules
- \`modules/${MACHINE_NAME}-passthrough.nix\` - VFIO passthrough configuration
- \`modules/${MACHINE_NAME}.nix\` - Complete machine configuration with router specialisation

### Scripts
- \`scripts/deploy-router-vm.sh\` - Production deployment with $PRIMARY_PCI passthrough
- \`scripts/start-router-vm.sh\` - Router VM startup wrapper

## Network Layout

- **virbr1**: 192.168.100.0/24 - Host management
- **virbr2**: 192.168.101.0/24 - Guest VMs network 1  
- **virbr3**: 192.168.102.0/24 - Guest VMs network 2
- **virbr4**: 192.168.103.0/24 - Guest VMs network 3 (isolated)
- **virbr5**: 192.168.104.0/24 - Guest VMs network 4 (isolated)

All networks route through router VM to WiFi.

## Next Steps

1. Copy configs to dotfiles
2. Add machine to flake.nix  
3. Git add files before building
4. Build with nixbuild

Generated: $(date)
Hardware: $PRIMARY_INTERFACE ($PRIMARY_ID), Driver: $PRIMARY_DRIVER
Router VM: $PROJECT_DIR/result/nixos.qcow2
READMEEOF

    log "Created: README.md with credentials"
}

main() {
    log "=== Complete Machine Setup ==="

    check_dependencies
    run_hardware_detection
    generate_router_credentials
    build_router_vm
    generate_machine_configs
    generate_deployment_scripts
    create_summary_readme
    
    log "=== Generation Complete ==="
    log "All files in: $GENERATED_DIR"
    log ""
    log "Router credentials saved in: router-credentials.env"
    log "Remember to 'git add' generated files before building with nixbuild"
}

main "$@"
