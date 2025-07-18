#!/usr/bin/env bash
# Router Cleanup Script - Removes all router configurations from dotfiles
# Run from splix repo to clean up dotfiles

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SPLIX_DIR="$(dirname "$SCRIPT_DIR")"
readonly DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

cleanup_router_modules() {
    log "Removing router modules from dotfiles..."
    
    if [[ -d "$DOTFILES_DIR/modules/router-generated" ]]; then
        rm -rf "$DOTFILES_DIR/modules/router-generated"
        log "✓ Removed dotfiles/modules/router-generated/"
    fi
    
    if [[ -f "$DOTFILES_DIR/modules/router.nix" ]]; then
        rm "$DOTFILES_DIR/modules/router.nix"
        log "✓ Removed dotfiles/modules/router.nix"
    fi
    
    if [[ -d "$DOTFILES_DIR/modules/router" ]]; then
        rm -rf "$DOTFILES_DIR/modules/router"
        log "✓ Removed dotfiles/modules/router/"
    fi
}

cleanup_flake_configs() {
    log "Removing router configurations from dotfiles flake.nix..."
    
    # Create backup
    cp "$DOTFILES_DIR/flake.nix" "$DOTFILES_DIR/flake.nix.backup"
    
    # Remove generated router configurations using awk for better handling
    awk '
    BEGIN { in_router_section = 0; skip_line = 0 }
    /# Generated Router Configurations/ { in_router_section = 1; skip_line = 1; next }
    in_router_section && /router-host.*=/ { skip_line = 1; brace_count = 0 }
    in_router_section && /router-vm.*=/ { skip_line = 1; brace_count = 0 }
    skip_line && /{/ { brace_count++ }
    skip_line && /}/ { 
        brace_count--
        if (brace_count <= 0) {
            skip_line = 0
            if (in_router_section) in_router_section = 0
            next
        }
    }
    !skip_line { print }
    ' "$DOTFILES_DIR/flake.nix" > "$DOTFILES_DIR/flake.nix.tmp"
    
    mv "$DOTFILES_DIR/flake.nix.tmp" "$DOTFILES_DIR/flake.nix"
    
    log "✓ Router configurations removed from dotfiles flake.nix"
    log "  Backup saved as flake.nix.backup"
}

cleanup_scripts() {
    log "Removing router scripts from dotfiles..."
    
    if [[ -f "$DOTFILES_DIR/scripts/bash/router-deploy.sh" ]]; then
        rm "$DOTFILES_DIR/scripts/bash/router-deploy.sh"
        log "✓ Removed dotfiles router-deploy.sh"
    fi
}

cleanup_vms() {
    log "Cleaning up router VMs..."
    
    # Stop and undefine router VM if it exists
    if sudo virsh list --all 2>/dev/null | grep -q router-vm; then
        sudo virsh destroy router-vm 2>/dev/null || true
        sudo virsh undefine router-vm 2>/dev/null || true
        log "✓ Router VM stopped and undefined"
    fi
}

main() {
    log "Starting router cleanup from splix..."
    log "Cleaning dotfiles at: $DOTFILES_DIR"
    
    if [[ ! -d "$DOTFILES_DIR" ]]; then
        log "Dotfiles directory not found at $DOTFILES_DIR"
        exit 0
    fi
    
    cleanup_router_modules
    cleanup_flake_configs
    cleanup_scripts
    cleanup_vms
    
    log "=== Router Cleanup Complete ==="
    log ""
    log "All router configurations removed from dotfiles"
    log "Your existing machine configs are untouched"
    log "Run 'cd $DOTFILES_DIR && nixbuild' to apply clean configuration"
    log ""
    log "To re-enable router: ~/splix/scripts/router-integrate.sh"
}

main "$@"
