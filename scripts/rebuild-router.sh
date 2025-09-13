#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date +%H:%M:%S)] $*"; }

cd ~/splix

log "=== Rebuilding Router VM ==="

log "Building router VM with updated config..."
if ! nix build .#router-vm-qcow --print-build-logs; then
    echo "ERROR: Router VM build failed"
    exit 1
fi

if [[ -f "result/nixos.qcow2" ]]; then
    log "Router VM built successfully: $(du -h result/nixos.qcow2 | cut -f1)"
else
    echo "ERROR: VM image not found after build"
    exit 1
fi

log "=== Deploying Updated Router VM ==="

# Check if deployment script exists
if [[ ! -f "generated/scripts/deploy-router-vm.sh" ]]; then
    echo "ERROR: Deploy script not found at generated/scripts/deploy-router-vm.sh"
    exit 1
fi

# Run deployment script
log "Deploying router VM with updated configuration..."
./generated/scripts/deploy-router-vm.sh

log "=== Setup libvirt networks ==="
if [[ -f "scripts/setup-libvirt-networks.sh" ]]; then
    ./scripts/setup-libvirt-networks.sh
else
    log "Network setup script not found, skipping..."
fi

log "=== Router VM Ready ==="
log "Connect with: sudo virsh console router-vm-passthrough"
log "Check status with: sudo virsh list"
