# Nixarium - Hardware-Agnostic VM Router

**WARNING: This is a complex network isolation system that will take control of your network hardware. Only use this if you actually need hardware-level network isolation for sensitive work.**

## What This Does

- Steals your WiFi card from the host OS using VFIO passthrough
- Runs a NixOS router VM that owns your network hardware
- Provides isolated networks for different VMs (work vs leisure)
- Includes emergency recovery when things break (and they will)

## Hardware Requirements

- x86_64 CPU with virtualization extensions (VT-x/AMD-V)
- IOMMU support (VT-d/AMD-Vi) enabled in BIOS
- PCIe network device in isolated IOMMU group
- Minimum 8GB RAM, 16GB recommended

## Quick Start

```bash
# Check if your hardware is compatible
make detect

# If score ≥8, proceed with setup
make test
make deploy

# Emergency network recovery if needed
make emergency
