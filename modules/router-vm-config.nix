# Router VM NixOS Configuration
{ config, lib, pkgs, modulesPath, ... }:
{
  # Allow unfree firmware (needed for Intel WiFi)
  nixpkgs.config.allowUnfree = true;

  # ESSENTIAL: Import QEMU guest profile for VM compatibility
  imports = [ 
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  # Essential virtio drivers for VM
  boot.initrd.availableKernelModules = [
    "virtio_balloon" "virtio_blk" "virtio_pci" "virtio_ring"
    "virtio_net" "virtio_scsi"
  ];

  # Console access for virsh console
  boot.kernelParams = [ 
    "console=tty1" 
    "console=ttyS0,115200n8" 
  ];

  # Basic system configuration
  system.stateVersion = "24.05";

  # Networking configuration
  networking = {
    hostName = "router-vm";
    useDHCP = false;
    enableIPv6 = false;
    
    # Use NetworkManager (disable wpa_supplicant)
    networkmanager.enable = true;
    wireless.enable = false;  # Conflicts with NetworkManager
    
    # Enable IP forwarding for routing
    nat = {
      enable = true;
      # We'll configure interfaces after seeing actual names
      # internalInterfaces = [ "eth1" ];  # Bridge interface
      # externalInterface = "enp1s0";   # Passthrough WiFi
    };
    
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 53 ];
      allowedUDPPorts = [ 53 67 68 ];
    };
  };

  # Enable all WiFi firmware
  hardware.enableAllFirmware = true;

  # Essential packages
  environment.systemPackages = with pkgs; [
    pciutils          # lspci command
    usbutils          # lsusb command  
    iw                # WiFi management
    wirelesstools    # iwconfig, etc (fixed typo)
    networkmanager    # Network management
    dhcpcd            # DHCP client
    iptables          # Firewall rules
    bridge-utils      # Bridge management
    tcpdump           # Network debugging
    nettools          # netstat, etc
    nano              # Text editor
  ];

  # VM services
  services.qemuGuest.enable = true;
  services.spice-vdagentd.enable = true;

  # SSH for management
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = true;  # For easier debugging
  };

  # Auto-login for console access
  services.getty.autologinUser = "router";

  # Create router user
  users.users.router = {
    isNormalUser = true;
    password = "router";  # Temporary for debugging
    extraGroups = [ "wheel" "networkmanager" ];
  };
}
