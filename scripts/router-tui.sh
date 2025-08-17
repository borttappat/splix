#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SPLIX_DIR="$(dirname "$SCRIPT_DIR")"
readonly DOTFILES_DIR="${HOME}/dotfiles"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
error() { echo "[ERROR] $*" >&2; }

show_menu() {
    clear
    echo "================================================================"
    echo "               VM Router Setup - Main Menu"
    echo "================================================================"
    echo
    echo "  PREPARATION (Safe)"
    echo "   1) Hardware Detection        - Detect WiFi card, check compatibility"
    echo "   2) Config Generation         - Generate hardware-specific configs"
    echo "   3) Dotfiles Integration      - Add to dotfiles (with git add)"
    echo "   4) VM Testing               - Safe testing with QEMU networking"
    echo
    echo "  DEPLOYMENT (Point of No Return)"
    echo "   5) Deploy Host Config       - Apply VFIO, reboot required"
    echo "   6) Start Router VM          - After reboot, start with passthrough"
    echo
    echo "  MANAGEMENT"
    echo "   7) Show Status             - Detailed system status"
    echo "   8) Connect to Router       - Console access to VM"
    echo "   9) Emergency Recovery      - Restore network if issues"
    echo "  10) Clean Up Everything     - Remove all router configs (with git)"
    echo
    echo "  AUTOMATION"
    echo "  12) Full Guided Setup       - Run steps 1-4 automatically"
    echo
    echo "   q) Quit"
    echo
    echo "================================================================"
}

cleanup_existing_vms() {
    log "Cleaning up existing router VMs..."
    for vm_name in router-vm router-vm-test router-vm-passthrough; do
        if sudo virsh --connect qemu:///system list --all | grep -q "$vm_name"; then
            log "Removing VM: $vm_name"
            sudo virsh --connect qemu:///system destroy "$vm_name" 2>/dev/null || true
            sudo virsh --connect qemu:///system undefine "$vm_name" --nvram --managed-save --snapshots-metadata 2>/dev/null || true
        fi
    done
    
    log "Cleaning up VM disk images..."
    sudo rm -f /var/lib/libvirt/images/router-vm*.qcow2
    
    log "Refreshing storage pool..."
    sudo virsh --connect qemu:///system pool-refresh default 2>/dev/null || true
    
    # Add verification
    log "Verifying cleanup..."
    if sudo virsh --connect qemu:///system list --all | grep -q "router-vm"; then
        error "VMs still exist after cleanup"
        sudo virsh --connect qemu:///system list --all
    fi
    
    # Add longer delay to ensure cleanup completes
    sleep 5
}

check_prerequisites() {
    if [[ ! -d "$DOTFILES_DIR" ]]; then
        error "Dotfiles directory not found at $DOTFILES_DIR"
        return 1
    fi
    
    if [[ ! -d "$DOTFILES_DIR/.git" ]]; then
        error "Dotfiles directory is not a git repository"
        return 1
    fi
    
    return 0
}

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

dotfiles_integration() {
    log "Integrating router configs into dotfiles..."
    
    if [[ ! -f "$SCRIPT_DIR/zephyrus-integration.sh" ]]; then
        error "zephyrus-integration.sh not found"
        return 1
    fi
    
    if [[ ! -d "$SCRIPT_DIR/generated-configs" ]]; then
        error "Generated configs not found. Run config generation first."
        return 1
    fi
    
    cd "$DOTFILES_DIR"
    
    # Check for uncommitted changes (modified or untracked files)
    if ! git diff --quiet || [[ -n $(git ls-files --others --exclude-standard) ]]; then
        log "Found uncommitted changes in dotfiles"
        
        # Show current status
        echo "Current git status:"
        git status --short
        echo
        
        read -p "Add all changes and commit? [y/N]: " commit_confirm
        
        if [[ "$commit_confirm" =~ ^[Yy]$ ]]; then
            # Add all untracked files that might be router-related
            if [[ -f "flake.nix.backup" ]]; then
                git add flake.nix.backup
            fi
            if [[ -f "scripts/bash/router-deploy.sh" ]]; then
                git add scripts/bash/router-deploy.sh
            fi
            
            # Commit all staged changes
            git commit -m "Add router VM configuration (pre-integration)" || true
            log "Committed existing changes"
        else
            error "Please handle uncommitted changes manually first"
            read -p "Press Enter to continue..."
            return 1
        fi
    fi
    
    cd "$SPLIX_DIR"
    ./scripts/zephyrus-integration.sh
    
    log "Adding files to git..."
    cd "$DOTFILES_DIR"
    
    if [[ -d "modules/router-generated" ]]; then
        git add modules/router-generated/
        log "Added router-generated module to git"
    fi
    
    if git diff --cached --quiet flake.nix 2>/dev/null || git diff --staged --quiet flake.nix 2>/dev/null; then
        log "No flake.nix changes to add"
    else
        git add flake.nix
        log "Added flake.nix changes to git"
    fi
    
    # Commit the integration changes
    if ! git diff --cached --quiet; then
        log "Committing router integration..."
        git commit -m "Integrate router VM configuration from splix
    
- Added router-generated module
- Updated flake.nix for router support
- Ready for VM testing"
        log "Router integration committed (not pushed)"
    else
        log "No changes to commit"
    fi
    
    log "Dotfiles integration complete"
    log "Changes committed locally - push manually when ready"
    
    read -p "Press Enter to continue..."
}

