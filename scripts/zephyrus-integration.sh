#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SPLIX_DIR="$(dirname "$SCRIPT_DIR")"
readonly DOTFILES_DIR="${HOME}/dotfiles"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

if [[ ! -d "$SPLIX_DIR/scripts/generated-configs" ]]; then
    error "Generated configs not found. Run vm-setup-generator.sh first."
fi

if [[ ! -d "$DOTFILES_DIR" ]]; then
    error "Dotfiles directory not found at $DOTFILES_DIR"
fi

log "Creating router-generated module directory..."
mkdir -p "$DOTFILES_DIR/modules/router-generated"

log "Copying generated configs..."
cp "$SPLIX_DIR/scripts/generated-configs/host-passthrough.nix" "$DOTFILES_DIR/modules/router-generated/"
cp "$SPLIX_DIR/modules/router-vm-config.nix" "$DOTFILES_DIR/modules/router-generated/vm.nix"

if [[ ! -f "$DOTFILES_DIR/flake.nix.backup" ]]; then
    log "Creating flake.nix backup..."
    cp "$DOTFILES_DIR/flake.nix" "$DOTFILES_DIR/flake.nix.backup"
fi

log "Checking if router module already integrated..."
if grep -q "router-generated" "$DOTFILES_DIR/flake.nix"; then
    log "Router module already integrated in flake.nix"
else
    log "Adding router module to zephyrus configuration..."
    
    awk '
    /zephyrus = nixpkgs\.lib\.nixosSystem/ { in_zephyrus = 1 }
    in_zephyrus && /modules = \[/ { in_modules = 1 }
    in_modules && /\];/ {
        print "            ./modules/router-generated/host-passthrough.nix"
        in_modules = 0
        in_zephyrus = 0
    }
    { print }
    ' "$DOTFILES_DIR/flake.nix" > "$DOTFILES_DIR/flake.nix.tmp"
    
    mv "$DOTFILES_DIR/flake.nix.tmp" "$DOTFILES_DIR/flake.nix"
fi

log "Integration complete"
log "Router configs added to: $DOTFILES_DIR/modules/router-generated/"
log "Original flake.nix backed up to: flake.nix.backup"
