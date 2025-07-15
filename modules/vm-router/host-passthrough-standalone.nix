# Standalone host passthrough configuration
# This module contains everything needed for the host without relying on /etc/nixos
{ config, lib, pkgs, ... }:

let
  # Read hardware results if available
  hardwareResults = if builtins.pathExists ../../hardware-results.env
    then lib.strings.fileContents ../../hardware-results.env
    else "";
  
  # Extract values from hardware results
  primaryPCI = lib.strings.trim (
    lib.strings.removePrefix "PRIMARY_PCI=" 
    (lib.findFirst (line: lib.hasPrefix "PRIMARY_PCI=" line) "PRIMARY_PCI=0000:00:14.3" 
    (lib.strings.splitString "\n" hardwareResults))
  );
  
  primaryDriver = lib.strings.trim (
    lib.strings.removePrefix "PRIMARY_DRIVER=" 
    (lib.findFirst (line: lib.hasPrefix "PRIMARY_DRIVER=" line) "PRIMARY_DRIVER=iwlwifi" 
    (lib.strings.splitString "\n" hardwareResults))
  );
in
{
  # Base system configuration
  system.stateVersion = "24.05";
  
  # Networking - minimal configuration for router host
  networking = {
    hostName = "router-host";
    networkmanager.enable = false; # Disabled for passthrough
    useDHCP = false;
    
    # Bridge for VM communication
    bridges.virbr0.interfaces = [];
    interfaces.virbr0.ipv4.addresses = [{
      address = "192.168.122.1";
      prefixLength = 24;
    }];
    
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 16509 5900 5901 ];
      allowedUDPPorts = [ 67 68 ];
      trustedInterfaces = [ "virbr0" "virbr1" ];
    };
  };
  
  # Boot configuration for VFIO
  boot = {
    kernelModules = [ "kvm-intel" "vfio" "vfio_iommu_type1" "vfio_pci" ];
    
    kernelParams = [
      "intel_iommu=on"
      "iommu=pt"
      "vfio-pci.ids=8086:a840"  # Your WiFi device ID
    ];
    
    # Blacklist WiFi driver to prevent host from using it
    blacklistedKernelModules = [ primaryDriver ];
    
    # Early VFIO binding
    extraModprobeConfig = ''
      options vfio-pci ids=8086:a840
    '';
    
    initrd.kernelModules = [ "vfio-pci" ];
  };
  
  # Virtualization
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu;
      swtpm.enable = true;
      ovmf.enable = true;
      runAsRoot = true;
    };
  };
  
  # Essential services
  services.openssh.enable = true;
  
  # Emergency network recovery service - FIXED PATH
  systemd.services.network-emergency = {
    description = "Emergency network recovery";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.bash}/bin/bash /root/emergency-recovery.sh";
      RemainAfterExit = false;
    };
  };
  
  # System packages
  environment.systemPackages = with pkgs; [
    vim git wget curl
    pciutils usbutils
    virt-manager virt-viewer
    bridge-utils iptables
    netcat tcpdump
  ];
  
  # User configuration - adjust as needed
  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" "libvirtd" "kvm" ];
    # Set a password or add SSH keys
    initialPassword = "changeme";
  };
  
  # Enable sudo
  security.sudo.wheelNeedsPassword = false;
  
  # Performance tuning
  boot.kernel.sysctl = {
    "vm.swappiness" = 10;
    "net.ipv4.ip_forward" = 1;
  };
}
