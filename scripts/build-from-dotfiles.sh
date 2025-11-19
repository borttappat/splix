#!/run/current-system/sw/bin/bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
readonly DOTFILES_DIR="$HOME/dotfiles"

log() { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

check_dependencies() {
    log "Checking dependencies..."
    
    if ! command -v nix >/dev/null 2>&1; then
        error "nix command not found"
    fi
    
    if [[ ! -d "$DOTFILES_DIR" ]]; then
        error "Dotfiles directory not found at $DOTFILES_DIR"
    fi
    
    log "Dependencies verified"
}

build_vm_from_dotfiles() {
    log "=== Building VM from Dotfiles Configuration ==="
    
    cd "$DOTFILES_DIR"
    
    # Build QCOW2 directly from your VM flake configuration  
    log "Building QCOW2 image from your VM flake configuration..."
    
    if ! nix run github:nix-community/nixos-generators -- --format qcow --flake .#VM; then
        error "Failed to build VM from dotfiles flake"
    fi
    
    if [[ -f "nixos.qcow2" ]]; then
        log "VM built successfully: $(du -h nixos.qcow2 | cut -f1)"
        echo "VM image location: $DOTFILES_DIR/nixos.qcow2"
    else
        error "VM image not found after build"
    fi
}

main() {
    log "=== Building Pentesting VM from Your Dotfiles ==="
    
    check_dependencies
    build_vm_from_dotfiles
    
    log ""
    log "🎯 VM built from your complete dotfiles configuration!"
    log "Next: Use deploy-pentest-vm-advanced.sh with -i $DOTFILES_DIR/nixos.qcow2"
}

main "$@"