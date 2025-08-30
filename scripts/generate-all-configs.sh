#!/run/current-system/sw/bin/bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
readonly TEMPLATES_DIR="$PROJECT_DIR/templates"
readonly GENERATED_DIR="$PROJECT_DIR/generated"

log() { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

check_prerequisites() {
    if [[ ! -f "$PROJECT_DIR/hardware-results.env" ]]; then
        error "Hardware detection results not found. Run: ./scripts/hardware-identify.sh"
    fi
    
    if [[ ! -f "$TEMPLATES_DIR/machine-passthrough.nix.template" ]]; then
        error "machine-passthrough.nix.template not found"
    fi
    
    if [[ ! -f "$TEMPLATES_DIR/specialisation-block.template" ]]; then
        error "specialisation-block.template not found"
    fi
}

derive_machine_info() {
    local vendor=$(hostnamectl | grep -i "Hardware Vendor" | awk -F': ' '{print $2}' | xargs)
    local model=$(hostnamectl | grep -i "Hardware Model" | awk -F': ' '{print $2}' | xargs)
    local model_lower=$(echo "$model" | tr '[:upper:]' '[:lower:]')
    
    log "Detected: $vendor - $model"
    
    # Determine machine name and match pattern
    if echo "$model_lower" | grep -q "zenbook"; then
        MACHINE_NAME="zenbook"
        MODEL_MATCH="zenbook"
    elif echo "$model_lower" | grep -q "zephyrus"; then
        MACHINE_NAME="zephyrus"
        MODEL_MATCH="zephyrus"
    elif echo "$model_lower" | grep -q "razer"; then
        MACHINE_NAME="razer"
        MODEL_MATCH="razer"
    elif echo "$vendor" | grep -qi "schenker"; then
        MACHINE_NAME="xmg"
        MODEL_MATCH="schenker"
    elif echo "$vendor" | grep -qi "asus"; then
        MACHINE_NAME="asus"
        MODEL_MATCH="asus"
    else
        # Generate safe machine name from model
        MACHINE_NAME=$(echo "$model_lower" | sed 's/[^a-z0-9]//g' | cut -c1-10)
        MODEL_MATCH="$MACHINE_NAME"
    fi
    
    log "Machine name: $MACHINE_NAME"
    log "Match pattern: $MODEL_MATCH"
}

generate_passthrough_config() {
    log "Generating passthrough configuration..."
    
    sed "s|{{DEVICE_ID}}|$PRIMARY_ID|g; \
         s|{{PRIMARY_DRIVER}}|$PRIMARY_DRIVER|g; \
         s|{{PROJECT_DIR}}|$PROJECT_DIR|g; \
         s|{{MACHINE_NAME}}|$MACHINE_NAME|g" \
        "$TEMPLATES_DIR/machine-passthrough.nix.template" > \
        "$GENERATED_DIR/modules/${MACHINE_NAME}-passthrough.nix"
    
    log "Created: modules/${MACHINE_NAME}-passthrough.nix"
}

generate_specialisation_block() {
    log "Generating specialisation block..."
    
    sed "s|{{MACHINE_NAME}}|$MACHINE_NAME|g" \
        "$TEMPLATES_DIR/specialisation-block.template" > \
        "$GENERATED_DIR/configs/${MACHINE_NAME}-specialisation-block.txt"
    
    log "Created: configs/${MACHINE_NAME}-specialisation-block.txt"
}

generate_machine_config() {
    log "Generating complete machine configuration..."
    
    # Create a complete machine.nix file with specialisation already included
    cat > "$GENERATED_DIR/modules/${MACHINE_NAME}.nix" << MACHINEEOF
{ config, pkgs, lib, ... }:
{
$(cat "$GENERATED_DIR/configs/${MACHINE_NAME}-specialisation-block.txt")

  # Basic machine configuration - customize as needed
  networking.hostName = lib.mkForce "$MACHINE_NAME";
  
  # Hardware-specific configurations can be added here
  # Example: hardware.cpu.intel.updateMicrocode = true;
}
MACHINEEOF

    log "Created: modules/${MACHINE_NAME}.nix (complete config with specialisation)"
}

generate_nixbuild_block() {
    log "Generating nixbuild.sh machine block..."
    
    local vendor=$(hostnamectl | grep -i "Hardware Vendor" | awk -F': ' '{print $2}' | xargs)
    local model=$(hostnamectl | grep -i "Hardware Model" | awk -F': ' '{print $2}' | xargs)
    
    cat > "$GENERATED_DIR/scripts/nixbuild-${MACHINE_NAME}-block.txt" << 'NIXEOF'
# For {{VENDOR}} {{MODEL}} specifically (check model line for "{{MODEL_MATCH}}")
elif echo "$current_model" | grep -qi "{{MODEL_MATCH}}"; then
    # Detect current specialisation by checking system state
    if lsmod | grep -q vfio_pci && [[ -d /sys/class/net/virbr1 ]]; then
        CURRENT_LABEL="router-setup"
    else
        CURRENT_LABEL="base-setup"
    fi
    echo "Current system: $CURRENT_LABEL (detected from system state)"

    case "${1:-auto}" in
        "router-boot")
            echo "Building {{MACHINE_NAME}} with router specialisation, staging for boot..."
            sudo nixos-rebuild boot --impure --show-trace --option warn-dirty false --flake ~/dotfiles#{{MACHINE_NAME}}
            echo "✅ Built. Reboot, then run 'switch-to-router' for router mode"
            ;;
        "router-switch")
            echo "Building {{MACHINE_NAME}} and switching to router mode..."
            sudo nixos-rebuild switch --impure --show-trace --option warn-dirty false --flake ~/dotfiles#{{MACHINE_NAME}}
            echo "Switching to router mode..."
            switch-to-router
            ;;
        "base-switch")
            echo "Building {{MACHINE_NAME}} and staying in base mode..."
            sudo nixos-rebuild switch --impure --show-trace --option warn-dirty false --flake ~/dotfiles#{{MACHINE_NAME}}
            echo "✅ Base mode active"
            ;;
        *)
            echo "Building {{MACHINE_NAME}} and maintaining current mode ($CURRENT_LABEL)..."
            sudo nixos-rebuild switch --impure --show-trace --option warn-dirty false --flake ~/dotfiles#{{MACHINE_NAME}}

            # Add bridge recreation for router mode
            if [[ "$CURRENT_LABEL" == "router-setup" ]]; then
                echo "Ensuring virbr1 bridge exists for router mode..."
                if ! ip link show virbr1 >/dev/null 2>&1; then
                    sudo ip link add virbr1 type bridge
                    sudo ip addr add 192.168.100.1/24 dev virbr1
                    sudo ip link set virbr1 up
                    echo "✓ virbr1 bridge recreated"
                else
                    echo "✓ virbr1 bridge already exists"
                fi
            fi

            # Switch back to whatever mode we were in
            if [[ "$CURRENT_LABEL" == "router-setup" ]]; then
                echo "Restoring router mode..."
                switch-to-router
            else
                echo "✅ Base mode active. Available commands:"
                echo "  switch-to-router  - Enable router mode with VFIO"
                echo "  switch-to-base    - Return to normal WiFi"
            fi
            ;;
    esac
