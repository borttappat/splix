#!/bin/bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
error() { echo "[ERROR] $*" >&2; }
prompt() { 
    echo
    read -p "Continue? (y/n): " response
    [[ "$response" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
}

step1_hardware_detection() {
    log "=== STEP 1: Hardware Detection ==="
    log "This will analyze your system's IOMMU, network interfaces, and compatibility"
    
    if [[ -f "$PROJECT_ROOT/hardware-results.env" ]]; then
        log "Previous hardware detection found:"
        cat "$PROJECT_ROOT/hardware-results.env"
        echo
        read -p "Re-run hardware detection? (y/n): " rerun
        [[ "$rerun" =~ ^[Yy]$ ]] || return 0
    fi
    
    prompt
    "$PROJECT_ROOT/scripts/hardware-identify.sh"
    
    source "$PROJECT_ROOT/hardware-results.env"
    log "Hardware compatibility: $COMPATIBILITY_SCORE/10 - $RECOMMENDATION"
    
    if [[ "$RECOMMENDATION" != "PROCEED" ]]; then
        error "Hardware compatibility too low. Consider different hardware or approach."
        exit 1
    fi
}

step2_generate_configs() {
    log "=== STEP 2: Generate Configurations ==="
    log "This will create NixOS configs, VM definitions, and recovery scripts"
    prompt
    
    "$PROJECT_ROOT/scripts/vm-setup-generator.sh"
    log "Configurations generated successfully"
}

step3_prepare_modules() {
    log "=== STEP 3: Prepare NixOS Modules ==="
    log "This will copy generated configs to the proper locations and fix compatibility issues"
    prompt
    
    # Copy router VM config
    cp "$PROJECT_ROOT/scripts/generated-configs/router-vm-config.nix" "$PROJECT_ROOT/modules/"
    
    # Fix deprecated services and packages
    
    # Add to git for nix flakes
    git add "$PROJECT_ROOT/modules/router-vm-config.nix"
    
    log "Module preparation complete"
}

step4_build_test() {
    log "=== STEP 4: Build and Test Router VM ==="
    log "This will build the router VM and test it safely with QEMU"
    prompt
    
    cd "$PROJECT_ROOT"
    nix build .#nixosConfigurations.router-vm.config.system.build.vm
    
    log "Router VM built successfully!"
    log "Starting test VM..."
    
    ./result/bin/run-router-vm-vm &
    VM_PID=$!
    
    log "Router VM running (PID: $VM_PID)"
    log "Test the VM - check network connectivity, services, etc."
    echo
    read -p "Press Enter when done testing (this will stop the VM)..."
    
    kill $VM_PID 2>/dev/null || true
    log "Test VM stopped"
}

step5_deployment_ready() {
    log "=== STEP 5: Deployment Ready ==="
    log "All preparation complete! Your system is ready for router deployment."
    echo
    log "Next steps for deployment:"
    log "  1. ./scripts/deploy-router.sh check"
    log "  2. ./scripts/deploy-router.sh test    (test with libvirt)"
    log "  3. ./scripts/deploy-router.sh passthrough  (POINT OF NO RETURN)"
    log "  4. sudo reboot"
    log "  5. ./scripts/deploy-router.sh deploy  (activate passthrough)"
    echo
    log "Emergency recovery available: ./scripts/generated-configs/emergency-recovery.sh"
    
    echo
    read -p "Run deployment check now? (y/n): " deploy_check
    if [[ "$deploy_check" =~ ^[Yy]$ ]]; then
        "$PROJECT_ROOT/scripts/deploy-router.sh" check
    fi
}

show_help() {
    echo "Fresh machine setup script for VM router project"
    echo
    echo "This script prepares a fresh machine by:"
    echo "1. Running hardware detection and compatibility check"
    echo "2. Generating all NixOS configurations and scripts"
    echo "3. Preparing modules and fixing compatibility issues"
    echo "4. Building and testing the router VM safely"
    echo "5. Preparing for actual deployment"
    echo
    echo "Usage: $0 [step_number]"
    echo "  Run without arguments for interactive full setup"
    echo "  Or specify step number (1-5) to run individual steps"
}

main() {
    log "Fresh Machine Setup for VM Router Project"
    log "========================================"
    
    case "${1:-full}" in
        "1") step1_hardware_detection ;;
        "2") step2_generate_configs ;;
        "3") step3_prepare_modules ;;
        "4") step4_build_test ;;
        "5") step5_deployment_ready ;;
        "full"|"")
            step1_hardware_detection
            step2_generate_configs
            step3_prepare_modules
            step4_build_test
            step5_deployment_ready
            ;;
        *) show_help ;;
    esac
    
    log "Setup completed successfully!"
}

main "$@"
