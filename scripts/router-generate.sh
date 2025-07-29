#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SPLIX_DIR="$(dirname "$SCRIPT_DIR")"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

check_requirements() {
    [ -f "$SPLIX_DIR/hardware-results.json" ] || error "Run ./scripts/hardware-detect.sh first"
    [ -f "$SPLIX_DIR/compatibility-score" ] || error "Hardware detection incomplete"
    
    local score
    score=$(cat "$SPLIX_DIR/compatibility-score")
    
    if [ "$score" -lt 5 ]; then
        error "Hardware compatibility too low ($score/10). Review compatibility-report.txt"
    fi
    
    log "Hardware compatibility: $score/10 - proceeding"
}

update_wifi_pci_id() {
    if [ -f "$SPLIX_DIR/wifi-pci.env" ]; then
        source "$SPLIX_DIR/wifi-pci.env"
        
        log "Updating WiFi PCI ID: $WIFI_PCI_ID"
        
        sed -i "s/vfio-pci.ids=.*/vfio-pci.ids=$WIFI_PCI_ID\"/" "$SPLIX_DIR/modules/router-host.nix"
        
        log "Host configuration updated with PCI ID: $WIFI_PCI_ID"
    else
        log "⚠ WiFi PCI ID not detected - using default configuration"
    fi
}

generate_libvirt_xml() {
    log "Generating libvirt XML configuration..."
    
    mkdir -p "$SPLIX_DIR/configs/libvirt"
    
    cat > "$SPLIX_DIR/configs/libvirt/router-vm.xml" << 'XMLEOF'
<domain type='kvm'>
  <name>router-vm</name>
  <memory unit='KiB'>2097152</memory>
  <vcpu placement='static'>2</vcpu>
  <os>
    <type arch='x86_64' machine='pc-q35-6.2'>hvm</type>
    <loader readonly='yes' type='pflash'>/run/libvirt/nix-ovmf/OVMF_CODE.fd</loader>
    <nvram>/var/lib/libvirt/qemu/nvram/router-vm_VARS.fd</nvram>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
    <vmport state='off'/>
  </features>
  <cpu mode='host-model' check='partial'/>
  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>
  <devices>
    <emulator>/run/current-system/sw/bin/qemu-kvm</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='/var/lib/libvirt/images/router-vm.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='network'>
      <source network='default'/>
      <model type='virtio'/>
    </interface>
    <interface type='bridge'>
      <source bridge='br0'/>
      <model type='virtio'/>
    </interface>
    <serial type='pty'>
      <target type='isa-serial' port='0'>
        <model name='isa-serial'/>
      </target>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <graphics type='spice' autoport='yes'>
      <listen type='address'/>
    </graphics>
    <video>
      <model type='qxl' ram='65536' vram='65536' vgamem='16384' heads='1'/>
    </video>
  </devices>
</domain>
XMLEOF

    if [ -f "$SPLIX_DIR/wifi-pci.env" ]; then
        source "$SPLIX_DIR/wifi-pci.env"
        
        local wifi_bdf
        wifi_bdf=$(lspci -nn | grep "$WIFI_PCI_ID" | cut -d' ' -f1)
        
        if [ -n "$wifi_bdf" ]; then
            local bus slot func
            bus="0x${wifi_bdf:0:2}"
            slot="0x${wifi_bdf:3:2}" 
            func="0x${wifi_bdf:6:1}"
            
            sed '/interface type=.bridge/a\
    <hostdev mode="subsystem" type="pci" managed="yes">\
      <source>\
        <address domain="0x0000" bus="'"$bus"'" slot="'"$slot"'" function="'"$func"'"/>\
      </source>\
    </hostdev>' "$SPLIX_DIR/configs/libvirt/router-vm.xml" > "$SPLIX_DIR/configs/libvirt/router-vm-passthrough.xml"
            
            log "Generated passthrough XML with WiFi card $wifi_bdf"
        fi
    fi
}

build_router_vm() {
    log "Building router VM with nixos-generators..."
    
    cd "$SPLIX_DIR"
    
    nix build .#packages.x86_64-linux.router-vm --impure
    
    if [ -L "result" ]; then
        local vm_path
        vm_path=$(readlink -f result)
        log "Router VM built successfully: $vm_path"
        
        sudo mkdir -p /var/lib/libvirt/images
        sudo cp "$vm_path/nixos.qcow2" /var/lib/libvirt/images/router-vm.qcow2
        sudo chown qemu:kvm /var/lib/libvirt/images/router-vm.qcow2
        
        log "VM image installed to /var/lib/libvirt/images/router-vm.qcow2"
    else
        error "Router VM build failed"
    fi
}

test_vm_boot() {
    log "Testing router VM boot..."
    
    timeout 60 qemu-system-x86_64 \
        -enable-kvm \
        -m 1024 \
        -netdev user,id=net0 \
        -device virtio-net,netdev=net0 \
        -drive file=/var/lib/libvirt/images/router-vm.qcow2,format=qcow2,if=virtio \
        -nographic \
        -serial mon:stdio &
    
    local qemu_pid=$!
    sleep 30
    
    if kill -0 "$qemu_pid" 2>/dev/null; then
        log "✓ VM boots successfully"
        kill "$qemu_pid" 2>/dev/null || true
    else
        log "⚠ VM boot test inconclusive"
    fi
}

main() {
    log "Generating router VM configuration..."
    
    check_requirements
    update_wifi_pci_id
    generate_libvirt_xml
    build_router_vm
    test_vm_boot
    
    log "Router VM generation complete"
    log ""
    log "Generated files:"
    log "  - Router VM: /var/lib/libvirt/images/router-vm.qcow2"
    log "  - Libvirt XML: $SPLIX_DIR/configs/libvirt/router-vm.xml"
    log "  - Host config: $SPLIX_DIR/modules/router-host.nix"
    log ""
    log "Next steps:"
    log "  1. Test VM: ./scripts/test-router-vm.sh"
    log "  2. Deploy to zephyrus: ./scripts/zephyrus-integrate.sh"
}

main "$@"
