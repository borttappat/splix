# Splix - VM Router with Dotfiles Integration

**Status**: Working on Intel WiFi hardware | **Setup**: Semi-automated | **Integration**: [Dotfiles](https://github.com/borttappat/dotfiles)-based NixOS workflow

Splix creates a NixOS VM router that provides network isolation through VFIO WiFi passthrough. It generates configuration files that integrate with your dotfiles-managed NixOS system, allowing you to switch between normal operation and router mode via NixOS specializations.

## How It Works with Your Dotfiles

Splix is designed to work alongside a dotfiles-managed NixOS system. Your dotfiles remain the backbone of your host OS configuration, while Splix adds router capabilities as an optional specialization.

### Integration Flow

```
Your Dotfiles (Host OS) → Splix (Router Generation) → Combined System
├── Base NixOS config        ├── Hardware detection        ├── Normal boot mode
├── User environment         ├── VM router config          ├── Router specialization  
└── System packages          └── Generated modules         └── Seamless switching
```

## Network Architecture

```
Internet ── WiFi Card (VFIO) ── Router VM ── Guest Networks
                │                   │            │
        [Hardware Passthrough]  [NAT + DHCP]  [Isolated VMs]
        Auto-detected PCI      192.168.10x.253   No host access
```

**Network Segments:**
- `virbr1` (192.168.100.x) - Host ↔ Router communication
- `virbr2` (192.168.101.x) - Guest network 1 (isolated work)  
- `virbr3` (192.168.102.x) - Guest network 2 (isolated testing)
- `virbr4` (192.168.103.x) - Development environment
- `virbr5` (192.168.104.x) - Additional isolation

## Setup Process

**Prerequisites**: 
- NixOS system managed via dotfiles
- Intel WiFi card (tested hardware)
- IOMMU enabled

### 1. Generate Configurations

```bash
cd ~/splix
./scripts/generate-all-configs.sh
```

This detects your hardware and generates machine-specific files in `generated/`:
- NixOS modules for your dotfiles
- Deployment scripts with correct PCI addresses
- VFIO passthrough configurations

### 2. Manual Integration Step

**Currently required**: Copy generated files to your dotfiles:

```bash
# Copy machine-specific module
cp generated/modules/$(hostname).nix ~/dotfiles/modules/

# Copy VFIO passthrough config  
cp generated/modules/$(hostname)-passthrough.nix ~/dotfiles/modules/router-generated/

# Import in your dotfiles configuration.nix
# imports = [ ./modules/$(hostname).nix ];
```

### 3. Switch to Router Mode

```bash
# Router mode (all traffic through VM)
sudo nixos-rebuild switch --specialisation router

# Normal mode (direct network access)
sudo nixos-rebuild switch
```

## What Gets Generated

### Machine-Specific Module (`~/dotfiles/modules/zenbook.nix`)

Adds a `router` specialization to your NixOS config that:
- Imports VFIO passthrough configuration
- Sets up network routing through router VM
- Configures auto-start services
- Uses your actual username (not hardcoded paths)

### VFIO Configuration (`~/dotfiles/modules/router-generated/zenbook-passthrough.nix`)

Hardware-specific configuration with:
- Your WiFi card's actual PCI address
- Device IDs from hardware detection
- Bridge network definitions
- Kernel parameters for VFIO

### Deployment Scripts (`generated/scripts/`)

Ready-to-use scripts with your hardware details:
- Router VM deployment with correct device passthrough
- Network setup and testing utilities
- Recovery scripts with your specific device IDs

## Key Features

### Hardware Detection
- Scans for WiFi interfaces and PCI addresses
- Generates hardware compatibility report
- **Note**: Currently tested on Intel WiFi only

### Dotfiles Integration
- Your dotfiles remain the primary NixOS configuration
- Splix adds router capabilities as a specialization
- No disruption to existing system setup
- Clean separation between base system and router features

### Mode Switching
Switch between configurations without rebooting:
```bash
# Work normally with direct internet
sudo nixos-rebuild switch

# Switch to isolated router mode  
sudo nixos-rebuild switch --specialisation router
```

### Network Isolation
- Guest VMs completely isolated from host
- Multiple isolated network segments
- All guest traffic routes through router VM
- Host retains management access

## Current Limitations

### Hardware Support
- **Intel WiFi only**: Tested on Intel WiFi 6/6E cards
- **Manual verification needed**: PCI addresses and device IDs must be confirmed
- **IOMMU required**: Hardware virtualization support needed

### Setup Process
- **Manual file copying**: Generated configs must be manually integrated into dotfiles
- **Configuration review**: Generated modules should be reviewed before use
- **Network setup**: Some network configuration may need manual adjustment

### Management
- **Console-based**: Router VM managed via virsh console
- **WiFi setup**: Manual WiFi configuration in router VM required
- **No GUI**: Text-based configuration and monitoring

## File Structure

```
splix/
├── scripts/
│   ├── generate-all-configs.sh    # Main generation script
│   └── hardware-identify.sh       # Hardware detection
├── modules/
│   └── router-vm-config.nix       # Router VM base configuration
├── templates/                     # Configuration templates with variables
├── generated/                     # Generated configurations (hardware-specific)
│   ├── modules/                   # For integration with dotfiles
│   └── scripts/                   # Deployment and management
└── hardware-results.env          # Detected hardware parameters
```

## Integration with Dotfiles

### Your Dotfiles Structure
```
~/dotfiles/
├── flake.nix                      # Main flake with system configurations
├── modules/
│   ├── configuration.nix          # Core system configuration
│   ├── zenbook.nix                # Generated by Splix (router specialization)
│   ├── zephyrus.nix               # Generated by Splix (another machine)
│   └── router-generated/
│       ├── zenbook-passthrough.nix  # Generated by Splix (VFIO config)
│       └── host-passthrough.nix     # Generated by Splix (generic config)
└── ...
```

### How It Works Together

1. **Base System**: Your dotfiles define the core NixOS configuration
2. **Router Module**: Splix generates a machine-specific module that adds router capabilities
3. **Specialization**: The router functionality is available as a NixOS specialization
4. **Clean Separation**: Router features don't interfere with your normal system operation

## Usage Examples

### Daily Workflow
```bash
# Normal work (direct internet)
sudo nixos-rebuild switch

# Switch to isolated environment for testing
sudo nixos-rebuild switch --specialisation router

# Create isolated VMs
sudo virt-install --network bridge=virbr2 --name="test-vm" ...
```

### Router VM Management
```bash
# Check router status
sudo virsh list --all

# Connect to router console for WiFi setup
sudo virsh console router-vm

# Inside router VM
nmcli device wifi connect "NETWORK" password "PASSWORD"
```

## Troubleshooting

### Generation Issues
```bash
# Check hardware detection
./scripts/hardware-identify.sh
cat hardware-results.env

# Verify compatibility score (should be ≥6)
```

### Router VM Issues
```bash
# Verify VFIO binding
lspci -nnk | grep -A3 "Network controller"
# Should show: Kernel driver in use: vfio-pci

# Check VM deployment
sudo systemctl status router-vm-autostart
journalctl -u router-vm-autostart
```

### Network Issues
```bash
# Test router connectivity
ping 192.168.100.253  # Router management IP

# Check guest VM internet
# (from inside guest VM)
ping 8.8.8.8
```

## Future Improvements

- **Broader hardware support**: AMD and other WiFi chipsets
- **Automated integration**: Direct dotfiles integration without manual copying
- **Enhanced automation**: One-command setup from detection to deployment
- **Monorepo approach**: Fully integrate into 
## Contributing

When adding features, maintain the dotfiles integration pattern and ensure generated configurations remain compatible with existing NixOS dotfiles workflows.
