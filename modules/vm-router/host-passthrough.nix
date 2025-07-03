# modules/vm-router/host-passthrough.nix - VM router host configuration with passthrough
{ config, lib, pkgs, ... }:

{
  # Import hardware detection
  imports = [
    ./hardware-detection.nix
  ];
  
  # Enable IOMMU and VFIO for device passthrough
  boot.kernelParams = [ 
    "intel_iommu=on" 
    "iommu=pt"
    "vfio-pci.ids=${config.hardware.vmRouter.primaryDeviceId}"
  ];

  # Load VFIO modules early
  boot.kernelModules = [ "vfio" "vfio_iommu_type1" "vfio_pci" ];
  
  # Blacklist the network driver on host to prevent conflicts
  boot.blacklistedKernelModules = [ config.hardware.vmRouter.primaryDriver ];

  # Enable virtualization
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu;
      ovmf = {
        enable = true;
        packages = [ pkgs.OVMF ];
      };
      swtpm.enable = true;
    };
  };

  # Network configuration for VM bridge
  networking = {
    # Disable NetworkManager on host since primary interface will be passed through
    networkmanager.enable = lib.mkForce false;
    useNetworkd = true;
    
    # Create bridge for VM networking
    bridges.virbr1 = {
      interfaces = [];
    };
  };

  # Enable IP forwarding
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.forwarding" = 1;
  };

  # Emergency network recovery service
  systemd.services.network-emergency = {
    description = "Emergency network recovery";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = false;
      ExecStart = pkgs.writeScript "network-emergency" ''
        #!/bin/bash
        echo "=== EMERGENCY NETWORK RECOVERY ==="
        
        # Stop router VM
        ${pkgs.libvirt}/bin/virsh destroy router-vm 2>/dev/null || true
        
        # Remove device from VFIO
        echo "${config.hardware.vmRouter.primaryDeviceId}" > /sys/bus/pci/drivers/vfio-pci/remove_id 2>/dev/null || true
        echo "${config.hardware.vmRouter.primaryPCI}" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
        
        # Rebind to original driver
        echo "${config.hardware.vmRouter.primaryPCI}" > /sys/bus/pci/drivers_probe 2>/dev/null || true
        
        # Load network module
        ${pkgs.kmod}/bin/modprobe ${config.hardware.vmRouter.primaryDriver}
        
        # Start NetworkManager
        ${pkgs.systemd}/bin/systemctl start NetworkManager
        
        echo "Emergency recovery completed"
      '';
    };
  };
  
  # Create alias for emergency recovery
  environment.shellAliases = {
    emergency-network = "sudo systemctl start network-emergency";
  };
}
