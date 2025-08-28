#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
readonly DOTFILES_DIR="$HOME/dotfiles"

log() { echo "[$(date +%H:%M:%S)] $*"; }

integrate_to_dotfiles() {
    if [[ ! -f "$PROJECT_DIR/scripts/generated-configs/specialisation-block.txt" ]]; then
        log "ERROR: Run essential-setup.sh Step 2 first to generate configs"
        exit 1
    fi
    
    # Detect machine name
    local machine_name
    if hostnamectl | grep -qi "zenbook"; then
        machine_name="zenbook"
    elif hostnamectl | grep -qi "zephyrus"; then
        machine_name="zephyrus"
    else
        machine_name="default"
    fi
    
    # Create router-generated directory
    mkdir -p "$DOTFILES_DIR/modules/router-generated"
    
    # Copy machine-specific passthrough config
    cp "$PROJECT_DIR/scripts/generated-configs/${machine_name}-passthrough.nix" \
       "$DOTFILES_DIR/modules/router-generated/"
    
    log "✅ Copied ${machine_name}-passthrough.nix to dotfiles"
    
    # Show specialisation block to insert
    echo
    echo "=========================================="
    echo "INSERT THIS INTO ~/dotfiles/modules/${machine_name}.nix:"
    echo "=========================================="
    cat "$PROJECT_DIR/scripts/generated-configs/specialisation-block.txt"
    echo "=========================================="
    echo
    
    # Git add the generated files
    cd "$DOTFILES_DIR"
    git add "modules/router-generated/${machine_name}-passthrough.nix"
    
    log "✅ Files added to git. Insert the block above, then run: cd ~/dotfiles && nixbuild"
}

integrate_to_dotfiles "$@"