NIXEOF

    # Replace template variables
    sed -i "s|{{VENDOR}}|$vendor|g; \
            s|{{MODEL}}|$model|g; \
            s|{{MODEL_MATCH}}|$MODEL_MATCH|g; \
            s|{{MACHINE_NAME}}|$MACHINE_NAME|g" \
        "$GENERATED_DIR/scripts/nixbuild-${MACHINE_NAME}-block.txt"
    
    log "Created: scripts/nixbuild-${MACHINE_NAME}-block.txt"
}

generate_deployment_scripts() {
    log "Generating deployment and utility scripts..."
    
    # Emergency recovery script with actual hardware values
    cat > "$GENERATED_DIR/scripts/emergency-recovery.sh" << 'EMERGEOF'
#!/run/current-system/sw/bin/bash
set -euo pipefail

log() { echo "[Emergency Recovery] $*"; }

log "Emergency network recovery for {{PRIMARY_INTERFACE}} ({{PRIMARY_ID}})"

# Unbind from VFIO
if [[ -d "/sys/bus/pci/devices/{{PRIMARY_PCI}}/driver" ]]; then
    driver_name=$(basename "$(readlink /sys/bus/pci/devices/{{PRIMARY_PCI}}/driver)")
    if [[ "$driver_name" == "vfio-pci" ]]; then
        log "Unbinding {{PRIMARY_PCI}} from vfio-pci..."
        echo "{{PRIMARY_PCI}}" | sudo tee /sys/bus/pci/devices/{{PRIMARY_PCI}}/driver/unbind
        sleep 2
    fi
fi

# Bind to correct driver
if [[ ! -d "/sys/bus/pci/devices/{{PRIMARY_PCI}}/driver" ]]; then
    log "Binding {{PRIMARY_PCI}} to {{PRIMARY_DRIVER}}..."
    echo "{{PRIMARY_PCI}}" | sudo tee /sys/bus/pci/drivers/{{PRIMARY_DRIVER}}/bind
    sleep 3
fi

# Restart NetworkManager
log "Restarting NetworkManager..."
sudo systemctl restart NetworkManager
sleep 5

# Check connectivity
log "Testing connectivity..."
if ping -c 3 8.8.8.8 >/dev/null 2>&1; then
    log "✅ Network recovery successful"
else
    log "⚠️ Manual intervention may be required"
fi
EMERGEOF

    # Replace placeholders
    sed -i "s|{{PRIMARY_INTERFACE}}|$PRIMARY_INTERFACE|g; \
            s|{{PRIMARY_ID}}|$PRIMARY_ID|g; \
            s|{{PRIMARY_PCI}}|$PRIMARY_PCI|g; \
            s|{{PRIMARY_DRIVER}}|$PRIMARY_DRIVER|g" \
        "$GENERATED_DIR/scripts/emergency-recovery.sh"
    
    chmod +x "$GENERATED_DIR/scripts/emergency-recovery.sh"
    log "Created: scripts/emergency-recovery.sh"
    
    # Start router VM script
    cat > "$GENERATED_DIR/scripts/start-router-vm.sh" << 'STARTEOF'
#!/run/current-system/sw/bin/bash
set -euo pipefail

log() { echo "[Router VM] $*"; }

if [[ ! -f "{{PROJECT_DIR}}/scripts/generated-configs/deploy-router-vm.sh" ]]; then
    log "ERROR: VM deployment script not found. Run vm-setup-generator.sh first."
    exit 1
fi

log "Starting router VM with {{PRIMARY_INTERFACE}} passthrough..."
"{{PROJECT_DIR}}/scripts/generated-configs/deploy-router-vm.sh"

if sudo virsh --connect qemu:///system list | grep -q "router-vm.*running"; then
    vm_name=$(sudo virsh --connect qemu:///system list | grep "router-vm.*running" | awk '{print $2}' | head -1)
    log "✅ Router VM started: $vm_name"
    log "Connect with: sudo virsh --connect qemu:///system console $vm_name"
else
    log "❌ VM failed to start"
    exit 1
fi
STARTEOF

    # Replace placeholders
    sed -i "s|{{PROJECT_DIR}}|$PROJECT_DIR|g; \
            s|{{PRIMARY_INTERFACE}}|$PRIMARY_INTERFACE|g" \
        "$GENERATED_DIR/scripts/start-router-vm.sh"
    
    chmod +x "$GENERATED_DIR/scripts/start-router-vm.sh"
    log "Created: scripts/start-router-vm.sh"
}

create_summary_readme() {
    log "Creating README with generated files summary..."
    
    cat > "$GENERATED_DIR/README.md" << READMEEOF
# Generated Configuration for $MACHINE_NAME

**Machine**: $(hostnamectl | grep -i "Hardware Model" | awk -F': ' '{print $2}' | xargs)
**WiFi Device**: $PRIMARY_INTERFACE ($PRIMARY_ID)
**Compatibility**: ${COMPATIBILITY_SCORE}/10

## Generated Files

### Modules
- \`modules/${MACHINE_NAME}-passthrough.nix\` - VFIO passthrough configuration
- \`modules/${MACHINE_NAME}.nix\` - Complete machine config with router specialisation

### Configuration Blocks  
- \`configs/${MACHINE_NAME}-specialisation-block.txt\` - Router specialisation block for insertion

### Scripts
- \`scripts/nixbuild-${MACHINE_NAME}-block.txt\` - nixbuild.sh logic for this machine
- \`scripts/emergency-recovery.sh\` - Hardware-specific network recovery
- \`scripts/start-router-vm.sh\` - Router VM startup script

## Next Steps

1. Review generated configurations
2. Copy/integrate into dotfiles as needed
3. Test emergency recovery script
4. Deploy VM configurations

Generated: $(date)
Hardware: $PRIMARY_INTERFACE ($PRIMARY_ID), Driver: $PRIMARY_DRIVER
READMEEOF

    log "Created: README.md"
}

build_router_vm() {
    log "Building router VM image..."

    cd "$PROJECT_DIR"
    if ! nix build .#router-vm-qcow --print-build-logs; then
        error "Router VM build failed"
        exit 1
    fi

    if [[ -f "result/nixos.qcow2" ]]; then
        log "✓ Router VM built successfully: $(du -h result/nixos.qcow2 | cut -f1)"
    else
        error "VM image not found after build"
        exit 1
    fi
}

generate_vm_deployment_scripts() {
    log "Generating VM deployment scripts..."

    # Test deployment script (safe, uses default networking)
    cat > "$GENERATED_DIR/scripts/test-router-vm.sh" << 'TESTEOF'
#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date +%H:%M:%S)] $*"; }

readonly VM_NAME="router-vm-test"
readonly SOURCE_IMAGE="{{PROJECT_DIR}}/result/nixos.qcow2"
readonly TARGET_IMAGE="/var/lib/libvirt/images/$VM_NAME.qcow2"

if [[ ! -f "$SOURCE_IMAGE" ]]; then
    log "ERROR: Router VM image not found. Run build first."
    exit 1
fi

log "Deploying router VM for safe testing..."

# Clean up existing test VM
if sudo virsh --connect qemu:///system list --all | grep -q "$VM_NAME"; then
    sudo virsh --connect qemu:///system destroy "$VM_NAME" 2>/dev/null || true
    sudo virsh --connect qemu:///system undefine "$VM_NAME" --nvram 2>/dev/null || true
fi

# Copy VM image
sudo cp "$SOURCE_IMAGE" "$TARGET_IMAGE"
sudo chown libvirt-qemu:kvm "$TARGET_IMAGE" 2>/dev/null || sudo chmod 644 "$TARGET_IMAGE"

# Deploy with default networking (safe for testing)
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
    --network default \
    --noautoconsole \
    --import

log "✅ Test VM deployed. Connect with: sudo virsh console $VM_NAME"
TESTEOF

    # Production deployment script (uses passthrough)
    cat > "$GENERATED_DIR/scripts/deploy-router-vm.sh" << 'DEPLOYEOF'
#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date +%H:%M:%S)] $*"; }

readonly VM_NAME="router-vm-passthrough"
readonly SOURCE_IMAGE="{{PROJECT_DIR}}/result/nixos.qcow2"
readonly TARGET_IMAGE="/var/lib/libvirt/images/$VM_NAME.qcow2"

if [[ ! -f "$SOURCE_IMAGE" ]]; then
    log "ERROR: Router VM image not found. Run build first."
    exit 1
fi

log "Deploying router VM with WiFi passthrough..."

# Clean up existing VM
if sudo virsh --connect qemu:///system list --all | grep -q "$VM_NAME"; then
    sudo virsh --connect qemu:///system destroy "$VM_NAME" 2>/dev/null || true
    sudo virsh --connect qemu:///system undefine "$VM_NAME" --nvram 2>/dev/null || true
fi

# Copy VM image
sudo cp "$SOURCE_IMAGE" "$TARGET_IMAGE"
sudo chown libvirt-qemu:kvm "$TARGET_IMAGE" 2>/dev/null || sudo chmod 644 "$TARGET_IMAGE"

# Deploy with WiFi passthrough
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
    --hostdev {{PRIMARY_PCI}} \
    --noautoconsole \
    --import

log "✅ Router VM deployed with WiFi passthrough!"
log "Connect with: sudo virsh console $VM_NAME"
DEPLOYEOF

    # Replace placeholders in deployment scripts
    sed -i "s|{{PROJECT_DIR}}|$PROJECT_DIR|g; \
            s|{{PRIMARY_PCI}}|$PRIMARY_PCI|g" \
        "$GENERATED_DIR/scripts/test-router-vm.sh" \
        "$GENERATED_DIR/scripts/deploy-router-vm.sh"

    chmod +x "$GENERATED_DIR/scripts/test-router-vm.sh"
    chmod +x "$GENERATED_DIR/scripts/deploy-router-vm.sh"

    log "Created: scripts/test-router-vm.sh (safe testing)"
    log "Created: scripts/deploy-router-vm.sh (passthrough)"
}

# Update main function to include VM building
main() {
    log "=== Generating All Configurations ==="

    check_prerequisites
    source "$PROJECT_DIR/hardware-results.env"

    log "Hardware: $PRIMARY_INTERFACE ($PRIMARY_ID), Driver: $PRIMARY_DRIVER"
    log "Compatibility: $COMPATIBILITY_SCORE/10"

    derive_machine_info

    # Create output directory structure
    rm -rf "$GENERATED_DIR"
    mkdir -p "$GENERATED_DIR"/{modules,configs,scripts}

    generate_passthrough_config
    generate_specialisation_block
    generate_machine_config
    generate_nixbuild_block
    build_router_vm
    generate_vm_deployment_scripts
    generate_deployment_scripts
    create_summary_readme

    log "=== Generation Complete ==="
    log "All files created in: $GENERATED_DIR"
    log "VM image built at: $PROJECT_DIR/result/nixos.qcow2"
    log "Review: cat $GENERATED_DIR/README.md"
}
