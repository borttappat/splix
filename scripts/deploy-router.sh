#!/usr/bin/env bash
# Router VM deployment script with passthrough support
# Updated to work with dotfiles integration

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SPLIX_DIR="$(dirname "$SCRIPT_DIR")"
readonly DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
error() { echo "[ERROR] $*" >&2; }
die() { error "$*"; exit 1; }

check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check if hardware detection was run
    [[ -f "$SPLIX_DIR/hardware-results.env" ]] || die "Run ./scripts/hardware-identify.sh first"
    
    # Check if configs were generated
    [[ -d "$SPLIX_DIR/scripts/generated-configs" ]] || die "Run ./scripts/vm-setup-generator.sh first"
    
    # Check if integrated with dotfiles
    [[ -d "$DOTFILES_DIR/modules/router-generated" ]] || die "Run ./scripts/router-integrate.sh first"
    
    # Check for root/sudo
    [[ $EUID -eq 0 ]] || [[ -n "${SUDO_USER:-}" ]] || die "Run with sudo"
    
    log "Prerequisites OK"
}

test_emergency_recovery() {
    log "Testing emergency recovery..."
    
    local recovery_script="$SPLIX_DIR/scripts/generated-configs/emergency-recovery.sh"
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

check_vfio_status() {
    log "Checking VFIO status..."
    
    # Source hardware results
    source "$SPLIX_DIR/hardware-results.env"
    
    # Check if device is bound to VFIO
    local driver=$(lspci -nnk -s "$PRIMARY_PCI_SLOT" | grep "Kernel driver in use:" | awk '{print $5}')
    
    if [[ "$driver" == "vfio-pci" ]]; then
        log "✓ Device is bound to VFIO: $driver"
        return 0
    else
        log "WARNING: Device not bound to VFIO"
        log "Current driver: $driver"
        return 1
    fi
}

apply_passthrough_config() {
    log "=== POINT OF NO RETURN ==="
    log "This will apply host passthrough configuration"
    log "You will lose host network access until router VM is running"
    log ""
    
    log "Using router-host configuration from dotfiles"
    log ""
    log "Ensure you have tested:"
    log "  ✓ Router VM boots and works with virtio"
    log "  ✓ Emergency recovery restores networking"
    log "  ✓ You have physical access to this machine"
    log ""
    
    read -p "Continue with passthrough deployment? (y/n): " continue_deploy
    
    if [[ ! "$continue_deploy" =~ ^[Yy]$ ]]; then
        log "Deployment aborted"
        exit 0
    fi
    
    log "Applying router host configuration..."
    cd "$DOTFILES_DIR"
    sudo nixos-rebuild switch --flake .#router-host
    
    log "Host configuration applied"
    log "REBOOT REQUIRED to activate VFIO passthrough"
    log ""
    read -p "Reboot now? (y/n): " do_reboot
    
    if [[ "$do_reboot" =~ ^[Yy]$ ]]; then
        log "Rebooting..."
        sudo reboot
    else
        log "Reboot manually, then run: $0 start"
    fi
}

start_router_vm() {
    log "Starting router VM with passthrough..."
    
    if ! check_vfio_status; then
        read -p "Continue anyway? (y/n): " continue_anyway
        [[ "$continue_anyway" =~ ^[Yy]$ ]] || die "Aborted"
    fi
    
    # Start the VM using libvirt
    local vm_xml="$SPLIX_DIR/scripts/generated-configs/router-vm-passthrough.xml"
    
    if ! sudo virsh list --all | grep -q router-vm; then
        log "Defining router VM..."
        sudo virsh define "$vm_xml"
    fi
    
    log "Starting router VM..."
    sudo virsh start router-vm
    
    log "Router VM started"
    log "Connect with: $SPLIX_DIR/scripts/router-vm-test.sh"
    log "Or: sudo virsh console router-vm"
}

case "${1:-}" in
    "test-recovery")
        test_emergency_recovery
        ;;
    "passthrough")
        check_prerequisites
        apply_passthrough_config
        ;;
    "start"|"deploy")
        check_prerequisites
        start_router_vm
        ;;
    "status")
        log "=== Router Status ==="
        sudo virsh list --all | grep router-vm || echo "No router VM defined"
        echo
        log "=== VFIO Status ==="
        check_vfio_status || true
        echo
        log "=== Integration Status ==="
        [[ -d "$DOTFILES_DIR/modules/router-generated" ]] && echo "✓ Integrated with dotfiles" || echo "✗ Not integrated"
        ;;
    *)
        echo "Usage: $0 [test-recovery|passthrough|start|status]"
        echo "  test-recovery - Test emergency recovery"
        echo "  passthrough   - Apply passthrough config and reboot"
        echo "  start/deploy  - Start router VM (after reboot)"
        echo "  status        - Show status"
        echo ""
        echo "Workflow:"
        echo "1. $0 test-recovery"
        echo "2. $0 passthrough    # Point of no return"
        echo "3. $0 start          # After reboot"
        ;;
esac
