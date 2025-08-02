{ config, pkgs, lib, ... }:

{
  imports = [ ];

  # Essential boot configuration for VM
  boot.loader.grub = {
    enable = true;
    device = "/dev/vda";
  };
  boot.loader.timeout = lib.mkDefault 1;
  
  boot.initrd.availableKernelModules = [ "ahci" "xhci_pci" "virtio_pci" "sr_mod" "virtio_blk" ];
  boot.kernelModules = [ "kvm-intel" "af_packet" ];

  # File systems - use label for flexibility
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };

  # Network configuration - Router mode
  networking = {
    hostName = "router-vm";
    useDHCP = false;
    
    # Test interface for QEMU user networking
    interfaces.eth0 = {
      useDHCP = true;
    };
    
    # WAN interface (for when WiFi is passed through)
    interfaces.wlan0 = {
      useDHCP = lib.mkDefault true;
    };

    # Enable forwarding and NAT
    nat = {
      enable = true;
      externalInterface = "wlan0";
      internalInterfaces = [ "eth0" ];
    };
    
    firewall = {
      enable = true;
      trustedInterfaces = [ "eth0" ];
      allowPing = true;
    };
  };

  # DHCP and DNS services
  services.dnsmasq = {
    enable = true;
    settings = {
      interface = "eth0";
      dhcp-range = "192.168.100.50,192.168.100.150,12h";
      dhcp-option = [
        "option:router,192.168.100.2"
        "option:dns-server,192.168.100.2"
      ];
      server = [ "8.8.8.8" "8.8.4.4" ];
      cache-size = 1000;
    };
  };

  # Essential packages for hardware detection and WiFi
  environment.systemPackages = with pkgs; [
    pciutils
    usbutils
    lshw
    iproute2
    bridge-utils
    iptables
    tcpdump
    iw
    wpa_supplicant
    vim
    tmux
    htop
    networkmanager
  ];

  # Enable NetworkManager for WiFi management
  hardware.enableRedistributableFirmware = true;
  networking.wireless.enable = false;

  networking.networkmanager = {
    enable = true;
    unmanaged = [ "eth0" ];
  };

  # User configuration
  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    password = "admin";
  };

  # Allow passwordless sudo for admin user
  security.sudo.extraRules = [{
    users = [ "admin" ];
    commands = [{
      command = "ALL";
      options = [ "NOPASSWD" ];
    }];
  }];
  
  # Enable getty autologin for testing
  services.getty.autologinUser = "admin";
  
  # VM specific configuration for testing
  virtualisation.vmVariant = {
    virtualisation = {
      memorySize = 2048;
      cores = 2;
      graphics = false;
      qemu.options = [
        "-nographic"
        "-serial mon:stdio"
      ];
    };
  };

  system.stateVersion = "24.05";
}
