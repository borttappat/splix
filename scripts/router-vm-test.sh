#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DOTFILES_DIR="${HOME}/dotfiles"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

if [[ ! -d "$DOTFILES_DIR" ]]; then
    error "Dotfiles directory not found"
fi

cd "$DOTFILES_DIR"

if [[ ! -L "./result" ]] || [[ ! -x "./result/bin/run-router-vm-vm" ]]; then
    log "Building router VM first..."
    if ! nix build .#nixosConfigurations.zephyrus.config.system.build.vm --impure; then
        error "Failed to build router VM"
    fi
fi

log "Starting router VM..."
log "Login: admin / admin"
log "Exit: Ctrl+A, X"
echo

export QEMU_NET_OPTS="netdev=user,id=n1,hostfwd=tcp::2222-:22"
export QEMU_OPTS="-m 2048 -nographic"

./result/bin/run-router-vm-vm
