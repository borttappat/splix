#!/run/current-system/sw/bin/bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SPLIX_DIR="$(dirname "$SCRIPT_DIR")"
readonly DOTFILES_DIR="${HOME}/dotfiles"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
error() { echo "[ERROR] $*" >&2; }

# Step 1: Hardware Detection (WORKING)
hardware_detection() {
    log "Running hardware detection..."
    
    if [[ ! -f "$SCRIPT_DIR/hardware-identify.sh" ]]; then
        error "hardware-identify.sh not found"
        return 1
    fi
    
    cd "$SPLIX_DIR"
    ./scripts/hardware-identify.sh
    
    if [[ -f "hardware-results.env" ]]; then
        source hardware-results.env
        log "Hardware detection complete. Compatibility: ${COMPATIBILITY_SCORE:-0}/10"
        
        if [[ "${COMPATIBILITY_SCORE:-0}" -lt 6 ]]; then
            error "Hardware compatibility too low (${COMPATIBILITY_SCORE}/10). Cannot proceed safely."
            return 1
        fi
    else
        error "Hardware detection failed - no results file generated"
        return 1
    fi
    
    read -p "Press Enter to continue..."
}

# Step 2: Config Generation (WORKING)
config_generation() {
    log "Generating hardware-specific configurations..."
    
    if [[ ! -f "hardware-results.env" ]]; then
        error "Run hardware detection first"
        return 1
    fi
    
    if [[ ! -f "$SCRIPT_DIR/vm-setup-generator.sh" ]]; then
        error "vm-setup-generator.sh not found"
        return 1
    fi
    
    cd "$SPLIX_DIR"
    ./scripts/vm-setup-generator.sh
    
    log "Configuration generation complete"
    log "Generated configs available in scripts/generated-configs/"
    
    read -p "Press Enter to continue..."
}

# Step 3: SAFE Manual Integration
integrate_dotfiles() {
    log "=== STEP 3: Integrate to Dotfiles (Manual) ==="
    
    if [[ ! -d "$SPLIX_DIR/scripts/generated-configs" ]]; then
        log "ERROR: Run Step 2 first to generate configs"
        return 1
    fi
    
    # Load hardware results for machine detection
    source "$SPLIX_DIR/hardware-results.env"
    
    # Detect machine name
    local machine_name
    if hostnamectl | grep -qi "zenbook"; then
        machine_name="zenbook"
    elif hostnamectl | grep -qi "zephyrus"; then
        machine_name="zephyrus"
    else
        machine_name="default"
    fi
    
    # Create router-generated directory
    mkdir -p "$DOTFILES_DIR/modules/router-generated"
    
    # Copy generated host passthrough config to dotfiles
    if [[ -f "$SPLIX_DIR/scripts/generated-configs/host-passthrough.nix" ]]; then
        cp "$SPLIX_DIR/scripts/generated-configs/host-passthrough.nix" \
           "$DOTFILES_DIR/modules/router-generated/${machine_name}-passthrough.nix"
        log "✅ Copied passthrough config as ${machine_name}-passthrough.nix"
    else
        error "Generated host-passthrough.nix not found"
        return 1
    fi
    
    # Git add the passthrough file
    cd "$DOTFILES_DIR"
    git add "modules/router-generated/${machine_name}-passthrough.nix"
    log "✅ Staged ${machine_name}-passthrough.nix in git"
    
    echo
    echo "=========================================="
    echo "MANUAL STEP REQUIRED:"
    echo "Add this block to ~/dotfiles/modules/${machine_name}.nix"
    echo "after the opening { brace:"
    echo "=========================================="
    echo
    cat << 'MANUAL_BLOCK'
###########################
# BEGIN ROUTER SPEC SETUP #
###########################
# System labels for identification
system.nixos.label = "base-setup";
# Router specialisation
specialisation.router.configuration = {
    system.nixos.label = lib.mkForce "router-setup";
    # Import router VFIO configuration
    imports = [ ./router-generated/zenbook-passthrough.nix ];
    systemd.services.router-default-route = {
        description = "Set default route through router VM";
        after = [ "router-vm-autostart.service" "network.target" ];
        wants = [ "router-vm-autostart.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            Restart = "no";
        };
        script = ''
            sleep 30
            ${pkgs.iproute2}/bin/ip route add default via 192.168.100.253 dev virbr1 || true
        '';
    };
};
##########################
#  END ROUTER SPEC SETUP #
##########################
MANUAL_BLOCK
    echo
    echo "Then run: cd ~/dotfiles && nixbuild"
    echo "=========================================="
    
    read -p "Press Enter to continue..."
}

# Step 4: Start Router VM (WORKING) 
start_router_vm() {
    log "Starting router VM with WiFi passthrough..."

    if [[ ! -f "$SCRIPT_DIR/generated-configs/deploy-router-vm.sh" ]]; then
        error "Generated deployment script not found. Run config generation first."
        read -p "Press Enter to continue..."
        return 1
    fi

    log "Using generated deployment script..."
    "$SCRIPT_DIR/generated-configs/deploy-router-vm.sh"

    if sudo virsh --connect qemu:///system list | grep -q "router-vm-passthrough.*running"; then
        log "✅ Router VM started with WiFi passthrough!"
        log "Connect with: sudo virsh --connect qemu:///system console router-vm-passthrough"
        log "In VM, check: lspci -nnk | grep -i network"
    else
        error "VM failed to start with passthrough"
    fi

    read -p "Press Enter to continue..."
}

# Step 5: Connect to Router (WORKING)
connect_to_router() {
    log "Connecting to router VM console..."

    if sudo virsh list | grep -q "router-vm.*running"; then
        vm_name=$(sudo virsh list | grep "router-vm.*running" | awk '{print $2}' | head -1)
        log "Found running VM: $vm_name"
    else
        error "No router VM is running. Start it first with option 4."
        read -p "Press Enter to continue..."
        return 1
    fi

    log "Use Ctrl+] to exit console"
    sleep 2

    sudo virsh console "$vm_name"

    read -p "Press Enter to continue..."
}

show_menu() {
    echo "============================================"
    echo "  Essential VM Router Setup"
    echo "============================================"
    echo "  1. Hardware Detection (Essential)"
    echo "  2. Generate Configs (Essential)" 
    echo "  3. Integrate to Dotfiles (SAFE Manual)"
    echo "  4. Start Router VM (Helpful)"
    echo "  5. Connect to Router (Helpful)"
    echo "  q. Quit"
    echo "============================================"
}

main() {
    while true; do
        show_menu
        read -p "Choose option: " choice
        
        case "$choice" in
            1) hardware_detection ;;
            2) config_generation ;;
            3) integrate_dotfiles ;;
            4) start_router_vm ;;
            5) connect_to_router ;;
            q|Q) exit 0 ;;
            *) echo "Invalid option: $choice" ;;
        esac
        
        echo
    done
}

main "$@"
