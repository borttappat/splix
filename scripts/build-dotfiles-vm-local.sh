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

build_vm_locally() {
    log "=== Building VM Locally from Dotfiles ==="
    
    cd "$DOTFILES_DIR"
    
    # Try different approaches
    log "Attempting local build methods..."
    
    # Method 1: Build VM using your flake directly 
    log "Method 1: Building VM system closure..."
    if nix build .#nixosConfigurations.VM.config.system.build.vm --print-build-logs; then
        log "✅ VM system built successfully"
        if [[ -f "result/bin/run-nixos-vm" ]]; then
            log "VM runner available at: $DOTFILES_DIR/result/bin/run-nixos-vm"
            return 0
        fi
    fi
    
    # Method 2: Build disk image using nixos-rebuild
    log "Method 2: Building disk image..."
    if nix build .#nixosConfigurations.VM.config.system.build.diskoImage 2>/dev/null; then
        log "✅ Disk image built"
        return 0
    fi
    
    # Method 3: Try building with local nixos-generators if available
    if command -v nixos-generate >/dev/null 2>&1; then
        log "Method 3: Using local nixos-generators..."
        if nixos-generate --format qcow --flake .#VM; then
            log "✅ QCOW2 generated locally"
            return 0
        fi
    fi
    
    # Method 4: Create a temporary flake with nixos-generators
    log "Method 4: Creating local nixos-generators flake..."
    local temp_dir=$(mktemp -d)
    trap "rm -rf $temp_dir" EXIT
    
    cat > "$temp_dir/flake.nix" << 'FLAKEEOF'
{
  description = "Local VM build";
  
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    dotfiles.url = "path:DOTFILES_PATH";
    nixos-generators.url = "github:nix-community/nixos-generators";
    nixos-generators.inputs.nixpkgs.follows = "nixpkgs";
  };
  
  outputs = { nixpkgs, dotfiles, nixos-generators, ... }: {
    packages.x86_64-linux.vm = nixos-generators.nixosGenerate {
      system = "x86_64-linux";
      modules = dotfiles.nixosConfigurations.VM.modules;
      format = "qcow";
    };
  };
}
FLAKEEOF
    
    sed -i "s|DOTFILES_PATH|$DOTFILES_DIR|g" "$temp_dir/flake.nix"
    
    cd "$temp_dir"
    if nix build .#vm --print-build-logs; then
        log "✅ VM built using temporary flake"
        cp result/nixos.qcow2 "$DOTFILES_DIR/nixos.qcow2"
        log "VM image copied to: $DOTFILES_DIR/nixos.qcow2"
        return 0
    fi
    
    error "All build methods failed"
}

main() {
    log "=== Building Pentesting VM Locally ==="
    
    check_dependencies
    build_vm_locally
    
    log ""
    log "🎯 VM built successfully from your dotfiles!"
    log "Use with: ./scripts/deploy-pentest-vm-advanced.sh -i ~/dotfiles/nixos.qcow2"
}

main "$@"