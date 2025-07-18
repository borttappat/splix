#!/usr/bin/env bash
# Router VM Setup TUI - Interactive guided setup
# Run from splix directory

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SPLIX_DIR="$(dirname "$SCRIPT_DIR")"
readonly DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly NC='\033[0m' # No Color

# Status tracking
declare -A STEP_STATUS
STEP_STATUS[hardware]="❌"
STEP_STATUS[configs]="❌"
STEP_STATUS[integration]="❌"
STEP_STATUS[vm_test]="❌"
STEP_STATUS[deployment]="❌"

log() { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warning() { echo -e "${YELLOW}⚠${NC} $*"; }
error() { echo -e "${RED}✗${NC} $*"; }
info() { echo -e "${BLUE}ℹ${NC} $*"; }

clear_screen() {
    clear
    echo -e "${PURPLE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║${NC}               ${WHITE}NixOS VM Router Setup - TUI${NC}                 ${PURPLE}║${NC}"
    echo -e "${PURPLE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
}

check_status() {
    # Check hardware detection
    if [[ -f "$SPLIX_DIR/hardware-results.env" ]]; then
        STEP_STATUS[hardware]="✅"
    fi
    
    # Check config generation
    if [[ -d "$SPLIX_DIR/scripts/generated-configs" ]] && [[ -f "$SPLIX_DIR/modules/router-vm-config.nix" ]]; then
        STEP_STATUS[configs]="✅"
    fi
    
    # Check dotfiles integration
    if [[ -d "$DOTFILES_DIR/modules/router-generated" ]] && grep -q "router-vm.*=" "$DOTFILES_DIR/flake.nix" 2>/dev/null; then
        STEP_STATUS[integration]="✅"
    fi
    
    # Check VM build
    if [[ -L "$DOTFILES_DIR/result" ]] && [[ -f "$DOTFILES_DIR/result/bin/run-router-vm-vm" ]]; then
        STEP_STATUS[vm_test]="✅"
    fi
    
    # Check deployment (VFIO active)
    if lspci -nnk | grep -A3 -i network | grep -q "vfio-pci"; then
        STEP_STATUS[deployment]="✅"
    fi
}

show_status() {
    check_status
    
    echo -e "${WHITE}Current Setup Status:${NC}"
    echo "  1. Hardware Detection    ${STEP_STATUS[hardware]}"
    echo "  2. Config Generation     ${STEP_STATUS[configs]}"
    echo "  3. Dotfiles Integration  ${STEP_STATUS[integration]}"
    echo "  4. VM Testing           ${STEP_STATUS[vm_test]}"
    echo "  5. Host Deployment      ${STEP_STATUS[deployment]}"
    echo
}

show_menu() {
    clear_screen
    show_status
    
    echo -e "${WHITE}Choose an option:${NC}"
    echo
    echo -e "${CYAN}Setup Workflow:${NC}"
    echo "  [1] 🔍 Hardware Detection & Validation"
    echo "  [2] ⚙️  Generate Router Configurations"
    echo "  [3] 🔗 Integrate with Dotfiles"
    echo "  [4] 🧪 Test Router VM"
    echo "  [5] 🚀 Deploy Host Configuration (Point of No Return)"
    echo "  [6] 📱 Start Router VM (After Reboot)"
    echo
    echo -e "${CYAN}Management:${NC}"
    echo "  [7] 📊 Show Detailed Status"
    echo "  [8] 🔌 Connect to Router VM Console"
    echo "  [9] 🆘 Emergency Recovery"
    echo "  [10] 🧹 Clean Up Everything"
    echo
    echo -e "${CYAN}Advanced:${NC}"
    echo "  [11] 🔧 Fix Polluted Dotfiles"
    echo "  [12] 📋 Run Full Guided Setup"
    echo
    echo "  [q] Quit"
    echo
    echo -n "Select option: "
}

hardware_detection() {
    clear_screen
    echo -e "${WHITE}Step 1: Hardware Detection & Validation${NC}"
    echo "========================================"
    echo
    info "This will detect your network hardware and check VFIO compatibility"
    echo
    read -p "Press Enter to continue..."
    
    log "Running hardware detection..."
    if ./scripts/hardware-identify.sh; then
        success "Hardware detection completed"
        
        # Show results
        echo
        if [[ -f "hardware-results.env" ]]; then
            source hardware-results.env
            echo -e "${WHITE}Results:${NC}"
            echo "  Interface: $PRIMARY_INTERFACE"
            echo "  PCI Slot: $PRIMARY_PCI_SLOT"
            echo "  Device ID: $PRIMARY_ID"
            echo "  Compatibility Score: $COMPATIBILITY_SCORE/10"
            echo
            
            if [[ $COMPATIBILITY_SCORE -ge 8 ]]; then
                success "Excellent compatibility - ready for passthrough!"
            elif [[ $COMPATIBILITY_SCORE -ge 5 ]]; then
                warning "Good compatibility - should work with some limitations"
            else
                error "Poor compatibility - not recommended for passthrough"
            fi
        fi
    else
        error "Hardware detection failed"
    fi
    
    echo
    read -p "Press Enter to return to menu..."
}

generate_configs() {
    clear_screen
    echo -e "${WHITE}Step 2: Generate Router Configurations${NC}"
    echo "====================================="
    echo
    
    if [[ "${STEP_STATUS[hardware]}" != "✅" ]]; then
        error "Please run hardware detection first!"
        read -p "Press Enter to return to menu..."
        return
    fi
    
    info "This will generate hardware-specific router configurations"
    echo
    read -p "Press Enter to continue..."
    
    log "Generating router configurations..."
    if ./scripts/vm-setup-generator.sh; then
        success "Router configurations generated"
        echo
        info "Generated files:"
        echo "  - Host VFIO configuration"
        echo "  - Router VM NixOS configuration" 
        echo "  - Libvirt XML definitions"
        echo "  - Emergency recovery scripts"
    else
        error "Configuration generation failed"
    fi
    
    echo
    read -p "Press Enter to return to menu..."
}

integrate_dotfiles() {
    clear_screen
    echo -e "${WHITE}Step 3: Integrate with Dotfiles${NC}"
    echo "==============================="
    echo
    
    if [[ "${STEP_STATUS[configs]}" != "✅" ]]; then
        error "Please generate configurations first!"
        read -p "Press Enter to return to menu..."
        return
    fi
    
    info "This will temporarily add router configs to your dotfiles"
    warning "This is reversible - use cleanup option to remove"
    echo
    read -p "Continue? (y/n): " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        return
    fi
    
    log "Integrating with dotfiles..."
    if ./scripts/router-integrate.sh; then
        success "Integration completed"
        echo
        info "Router configurations added to dotfiles as:"
        echo "  - router-host (host configuration)"
        echo "  - router-vm (VM configuration)"
    else
        error "Integration failed"
    fi
    
    echo
    read -p "Press Enter to return to menu..."
}

test_vm() {
    clear_screen
    echo -e "${WHITE}Step 4: Test Router VM${NC}"
    echo "====================="
    echo
    
    if [[ "${STEP_STATUS[integration]}" != "✅" ]]; then
        error "Please integrate with dotfiles first!"
        read -p "Press Enter to return to menu..."
        return
    fi
    
    info "This will build and test the router VM with safe QEMU networking"
    echo
    read -p "Continue? (y/n): " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        return
    fi
    
    log "Building router VM..."
    cd "$DOTFILES_DIR"
    
    if nix build .#nixosConfigurations.router-vm.config.system.build.vm --impure; then
        success "Router VM built successfully"
        echo
        info "VM is ready for testing"
        echo
        read -p "Start VM now for testing? (y/n): " start_test
        
        if [[ "$start_test" =~ ^[Yy]$ ]]; then
            echo
            info "Starting router VM test..."
            info "Login: admin / admin"
            info "Test: ping 8.8.8.8"
            info "Exit: Ctrl+A, then X"
            echo
            read -p "Press Enter to start VM..."
            
            cd "$SPLIX_DIR"
            ./scripts/router-vm-test.sh
        fi
    else
        error "VM build failed"
    fi
    
    echo
    read -p "Press Enter to return to menu..."
}

deploy_host() {
    clear_screen
    echo -e "${RED}Step 5: Deploy Host Configuration${NC}"
    echo -e "${RED}=================================${NC}"
    echo
    warning "⚠️  POINT OF NO RETURN ⚠️"
    echo
    error "This will:"
    echo "  - Apply VFIO passthrough configuration"
    echo "  - Reboot the system"
    echo "  - Host will LOSE WIFI until router VM starts"
    echo
    info "Prerequisites:"
    echo "  ✓ Router VM tested and working"
    echo "  ✓ Emergency recovery tested"
    echo "  ✓ Physical access to machine"
    echo
    
    if [[ "${STEP_STATUS[vm_test]}" != "✅" ]]; then
        error "Please test the router VM first!"
        read -p "Press Enter to return to menu..."
        return
    fi
    
    echo -e "${RED}Are you absolutely sure? Type 'DEPLOY' to continue:${NC}"
    read -r confirmation
    
    if [[ "$confirmation" != "DEPLOY" ]]; then
        info "Deployment cancelled"
        read -p "Press Enter to return to menu..."
        return
    fi
    
    log "Deploying host configuration..."
    if ./scripts/deploy-router.sh passthrough; then
        success "Host configuration applied"
        info "System will reboot automatically"
    else
        error "Deployment failed"
    fi
    
    echo
    read -p "Press Enter to return to menu..."
}

start_router() {
    clear_screen
    echo -e "${WHITE}Step 6: Start Router VM${NC}"
    echo "======================="
    echo
    
    info "This starts the router VM with WiFi passthrough"
    warning "Host should have VFIO active after reboot"
    echo
    
    # Check VFIO status
    if lspci -nnk | grep -A3 -i network | grep -q "vfio-pci"; then
        success "VFIO is active - ready to start router VM"
    else
        warning "VFIO not detected - router may not work properly"
        echo
        read -p "Continue anyway? (y/n): " continue_anyway
        if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
            return
        fi
    fi
    
    echo
    read -p "Start router VM? (y/n): " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log "Starting router VM..."
        if ./scripts/deploy-router.sh start; then
            success "Router VM started"
            echo
            info "Connect with: ./scripts/router-vm-test.sh"
        else
            error "Failed to start router VM"
        fi
    fi
    
    echo
    read -p "Press Enter to return to menu..."
}

show_detailed_status() {
    clear_screen
    echo -e "${WHITE}Detailed System Status${NC}"
    echo "====================="
    echo
    
    # Hardware status
    echo -e "${CYAN}Hardware Status:${NC}"
    if [[ -f "hardware-results.env" ]]; then
        source hardware-results.env
        echo "  Interface: $PRIMARY_INTERFACE"
        echo "  PCI Slot: $PRIMARY_PCI_SLOT"
        echo "  Compatibility: $COMPATIBILITY_SCORE/10"
    else
        echo "  No hardware detection results"
    fi
    echo
    
    # VFIO status
    echo -e "${CYAN}VFIO Status:${NC}"
    lspci -nnk | grep -A3 -i network | head -10
    echo
    
    # VM status
    echo -e "${CYAN}VM Status:${NC}"
    sudo virsh list --all | grep router-vm || echo "  No router VM found"
    echo
    
    # Integration status
    echo -e "${CYAN}Integration Status:${NC}"
    if [[ -d "$DOTFILES_DIR/modules/router-generated" ]]; then
        echo "  ✅ Integrated with dotfiles"
    else
        echo "  ❌ Not integrated with dotfiles"
    fi
    
    if grep -q "router-vm.*=" "$DOTFILES_DIR/flake.nix" 2>/dev/null; then
        echo "  ✅ Router configs in flake.nix"
    else
        echo "  ❌ Router configs not in flake.nix"
    fi
    
    echo
    read -p "Press Enter to return to menu..."
}

connect_console() {
    clear_screen
    echo -e "${WHITE}Connect to Router VM Console${NC}"
    echo "============================"
    echo
    
    info "This will connect to the router VM console"
    echo
    
    # Check if VM is running
    if sudo virsh list | grep -q router-vm; then
        success "Router VM is running"
        echo
        info "Login: admin / admin"
        info "Exit: Ctrl+] or type 'exit'"
        echo
        read -p "Connect now? (y/n): " confirm
        
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            ./scripts/router-vm-test.sh
        fi
    else
        warning "Router VM is not running"
        echo
        read -p "Start router VM first? (y/n): " start_first
        
        if [[ "$start_first" =~ ^[Yy]$ ]]; then
            if sudo virsh start router-vm 2>/dev/null; then
                success "Router VM started"
                sleep 3
                ./scripts/router-vm-test.sh
            else
                error "Failed to start router VM"
            fi
        fi
    fi
    
    echo
    read -p "Press Enter to return to menu..."
}

emergency_recovery() {
    clear_screen
    echo -e "${RED}Emergency Network Recovery${NC}"
    echo -e "${RED}=========================${NC}"
    echo
    
    warning "This will attempt to restore network connectivity"
    info "Actions:"
    echo "  - Stop router VM"
    echo "  - Unbind WiFi from VFIO"
    echo "  - Restore original driver"
    echo "  - Restart NetworkManager"
    echo
    
    read -p "Run emergency recovery? (y/n): " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log "Running emergency recovery..."
        
        if [[ -f "scripts/generated-configs/emergency-recovery.sh" ]]; then
            sudo ./scripts/generated-configs/emergency-recovery.sh
            success "Emergency recovery completed"
        else
            warning "No emergency script found, running manual recovery..."
            sudo virsh destroy router-vm 2>/dev/null || true
            sudo systemctl restart NetworkManager
            success "Manual recovery completed"
        fi
        
        info "Test network connectivity now"
    fi
    
    echo
    read -p "Press Enter to return to menu..."
}

cleanup_everything() {
    clear_screen
    echo -e "${YELLOW}Clean Up Everything${NC}"
    echo -e "${YELLOW}==================${NC}"
    echo
    
    warning "This will remove ALL router configurations"
    info "Actions:"
    echo "  - Remove router configs from dotfiles"
    echo "  - Stop and remove router VM"
    echo "  - Restore clean dotfiles state"
    echo
    error "This is irreversible!"
    echo
    
    read -p "Type 'CLEANUP' to confirm: " confirmation
    
    if [[ "$confirmation" == "CLEANUP" ]]; then
        log "Cleaning up router configuration..."
        
        if ./scripts/router-clean.sh; then
            success "Router cleanup completed"
            echo
            info "Your dotfiles are now clean"
            info "Run 'cd $DOTFILES_DIR && nixbuild' to apply"
        else
            error "Cleanup failed"
        fi
    else
        info "Cleanup cancelled"
    fi
    
    echo
    read -p "Press Enter to return to menu..."
}

fix_polluted_dotfiles() {
    clear_screen
    echo -e "${YELLOW}Fix Polluted Dotfiles${NC}"
    echo -e "${YELLOW}====================${NC}"
    echo
    
    info "This removes router pollution from existing machine configs"
    warning "Use this if router configs were added to all your machines"
    echo
    
    read -p "Fix dotfiles flake.nix? (y/n): " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log "Fixing polluted dotfiles..."
        
        if ./scripts/fix-flake-router.sh; then
            success "Dotfiles fixed"
            echo
            info "Backup saved as flake.nix.pre-fix-backup"
            info "Run 'cd $DOTFILES_DIR && nixbuild' to apply"
        else
            error "Fix failed"
        fi
    fi
    
    echo
    read -p "Press Enter to return to menu..."
}

guided_setup() {
    clear_screen
    echo -e "${WHITE}Full Guided Setup${NC}"
    echo "================="
    echo
    
    info "This will run through the complete setup process"
    warning "Each step will ask for confirmation"
    echo
    
    read -p "Start guided setup? (y/n): " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        return
    fi
    
    # Run through all steps
    if [[ "${STEP_STATUS[hardware]}" != "✅" ]]; then
        hardware_detection
    fi
    
    if [[ "${STEP_STATUS[configs]}" != "✅" ]]; then
        generate_configs
    fi
    
    if [[ "${STEP_STATUS[integration]}" != "✅" ]]; then
        integrate_dotfiles
    fi
    
    if [[ "${STEP_STATUS[vm_test]}" != "✅" ]]; then
        test_vm
    fi
    
    # Stop here - deployment requires manual confirmation
    clear_screen
    echo -e "${GREEN}Guided Setup Complete!${NC}"
    echo "====================="
    echo
    success "Ready for deployment"
    info "Next step: Choose option 5 to deploy (Point of No Return)"
    echo
    read -p "Press Enter to return to menu..."
}

main() {
    # Change to splix directory
    cd "$SPLIX_DIR"
    
    while true; do
        show_menu
        read -r choice
        
        case "$choice" in
            1) hardware_detection ;;
            2) generate_configs ;;
            3) integrate_dotfiles ;;
            4) test_vm ;;
            5) deploy_host ;;
            6) start_router ;;
            7) show_detailed_status ;;
            8) connect_console ;;
            9) emergency_recovery ;;
            10) cleanup_everything ;;
            11) fix_polluted_dotfiles ;;
            12) guided_setup ;;
            q|Q) break ;;
            *) 
                echo "Invalid option"
                sleep 1
                ;;
        esac
    done
    
    clear_screen
    echo -e "${GREEN}Thanks for using Router VM Setup TUI!${NC}"
    echo
}

main "$@"
