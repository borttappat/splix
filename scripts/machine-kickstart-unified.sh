#!/run/current-system/sw/bin/bash
set -euo pipefail

# Splix Unified Machine Kickstart Script
# Fresh machine → Single consolidated module with all specializations
# Replaces 3 separate imports with 1 unified import

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
readonly DOTFILES_DIR="${HOME}/dotfiles"
readonly TEMPLATES_DIR="$PROJECT_DIR/templates"
readonly GENERATED_DIR="$PROJECT_DIR/generated-unified"

log() { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }
success() { echo "[SUCCESS] $*"; }

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Unified machine kickstart - Generates SINGLE consolidated module

This script creates ONE module file that contains:
- VFIO passthrough configuration (always enabled)  
- Router specialization (WiFi passthrough + router VM)
- Maximalism specialization (router + pentest VMs)
- Base mode tools and status commands

GOAL: Replace your current 3 imports:
  imports = [
    ./router-generated/zephyrus-passthrough.nix     # ❌ Remove
    ./router-generated/zephyrus-router.nix          # ❌ Remove  
    ./router-generated/zephyrus-maximalism.nix      # ❌ Remove
  ];

WITH single import:
  imports = [
    ./router-generated/zephyrus-consolidated.nix    # ✅ Single file
  ];

OPTIONS:
    --machine-name NAME     Machine name (default: auto-detect)
    --vm-name NAME          Pentest VM name (default: pentest-vm-auto)
    --workspace NUM         Target workspace (default: 2)
    --force-rebuild        Force rebuild even if VMs exist
    --dry-run             Generate config but don't integrate with dotfiles
    --help                Show this help

EXAMPLES:
    # Generate unified config for current machine
    $0

    # Custom machine setup with unified config
    $0 --machine-name zenbook --vm-name kali-vm

    # Generate config without dotfiles integration (preview)
    $0 --dry-run

OUTPUT:
    - Single consolidated module: generated-unified/modules/[machine]-consolidated.nix
    - Integration guide: generated-unified/setup-examples/[machine]-unified-setup.md
    - Ready for nixbuild with --impure flag
EOF
}

# Default values
MACHINE_NAME=""
VM_NAME="pentest-vm-auto"
WORKSPACE_NUMBER="2"
FORCE_REBUILD=false
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --machine-name)
            MACHINE_NAME="$2"
            shift 2
            ;;
        --vm-name)
            VM_NAME="$2"
            shift 2
            ;;
        --workspace)
            WORKSPACE_NUMBER="$2"
            shift 2
            ;;
        --force-rebuild)
            FORCE_REBUILD=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1. Use --help for usage."
            ;;
    esac
done

check_prerequisites() {
    log "=== UNIFIED KICKSTART: Prerequisites ==="
    
    if [[ $EUID -eq 0 ]]; then
        error "Don't run this as root"
    fi
    
    if [[ ! -d "$DOTFILES_DIR" ]]; then
        error "Dotfiles directory not found: $DOTFILES_DIR"
    fi
    
    # Check required commands
    local missing=()
    for cmd in nix virsh virt-install openssl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing dependencies: ${missing[*]}"
    fi
    
    log "Prerequisites verified"
}

auto_detect_machine() {
    log "=== Auto-detecting Machine Configuration ==="
    
    if [[ -z "$MACHINE_NAME" ]]; then
        local vendor=$(hostnamectl | grep -i "Hardware Vendor" | awk -F': ' '{print $2}' | xargs || echo "")
        local model=$(hostnamectl | grep -i "Hardware Model" | awk -F': ' '{print $2}' | xargs || echo "")
        local hostname=$(hostname)
        
        if [[ -n "$model" ]]; then
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
        else
            MACHINE_NAME="$hostname"
        fi
    fi
    
    log "Machine: $MACHINE_NAME"
}

step1_hardware_detection() {
    log "=== STEP 1: Hardware Detection ==="
    
    cd "$PROJECT_DIR"
    
    if ! ./scripts/hardware-identify.sh; then
        error "Hardware detection failed"
    fi
    
    if [[ -f "hardware-results.env" ]]; then
        source hardware-results.env
        log "Hardware Score: ${COMPATIBILITY_SCORE:-0}/10"
        
        if [[ ${COMPATIBILITY_SCORE:-0} -lt 5 ]]; then
            error "Hardware compatibility too low (${COMPATIBILITY_SCORE:-0}/10)"
        fi
    else
        error "Hardware detection did not produce results"
    fi
    
    success "Hardware detection completed"
}

