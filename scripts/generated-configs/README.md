# VM Router Setup - Usage Instructions

Generated for hardware: wlo1 (8086:a840) driver: iwlwifi
Compatibility score: 8/10

## Quick Start

1. **Apply host configuration:**
   ```bash
   # Copy to your NixOS configuration
   sudo cp host-passthrough.nix /etc/nixos/
   
   # Import in configuration.nix:
   # imports = [ ./host-passthrough.nix ];
   
   # Rebuild and reboot
   sudo nixos-rebuild boot
   sudo reboot
   ```

2. **Setup VM:**
   ```bash
   cd /home/traum/splix/scripts/generated-configs
   sudo ./setup-vm.sh
   ```

3. **Start VM and install NixOS:**
   ```bash
   sudo virsh start router-vm
   sudo virsh console router-vm
   # Install NixOS using router-vm-config.nix
   ```

## Emergency Recovery

If something goes wrong and you lose network:

```bash
sudo ./emergency-recovery.sh
```

This will:
- Stop the router VM
- Release the WiFi card from passthrough  
- Restore normal host networking

## Files Generated

- `host-passthrough.nix` - NixOS host configuration
- `router-vm.xml` - VM definition for libvirt
- `router-vm-config.nix` - NixOS config for inside the VM
- `emergency-recovery.sh` - Network recovery script
- `setup-vm.sh` - VM setup automation

## Testing

Before deploying:
1. Test emergency recovery works
2. Verify VM can start with passthrough
3. Confirm router VM can connect to WiFi
4. Test guest VMs can route through router

## Hardware Details

- Primary Interface: wlo1
- PCI Slot: 0000:00:14.3
- Device ID: 8086:a840
- Driver: iwlwifi
- IOMMU Group: Isolated (good for passthrough)
- Alternative Interfaces: false
