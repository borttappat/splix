# Splix - NixOS VM Router with Network Isolation

**Status**: Working on ASUS Zenbook | **Setup**: 4 commands | **Networks**: 3 isolated segments

A minimal NixOS VM router that provides WiFi card passthrough to create isolated guest networks. Guest VMs get internet through the router VM while remaining completely isolated from the host system.

My setup is over at [my dotfiles repo](https://github.com/borttappat/dotfiles) and I integrate the generated modules into that setup. 


## Network Architecture

```
Internet ── WiFi Card (VFIO) ── Router VM ── Guest Networks
                │                   │            │
        [Hardware Passthrough]  [NAT + DHCP]  [Isolated VMs]
        Zenbook: 8086:a840     192.168.10x.253   No host access
```

**Network Segments:**
- `virbr1` (192.168.100.x) - Host ↔ Router communication
- `virbr2` (192.168.101.x) - Guest network 1 (pentesting/work)  
- `virbr3` (192.168.102.x) - Guest network 2 (gaming/leisure)

## Quick Setup

**Prerequisites**: NixOS with IOMMU enabled, compatible WiFi card

```bash
# 1. Build router VM
nix build .#router-vm-qcow

# 2. Deploy router with WiFi passthrough  
./scripts/rebuild-router.sh

# 3. Connect to router VM and setup WiFi
sudo virsh console router-vm-passthrough
nmcli device wifi connect "NETWORK" password "PASSWORD"

# 4. Create guest VMs on isolated networks
sudo virt-install --name="test-vm" --network bridge=virbr2 ...
```

Guest VMs automatically get DHCP (192.168.101.x or 192.168.102.x) and internet through router VM's WiFi.

## Essential Files

**Core Configuration:**
- `flake.nix` - Builds router VM image
- `modules/router-vm-config.nix` - Router VM NixOS config with network setup
- `hardware-results.env` - Hardware-specific values (PCI address, device ID)

**Deployment Scripts:**
- `scripts/rebuild-router.sh` - Build and deploy router VM
- `scripts/setup-networks-post-deploy.sh` - Configure libvirt networks
- `generated/scripts/deploy-router-vm.sh` - Hardware-specific VM deployment

## Hardware Configuration

**Current Setup (Zenbook):**
- WiFi Device: 8086:a840 (Intel Wi-Fi 6E)
- PCI Address: 0000:00:14.3
- Driver: iwlwifi (blacklisted on host)
- Status: Working, 8/10 compatibility

**Requirements:**
- IOMMU support (Intel VT-d/AMD-Vi)
- Compatible WiFi card in isolated IOMMU group
- 8GB+ RAM (2GB for router VM)
- NixOS 25.05+

## Usage

**Router VM Management:**
```bash
# Deploy/redeploy router
./scripts/rebuild-router.sh

# Connect to router console
sudo virsh console router-vm-passthrough

# Check router status
sudo virsh list --all
```

**Guest VM Creation:**
```bash
# Work/pentesting VMs (192.168.101.x network)
sudo virt-install --network bridge=virbr2 --name="kali-vm" ...

# Gaming/leisure VMs (192.168.102.x network)  
sudo virt-install --network bridge=virbr3 --name="gaming-vm" ...

# Direct host access (bypass router)
sudo virt-install --network bridge=virbr0 --name="direct-vm" ...
```

## Security Benefits

**Network Isolation:**
- Guest VMs cannot access host system
- Guest networks completely separated
- All internet traffic routed through router VM WiFi
- Host maintains separate internet connection for management

**Traffic Control:**
- Monitor all guest internet activity at router VM level
- Block/filter traffic centrally
- Isolated network segments prevent cross-contamination
- Emergency host network recovery available

## File Structure

```
splix/
├── flake.nix                           # VM builder
├── modules/router-vm-config.nix        # Router configuration  
├── scripts/
│   ├── rebuild-router.sh               # Main deployment script
│   └── setup-networks-post-deploy.sh  # Network setup
├── generated/scripts/
│   └── deploy-router-vm.sh             # Hardware-specific deployment
└── hardware-results.env               # Hardware configuration
```

**Not Tracked:** VM images (`result/`), libvirt disk images, build artifacts

## Limitations

**Hardware Specific:**
- Currently configured for one Zenbook machine
- Requires manual configuration for different hardware
- Device IDs hardcoded in deployment scripts

**Network Features:**
- No VPN server integration
- No advanced traffic shaping
- Basic iptables firewalling only

**Management:**
- No web interface
- Console-based router VM management
- Manual WiFi configuration required

## Troubleshooting

**Router VM won't start:**
```bash
# Check VFIO binding
lspci -nnk | grep -A3 "Network controller"
# Should show: Kernel driver in use: vfio-pci

# Check libvirtd
sudo systemctl status libvirtd
```

**No internet in guest VMs:**
```bash
# Verify router VM WiFi
sudo virsh console router-vm-passthrough
ip addr show wlp7s0  # Should have IP
ping 8.8.8.8

# Check DHCP service
sudo ss -ulnp | grep :67  # Should show dnsmasq
```

**Host lost internet:**
```bash
# Router VM should provide host internet via management bridge
ping 192.168.100.253  # Router VM management IP
```

## Performance

**Typical Resource Usage:**
- CPU: 5-10% overhead from VM routing
- Memory: 2GB dedicated to router VM
- Network: <5% latency increase  
- Storage: ~2GB for router VM image

**Tested Performance:**
- Guest VM internet speeds: 90%+ of native WiFi speed
- Host internet through router: No noticeable impact
- Multiple guest VMs: Scales well up to memory limits

## License

MIT License - Use at your own risk. Hardware passthrough can potentially cause system instability.