step2_ensure_vms_built() {
    log "=== STEP 2: Ensure VMs are Built ==="
    
    cd "$PROJECT_DIR"
    
    # Check router VM
    if [[ "$FORCE_REBUILD" == false ]] && [[ -f "result/nixos.qcow2" ]]; then
        log "Router VM already built - using existing"
        ROUTER_SIZE=$(du -h result/nixos.qcow2 | cut -f1)
    else
        log "Building router VM using generate-all-configs.sh..."
        if ! ./scripts/generate-all-configs.sh; then
            error "Router VM build failed"
        fi
        ROUTER_SIZE=$(du -h result/nixos.qcow2 | cut -f1)
    fi
    
    # Check pentest VM
    local pentest_vm_result="$PROJECT_DIR/pentest-vm/result/nixos.qcow2"
    if [[ "$FORCE_REBUILD" == false ]] && [[ -f "$pentest_vm_result" ]]; then
        log "Pentest VM already built - using existing"
        PENTEST_SIZE=$(du -h "$pentest_vm_result" | cut -f1)
    else
        log "Building pentest VM..."
        if ! nix build .#pentest-vm-full --print-build-logs --impure -o pentest-vm/result; then
            error "Pentest VM build failed"
        fi
        PENTEST_SIZE=$(du -h "$pentest_vm_result" | cut -f1)
    fi
    
    success "VMs verified: Router (${ROUTER_SIZE}), Pentest (${PENTEST_SIZE})"
}

step3_generate_consolidated_config() {
    log "=== STEP 3: Generate Consolidated Configuration ==="
    
    cd "$PROJECT_DIR"
    
    # Source hardware detection results
    source "$PROJECT_DIR/hardware-results.env" 2>/dev/null || error "Hardware detection results missing"
    
    local output_file="$GENERATED_DIR/modules/${MACHINE_NAME}-consolidated.nix"
    local template_file="$TEMPLATES_DIR/consolidated-machine.nix.template"
    local vm_image_path="/home/traum/splix/pentest-vm/result/nixos.qcow2"
    
    log "Generating consolidated configuration..."
    log "  Machine: $MACHINE_NAME"
    log "  VM Name: $VM_NAME"
    log "  VM Image: $vm_image_path"
    log "  Workspace: $WORKSPACE_NUMBER"
    log "  Hardware: $PRIMARY_ID ($PRIMARY_PCI)"
    log "  Driver: $PRIMARY_DRIVER"
    
    if [[ ! -f "$template_file" ]]; then
        error "Consolidated template not found: $template_file"
    fi
    
    mkdir -p "$(dirname "$output_file")"
    
    # Process template with variable substitution
    sed \
        -e "s|{{MACHINE_NAME}}|$MACHINE_NAME|g" \
        -e "s|{{VM_NAME}}|$VM_NAME|g" \
        -e "s|{{VM_IMAGE_PATH}}|$vm_image_path|g" \
        -e "s|{{WORKSPACE_NUMBER}}|$WORKSPACE_NUMBER|g" \
        -e "s|{{USERNAME}}|$(whoami)|g" \
        -e "s|{{PRIMARY_ID}}|$PRIMARY_ID|g" \
        -e "s|{{PRIMARY_PCI}}|$PRIMARY_PCI|g" \
        -e "s|{{PRIMARY_DRIVER}}|$PRIMARY_DRIVER|g" \
        "$template_file" > "$output_file"
    
    log ""
    success "✅ CONSOLIDATED CONFIGURATION GENERATED!"
    log "======================================"
    log ""
    log "Generated single module: $output_file"
    log ""
    log "This ONE module contains:"
    log "  ✅ VFIO/Hardware passthrough (always enabled)"
    log "  ✅ Router specialization (router VM + networking)" 
    log "  ✅ Maximalism specialization (router + pentest VMs)"
    log "  ✅ Status commands for all modes"
    log ""
    log "🎯 GOAL ACHIEVED: Replace 3 imports with 1!"
    log ""
    log "BEFORE (current setup):"
    log "  imports = ["
    log "    ./router-generated/${MACHINE_NAME}-passthrough.nix"
    log "    ./router-generated/${MACHINE_NAME}-router.nix"
    log "    ./router-generated/${MACHINE_NAME}-maximalism.nix"
    log "  ];"
    log ""
    log "AFTER (unified setup):"
    log "  imports = ["
    log "    ./router-generated/${MACHINE_NAME}-consolidated.nix"
    log "  ];"
    log ""
}