vm_testing() {
    log "Testing router VM with safe networking..."

    # Build VM using your proven working approach
    log "Building router VM..."
    cleanup_existing_vms
    cd "$SPLIX_DIR"
    if ! nix build .#router-vm-qcow --print-build-logs; then
        error "Router VM build failed"
        return 1
    fi

    # Deploy using your proven virt-install pattern (from success guide)
    log "Deploying router VM for testing..."
    readonly VM_NAME="router-vm"
    readonly SOURCE_IMAGE="$SPLIX_DIR/result/nixos.qcow2"
    readonly TARGET_IMAGE="/var/lib/libvirt/images/$VM_NAME.qcow2"

    # Clean up existing VM
    sudo virsh --connect qemu:///system destroy "$VM_NAME" 2>/dev/null || true
    sudo virsh --connect qemu:///system undefine "$VM_NAME" --nvram 2>/dev/null || true

    # Copy VM image (same as your working approach)
    sudo cp "$SOURCE_IMAGE" "$TARGET_IMAGE"
    if id "libvirt-qemu" >/dev/null 2>&1; then
        sudo chown libvirt-qemu:kvm "$TARGET_IMAGE"
    else
        sudo chmod 644 "$TARGET_IMAGE"
    fi

    # Deploy with your proven virt-install pattern (TEST MODE)
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
        --network network=default,model=virtio \
        --noautoconsole \
        --import

    # Wait and connect (same as your success guide)
    log "Waiting for VM to boot..."
    sleep 30

    if sudo virsh --connect qemu:///system list | grep -q "$VM_NAME.*running"; then
        log "✅ Router VM started successfully!"
        log "Connecting to console (exit with Ctrl+])..."
        sudo virsh --connect qemu:///system console "$VM_NAME"
    else
        error "VM failed to start"
    fi
}

deploy_host_config() {
    echo "================================================================"
    echo "                 !!!  POINT OF NO RETURN  !!!"
    echo "================================================================"
    echo "This will:"
    echo "  - Build your zephyrus config with VFIO passthrough"
    echo "  - Bind WiFi card to VFIO driver"
    echo "  - REQUIRE REBOOT to take effect"
    echo "  - Host will lose WiFi until router VM starts"
    echo
    echo "Make sure you have:"
    echo "  ✓ Physical access to the machine"
    echo "  ✓ Tested emergency recovery"
    echo "  ✓ Backup network access method"
    echo
    read -p "Are you SURE you want to proceed? Type "yes" to continue: " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        log "Deployment cancelled"
        read -p "Press Enter to continue..."
        return 1
    fi
    
    log "Checking dotfiles integration..."
    if [[ ! -f "$DOTFILES_DIR/modules/router-generated/host-passthrough.nix" ]]; then
        error "Router module not found in dotfiles. Run option 3 first."
        read -p "Press Enter to continue..."
        return 1
    fi
    
    log "Committing changes in dotfiles..."
    cd "$DOTFILES_DIR"
    git add modules/router-generated/host-passthrough.nix flake.nix
    git commit -m "Apply router VFIO passthrough configuration" || true
    
    echo
    echo "================================================================"
    echo "                    MANUAL DEPLOYMENT STEP"
    echo "================================================================"
    echo "Run the following commands to deploy:"
    echo
    echo "cd ~/dotfiles"
    echo "./scripts/bash/nixbuild.sh"
    echo
    echo "After the build completes successfully, reboot your system."
    echo "Then return to this TUI and use Option 6 to start the router VM."
    echo "================================================================"
    
    read -p "Press Enter when you have completed the deployment..."
}

