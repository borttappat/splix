#!/run/current-system/sw/bin/bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
error() { echo "[ERROR] $*" >&2; }
die() { error "$*"; exit 1; }

check_prerequisites() {
    log "Checking prerequisites..."
    
    [[ -f "$PROJECT_ROOT/hardware-results.env" ]] || die "Run hardware detection first"
    
    source "$PROJECT_ROOT/hardware-results.env"
    [[ "$RECOMMENDATION" == "PROCEED" ]] || die "Hardware not suitable (score: $COMPATIBILITY_SCORE)"
    
    systemctl is-active --quiet libvirtd || die "libvirtd not running"
    
    # Check if generated configs exist
    [[ -f "$SCRIPT_DIR/generated-configs/router-vm-virtio.xml" ]] || die "Generated configs not found. Run vm-setup-generator.sh first"
    
    log "Prerequisites OK"
}

build_router_vm() {
    log "Building router VM image..."
    
    cd "$PROJECT_ROOT"
    nix build .#nixosConfigurations.router-vm.config.system.build.vm
    
    log "Router VM built successfully"
}

test_router_vm_virtio() {
    log "Testing router VM with virtio networking..."
    
    # Ensure qemu-img is available
    if ! command -v qemu-img >/dev/null 2>&1; then
        log "qemu-img not found in PATH, using nix-shell..."
        nix-shell -p qemu --run "sudo qemu-img create -f qcow2 /var/lib/libvirt/images/router-vm.qcow2 10G" || die "Failed to create VM disk"
    else
        # Create VM disk if needed
        sudo mkdir -p /var/lib/libvirt/images
        if [[ ! -f /var/lib/libvirt/images/router-vm.qcow2 ]]; then
            sudo qemu-img create -f qcow2 /var/lib/libvirt/images/router-vm.qcow2 10G
        fi
    fi
    
    # Use generated XML configuration
    local xml_file="$SCRIPT_DIR/generated-configs/router-vm-virtio.xml"
    
    # Define and start virtio version
    sudo virsh define "$xml_file"
    sudo virsh start router-vm-virtio
    
    log "Router VM started with virtio networking"
    log "Connect with: sudo virsh console router-vm-virtio"
    log "Exit console with: Ctrl+]"
    log ""
    log "Test checklist in VM:"
    log "  1. Verify boot and login"
    log "  2. Check interfaces: ip addr show"
    log "  3. Test connectivity: ping 8.8.8.8"
    log "  4. Verify DHCP service: systemctl status dhcpd4"
    log ""
    log "When testing is complete, stop VM with: sudo virsh destroy router-vm-virtio"
}

test_emergency_recovery() {
    log "Testing emergency recovery system..."
    
    local recovery_script="$SCRIPT_DIR/generated-configs/emergency-recovery.sh"
    [[ -f "$recovery_script" ]] || die "Emergency recovery script not found"
    
    log "Emergency recovery script: $recovery_script"
    log "This will:"
    log "  1. Stop any running router VMs"
    log "  2. Unbind WiFi card from VFIO (if bound)"
    log "  3. Restore original network driver"
    log "  4. Start NetworkManager"
    log ""
    read -p "Test emergency recovery now? (y/n): " test_recovery
    
    if [[ "$test_recovery" =~ ^[Yy]$ ]]; then
        sudo "$recovery_script"
        log "Emergency recovery test completed"
    else
        log "Emergency recovery test skipped"
        log "IMPORTANT: Test this before deploying passthrough!"
    fi
}

apply_passthrough_config() {
    log "=== POINT OF NO RETURN ==="
    log "This will apply host passthrough configuration"
    log "You will lose host network access until router VM is running"
    log ""
    log "Ensure you have tested:"
    log "  ✓ Router VM boots and works with virtio"
    log "  ✓ Emergency recovery restores networking"
    log "  ✓ You have physical access to this machine"
    log ""
    
    read -p "Continue with passthrough deployment? (yes/no): " confirm
    [[ "$confirm" == "yes" ]] || die "Aborted"
    
    log "Applying host passthrough configuration..."
    
    # Use the generated host configuration
    if [[ -f "$SCRIPT_DIR/generated-configs/host-passthrough.nix" ]]; then
        log "Using generated host configuration"
        sudo nixos-rebuild switch --flake "$PROJECT_ROOT#router-host-test"
    else
        die "Generated host configuration not found"
    fi
    
    log "Host configuration applied"
    log "REBOOT REQUIRED to activate passthrough"
    log "After reboot, run: $0 deploy"
}

