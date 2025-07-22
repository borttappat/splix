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
    
    if [[ ! -f "$SCRIPT_DIR/router-vm-test.sh" ]]; then
        error "router-vm-test.sh not found"
        return 1
    fi
    
    cd "$SPLIX_DIR"
    
    log "Building router VM..."
    if ! nix build .#nixosConfigurations.router-vm.config.system.build.vm --impure; then
        error "VM build failed. Check flake.nix integration."
        return 1
    fi
    
    if [[ ! -L "./result" ]] || [[ ! -x "./result/bin/run-router-vm-vm" ]]; then
        error "VM build produced invalid result"
        return 1
    fi
    
    log "Starting VM test..."
    cd "$SPLIX_DIR"
    ./scripts/router-vm-test.sh
    
    read -p "Press Enter to continue..."
}

deploy_host_config() {
    echo "================================================================"
    echo "                 !!!  POINT OF NO RETURN  !!!"
    echo "================================================================"
    echo
    echo "This will:"
    echo "  - Apply VFIO passthrough configuration"
    echo "  - Bind WiFi card to VFIO driver"
    echo "  - REQUIRE REBOOT to take effect"
    echo "  - Host will lose WiFi until router VM starts"
    echo
    echo "Make sure you have:"
    echo "  ✓ Physical access to the machine"
    echo "  ✓ Tested emergency recovery"
    echo "  ✓ Backup network access method"
    echo
    read -p "Are you SURE you want to proceed? Type 'yes' to continue: " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        log "Deployment cancelled"
        return 0
    fi
    
    log "Creating system restore point..."
    sudo nix-env -p /nix/var/nix/profiles/system --list-generations | tail -1 > "$SPLIX_DIR/.last-known-good"
    
    cd "$DOTFILES_DIR"
    log "Building and applying host configuration..."
    
    if ! sudo nixos-rebuild switch --flake .#zephyrus; then
        error "Host configuration failed to apply"
        return 1
    fi
    
    log "Host configuration applied successfully"
    log "REBOOT REQUIRED to activate VFIO passthrough"
    echo
    read -p "Reboot now? [y/N]: " reboot_confirm
    
    if [[ "$reboot_confirm" =~ ^[Yy]$ ]]; then
        sudo reboot
    else
        log "Reboot when ready. After reboot, use option 6 to start router VM."
    fi
}

start_router_vm() {
    log "Starting router VM with WiFi passthrough..."
    
    if [[ ! -f "$SCRIPT_DIR/deploy-router.sh" ]]; then
        error "deploy-router.sh not found"
        return 1
    fi
    
    cd "$SPLIX_DIR"
    sudo ./scripts/deploy-router.sh deploy
    
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
        echo "WiFi Interface: ${BEST_INTERFACE:-Unknown}"
        echo "PCI Device: ${DEVICE_ID:-Unknown}"
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
    log "Running emergency network recovery..."
    
    if [[ -f "$SPLIX_DIR/scripts/generated-configs/emergency-recovery.sh" ]]; then
        sudo "$SPLIX_DIR/scripts/generated-configs/emergency-recovery.sh"
    else
        log "Generated recovery script not found, using fallback..."
        
        log "Stopping any running VMs..."
        sudo virsh destroy router-vm 2>/dev/null || true
        
        log "Unloading VFIO modules..."
        sudo modprobe -r vfio_pci vfio_iommu_type1 vfio 2>/dev/null || true
        
        log "Loading WiFi driver..."
        sudo modprobe iwlwifi 2>/dev/null || true
        
        log "Restarting NetworkManager..."
        sudo systemctl restart NetworkManager
        
        sleep 5
        if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
            log "Network connectivity restored!"
        else
            error "Network recovery may have failed. Try rebooting."
        fi
    fi
    
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