step4_generate_integration_guide() {
    log "=== STEP 4: Generate Integration Guide ==="
    
    local guide_file="$GENERATED_DIR/setup-examples/${MACHINE_NAME}-unified-setup.md"
    local config_file="$GENERATED_DIR/modules/${MACHINE_NAME}-consolidated.nix"
    
    mkdir -p "$(dirname "$guide_file")"
    
    cat > "$guide_file" << GUIDEEOF
# ${MACHINE_NAME^} Unified Configuration Setup

Generated by machine-kickstart-unified.sh on $(date)

## 🎯 Goal: Single Module Import

Replace your current **3 separate imports** with **1 consolidated import**.

### Current Setup (3 files):
\`\`\`nix
# In ~/dotfiles/modules/${MACHINE_NAME}.nix
imports = [
  ./router-generated/${MACHINE_NAME}-passthrough.nix    # VFIO config
  ./router-generated/${MACHINE_NAME}-router.nix         # Router services  
  ./router-generated/${MACHINE_NAME}-maximalism.nix     # Maximalism spec
];
\`\`\`

### New Unified Setup (1 file):
\`\`\`nix
# In ~/dotfiles/modules/${MACHINE_NAME}.nix  
imports = [
  ./router-generated/${MACHINE_NAME}-consolidated.nix   # Everything in one!
];
\`\`\`

## 🚀 Integration Steps

### 1. Backup Current Working Setup
\`\`\`bash
cd ~/dotfiles/modules/router-generated/
cp ${MACHINE_NAME}-passthrough.nix ${MACHINE_NAME}-passthrough.nix.backup
cp ${MACHINE_NAME}-router.nix ${MACHINE_NAME}-router.nix.backup  
cp ${MACHINE_NAME}-maximalism.nix ${MACHINE_NAME}-maximalism.nix.backup
\`\`\`

### 2. Copy Consolidated Module
\`\`\`bash
cp $config_file ~/dotfiles/modules/router-generated/
\`\`\`

### 3. Update Your Machine Configuration
Edit \`~/dotfiles/modules/${MACHINE_NAME}.nix\`:

\`\`\`nix
{ config, pkgs, lib, ... }:
{
  imports = [
    # Replace these 3 lines:
    # ./router-generated/${MACHINE_NAME}-passthrough.nix
    # ./router-generated/${MACHINE_NAME}-router.nix  
    # ./router-generated/${MACHINE_NAME}-maximalism.nix
    
    # With this 1 line:
    ./router-generated/${MACHINE_NAME}-consolidated.nix
  ];

  # ... rest of your configuration unchanged
}
\`\`\`

### 4. Test the New Configuration
\`\`\`bash
# Build with your existing nixbuild script (uses --impure)
cd ~/dotfiles
./scripts/bash/nixbuild.sh

# Router and Maximalism modes use 'boot' (requires reboot to activate)
# Base mode uses 'switch' (instant activation, no reboot needed)

# The script automatically detects your current mode and uses the correct strategy
\`\`\`

### 5. Verify All Modes Work
\`\`\`bash
# Check status in any mode
vm-status

# Mode-specific status commands  
router-status        # Available in router specialization
maximalism-status    # Available in maximalism specialization
\`\`\`

## 🔧 What's Included in Consolidated Module

### VFIO Configuration (Always Active)
- Intel IOMMU enabled
- VFIO PCI passthrough for {{PRIMARY_ID}} 
- libvirtd with QEMU/KVM support
- OVMF UEFI firmware

### Router Specialization
- WiFi driver blacklisting ({{PRIMARY_DRIVER}})
- Bridge networking (virbr1-virbr5)
- Router VM autostart service
- Firewall rules for VM networking
- Router status command

### Maximalism Specialization  
- Inherits all router configuration
- Pentest VM ({{VM_NAME}}) autostart service
- Workspace {{WORKSPACE_NUMBER}} assignment
- Both VMs start in sequence: Router → Pentest
- Combined status command

### Base Mode
- VM management tools always available
- Status commands for mode detection
- Easy switching between specializations

## 🔄 Rollback Plan

If anything goes wrong:

\`\`\`bash
cd ~/dotfiles/modules/router-generated/
mv ${MACHINE_NAME}-passthrough.nix.backup ${MACHINE_NAME}-passthrough.nix
mv ${MACHINE_NAME}-router.nix.backup ${MACHINE_NAME}-router.nix  
mv ${MACHINE_NAME}-maximalism.nix.backup ${MACHINE_NAME}-maximalism.nix
rm ${MACHINE_NAME}-consolidated.nix

# Restore 3-import setup in ${MACHINE_NAME}.nix
# Build with: cd ~/dotfiles && ./scripts/bash/nixbuild.sh
\`\`\`

## 🎉 Benefits of Unified Approach

- ✅ **Single Import**: Only one file to manage
- ✅ **Template-Based**: Easy to replicate on new machines  
- ✅ **Self-Contained**: All specializations in one module
- ✅ **Backwards Compatible**: Same functionality, cleaner structure
- ✅ **Future-Ready**: Easy to add communications VM later

## 📋 Next Steps

1. Test the unified configuration thoroughly
2. If satisfied, remove the old 3-file backup
3. Use this approach for new machine setups
4. Consider extending for communications VM (future enhancement)

---

Generated by machine-kickstart-unified.sh - Splix VM Automation
Hardware: {{PRIMARY_INTERFACE}} ({{PRIMARY_ID}}) on {{PRIMARY_PCI}}
VM: {{VM_NAME}} assigned to workspace {{WORKSPACE_NUMBER}}
GUIDEEOF

    success "Integration guide created: $guide_file"
}

step5_integrate_dotfiles() {
    if [[ "$DRY_RUN" == true ]]; then
        log "=== STEP 5: Skipping Dotfiles Integration (--dry-run) ==="
        log "Generated files are in: $GENERATED_DIR"
        log "Review and manually copy when ready"
        return
    fi
    
    log "=== STEP 5: Integrate with Dotfiles ==="
    
    local source_file="$GENERATED_DIR/modules/${MACHINE_NAME}-consolidated.nix"
    local target_dir="$DOTFILES_DIR/modules/router-generated"
    local target_file="$target_dir/${MACHINE_NAME}-consolidated.nix"
    
    if [[ ! -f "$source_file" ]]; then
        error "Generated consolidated config not found: $source_file"
    fi
    
    # Backup if exists
    if [[ -f "$target_file" ]]; then
        local backup_file="${target_file}.backup.$(date +%Y%m%d-%H%M%S)"
        log "Backing up existing file: $(basename "$backup_file")"
        cp "$target_file" "$backup_file"
    fi
    
    log "Copying consolidated module to dotfiles..."
    mkdir -p "$target_dir"
    cp "$source_file" "$target_file"
    
    success "Consolidated module integrated: $target_file"
}

show_completion_summary() {
    log ""
    success "🎉 UNIFIED MACHINE KICKSTART COMPLETED! 🎉"
    log "=========================================="
    log ""
    log "Configuration:"
    log "  Machine: $MACHINE_NAME"
    log "  VM Name: $VM_NAME"
    log "  Workspace: $WORKSPACE_NUMBER"
    if [[ "$DRY_RUN" == true ]]; then
        log "  Mode: DRY RUN (not integrated)"
    else
        log "  Mode: Integrated with dotfiles"
    fi
    log ""
    
    log "🎯 ACHIEVEMENT: Single Unified Module Created!"
    log ""
    log "Generated Files:"
    log "  📄 Consolidated: $GENERATED_DIR/modules/${MACHINE_NAME}-consolidated.nix"
    log "  📋 Guide: $GENERATED_DIR/setup-examples/${MACHINE_NAME}-unified-setup.md"
    log ""
    
    if [[ "$DRY_RUN" == false ]]; then
        log "✅ Integrated: ~/dotfiles/modules/router-generated/${MACHINE_NAME}-consolidated.nix"
        log ""
    fi
    
    log "Next Steps:"
    if [[ "$DRY_RUN" == true ]]; then
        log "1. Review generated files in: $GENERATED_DIR"
        log "2. Run without --dry-run to integrate with dotfiles"
    else
        log "1. Edit ~/dotfiles/modules/${MACHINE_NAME}.nix"
        log "2. Replace 3 imports with: ./router-generated/${MACHINE_NAME}-consolidated.nix"
        log "3. Build: cd ~/dotfiles && ./scripts/bash/nixbuild.sh"
        log "4. Test: vm-status, router-status, maximalism-status"
    fi
    log ""
    
    log "Complete setup guide:"
    log "  cat $GENERATED_DIR/setup-examples/${MACHINE_NAME}-unified-setup.md"
    log ""
    
    success "Your unified VM automation setup is ready! 🚀"
}

main() {
    log ""
    log "🚀 SPLIX UNIFIED MACHINE KICKSTART 🚀"
    log "===================================="
    log ""
    log "Goal: Replace 3 separate imports with 1 consolidated module"
    log "Approach: Generate single .nix file with all specializations"
    log ""
    
    check_prerequisites
    auto_detect_machine
    
    log ""
    log "Configuration Summary:"
    log "  Machine: $MACHINE_NAME"
    log "  VM Name: $VM_NAME" 
    log "  Workspace: $WORKSPACE_NUMBER"
    log "  Force Rebuild: $FORCE_REBUILD"
    log "  Dry Run: $DRY_RUN"
    log ""
    
    if [[ "$DRY_RUN" == false ]] && [[ "$FORCE_REBUILD" == false ]]; then
        read -p "Continue with unified setup generation? [Y/n]: " -r
        if [[ $REPLY =~ ^[Nn]$ ]]; then
            log "Setup cancelled by user"
            exit 0
        fi
    fi
    
    step1_hardware_detection
    step2_ensure_vms_built
    step3_generate_consolidated_config
    step4_generate_integration_guide
    step5_integrate_dotfiles
    show_completion_summary
    
    log ""
    success "✅ Unified machine kickstart completed successfully!"
}

main "$@"