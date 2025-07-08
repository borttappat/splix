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
    
    # Create VM disk if needed
    sudo mkdir -p /var/lib/libvirt/images
    if [[ ! -f /var/lib/libvirt/images/router-vm.qcow2 ]]; then
        sudo qemu-img create -f qcow2 /var/lib/libvirt/images/router-vm.qcow2 10G
    fi
    
    # Define and start virtio version
    sudo virsh define "$PROJECT_ROOT/configs/libvirt/router-vm-virtio.xml"
    sudo virsh start router-vm-virtio
    
    log "Router VM started with virtio networking"
    log "Connect with: virsh console router-vm-virtio"
    log "Test connectivity and DHCP before proceeding to passthrough"
}

apply_passthrough_config() {
    log "=== POINT OF NO RETURN ==="
    log "This will apply host passthrough configuration"
    log "You will lose host network access until router VM is running"
    
    read -p "Continue? (yes/no): " confirm
    [[ "$confirm" == "yes" ]] || die "Aborted"
    
    log "Applying host passthrough configuration..."
    sudo nixos-rebuild switch --flake "$PROJECT_ROOT#router-host-test"
    
    log "Host configuration applied"
    log "REBOOT REQUIRED to activate passthrough"
}

deploy_passthrough_vm() {
    log "Deploying router VM with passthrough..."
    
    # Stop virtio version
    sudo virsh destroy router-vm-virtio 2>/dev/null || true
    sudo virsh undefine router-vm-virtio 2>/dev/null || true
    
    # Deploy passthrough version
    sudo virsh define "$PROJECT_ROOT/configs/libvirt/router-vm-passthrough.xml"
    sudo virsh start router-vm
    
    log "Router VM started with WiFi passthrough"
}

show_help() {
    echo "Router deployment script - follows safe VM-first sequence"
    echo
    echo "Usage: $0 <command>"
    echo
    echo "Commands:"
    echo "  check       - Check prerequisites"
    echo "  build       - Build router VM image"
    echo "  test        - Test router VM with virtio networking"
    echo "  passthrough - Apply host passthrough config (DESTRUCTIVE)"
    echo "  deploy      - Deploy router VM with passthrough"
    echo "  full        - Run complete deployment sequence"
}

main() {
    case "${1:-help}" in
        "check") check_prerequisites ;;
        "build") build_router_vm ;;
        "test") test_router_vm_virtio ;;
        "passthrough") apply_passthrough_config ;;
        "deploy") deploy_passthrough_vm ;;
        "full") 
            check_prerequisites
            build_router_vm
            test_router_vm_virtio
            echo "Manual verification required before passthrough"
            ;;
        *) show_help ;;
    esac
}

main "$@"
