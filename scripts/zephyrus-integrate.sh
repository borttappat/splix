#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SPLIX_DIR="$(dirname "$SCRIPT_DIR")"
readonly DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

check_requirements() {
    [ -d "$DOTFILES_DIR" ] || error "Dotfiles not found at $DOTFILES_DIR"
    [ -f "$SPLIX_DIR/modules/router-host.nix" ] || error "Run ./scripts/router-generate.sh first"
    [ -f "$SPLIX_DIR/configs/libvirt/router-vm.xml" ] || error "Libvirt configs not generated"
    
    if ! grep -q "zephyrus" "$DOTFILES_DIR/flake.nix"; then
        error "Zephyrus machine config not found in dotfiles"
    fi
    
    log "Requirements check passed"
}

create_router_module() {
    log "Creating isolated router module for zephyrus..."
    
    mkdir -p "$DOTFILES_DIR/modules/zephyrus-router"
    
    cp "$SPLIX_DIR/modules/router-host.nix" "$DOTFILES_DIR/modules/zephyrus-router/host.nix"
    
    cat > "$DOTFILES_DIR/modules/zephyrus-router/default.nix" << 'NIXEOF'
{ config, lib, pkgs, ... }:

{
  options.zephyrus.router = {
    enable = lib.mkEnableOption "Router VM with WiFi passthrough";
    
    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Automatically start router VM on boot";
    };
  };

  config = lib.mkIf config.zephyrus.router.enable {
    imports = [ ./host.nix ];
    
    systemd.services.router-vm.wantedBy = lib.mkIf (!config.zephyrus.router.autoStart) 
      (lib.mkForce [ ]);
  };
}
NIXEOF

    log "Router module created at modules/zephyrus-router/"
}

update_zephyrus_config() {
    log "Updating ONLY zephyrus machine configuration..."
    
    if [ ! -f "$DOTFILES_DIR/modules/zephyrus.nix" ]; then
        error "Zephyrus config not found at modules/zephyrus.nix"
    fi
    
    cp "$DOTFILES_DIR/modules/zephyrus.nix" "$DOTFILES_DIR/modules/zephyrus.nix.backup"
    
    if ! grep -q "zephyrus-router" "$DOTFILES_DIR/modules/zephyrus.nix"; then
        log "Adding router import to zephyrus config..."
        
        sed -i '/imports = \[/a\    ./zephyrus-router' "$DOTFILES_DIR/modules/zephyrus.nix"
        
        cat >> "$DOTFILES_DIR/modules/zephyrus.nix" << 'NIXEOF'

  zephyrus.router = {
    enable = false;
    autoStart = false;
  };
NIXEOF
        
        log "Router configuration added to zephyrus.nix"
    else
        log "Router already configured in zephyrus.nix"
    fi
}

install_libvirt_configs() {
    log "Installing libvirt configurations..."
    
    sudo mkdir -p /etc/libvirt/qemu/
    sudo cp "$SPLIX_DIR/configs/libvirt/router-vm.xml" /etc/libvirt/qemu/
    
    if [ -f "$SPLIX_DIR/configs/libvirt/router-vm-passthrough.xml" ]; then
        sudo cp "$SPLIX_DIR/configs/libvirt/router-vm-passthrough.xml" /etc/libvirt/qemu/
        log "Passthrough configuration installed"
    fi
    
    log "Libvirt configurations installed"
}

create_management_scripts() {
    log "Creating router management scripts..."
    
    mkdir -p "$DOTFILES_DIR/scripts/router"
    
    cat > "$DOTFILES_DIR/scripts/router/control.sh" << 'BASHEOF'
#!/usr/bin/env bash

case "${1:-status}" in
    enable)
        echo "Enabling router in zephyrus config..."
        sed -i 's/enable = false;/enable = true;/' ~/dotfiles/modules/zephyrus.nix
        echo "Run 'nixbuild' to apply changes"
        ;;
    disable)
        echo "Disabling router in zephyrus config..."
        sed -i 's/enable = true;/enable = false;/' ~/dotfiles/modules/zephyrus.nix
        echo "Run 'nixbuild' to apply changes"
        ;;
    start)
        sudo virsh start router-vm
        ;;
    stop)
        sudo virsh shutdown router-vm
        ;;
    status)
        echo "=== Router VM Status ==="
        sudo virsh list --all | grep -E "(router-vm|State)"
        echo
        echo "=== Configuration Status ==="
        if grep -q "enable = true" ~/dotfiles/modules/zephyrus.nix; then
            echo "Router: ENABLED in zephyrus config"
        else
            echo "Router: DISABLED in zephyrus config"  
        fi
        ;;
    emergency)
        echo "Emergency network recovery..."
        sudo systemctl start network-emergency
        ;;
    *)
        echo "Usage: $0 [enable|disable|start|stop|status|emergency]"
        ;;
esac
BASHEOF

    chmod +x "$DOTFILES_DIR/scripts/router/control.sh"
    
    log "Management scripts created"
}

verify_integration() {
    log "Verifying integration..."
    
    local modified_configs
    modified_configs=$(find "$DOTFILES_DIR/modules" -name "*.nix" -newer "$DOTFILES_DIR/modules/zephyrus.nix.backup" | grep -v zephyrus | wc -l)
    
    if [ "$modified_configs" -eq 0 ]; then
        log "✓ Only zephyrus config modified - other machines unaffected"
    else
        log "⚠ Warning: Other configs may have been modified"
    fi
    
    cd "$DOTFILES_DIR"
    if nix flake check --no-build 2>/dev/null; then
        log "✓ Flake syntax valid"
    else
        log "⚠ Flake syntax issues detected"
    fi
}

main() {
    log "Integrating router configuration into zephyrus machine..."
    log "Target dotfiles: $DOTFILES_DIR"
    
    check_requirements
    create_router_module
    update_zephyrus_config
    install_libvirt_configs
    create_management_scripts
    verify_integration
    
    cd "$DOTFILES_DIR"
    git add modules/zephyrus-router/ modules/zephyrus.nix scripts/router/
    
    log "=== Integration Complete ==="
    log ""
    log "Router added to zephyrus machine (DISABLED by default)"
    log ""
    log "Files modified:"
    log "  - modules/zephyrus.nix (backed up as .backup)"
    log "  - modules/zephyrus-router/ (new module)"
    log "  - scripts/router/control.sh (management script)"
    log ""
    log "Next steps:"
    log "  1. cd $DOTFILES_DIR"
    log "  2. git commit -m 'Add router VM support to zephyrus'"
    log "  3. nixbuild  # Test build"
    log "  4. ./scripts/router/control.sh enable  # When ready"
    log "  5. nixbuild && sudo reboot  # Activate passthrough"
}

main "$@"
