#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIG_FILE="$SCRIPT_DIR/../detected-hardware.json"
readonly MIN_COMPATIBILITY_SCORE=5

log() { echo "[$(date '+%H:%M:%S')] $*"; }
error() { echo "[ERROR] $*" >&2; }
die() { error "$*"; exit 1; }

detect_virtualization_support() {
    local score=0

    if ! grep -q "vmx\|svm" /proc/cpuinfo; then
        return 0
    fi
    score=$((score + 2))

    if ! lsmod | grep -q "kvm_intel\|kvm_amd"; then
        if ! modprobe kvm-intel 2>/dev/null && ! modprobe kvm-amd 2>/dev/null; then
            return $score
        fi
    fi
    score=$((score + 2))

    echo "$score"
}

detect_iommu_support() {
    local score=0

    if ! dmesg | grep -q "DMAR\|AMD-Vi"; then
        return 0
    fi
    score=$((score + 1))

    if ! dmesg | grep -q "IOMMU.*enabled\|DMAR.*enabled"; then
        return $score
    fi
    score=$((score + 2))

    if [[ ! -d /sys/kernel/iommu_groups ]]; then
        return $score
    fi
    score=$((score + 1))

    echo "$score"
}

analyze_network_device() {
    local interface="$1"
    local device_path="/sys/class/net/$interface/device"
    
    [[ -d "$device_path" ]] || return 1

    local pci_slot driver vendor_id
    pci_slot=$(basename "$(readlink "$device_path" 2>/dev/null || echo '')")
    
    if [[ ! "$pci_slot" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$ ]]; then
        return 1
    fi

    driver=$(basename "$(readlink "$device_path/driver" 2>/dev/null || echo 'unknown')")
    
    local pci_info
    pci_info=$(lspci -nn -s "$pci_slot" 2>/dev/null || echo '')
    vendor_id=$(echo "$pci_info" | grep -o '\[.*:.*\]' | tr -d '[]' || echo 'unknown')

    local iommu_group=""
    if [[ -L "$device_path/iommu_group" ]]; then
        iommu_group=$(basename "$(readlink "$device_path/iommu_group")")
    fi

    cat << EOF
{
  "interface": "$interface",
  "pci_slot": "$pci_slot",
  "driver": "$driver",
  "vendor_device_id": "$vendor_id",
  "iommu_group": "$iommu_group",
  "type": "pcie"
}
EOF
}

find_network_devices() {
    local devices=()
    
    for interface in /sys/class/net/*; do
        interface=$(basename "$interface")
        [[ "$interface" != "lo" ]] || continue
        
        if device_json=$(analyze_network_device "$interface" 2>/dev/null); then
            devices+=("$device_json")
        fi
    done
    
    printf '%s\n' "${devices[@]}" | jq -s '.'
}

assess_device_passthrough_viability() {
    local device="$1"
    local score=0
    local issues=()
    
    local iommu_group
    iommu_group=$(echo "$device" | jq -r '.iommu_group')
    
    if [[ "$iommu_group" == "null" || "$iommu_group" == "" ]]; then
        issues+=("Device not in IOMMU group")
        echo '{"score": 0, "issues": ["Device not in IOMMU group"]}'
        return
    fi
    score=$((score + 2))
    
    local group_devices
    if group_devices=$(ls "/sys/kernel/iommu_groups/$iommu_group/devices" 2>/dev/null); then
        local device_count
        device_count=$(echo "$group_devices" | wc -w)
        
        if [[ "$device_count" -eq 1 ]]; then
            score=$((score + 4))
        elif [[ "$device_count" -le 3 ]]; then
            score=$((score + 2))
            issues+=("Shares IOMMU group with $((device_count - 1)) other devices")
        else
            score=$((score + 1))
            issues+=("Shares IOMMU group with many devices - high risk")
        fi
    else
        issues+=("Cannot analyze IOMMU group")
    fi
    
    local driver
    driver=$(echo "$device" | jq -r '.driver')
    case "$driver" in
        "iwlwifi"|"ath10k"|"ath11k"|"mt76"|"rtw88"|"rtw89")
            score=$((score + 2))
            ;;
        "unknown")
            issues+=("Unknown or missing driver")
            ;;
        *)
            score=$((score + 1))
            issues+=("Untested driver: $driver")
            ;;
    esac
    
    jq -n --argjson score "$score" --argjson issues "$(printf '%s\n' "${issues[@]}" | jq -R . | jq -s .)" \
        '{"score": $score, "issues": $issues}'
}

generate_hardware_config() {
    log "Detecting hardware configuration..."
    
    local virt_score iommu_score
    virt_score=$(detect_virtualization_support)
    iommu_score=$(detect_iommu_support)
    
    if [[ $((virt_score + iommu_score)) -lt 4 ]]; then
        die "System lacks basic virtualization requirements (score: $((virt_score + iommu_score))/8)"
    fi
    
    local network_devices
    network_devices=$(find_network_devices)
    
    if [[ "$(echo "$network_devices" | jq length)" -eq 0 ]]; then
        die "No compatible network devices found"
    fi
    
    local best_device best_score=0 device_assessments=()
    
    while read -r device; do
        local assessment
        assessment=$(assess_device_passthrough_viability "$device")
        local score
        score=$(echo "$assessment" | jq -r '.score')
        
        device_assessments+=("$(echo "$device" | jq --argjson assessment "$assessment" '. + {assessment: $assessment}')")
        
        if [[ "$score" -gt "$best_score" ]]; then
            best_score="$score"
            best_device="$device"
        fi
    done < <(echo "$network_devices" | jq -c '.[]')
    
    local total_score=$((virt_score + iommu_score + best_score))
    
    cat > "$CONFIG_FILE" << EOF
{
  "compatibility_score": $total_score,
  "virtualization_score": $virt_score,
  "iommu_score": $iommu_score,
  "best_device": $best_device,
  "all_devices": $(printf '%s\n' "${device_assessments[@]}" | jq -s '.'),
  "recommendation": "$(get_recommendation "$total_score")",
  "generated_at": "$(date -Iseconds)"
}
EOF
    
    log "Hardware detection complete. Score: $total_score/16"
    
    if [[ "$total_score" -lt "$MIN_COMPATIBILITY_SCORE" ]]; then
        die "Hardware compatibility too low (score: $total_score). VM router not recommended."
    fi
}

get_recommendation() {
    local score="$1"
    if [[ "$score" -ge 12 ]]; then
        echo "excellent"
    elif [[ "$score" -ge 8 ]]; then
        echo "good"
    elif [[ "$score" -ge 5 ]]; then
        echo "acceptable_with_risks"
    else
        echo "not_recommended"
    fi
}

main() {
    command -v jq >/dev/null || die "jq is required but not installed"
    [[ $EUID -ne 0 ]] || die "Do not run as root"
    
    generate_hardware_config
    
    local recommendation
    recommendation=$(jq -r '.recommendation' "$CONFIG_FILE")
    
    case "$recommendation" in
        "excellent"|"good")
            log "System ready for VM router setup"
            ;;
        "acceptable_with_risks")
            log "WARNING: System has compatibility issues but may work"
            ;;
        "not_recommended")
            error "System not suitable for VM router setup"
            exit 1
            ;;
    esac
    
    log "Configuration saved to: $CONFIG_FILE"
}

main "$@"
