#!/usr/bin/env bash
# Fix Flake - Remove router pollution from existing machine configs
# Run from splix repo to fix dotfiles

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SPLIX_DIR="$(dirname "$SCRIPT_DIR")"
readonly DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

fix_flake() {
    log "Fixing dotfiles flake.nix - removing router pollution from machine configs..."
    
    if [[ ! -f "$DOTFILES_DIR/flake.nix" ]]; then
        log "No flake.nix found at $DOTFILES_DIR/flake.nix"
        return
    fi
    
    # Create backup
    cp "$DOTFILES_DIR/flake.nix" "$DOTFILES_DIR/flake.nix.pre-fix-backup"
    
    # Remove router module imports from ALL machine configs
    sed '/\.\/modules\/router\.nix/d' "$DOTFILES_DIR/flake.nix" > "$DOTFILES_DIR/flake.nix.tmp1"
    
    # Remove router configuration blocks from ALL machine configs
    # This removes the entire router = { ... }; blocks
    awk '
    /router = {/ { 
        in_router = 1
        brace_count = 1
        next
    }
    in_router && /{/ { brace_count++ }
    in_router && /}/ { 
        brace_count--
        if (brace_count == 0) {
            in_router = 0
            next
        }
    }
    !in_router { print }
    ' "$DOTFILES_DIR/flake.nix.tmp1" > "$DOTFILES_DIR/flake.nix.tmp2"
    
    # Clean up empty lines and formatting
    sed '/^[[:space:]]*$/N;/^\n$/d' "$DOTFILES_DIR/flake.nix.tmp2" > "$DOTFILES_DIR/flake.nix"
    
    rm -f "$DOTFILES_DIR/flake.nix.tmp1" "$DOTFILES_DIR/flake.nix.tmp2"
    
    log "✓ Dotfiles flake.nix fixed - router removed from all machine configs"
    log "  Backup saved as flake.nix.pre-fix-backup"
}

main() {
    log "Fixing router pollution in dotfiles flake.nix..."
    log "Target dotfiles: $DOTFILES_DIR"
    
    if [[ ! -d "$DOTFILES_DIR" ]]; then
        log "Dotfiles directory not found at $DOTFILES_DIR"
        exit 1
    fi
    
    fix_flake
    
    log "=== Flake Fix Complete ==="
    log ""
    log "Your machine configs are now clean:"
    log "  - armVM, default, zephyrus, asus, razer, xmg, VM"
    log "  - No router configuration affecting existing machines"
    log ""
    log "Next steps:"
    log "1. cd $DOTFILES_DIR"
    log "2. git add flake.nix && git commit -m 'Remove router pollution from machine configs'"
    log "3. nixbuild  # Apply clean config"
    log "4. ~/splix/scripts/router-integrate.sh  # Add router as separate configs"
}

main "$@"
