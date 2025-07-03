#!/usr/bin/env bash
set -euo pipefail

readonly CONFIG_FILE="detected-hardware.json"

log() { echo "[TEST] $*"; }
error() { echo "[ERROR] $*" >&2; }

test_virtualization() {
    log "Testing virtualization support..."
    
    if ! grep -q "vmx\|svm" /proc/cpuinfo; then
        error "CPU lacks virtualization extensions"
        return 1
    fi
    
    if ! lsmod | grep -q "kvm"; then
        error "KVM modules not loaded"
        return 1
    fi
    
    log "Virtualization support OK"
    return 0
}

test_iommu() {
    log "Testing IOMMU configuration..."
    
    if [[ ! -d /sys/kernel/iommu_groups ]]; then
        error "IOMMU groups not available"
        return 1
    fi
    
    local group_count
    group_count=$(ls /sys/kernel/iommu_groups | wc -l)
    
    if [[ $group_count -lt 1 ]]; then
        error "No IOMMU groups found"
        return 1
    fi
    
    log "IOMMU configuration OK (${group_count} groups)"
    return 0
}

test_network_device() {
    log "Testing network device configuration..."
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        error "Hardware configuration not found. Run 'make detect' first."
        return 1
    fi
    
    local best_device
    best_device=$(jq -r '.best_device.interface' "$CONFIG_FILE")
    
    if [[ "$best_device" == "null" ]]; then
        error "No suitable network device found"
        return 1
    fi
    
    local device_path="/sys/class/net/$best_device/device"
    
    if [[ ! -d "$device_path" ]]; then
        error "Network device $best_device not found"
        return 1
    fi
    
    log "Network device $best_device OK"
    return 0
}

main() {
    log "Running hardware validation tests..."
    
    local failed=0
    
    test_virtualization || failed=$((failed + 1))
    test_iommu || failed=$((failed + 1))
    test_network_device || failed=$((failed + 1))
    
    if [[ $failed -eq 0 ]]; then
        log "All hardware tests passed"
        return 0
    else
        error "$failed test(s) failed"
        return 1
    fi
}

main "$@"
