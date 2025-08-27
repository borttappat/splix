#!/usr/bin/env bash
# Integrate generated router configs into dotfiles repo

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
readonly DOTFILES_DIR="${HOME}/dotfiles"
readonly CONFIG_DIR="$SCRIPT_DIR/generated-configs"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# Detect machine type using same logic as nixbuild.sh
detect_machine_type() {
    local current_host=$(hostnamectl | grep -i "Hardware Vendor" | awk -F': ' '{print $2}' | xargs)
    local current_model=$(hostnamectl | grep -i "Hardware Model" | awk -F': ' '{print $2}' | xargs)
    
    # For Razer-hosts
    if echo "$current_host" | grep -q "Razer"; then
        echo "razer"
    # For Virtual machines
    elif echo "$current_host" | grep -q "QEMU"; then
        echo "VM"
    # For ASUS Zenbook specifically
    elif echo "$current_model" | grep -qi "zenbook"; then
        echo "zenbook"
    # For ASUS Zephyrus specifically
    elif echo "$current_model" | grep -qi "zephyrus"; then
        echo "zephyrus"
    # For other Asus-hosts
    elif echo "$current_host" | grep -q "ASUS"; then
        echo "asus"
    # For Schenker machines
    elif echo "$current_host" | grep -q "Schenker"; then
        echo "xmg"
    # Fallback
    else
        echo "default"
    fi
}

# Check prerequisites
if [[ ! -d "$DOTFILES_DIR" ]]; then
    log "ERROR: Dotfiles directory not found at $DOTFILES_DIR"
    exit 1
fi

if [[ ! -d "$DOTFILES_DIR/.git" ]]; then
    log "ERROR: Dotfiles is not a git repository"
    exit 1
fi

if [[ ! -d "$CONFIG_DIR" ]]; then
    log "ERROR: Generated configs not found. Run vm-setup-generator.sh first"
    exit 1
fi

# Detect machine type
MACHINE_TYPE=$(detect_machine_type)
log "=== Integrating Router Configs for $MACHINE_TYPE ==="

# Create router-generated directory
mkdir -p "$DOTFILES_DIR/modules/router-generated"

# Set machine-specific filename
PASSTHROUGH_FILE="$MACHINE_TYPE-passthrough.nix"

# Copy generated host config with machine-specific name
log "1. Copying host passthrough config as $PASSTHROUGH_FILE..."
cp "$CONFIG_DIR/host-passthrough.nix" "$DOTFILES_DIR/modules/router-generated/$PASSTHROUGH_FILE"

# Copy router VM config
log "2. Copying router VM config..."
cp "$PROJECT_DIR/modules/router-vm-config.nix" "$DOTFILES_DIR/modules/router-generated/vm.nix"

# Update emergency recovery path in host config to point to splix
log "3. Updating emergency recovery path..."
sed -i "s|ExecStart = \".*emergency-recovery.sh\"|ExecStart = \"$CONFIG_DIR/emergency-recovery.sh\"|" \
    "$DOTFILES_DIR/modules/router-generated/$PASSTHROUGH_FILE"

# Check if the machine config imports the router-generated config
log "4. Checking $MACHINE_TYPE.nix configuration..."
MACHINE_CONFIG="$DOTFILES_DIR/modules/$MACHINE_TYPE.nix"

if [[ -f "$MACHINE_CONFIG" ]]; then
    if grep -q "router-generated" "$MACHINE_CONFIG"; then
        log "✓ $MACHINE_TYPE.nix already imports router-generated configs"
        # Check if it imports the correct filename
        if grep -q "router-generated/$PASSTHROUGH_FILE" "$MACHINE_CONFIG"; then
            log "✓ Imports correct passthrough file: $PASSTHROUGH_FILE"
        elif grep -q "router-generated/host-passthrough.nix" "$MACHINE_CONFIG"; then
            log "⚠ Updating import path to use machine-specific filename..."
            sed -i "s|router-generated/host-passthrough.nix|router-generated/$PASSTHROUGH_FILE|g" "$MACHINE_CONFIG"
            log "✓ Updated import path in $MACHINE_TYPE.nix"
        else
            log "ℹ Found router-generated import but may need to verify path"
        fi
    else
        log "WARNING: $MACHINE_TYPE.nix may need to import ./router-generated/$PASSTHROUGH_FILE"
        log "Check the specialisation.router.configuration section"
    fi
else
    log "WARNING: Machine config $MACHINE_CONFIG not found"
fi

# Stage files for git
log "5. Adding files to git..."
cd "$DOTFILES_DIR"

git add "modules/router-generated/$PASSTHROUGH_FILE"
git add "modules/router-generated/vm.nix"

# Add machine config if it was modified
if [[ -f "$MACHINE_CONFIG" ]]; then
    git add "modules/$MACHINE_TYPE.nix"
fi

# Check staged changes
if ! git diff --cached --quiet; then
    log "✓ Files staged for commit:"
    git diff --cached --name-only
else
    log "✓ Router configs staged for commit"
fi

log ""
log "=== Integration Complete for $MACHINE_TYPE ==="
log ""
log "Files integrated:"
log "  • $DOTFILES_DIR/modules/router-generated/$PASSTHROUGH_FILE"
log "  • $DOTFILES_DIR/modules/router-generated/vm.nix"
if [[ -f "$MACHINE_CONFIG" ]]; then
    log "  • Updated: $DOTFILES_DIR/modules/$MACHINE_TYPE.nix (if needed)"
fi
log ""
log "Emergency recovery available at:"
log "  • $CONFIG_DIR/emergency-recovery.sh"
log ""
log "Next steps:"
log "  1. Test build:     cd ~/dotfiles && nix build .#nixosConfigurations.$MACHINE_TYPE.config.system.build.toplevel --dry-run"
log "  2. Test VM first:  $CONFIG_DIR/test-router-vm.sh"  
log "  3. Deploy host:    cd ~/dotfiles && ./scripts/bash/nixbuild.sh router-boot"
log "  4. After reboot:   $CONFIG_DIR/deploy-router-vm.sh"
