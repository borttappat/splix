#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SPLIX_DIR="$(dirname "$SCRIPT_DIR")"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

build_minimal_vm() {
    log "Building minimal virsh-compatible VM..."
    
    cd "$SPLIX_DIR"
    
    if ! nix build .#minimal-vm-qcow --print-build-logs; then
        log "❌ VM build failed!"
        return 1
    fi
    
    local qcow_path="$SPLIX_DIR/result/nixos.qcow2"
    
    if [[ ! -f "$qcow_path" ]]; then
        log "❌ No qcow2 file found at $qcow_path"
        return 1
    fi
    
    log "✓ VM built successfully: $qcow_path"
    
    local vm_name="splix-minimal-vm"
    local target_path="/var/lib/libvirt/images/${vm_name}.qcow2"
    
    log "Copying VM to libvirt images directory..."
    sudo cp "$qcow_path" "$target_path"
    sudo chown libvirt-qemu:kvm "$target_path"
    
    log "✓ VM copied to $target_path"
    
    if virsh list --all | grep -q "$vm_name"; then
        log "Removing existing VM definition..."
        virsh destroy "$vm_name" 2>/dev/null || true
        virsh undefine "$vm_name" --nvram 2>/dev/null || true
    fi
    
    log "Creating VM definition..."
    virt-install \
        --name="$vm_name" \
        --memory=2048 \
        --vcpus=2 \
        --disk "$target_path,device=disk,bus=virtio" \
        --os-variant=nixos-unstable \
        --boot=hd \
        --nographics \
        --console pty,target_type=virtio \
        --network network=default,model=virtio \
        --noautoconsole \
        --import
    
    log "✅ VM created successfully!"
    log ""
    log "Next steps:"
    log "  Start VM:    virsh start $vm_name"
    log "  Console:     virsh console $vm_name"
    log "  Stop VM:     virsh destroy $vm_name"
    log "  SSH access:  ssh nixos@<vm-ip> (password: nixos)"
    log ""
    log "VM will auto-start. Connect with:"
    echo "  virsh console $vm_name"
}

test_vm() {
    local vm_name="splix-minimal-vm"
    
    log "Testing VM connectivity..."
    
    if ! virsh list | grep -q "$vm_name.*running"; then
        log "Starting VM..."
        virsh start "$vm_name"
        sleep 5
    fi
    
    log "VM should be booting. Connect with:"
    echo "  virsh console $vm_name"
    log ""
    log "Exit console: Ctrl+] then Enter"
    log "Login: nixos / nixos (or root / nixos)"
}

show_status() {
    local vm_name="splix-minimal-vm"
    
    log "=== VM Status ==="
    virsh list --all | grep -E "($vm_name|Name)" || echo "No VMs found"
    
    log ""
    log "=== Default Network Status ==="
    virsh net-list --all | grep -E "(default|Name)"
    
    log ""
    log "=== Libvirt Images ==="
    ls -lh /var/lib/libvirt/images/ | grep -E "(splix|total)" || echo "No splix images found"
}

main() {
    case "${1:-build}" in
        build)
            build_minimal_vm
            ;;
        test)
            test_vm
            ;;
        status)
            show_status
            ;;
        console)
            virsh console splix-minimal-vm
            ;;
        clean)
            log "Cleaning up VM..."
            virsh destroy splix-minimal-vm 2>/dev/null || true
            virsh undefine splix-minimal-vm --nvram 2>/dev/null || true
            sudo rm -f /var/lib/libvirt/images/splix-minimal-vm.qcow2
            log "✓ Cleanup complete"
            ;;
        *)
            echo "Usage: $0 {build|test|console|status|clean}"
            echo ""
            echo "  build    - Build and deploy minimal VM"
            echo "  test     - Start VM and show connection info"  
            echo "  console  - Connect to VM console"
            echo "  status   - Show VM and network status"
            echo "  clean    - Remove VM and files"
            exit 1
            ;;
    esac
}

main "$@"
