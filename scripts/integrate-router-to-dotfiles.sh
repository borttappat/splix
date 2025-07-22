#!/usr/bin/env bash
# Router VM Integration Script for Dotfiles
# This script properly integrates the router VM setup into existing dotfiles

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SPLIX_DIR="${SPLIX_DIR:-$HOME/splix}"
readonly DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

# Check prerequisites
check_requirements() {
    log "Checking requirements..."
    
    [[ -d "$SPLIX_DIR" ]] || error "Splix directory not found at $SPLIX_DIR"
    [[ -f "$SPLIX_DIR/hardware-results.env" ]] || error "Run hardware detection first: cd $SPLIX_DIR && ./scripts/hardware-identify.sh"
    [[ -d "$DOTFILES_DIR" ]] || error "Dotfiles directory not found at $DOTFILES_DIR"
    
    log "Requirements satisfied"
}

# Get correct device ID from actual hardware
get_device_id() {
    local device_id=$(lspci -nn | grep -i network | grep -oP '\[8086:[a-f0-9]{4}\]' | head -1 | tr -d '[]')
    echo "${device_id:-8086:a370}"
}

# Get PCI address
get_pci_address() {
    local pci_addr=$(lspci | grep -i network | awk '{print $1}' | head -1)
    echo "0000:${pci_addr}"
}

# Create router module for dotfiles
create_router_module() {
    log "Creating router module..."
    
    local device_id=$(get_device_id)
    local pci_addr=$(get_pci_address)
    
    mkdir -p "$DOTFILES_DIR/modules/router"
    
    cat > "$DOTFILES_DIR/modules/router.nix" << EOF
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.router;
in
{
  options.router = {
    enable = mkEnableOption "VM router with WiFi passthrough";
    passthrough = mkEnableOption "Enable VFIO passthrough for WiFi card";
  };

  config = mkIf cfg.enable (mkMerge [
    # Basic router VM support
    {
      virtualisation.libvirtd.enable = true;
      environment.systemPackages = with pkgs; [ 
        bridge-utils
        iptables
        tcpdump
      ];
    }
    
    # Passthrough configuration
    (mkIf cfg.passthrough {
      # VFIO configuration
      boot.kernelParams = [
        "intel_iommu=on"
        "iommu=pt"
        "vfio-pci.ids=${device_id}"
      ];
      
      boot.kernelModules = [ "vfio" "vfio_iommu_type1" "vfio_pci" ];
      boot.blacklistedKernelModules = [ "iwlwifi" ];
      
      # Network bridges
      networking.bridges.virbr1 = {
        interfaces = [];
      };
      
      networking.interfaces.virbr1 = {
        ipv4.addresses = [{
          address = "192.168.100.1";
          prefixLength = 24;
        }];
      };
      
      networking.firewall = {
        trustedInterfaces = [ "virbr0" "virbr1" ];
      };
      
      # Emergency recovery service
      systemd.services.network-emergency = {
        description = "Emergency network recovery";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = false;
          ExecStart = pkgs.writeScript "network-emergency" ''
            #!/bin/bash
            echo "=== EMERGENCY NETWORK RECOVERY ==="
            /run/current-system/sw/bin/virsh destroy router-vm 2>/dev/null || true
            echo "${device_id}" > /sys/bus/pci/drivers/vfio-pci/remove_id 2>/dev/null || true
            echo "${pci_addr}" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
            echo "${pci_addr}" > /sys/bus/pci/drivers_probe 2>/dev/null || true
            /run/current-system/sw/bin/modprobe iwlwifi
            /run/current-system/sw/bin/systemctl start NetworkManager
            echo "Recovery completed"
          '';
        };
      };
    })
  ]);
}
EOF
    
    log "Router module created with device ID: $device_id"
}

# Update router VM config to include NetworkManager
update_router_vm_config() {
    log "Updating router VM configuration..."
    
    # First regenerate with NetworkManager support
    cd "$SPLIX_DIR"
    
    # Update the generator to include NetworkManager
    if ! grep -q "networkmanager.enable = true" "$SPLIX_DIR/scripts/vm-setup-generator.sh"; then
        sed -i 's/networkmanager.enable = false;/networkmanager.enable = true;/' "$SPLIX_DIR/scripts/vm-setup-generator.sh"
    fi
    
    # Regenerate configs
    ./scripts/vm-setup-generator.sh
    
    # Copy to dotfiles
    cp "$SPLIX_DIR/modules/router-vm-config.nix" "$DOTFILES_DIR/modules/router/vm.nix"
    
    log "Router VM config updated"
}

# Update flake.nix if needed
update_flake() {
    log "Updating flake.nix..."
    
    # Check if router module is already added
    if ! grep -q "./modules/router.nix" "$DOTFILES_DIR/flake.nix"; then
        log "Adding router module to zephyrus configuration..."
        
        # Add router.nix to modules list
        sed -i '/\.\/modules\/audio\.nix/a\            ./modules/router.nix' "$DOTFILES_DIR/flake.nix"
        
        # Add router configuration block
        sed -i '/modules = \[/,/\];/ {
            /\];/i\            {\
              router = {\
                enable = true;\
                passthrough = true;\
              };\
            }
        }' "$DOTFILES_DIR/flake.nix"
    else
        log "Router module already in flake.nix"
    fi
}

# Create deployment helper
create_deployment_helper() {
    log "Creating deployment helper..."
    
    cat > "$DOTFILES_DIR/scripts/bash/router-deploy.sh" << 'EOF'
#!/usr/bin/env bash
# Router VM deployment helper

set -euo pipefail

case "${1:-status}" in
    status)
        echo "=== Router VM Status ==="
        sudo virsh list --all | grep -E "(router-vm|State)"
        echo
        echo "=== VFIO Status ==="
        lspci -nnk | grep -A3 -i network
        echo
        echo "=== Bridge Status ==="
        ip link show type bridge
        ;;
    start)
        cd ~/splix
        sudo ./scripts/deploy-router.sh deploy
        ;;
    console)
        sudo virsh console router-vm
        ;;
    recovery)
        sudo systemctl start network-emergency
        ;;
    *)
        echo "Usage: $0 [status|start|console|recovery]"
        ;;
esac
EOF
    
    chmod +x "$DOTFILES_DIR/scripts/bash/router-deploy.sh"
    log "Deployment helper created"
}

# Main execution
main() {
    log "Starting router integration for dotfiles..."
    
    check_requirements
    create_router_module
    update_router_vm_config
    update_flake
    create_deployment_helper
    
    log "=== Integration Complete ==="
    log ""
    log "Next steps:"
    log "1. cd $DOTFILES_DIR"
    log "2. git add modules/router.nix modules/router/ scripts/bash/router-deploy.sh"
    log "3. git commit -m 'Add router VM with passthrough support'"
    log "4. nixbuild  # or nb"
    log "5. sudo reboot"
    log "6. After reboot: router-deploy start"
    log ""
    log "Router management commands:"
    log "  router-deploy status   - Check VM and VFIO status"
    log "  router-deploy start    - Start router VM"
    log "  router-deploy console  - Connect to VM console"
    log "  router-deploy recovery - Emergency network recovery"
}

main "$@"
