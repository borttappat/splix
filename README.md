# Septix - Secure VM Router Setup

A complete NixOS-based VM router system with hardware passthrough for secure network isolation.

## Overview

Septix automatically sets up a virtualized router environment where your primary network interface is passed through to a router VM, providing strong isolation between work and leisure environments while maintaining reliable network connectivity.

### Architecture

```
Internet → WiFi Card (Passthrough) → Router VM → Internal Network
                                       ↓
                Host Machine ← Emergency Recovery
                                       ↓
                            [Pentesting VM] [Leisure VM]
```

### Key Features

- **Automatic Hardware Detection** - Detects network interfaces, IOMMU groups, and compatibility
- **Dynamic Configuration** - Generates NixOS configs based on your specific hardware
- **Emergency Recovery** - Built-in network recovery system when router VM fails
- **Hardware Agnostic** - Works with any compatible network interface and driver
- **Flake-based Deployment** - Reproducible and version-controlled setup
- **Security Isolation** - Strong separation between different environments

## Quick Start

### Prerequisites

- NixOS system with IOMMU support
- At least one network interface (WiFi or Ethernet)
- 8GB+ RAM recommended
- Basic understanding of NixOS and virtualization

### Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/yourusername/septix.git
   cd septix
   ```

2. **Run hardware detection:**
   ```bash
   ./scripts/hardware-identify.sh
   ```

3. **Copy your hardware configuration:**
   ```bash
   sudo cp /etc/nixos/hardware-configuration.nix hosts/router-host/
   ```

4. **Deploy the configuration:**
   ```bash
   sudo nixos-rebuild switch --flake .#router-host
   ```

5. **Reboot to activate passthrough:**
   ```bash
   sudo reboot
   ```

## Hardware Detection

The hardware detection script analyzes your system and provides a compatibility score:

- **8-10/10**: Excellent - Setup should work reliably
- **5-7/10**: Good - Setup should work with some risks  
- **0-4/10**: Poor - Setup not recommended

### Detection Results

The script checks for:
- ✅ IOMMU support and enablement
- ✅ Network interface compatibility
- ✅ IOMMU group isolation
- ⚠️ Alternative network interfaces (for fallback)

Example output:
```
Primary Interface: wlo1
PCI Slot: 0000:00:14.3
Device ID: 8086:a840
Driver: iwlwifi
IOMMU Isolated: true
Compatibility Score: 8/10
Recommendation: PROCEED
```

## Emergency Recovery

If the router VM fails and you lose network access:

### Method 1: Built-in Command
```bash
emergency-network
```

### Method 2: Manual Recovery
```bash
sudo systemctl start network-emergency
```

### Method 3: Direct Script
```bash
sudo ./scripts/generated-configs/emergency-recovery.sh
```

This will:
1. Stop the router VM
2. Release the network card from VFIO
3. Restore the original driver
4. Restart NetworkManager
5. Test connectivity

## Project Structure

```
septix/
├── flake.nix                          # Main flake configuration
├── flake.lock                         # Dependency lock file
├── scripts/
│   ├── hardware-identify.sh           # Hardware detection script
│   ├── vm-setup-generator.sh          # VM configuration generator
│   └── generated-configs/             # Generated VM configurations
├── modules/
│   ├── base.nix                       # Base system configuration
│   └── vm-router/
│       ├── hardware-detection.nix     # Hardware-specific options
│       └── host-passthrough.nix       # VFIO passthrough configuration
├── hosts/
│   └── router-host/
│       ├── configuration.nix          # Host-specific settings
│       └── hardware-configuration.nix # Hardware configuration
└── README.md                          # This file
```

## Supported Hardware

### Tested Network Interfaces
- Intel WiFi 6E (BE201) - Excellent compatibility
- Intel WiFi 6 (AX200/AX201) - Good compatibility
- Intel WiFi 5 (AC7260/AC8265) - Good compatibility

### Requirements
- **IOMMU Support**: Intel VT-d or AMD-Vi required
- **IOMMU Groups**: Network interface should be isolated
- **Memory**: 8GB+ recommended (2GB for router VM)
- **Storage**: 20GB+ free space

### Compatibility Matrix

| Score | IOMMU | Interface | Isolation | Alternative | Status |
|-------|-------|-----------|-----------|-------------|---------|
| 10/10 | ✅ | ✅ | ✅ | ✅ | Perfect |
| 8-9/10 | ✅ | ✅ | ✅ | ❌ | Excellent |
| 6-7/10 | ✅ | ✅ | ⚠️ | ❌ | Good |
| 3-5/10 | ✅ | ❌ | ❌ | ❌ | Risky |
| 0-2/10 | ❌ | ❌ | ❌ | ❌ | Not Compatible |

## Configuration

### Host Configuration

The system automatically generates:
- IOMMU and VFIO kernel parameters
- Driver blacklisting for your specific hardware
- Virtualization services (libvirtd, QEMU)
- Network bridges for VM communication
- Emergency recovery services

### Router VM Configuration

Includes:
- WiFi networking with WPA2/WPA3 support
- DHCP server for guest VMs
- DNS forwarding and caching
- NAT configuration for internet access
- SSH access for management

## Usage Examples

### Check System Status
```bash
# Check if passthrough is active
lspci -k | grep -A 3 "Network controller"

