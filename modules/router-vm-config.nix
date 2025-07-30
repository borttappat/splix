# User-customizable router VM configuration
# This file is NEVER overwritten by the generator
{ config, pkgs, lib, ... }:

{
  imports = [
    ./router-vm-hardware.nix  # Hardware-specific generated config
  ];

  # User customizations - edit freely
  networking.hostName = "router-vm";
  
  # Essential packages - add/remove as needed
  environment.systemPackages = with pkgs; [
    # Hardware detection tools
    pciutils
    usbutils
    lshw
    
    # Network tools
    iproute2
    bridge-utils
    iptables
    tcpdump
    
    # WiFi essentials
    iw
    wireless-tools
    wpa_supplicant
    
    # System tools
    vim
    tmux
    htop
    curl
    wget
    
    # Network management
    networkmanager
  ];

  # WiFi configuration
  hardware.enableRedistributableFirmware = true;
  networking.wireless.enable = false; # Use NetworkManager instead
  
  # NetworkManager configuration
  networking.networkmanager = {
    enable = true;
    unmanaged = [ "eth0" ];
  };

  # User account
  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    password = "admin";
  };

  # Sudo configuration
  security.sudo.extraRules = [{
    users = [ "admin" ];
    commands = [{
      command = "ALL";
      options = [ "NOPASSWD" ];
    }];
  }];
  
  # Auto-login for testing
  services.getty.autologinUser = "admin";
  
  system.stateVersion = "24.05";
}
