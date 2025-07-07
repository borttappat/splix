#!/run/current-system/sw/bin/bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

get_real_user() {
    echo "${SUDO_USER:-${USER:-$(whoami)}}"
}

detect_target() {
    local current_host=$(hostnamectl | grep -i "Hardware Vendor" | awk -F': ' '{print $2}' | xargs)
    local current_model=$(hostnamectl | grep -i "Hardware Model" | awk -F': ' '{print $2}' | xargs)
    
    if echo "$current_host" | grep -q "QEMU"; then
        echo "VM-test"
    else
        echo "router-host"
    fi
}

build_router_system() {
    local target="$1"
    local user="$2"
    
    log "Building router system for target: $target, user: $user"
    
    export USER="$user"
    export SUDO_USER="$user"
    
    cd "$PROJECT_ROOT"
    
    case "$target" in
        "router-host")
            log "Building host configuration with passthrough..."
            sudo nixos-rebuild switch --impure --show-trace --option warn-dirty false --flake ".#router-host"
            ;;
        "VM-test")
            log "Building router VM for testing..."
            nix --experimental-features "nix-command flakes" build --impure ".#nixosConfigurations.router-vm.config.system.build.vm"
            ;;
        *)
            error "Unknown target: $target"
            ;;
    esac
}

main() {
    local real_user=$(get_real_user)
    local target=$(detect_target)
    
    log "VM Router build script"
    log "Real user: $real_user"
    log "Target: $target"
    
    case "${1:-auto}" in
        "host")
            build_router_system "router-host" "$real_user"
            ;;
        "vm")
            build_router_system "VM-test" "$real_user"
            ;;
        "auto")
            build_router_system "$target" "$real_user"
            ;;
        *)
            echo "Usage: $0 [host|vm|auto]"
            echo "  host - Build host configuration with passthrough"
            echo "  vm   - Build router VM for testing"
            echo "  auto - Auto-detect target based on hardware"
            ;;
    esac
}

main "$@"
