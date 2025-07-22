#!/usr/bin/env bash
# Simple router VM testing script

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

case "${1:-}" in
    "start"|"")
        echo "Starting router VM for testing..."
        echo "Login: admin / admin"
        echo "Exit: Ctrl+A, X to quit QEMU"
        echo
        cd "$PROJECT_ROOT"
        
        # Check if VM is built
        if [[ ! -f "result/bin/run-router-vm-vm" ]]; then
            echo "Building router VM first..."
            nix build .#nixosConfigurations.router-vm.config.system.build.vm --impure
        fi
        
        # Use proper QEMU options without conflicting serial settings
        QEMU_OPTS="-nographic" ./result/bin/run-router-vm-vm
        ;;
    "build")
        echo "Building router VM..."
        cd "$PROJECT_ROOT"
        nix build .#nixosConfigurations.router-vm.config.system.build.vm --impure
        echo "✓ Router VM built. Start with: $0"
        ;;
    *)
        echo "Usage: $0 [start|build]"
        echo "  start (default) - Start and connect to router VM"
        echo "  build          - Build the router VM"
        ;;
esac