deploy_passthrough_vm() {
    log "Deploying router VM with passthrough..."
    
    # Check that we're in passthrough mode
    source "$PROJECT_ROOT/hardware-results.env"
    if lspci -s "$PRIMARY_PCI" | grep -q "Kernel driver in use: $PRIMARY_DRIVER"; then
        log "WARNING: Device still bound to $PRIMARY_DRIVER"
        log "Passthrough may not be active. Did you reboot after applying host config?"
        read -p "Continue anyway? (y/n): " continue_anyway
        [[ "$continue_anyway" =~ ^[Yy]$ ]] || die "Aborted"
    fi
    
    # Stop virtio version if running
    sudo virsh destroy router-vm-virtio 2>/dev/null || true
    sudo virsh undefine router-vm-virtio 2>/dev/null || true
    
    # Deploy passthrough version using generated XML
    local xml_file="$SCRIPT_DIR/generated-configs/router-vm-passthrough.xml"
    [[ -f "$xml_file" ]] || die "Generated passthrough XML not found"
    
    sudo virsh define "$xml_file"
    sudo virsh start router-vm
    
    log "Router VM started with WiFi passthrough"
    log "Connect with: sudo virsh console router-vm"
    log ""
    log "Configure WiFi in VM:"
    log "  1. Connect to console"
    log "  2. Configure WiFi: nmcli device wifi connect \"SSID\" password \"PASSWORD\""
    log "  3. Verify internet: ping 8.8.8.8"
    log "  4. Check guest bridge: ip addr show eth1"
    log ""
    log "If issues occur, run emergency recovery: sudo $SCRIPT_DIR/generated-configs/emergency-recovery.sh"
}

status_check() {
    log "Router VM Status Check"
    log "====================="
    
    # Check VM status
    log "Virtual Machines:"
    sudo virsh list --all
    
    echo
    log "Network Interfaces:"
    ip addr show | grep -E "^[0-9]+:|inet "
    
    echo
    # Check if hardware detection results exist
    if [[ -f "$PROJECT_ROOT/hardware-results.env" ]]; then
        source "$PROJECT_ROOT/hardware-results.env"
        log "Hardware Status:"
        log "  Primary Interface: $PRIMARY_INTERFACE ($PRIMARY_PCI)"
        log "  Current Driver: $(lspci -s "$PRIMARY_PCI" | grep -o "Kernel driver in use: [a-z0-9_-]*" | cut -d: -f2 | xargs || echo "unknown")"
        log "  Compatibility: $COMPATIBILITY_SCORE/10"
    fi
    
    echo
    log "Emergency Recovery Available: $SCRIPT_DIR/generated-configs/emergency-recovery.sh"
}

show_help() {
    echo "Router deployment script - follows safe VM-first sequence"
    echo
    echo "Usage: $0 <command>"
    echo
    echo "Commands:"
    echo "  check       - Check prerequisites and system status"
    echo "  build       - Build router VM image"
    echo "  test        - Test router VM with virtio networking (safe)"
    echo "  recovery    - Test emergency recovery system"
    echo "  passthrough - Apply host passthrough config (DESTRUCTIVE)"
    echo "  deploy      - Deploy router VM with passthrough"
    echo "  status      - Show current system and VM status"
    echo "  full        - Run complete testing sequence (check + build + test)"
    echo ""
    echo "Recommended sequence:"
    echo "  1. $0 check       # Verify prerequisites"
    echo "  2. $0 build       # Build router VM"
    echo "  3. $0 test        # Test VM with safe networking"
    echo "  4. $0 recovery    # Test emergency recovery"
    echo "  5. $0 passthrough # Apply passthrough (point of no return)"
    echo "  6. sudo reboot    # Activate VFIO passthrough"
    echo "  7. $0 deploy      # Start router VM with WiFi passthrough"
}

main() {
    case "${1:-help}" in
        "check") check_prerequisites ;;
        "build") build_router_vm ;;
        "test") test_router_vm_virtio ;;
        "recovery") test_emergency_recovery ;;
        "passthrough") apply_passthrough_config ;;
        "deploy") deploy_passthrough_vm ;;
        "status") status_check ;;
        "full") 
            check_prerequisites
            build_router_vm
            test_router_vm_virtio
            echo
            log "Testing complete! Next steps:"
            log "  1. Test the router VM: sudo virsh console router-vm-virtio"
            log "  2. Test emergency recovery: $0 recovery"
            log "  3. When ready: $0 passthrough"
            ;;
        *) show_help ;;
    esac
}

main "$@"