# Verify VFIO binding
ls /sys/bus/pci/drivers/vfio-pci/

# Check VM status
virsh list --all
```

### VM Management
```bash
# Start router VM
sudo virsh start router-vm

# Connect to VM console
sudo virsh console router-vm

# Stop router VM
sudo virsh shutdown router-vm

# Force stop router VM
sudo virsh destroy router-vm
```

### Network Testing
```bash
# Test host connectivity (should fail after reboot)
ping -c 3 8.8.8.8

# Test after starting router VM
sudo virsh start router-vm
sleep 30
ping -c 3 8.8.8.8
```

## Troubleshooting

### Common Issues

**1. IOMMU not enabled**
- Enable in BIOS/UEFI settings
- Check kernel parameters include `intel_iommu=on`

**2. Network interface not isolated**
- Check IOMMU groups: `find /sys/kernel/iommu_groups/ -type l`
- Consider ACS override patches (advanced)

**3. Driver conflicts**
- Verify driver blacklisting: `lsmod | grep iwlwifi`
- Check kernel module loading order

**4. VM won't start**
- Verify OVMF packages installed
- Check libvirtd service status
- Review VM logs: `virsh dumpxml router-vm`

**5. No network after reboot**
- Run emergency recovery: `emergency-network`
- Check device binding: `lspci -k`
- Verify NetworkManager status

### Debug Commands

```bash
# Hardware detection debug
./scripts/hardware-identify.sh

# Check IOMMU status
sudo dmesg | grep -i iommu

# Verify device binding
lspci -k -s $(cat scripts/hardware-results.env | grep PRIMARY_PCI | cut -d= -f2)

# Test flake evaluation
nix eval .#nixosConfigurations.router-host.config.hardware.vmRouter.primaryInterface

# Emergency network recovery
sudo systemctl start network-emergency
```

## Development

### Adding Support for New Hardware

1. Test hardware detection:
   ```bash
   ./scripts/hardware-identify.sh
   ```

2. Check compatibility score and issues

3. Add hardware-specific workarounds if needed

4. Test emergency recovery thoroughly

### Contributing

1. Fork the repository
2. Create a feature branch
3. Test on your hardware
4. Submit a pull request with:
   - Hardware compatibility report
   - Test results
   - Documentation updates

## Security Considerations

### Isolation Boundaries

- **Host ↔ Router VM**: Network interface passthrough
- **Router VM ↔ Guest VMs**: Virtual network isolation
- **Guest VMs ↔ Guest VMs**: Network segmentation

### Attack Vectors

- **Hypervisor vulnerabilities**: VM escape potential
- **Shared memory**: DMA attacks via IOMMU
- **Network bridges**: Inter-VM communication

### Mitigations

- Regular system updates
- IOMMU protection enabled
- Minimal host surface area
- Emergency recovery procedures

## Performance

### Expected Overhead

- **CPU**: 5-10% overhead from virtualization
- **Memory**: 2GB dedicated to router VM
- **Network**: <5% latency increase
- **Storage**: Minimal impact

### Optimization Tips

- Assign multiple CPU cores to router VM
- Use virtio drivers for better performance
- Enable SR-IOV if supported
- Tune kernel parameters for low latency

## Roadmap

- [ ] Support for multiple network interfaces
- [ ] Automated guest VM creation
- [ ] Web-based management interface
- [ ] VPN server integration
- [ ] Traffic monitoring and logging
- [ ] Support for USB WiFi adapters
- [ ] Container-based isolation option

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgments

- NixOS community for excellent documentation
- VFIO community for passthrough expertise
- libvirt developers for virtualization tools

## Support

For issues and questions:
1. Check the troubleshooting section
2. Search existing GitHub issues
3. Create a new issue with:
   - Hardware detection output
   - Error messages
   - System information
   - Steps to reproduce
