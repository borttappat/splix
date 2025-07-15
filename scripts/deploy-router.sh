#!/usr/bin/env bash
# Router VM deployment script with passthrough support

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
error() { echo "[ERROR] $*" >&2; }
die() { error "$*"; exit 1; }

check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check if hardware detection was run
    [[ -f "$PROJECT_ROOT/hardware-results.env" ]] || die "Run ./scripts/hardware-identify.sh first"
    
    # Check if configs were generated
    [[ -d "$SCRIPT_DIR/generated-configs" ]] || die "Run ./scripts/vm-setup-generator.sh first"
    
    # Check for root/sudo
    [[ $EUID -eq 0 ]] || [[ -n "${SUDO_USER:-}" ]] || die "Run with sudo"
    
    log "Prerequisites OK"
}

test_emergency_recovery() {
    log "Testing emergency recovery..."
    
    local recovery_script="$SCRIPT_DIR/generated-configs/emergency-recovery.sh"
    [[ -f "$recovery_script" ]] || die "Emergency recovery script not found"
    
    log "Emergency recovery will:"
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
    log "Configuration options:"
    log "  1. router-host-import - Uses /etc/nixos imports (may have conflicts)"
    log "  2. router-host - Standalone configuration (recommended)"
    log ""
    
    read -p "Which configuration to use? (1/2): " config_choice
    
    local flake_target
    case "$config_choice" in
        1) flake_target="router-host-import" ;;
        2) flake_target="router-host" ;;
        *) die "Invalid choice" ;;
    esac
    
    log "Using configuration: $flake_target"
    log ""
    log "Ensure you have tested:"
    log "  ✓ Router VM boots and works with virtio"
    log "  ✓ Emergency recovery restores networking"
    log "  ✓ You have physical access to this machine"
    log ""
    
    read -p "Continue with passthrough deployment? (yes/no): " confirm
    [[ "$confirm" == "yes" ]] || die "Aborted"
    
    log "Applying host passthrough configuration..."
    
    # Copy emergency recovery script to a safe location
    sudo cp "$SCRIPT_DIR/generated-configs/emergency-recovery.sh" /root/
    sudo chmod +x /root/emergency-recovery.sh
    
    # Apply the configuration
    cd "$PROJECT_ROOT"
    sudo nixos-rebuild switch --flake ".#${flake_target}" --impure
    
    log "Host configuration applied"
    log "REBOOT REQUIRED to activate passthrough"
    log "After reboot, run: $0 deploy"
}

deploy_passthrough_vm() {
    log "Deploying router VM with passthrough..."
    
    # Check that we're in passthrough mode
    source "$PROJECT_ROOT/hardware-results.env"
    
    if lspci -nnk -s "$PRIMARY_PCI" | grep -q "Kernel driver in use: vfio-pci"; then
        log "✓ Device bound to VFIO"
    else
        log "WARNING: Device not bound to VFIO"
        log "Current driver:"
        lspci -nnk -s "$PRIMARY_PCI" | grep "Kernel driver"
        read -p "Continue anyway? (y/n): " continue_anyway
        [[ "$continue_anyway" =~ ^[Yy]$ ]] || die "Aborted"
    fi
    
    # Deploy passthrough VM
    local xml_file="$SCRIPT_DIR/generated-configs/router-vm-passthrough.xml"
    [[ -f "$xml_file" ]] || die "Generated passthrough XML not found"
    
    # Stop and remove any existing router VMs
    for vm in router-vm router-vm-virtio router-vm-passthrough; do
        sudo virsh destroy "$vm" 2>/dev/null || true
        sudo virsh undefine "$vm" 2>/dev/null || true
    done
    
    sudo virsh define "$xml_file"
    sudo virsh start router-vm
    
    log "Router VM started with WiFi passthrough"
    log "Connect with: sudo virsh console router-vm"
    log ""
    log "Next steps in VM:"
    log "  1. Login as admin/admin"
    log "  2. Check WiFi: ip link show"
    log "  3. Configure WiFi: nmcli device wifi connect 'SSID' password 'PASSWORD'"
    log "  4. Verify internet: ping 8.8.8.8"
}

show_status() {
    log "Current system status:"
    
    # Check IOMMU
    if dmesg | grep -q "IOMMU enabled"; then
        log "✓ IOMMU: Enabled"
    else
        log "✗ IOMMU: Not enabled"
    fi
    
    # Check VFIO modules
    if lsmod | grep -q vfio_pci; then
        log "✓ VFIO modules: Loaded"
    else
        log "✗ VFIO modules: Not loaded"
    fi
    
    # Check WiFi device
    if [[ -f "$PROJECT_ROOT/hardware-results.env" ]]; then
        source "$PROJECT_ROOT/hardware-results.env"
        log "WiFi device: $PRIMARY_INTERFACE ($PRIMARY_PCI)"
        log "Current driver: $(lspci -nnk -s "$PRIMARY_PCI" | grep "Kernel driver" | awk '{print $NF}')"
    fi
    
    # Check VMs
    log "Virtual machines:"
    sudo virsh list --all | grep -E "(router-vm|State)" || true
}

main() {
    case "${1:-help}" in
        check)
            check_prerequisites
            show_status
            ;;
        recovery-test)
            check_prerequisites
            test_emergency_recovery
            ;;
        passthrough)
            check_prerequisites
            apply_passthrough_config
            ;;
        deploy)
            check_prerequisites
            deploy_passthrough_vm
            ;;
        status)
            show_status
            ;;
        *)
            echo "VM Router Deployment Script"
            echo ""
            echo "Usage: $0 <command>"
            echo ""
            echo "Commands:"
            echo "  check         - Check prerequisites and show status"
            echo "  recovery-test - Test emergency recovery"
            echo "  passthrough   - Apply passthrough config (point of no return)"
            echo "  deploy        - Deploy router VM after reboot"
            echo "  status        - Show current system status"
            ;;
    esac
}

main "$@"
