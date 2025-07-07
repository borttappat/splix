# Generated NixOS configuration for VM router passthrough
# Generated on Mon Jul  7 23:01:29 CEST 2025
# Hardware: wlo1 (8086:a840) using iwlwifi driver

{ config, lib, pkgs, ... }:

{
  # Enable IOMMU and VFIO for device passthrough
  boot.kernelParams = [ 
    "intel_iommu=on" 
    "iommu=pt"
    "vfio-pci.ids=8086:a840"
  ];

  # Load VFIO modules early
  boot.kernelModules = [ "vfio" "vfio_iommu_type1" "vfio_pci" ];
  
  # Blacklist the network driver on host to prevent conflicts
  boot.blacklistedKernelModules = [ "iwlwifi" ];

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
    
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 16509 ];  # SSH and libvirt
      allowedUDPPorts = [ 67 68 ];     # DHCP
      trustedInterfaces = [ "virbr1" ];
    };
  };

  # Enable IP forwarding
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.forwarding" = 1;
  };

  # System packages for VM management
  environment.systemPackages = with pkgs; [
    virt-manager
    virt-viewer
    bridge-utils
    iptables
    netcat
  ];

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
        /run/current-system/sw/bin/virsh destroy router-vm 2>/dev/null || true
        
        # Remove device from VFIO
        echo "8086:a840" > /sys/bus/pci/drivers/vfio-pci/remove_id 2>/dev/null || true
        echo "0000:00:14.3" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
        
        # Rebind to original driver
        echo "0000:00:14.3" > /sys/bus/pci/drivers_probe 2>/dev/null || true
        
        # Load network module
        /run/current-system/sw/bin/modprobe iwlwifi
        
        # Start NetworkManager
        /run/current-system/sw/bin/systemctl start NetworkManager
        
        echo "Emergency recovery completed"
        echo "You should now have network access"
      '';
    };
  };
}
