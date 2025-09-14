#!/run/current-system/sw/bin/bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
readonly TEMPLATES_DIR="$PROJECT_DIR/templates"
readonly GENERATED_DIR="$PROJECT_DIR/generated"

log() { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

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

build_router_vm() {
    log "=== Step 2: Build Router VM ==="
    
    cd "$PROJECT_DIR"
    if ! nix build .#router-vm-qcow --print-build-logs; then
        error "Router VM build failed"
        exit 1
    fi

    if [[ -f "result/nixos.qcow2" ]]; then
        log "Router VM built successfully: $(du -h result/nixos.qcow2 | cut -f1)"
    else
        error "VM image not found after build"
        exit 1
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
    
    sed "s|{{DEVICE_ID}}|$PRIMARY_ID|g; s|{{PRIMARY_DRIVER}}|$PRIMARY_DRIVER|g; s|{{MACHINE_NAME}}|$MACHINE_NAME|g" \
        "$TEMPLATES_DIR/machine-passthrough.nix.template" > \
        "$GENERATED_DIR/modules/${MACHINE_NAME}-passthrough.nix"
    
    sed "s|{{MACHINE_NAME}}|$MACHINE_NAME|g" \
        "$TEMPLATES_DIR/specialisation-block.template" > \
        "$GENERATED_DIR/modules/${MACHINE_NAME}.nix"
    
    log "Generated machine configs for $MACHINE_NAME"
}

generate_deployment_scripts() {
    log "=== Step 4: Generate Deployment Scripts ==="
    
    source "$PROJECT_DIR/hardware-results.env"
    
    cat > "$GENERATED_DIR/scripts/deploy-router-vm.sh" << 'DEPLOYEOF'
#!/usr/bin/env bash
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
    
    cat > "$GENERATED_DIR/README.md" << READMEEOF
# Generated Configuration for $MACHINE_NAME

**Machine**: $(hostnamectl | grep -i "Hardware Model" | awk -F': ' '{print $2}' | xargs)
**WiFi Device**: $PRIMARY_INTERFACE ($PRIMARY_ID)
**PCI Device**: $PRIMARY_PCI  
**Compatibility**: ${COMPATIBILITY_SCORE}/10

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

    log "Created: README.md"
}

main() {
    log "=== Complete Machine Setup ==="

    run_hardware_detection
    build_router_vm
    generate_machine_configs
    generate_deployment_scripts
    create_summary_readme
    
    log "=== Generation Complete ==="
    log "All files in: $GENERATED_DIR"
    log ""
    log "Remember to 'git add' generated files before building with nixbuild"
}

main "$@"
