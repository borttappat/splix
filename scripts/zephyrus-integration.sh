#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SPLIX_DIR="$(dirname "$SCRIPT_DIR")"
readonly DOTFILES_DIR="${HOME}/dotfiles"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

[[ -d "$DOTFILES_DIR" ]] || error "Dotfiles not found at $DOTFILES_DIR"
[[ -f "$SPLIX_DIR/hardware-results.env" ]] || error "Run hardware detection first"
[[ -d "$SPLIX_DIR/scripts/generated-configs" ]] || error "Run config generation first"

mkdir -p "$DOTFILES_DIR/modules/router-generated"

cp "$SPLIX_DIR/modules/router-vm-config.nix" "$DOTFILES_DIR/modules/router-generated/vm.nix"
cp "$SPLIX_DIR/scripts/generated-configs/host-passthrough.nix" "$DOTFILES_DIR/modules/router-generated/host.nix"

if ! grep -q "router-host.*=" "$DOTFILES_DIR/flake.nix"; then
    cp "$DOTFILES_DIR/flake.nix" "$DOTFILES_DIR/flake.nix.backup"
    
    awk '
    /nixosConfigurations = {/ { in_configs = 1 }
    in_configs && /^[[:space:]]*};[[:space:]]*$/ && !added {
        print "        router-host = nixpkgs.lib.nixosSystem {"
        print "          system = \"x86_64-linux\";"
        print "          modules = ["
        print "            { nixpkgs.config.allowUnfree = true; }"
        print "            { nixpkgs.overlays = [ overlay-unstable ]; }"
        print "            /etc/nixos/hardware-configuration.nix"
        print "            ./modules/router-generated/host.nix"
        print "          ];"
        print "        };"
        print "        router-vm = nixpkgs.lib.nixosSystem {"
        print "          system = \"x86_64-linux\";"
        print "          modules = ["
        print "            { nixpkgs.config.allowUnfree = true; }"
        print "            { nixpkgs.overlays = [ overlay-unstable ]; }"
        print "            ./modules/router-generated/vm.nix"
        print "            { fileSystems.\"/\".device = \"/dev/vda\"; fileSystems.\"/\".fsType = \"ext4\"; boot.loader.grub.device = \"/dev/vda\"; system.stateVersion = \"25.05\"; }"
        print "          ];"
        print "        };"
        added = 1
    }
    { print }
    ' "$DOTFILES_DIR/flake.nix" > "$DOTFILES_DIR/flake.nix.tmp"
    
    mv "$DOTFILES_DIR/flake.nix.tmp" "$DOTFILES_DIR/flake.nix"
fi

cd "$DOTFILES_DIR"
git add modules/router-generated/
git add flake.nix

log "Integration complete - router configs staged in git"