start_router_vm() {
    log "Starting router VM with WiFi passthrough..."

   # # Verify VFIO first
    if [[ ! -f "$SPLIX_DIR/hardware-results.env" ]]; then
        error "Run hardware detection first"
        return 1
    fi

    source "$SPLIX_DIR/hardware-results.env"
# Check VFIO infrastructure is ready
#if ! lsmod | grep -q vfio_pci; then
#    error "VFIO modules not loaded. Run 'Deploy Host Config' first and reboot"
#    return 1
#fi

local current_driver=$(lspci -nnk -s "00:14.3" | grep "Kernel driver in use:" | awk '{print $5}' || echo "none")
log "WiFi card current driver: $current_driver (libvirt will handle VFIO binding automatically)"
    # EXACT SAME BUILD AND DEPLOY as test mode
    log "Building router VM..."
    cd "$SPLIX_DIR"
    cleanup_existing_vms
    if ! nix build .#router-vm-qcow --print-build-logs; then
        error "Router VM build failed"
        return 1
    fi

    readonly VM_NAME="router-vm"
    readonly SOURCE_IMAGE="$SPLIX_DIR/result/nixos.qcow2"
    readonly TARGET_IMAGE="/var/lib/libvirt/images/$VM_NAME.qcow2"

    # Same cleanup and copy
    sudo virsh --connect qemu:///system destroy "$VM_NAME" 2>/dev/null || true
    sudo virsh --connect qemu:///system undefine "$VM_NAME" --nvram 2>/dev/null || true
    sudo cp "$SOURCE_IMAGE" "$TARGET_IMAGE"
    if id "libvirt-qemu" >/dev/null 2>&1; then
        sudo chown libvirt-qemu:kvm "$TARGET_IMAGE"
    fi

    # SAME virt-install but with passthrough (PASSTHROUGH MODE)
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
        --hostdev 00:14.3 \
        --network bridge=virbr0,model=virtio \
        --noautoconsole \
        --import

    log "Waiting for VM to boot with passthrough..."
    sleep 30

    if sudo virsh --connect qemu:///system list | grep -q "$VM_NAME.*running"; then
        log "✅ Router VM started with WiFi passthrough!"
        log "Connect with: sudo virsh --connect qemu:///system console $VM_NAME"
        log "In VM, check: lspci -nnk | grep -i network"
    else
        error "VM failed to start with passthrough"
    fi

    read -p "Press Enter to continue..."
}

show_status() {
    echo "================================================================"
    echo "                    System Status"
    echo "================================================================"
    echo
    
    echo "=== Hardware Detection ==="
    if [[ -f "$SPLIX_DIR/hardware-results.env" ]]; then
        source "$SPLIX_DIR/hardware-results.env"
        echo "Compatibility Score: ${COMPATIBILITY_SCORE:-Unknown}/10"
        echo "WiFi Interface: ${PRIMARY_INTERFACE:-Unknown}"
        echo "PCI Device: ${PRIMARY_ID:-Unknown}"
    else
        echo "[FAIL] Hardware detection not run"
    fi
    echo
    
    echo "=== Generated Configs ==="
    if [[ -d "$SPLIX_DIR/scripts/generated-configs" ]]; then
        echo "[OK] Configs generated ($(ls "$SPLIX_DIR/scripts/generated-configs" | wc -l) files)"
    else
        echo "[FAIL] Configs not generated"
    fi
    echo
    
    echo "=== Dotfiles Integration ==="
    if [[ -d "$DOTFILES_DIR/modules/router-generated" ]]; then
        echo "[OK] Router module integrated"
        cd "$DOTFILES_DIR"
        if git diff --cached --quiet 2>/dev/null; then
            echo "   No staged changes"
        else
            echo "   Files staged for commit"
        fi
    else
        echo "[FAIL] Not integrated with dotfiles"
    fi
    echo
    
    echo "=== VFIO Status ==="
    if lsmod | grep -q vfio_pci; then
        echo "[OK] VFIO modules loaded"
        lspci -nnk | grep -A3 -i network | head -10
    else
        echo "[FAIL] VFIO not active"
    fi
    echo
    
    echo "=== VM Status ==="
    if command -v virsh >/dev/null 2>&1; then
        sudo virsh list --all | grep -E "(router-vm|State)" || echo "No router VM found"
    else
        echo "[FAIL] Libvirt not available"
    fi
    
    read -p "Press Enter to continue..."
}

connect_to_router() {
    log "Connecting to router VM console..."
    
    if ! sudo virsh list | grep -q "router-vm"; then
        error "Router VM is not running. Start it first with option 6."
        read -p "Press Enter to continue..."
        return 1
    fi
    
    log "Use Ctrl+] to exit console"
    sleep 2
    
    sudo virsh console router-vm
    
    read -p "Press Enter to continue..."
}

