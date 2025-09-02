# ⚠️ PROJECT HALTED ⚠️

**This project has been discontinued due to critical issues with Microsoft's software engineering practices.**


Microsoft's inability to maintain basic compatibility and provide their idiotic piece of shit software [EXACT DETAILS REDACTED] has rendered this project obsolete for the time being. The original plan for the project was to be implemented in a pentesting environment with separation of Host and VM. Due to specific software not being packaged, this will no longer be used and a more traditional package manager on a separate OS will be chosen instead.

Fuck you, Microsoft.
Fuck you bad.

**Details regarding the specific technical failures cannot be disclosed due to confidentiality agreements.**

**Alternative recommendations:**
- Use dedicated hardware routers
- Consider pfSense or OPNsense on bare metal  
- Avoid Microsoft-dependent virtualization stacks

The code remains available for educational purposes only. The ´´scripts/generate-all-configs.sh´´ is the lastest working prototype and has proven to work with some tweaks depending on output. Also note that my **dotfiles** repo is a backbone for the output this project and script provides. **DO NOT USE IN PRODUCTION.**

---

# Splix - Secure VM Router Setup (DISCONTINUED)

~~A complete NixOS-based VM router system with hardware passthrough for secure network isolation.~~

## ~~Overview~~

~~Splix automatically sets up a virtualized router environment where your primary network interface is passed through to a router VM, providing strong isolation between work and leisure environments while maintaining reliable network connectivity.~~

## ~~VM Router Setup Flow~~

### ~~Fresh Machine Setup Process~~
```
Fresh Machine → Hardware Detection → Config Generation → Safe VM Testing → Deployment Ready
     │                    │                  │                    │              │
     │              [Compatibility         [NixOS Configs    [QEMU Testing]   [Libvirt Ready]
     │               Check 8/10]            Generated]                          
     │                    │                  │                    │              │
     └─── git clone ──────┼──────────────────┼────────────────────┼──────────────┘
                          │                  │                    │
                    hardware-results.env   modules/          Router VM works
                                          generated configs
```

### ~~Deployment Sequence (Safe → Passthrough)~~

~~Phase 1: Safe Testing          Phase 2: Point of No Return       Phase 3: Production~~
```
┌─────────────────────┐       ┌─────────────────────────┐       ┌──────────────────────┐
│ Host: Normal WiFi   │  ──▶  │ Host: WiFi → VFIO       │  ──▶  │ Router VM: WiFi Card │
│ Router VM: virtio   │       │ Router VM: virtio       │       │ Guest VMs: Bridge    │
│ Risk: None          │       │ Risk: Network loss      │       │ Risk: VM failure     │
└─────────────────────┘       └─────────────────────────┘       └──────────────────────┘
     libvirt testing                reboot required                 production ready
```

### ~~Final Architecture~~
```
Internet ── WiFi Card (Passthrough) ── Router VM ── Internal Bridge
                │                         │              │
        Emergency Recovery          [DHCP/DNS/NAT]   Guest VMs
        (restore host wifi)         [SSH Management]  │    │
                                                   Pentest Work
                                                     VM    VM
```

### ~~Key Features~~

- ~~**Automatic Hardware Detection** - Detects network interfaces, IOMMU groups, and compatibility~~
- ~~**Dynamic Configuration** - Generates NixOS configs based on your specific hardware~~
- ~~**Emergency Recovery** - Built-in network recovery system when router VM fails~~
- ~~**Hardware Agnostic** - Works with any compatible network interface and driver~~
- ~~**Flake-based Deployment** - Reproducible and version-controlled setup~~
- ~~**Security Isolation** - Strong separation between different environments~~

## ~~Quick Start~~

### ~~Prerequisites~~

- ~~NixOS system with IOMMU support~~
- ~~At least one network interface (WiFi or Ethernet)~~
- ~~8GB+ RAM recommended~~
- ~~Basic understanding of NixOS and virtualization~~

### ~~Installation~~

1. ~~**Clone the repository:**~~
   ```bash
   git clone https://github.com/yourusername/splix.git
   cd splix
   ```

2. ~~**Run hardware detection:**~~
   ```bash
   ./scripts/hardware-identify.sh
   ```

3. ~~**Copy your hardware configuration:**~~
   ```bash
   sudo cp /etc/nixos/hardware-configuration.nix hosts/router-host/
   ```

4. ~~**Deploy the configuration:**~~
   ```bash
   sudo nixos-rebuild switch --flake .#router-host
   ```

5. ~~**Reboot to activate passthrough:**~~
   ```bash
   sudo reboot
   ```

## ~~Hardware Detection~~

~~The hardware detection script analyzes your system and provides a compatibility score:~~

- ~~**8-10/10**: Excellent - Setup should work reliably~~
- ~~**5-7/10**: Good - Setup should work with some risks~~  
- ~~**0-4/10**: Poor - Setup not recommended~~

### ~~Detection Results~~

~~The script checks for:~~
- ~~✅ IOMMU support and enablement~~
- ~~✅ Network interface compatibility~~
- ~~✅ IOMMU group isolation~~
- ~~⚠️ Alternative network interfaces (for fallback)~~

~~Example output:~~
```
Primary Interface: wlo1
PCI Slot: 0000:00:14.3
Device ID: 8086:a840
Driver: iwlwifi
IOMMU Isolated: true
Compatibility Score: 8/10
Recommendation: PROCEED
```

## ~~Emergency Recovery~~

~~If the router VM fails and you lose network access:~~

### ~~Method 1: Built-in Command~~
```bash
emergency-network
```

### ~~Method 2: Manual Recovery~~
```bash
sudo systemctl start network-emergency
```

### ~~Method 3: Direct Script~~
```bash
sudo ./scripts/generated-configs/emergency-recovery.sh
```

~~This will:~~
1. ~~Stop the router VM~~
2. ~~Release the network card from VFIO~~
3. ~~Restore the original driver~~
4. ~~Restart NetworkManager~~
5. ~~Test connectivity~~

**This documentation is preserved for historical reference only.**

**DO NOT ATTEMPT TO USE THIS SOFTWARE.**
