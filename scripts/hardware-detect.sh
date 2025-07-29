#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SPLIX_DIR="$(dirname "$SCRIPT_DIR")"
readonly RESULTS_FILE="$SPLIX_DIR/hardware-results.json"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

check_requirements() {
    command -v nix >/dev/null || error "Nix not installed"
    command -v lspci >/dev/null || error "lspci not available"
    
    if ! nix run nixpkgs#nixos-facter -- --help >/dev/null 2>&1; then
        log "Installing nixos-facter..."
        nix profile install nixpkgs#nixos-facter || error "Failed to install nixos-facter"
    fi
}

detect_hardware() {
    log "Running comprehensive hardware detection..."
    
    nix run nixpkgs#nixos-facter > "$RESULTS_FILE"
    
    log "Hardware report saved to: $RESULTS_FILE"
}

analyze_compatibility() {
    log "Analyzing hardware compatibility..."
    
    local score=0
    local issues=()
    
    if grep -q "intel_iommu=on\|amd_iommu=on" /proc/cmdline 2>/dev/null; then
        score=$((score + 3))
        log "✓ IOMMU enabled"
    elif dmesg | grep -q "IOMMU\|DMAR" 2>/dev/null; then
        score=$((score + 2))
        log "⚠ IOMMU hardware present but not enabled"
        issues+=("Add intel_iommu=on to kernel parameters")
    else
        issues+=("IOMMU not supported - WiFi passthrough will not work")
    fi
    
    local wifi_info
    if wifi_info=$(lspci -nn | grep -i "network\|wireless" | head -1); then
        score=$((score + 2))
        log "✓ WiFi card detected: $wifi_info"
        
        local pci_id
        pci_id=$(echo "$wifi_info" | grep -o '\[.*\]' | tr -d '[]')
        echo "WIFI_PCI_ID=$pci_id" > "$SPLIX_DIR/wifi-pci.env"
        log "WiFi PCI ID: $pci_id"
    else
        issues+=("No WiFi card detected")
    fi
    
    if grep -q "vmx\|svm" /proc/cpuinfo; then
        score=$((score + 2))
        log "✓ Virtualization support detected"
    else
        issues+=("No virtualization support")
    fi
    
    if systemctl is-active libvirtd >/dev/null 2>&1; then
        score=$((score + 1))
        log "✓ Libvirtd running"
    else
        log "⚠ Libvirtd not running"
    fi
    
    local mem_gb
    mem_gb=$(awk '/MemTotal/ {print int($2/1024/1024)}' /proc/meminfo)
    if [ "$mem_gb" -ge 8 ]; then
        score=$((score + 2))
        log "✓ Sufficient memory: ${mem_gb}GB"
    else
        issues+=("Low memory: ${mem_gb}GB (8GB+ recommended)")
    fi
    
    cat > "$SPLIX_DIR/compatibility-report.txt" << EOF
Hardware Compatibility Report
============================

Score: $score/10

$(if [ "$score" -ge 8 ]; then
    echo "Status: ✅ EXCELLENT - Ready for WiFi passthrough"
elif [ "$score" -ge 5 ]; then
    echo "Status: ⚠ GOOD - Should work with minor adjustments"
else
    echo "Status: ❌ POOR - Significant issues detected"
fi)

Issues Found:
$(printf '%s\n' "${issues[@]}" | sed 's/^/- /')

Hardware Details:
- CPU: $(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
- Memory: ${mem_gb}GB
- WiFi: ${wifi_info:-"Not detected"}

Recommendations:
$(if [ "$score" -ge 8 ]; then
    echo "- Proceed with router setup"
    echo "- Run: ./scripts/router-generate.sh"
elif [ "$score" -ge 5 ]; then
    echo "- Address issues above before proceeding"
    echo "- Enable IOMMU in BIOS and kernel parameters"
else
    echo "- Hardware not suitable for WiFi passthrough"
    echo "- Consider USB WiFi adapter or different approach"
fi)
EOF
    
    log "Compatibility report saved to: $SPLIX_DIR/compatibility-report.txt"
    
    echo "$score" > "$SPLIX_DIR/compatibility-score"
    
    return 0
}

main() {
    log "Starting hardware detection for VM router setup..."
    
    check_requirements
    detect_hardware
    analyze_compatibility
    
    local score
    score=$(cat "$SPLIX_DIR/compatibility-score")
    
    log "Hardware detection complete"
    log "Compatibility score: $score/10"
    
    if [ "$score" -ge 8 ]; then
        log "✅ System ready for router setup"
        log "Next: ./scripts/router-generate.sh"
    elif [ "$score" -ge 5 ]; then
        log "⚠ Review compatibility-report.txt before proceeding"
    else
        log "❌ Hardware not suitable for this setup"
    fi
}

main "$@"
