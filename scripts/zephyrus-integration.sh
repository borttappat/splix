#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="${HOME}/dotfiles"
SPLIX_DIR="${PWD}"

copy_to_dotfiles() {
    mkdir -p "${DOTFILES_DIR}/modules/router-generated"
    cp "${SPLIX_DIR}/scripts/generated-configs/"*.nix "${DOTFILES_DIR}/modules/router-generated/"
    
    cd "${DOTFILES_DIR}"
    git add modules/router-generated/
    git add flake.nix
}

integrate_flake() {
    cd "${DOTFILES_DIR}"
    
    if ! grep -q "router-generated" flake.nix; then
        sed -i '/zephyrus = {/,/};/{ /modules = \[/,/\];/{ /\];/i\            ./modules/router-generated/host-passthrough.nix
        }}' flake.nix
    fi
}

copy_to_dotfiles
integrate_flake
EOF