emergency_recovery() {
    log "=== EMERGENCY NETWORK RECOVERY ==="

    # Load hardware info with fallback
    if [[ -f "$SPLIX_DIR/hardware-results.env" ]]; then
        source "$SPLIX_DIR/hardware-results.env"
        # Use the actual variable names from your hardware detection
        PCI_SLOT="${PRIMARY_PCI_SLOT:-00:14.3}"
        DEVICE_ID="${DEVICE_ID:-8086:a370}"
        log "Target device: $PCI_SLOT ($DEVICE_ID)"
    else
        log "No hardware info found - using detection"
        PCI_SLOT="00:14.3"
        DEVICE_ID="8086:a370"
    fi

    # Step 1: Force stop ALL VMs
    log "Stopping all VMs..."
    for vm in router-vm router-vm-test router-vm-passthrough splix-minimal-vm; do
        sudo virsh --connect qemu:///system destroy "$vm" 2>/dev/null || true
        sudo virsh --connect qemu:///system undefine "$vm" --nvram 2>/dev/null || true
    done

    # Step 2: Aggressively unbind from VFIO
    log "Unbinding WiFi card from VFIO..."
    echo "$PCI_SLOT" | sudo tee /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true

    # Step 3: Remove device ID override
    log "Removing VFIO device ID override..."
    echo "$DEVICE_ID" | sudo tee /sys/bus/pci/drivers/vfio-pci/remove_id 2>/dev/null || true

    # Step 4: Force load iwlwifi
    log "Loading iwlwifi driver..."
    sudo modprobe iwlwifi

    # Step 5: Force bind to iwlwifi
    log "Binding WiFi card to iwlwifi..."
    echo "$PCI_SLOT" | sudo tee /sys/bus/pci/drivers/iwlwifi/bind 2>/dev/null || true

    # Step 6: Restart NetworkManager with retry
    log "Restarting NetworkManager..."
    sudo systemctl restart NetworkManager
    sleep 5
    sudo systemctl restart NetworkManager

    # Step 7: Test connectivity with extended retry
    log "Testing connectivity..."
    for i in {1..30}; do
        if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
            log "✅ Network connectivity restored! (attempt $i)"
            read -p "Press Enter to continue..."
            return 0
        fi
        sleep 2
    done

    log "❌ Automatic recovery failed. Manual steps:"
    log "1. sudo systemctl restart NetworkManager"
    log "2. nmcli device connect wlo1"
    log "3. Check: lspci -nnk | grep -A3 'Network controller'"
    read -p "Press Enter to continue..."
}

cleanup_everything() {
    echo "================================================================"
    echo "                  Clean Up Everything"
    echo "================================================================"
    echo
    echo "This will:"
    echo "  - Remove router-generated module from dotfiles"
    echo "  - Restore original flake.nix from backup"
    echo "  - Clean up git staging"
    echo "  - Optionally rebuild system without router"
    echo
    read -p "Continue with cleanup? [y/N]: " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log "Starting cleanup..."
        
        cd "$DOTFILES_DIR"
        
        if [[ -d "modules/router-generated" ]]; then
            log "Removing router-generated module..."
            rm -rf modules/router-generated
            git rm -rf modules/router-generated 2>/dev/null || true
        fi
        
        if [[ -f "flake.nix.backup" ]]; then
            log "Restoring original flake.nix..."
            mv flake.nix.backup flake.nix
            git add flake.nix
        fi
        
        git reset HEAD 2>/dev/null || true
        
        log "Cleanup complete"
        echo
        read -p "Rebuild system without router configs? [y/N]: " rebuild_confirm
        
        if [[ "$rebuild_confirm" =~ ^[Yy]$ ]]; then
            log "Rebuilding system..."
            sudo nixos-rebuild switch --flake .#zephyrus
        fi
    else
        log "Cleanup cancelled"
    fi
    
    read -p "Press Enter to continue..."
}

guided_setup() {
    echo "================================================================"
    echo "                 Full Guided Setup"
    echo "================================================================"
    echo
    echo "This will run steps 1-4 automatically:"
    echo "  1. Hardware Detection"
    echo "  2. Config Generation" 
    echo "  3. Dotfiles Integration (with git add)"
    echo "  4. VM Testing"
    echo
    read -p "Proceed with guided setup? [y/N]: " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        hardware_detection && \
        config_generation && \
        dotfiles_integration && \
        vm_testing
        
        echo
        echo "================================================================"
        echo "  Guided setup complete! Ready for deployment."
        echo "  Use option 5 to deploy (point of no return)"
        echo "================================================================"
    fi
    
    read -p "Press Enter to continue..."
}

main() {
    if ! check_prerequisites; then
        exit 1
    fi
    
    while true; do
        show_menu
        read -p "Choose option: " choice
        
        case "$choice" in
            1) hardware_detection ;;
            2) config_generation ;;
            3) dotfiles_integration ;;
            4) vm_testing ;;
            5) deploy_host_config ;;
            6) start_router_vm ;;
            7) show_status ;;
            8) connect_to_router ;;
            9) emergency_recovery ;;
            10) cleanup_everything ;;
            12) guided_setup ;;
            q|Q) log "Goodbye!"; exit 0 ;;
            *) error "Invalid option: $choice" ;;
        esac
    done
}

main "$@"
