#!/run/current-system/sw/bin/bash
# Simple router VM testing script

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

case "${1:-}" in
    "start"|"")
        echo "Starting router VM for testing..."
        echo "Login: admin / admin"
        echo "Exit: type 'exit', then Ctrl+A, C, then 'quit'"
        echo
        cd "$PROJECT_ROOT"
        QEMU_OPTS="-nographic -serial mon:stdio" ./result/bin/run-router-vm-vm
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
