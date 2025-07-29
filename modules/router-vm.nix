{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    "${toString modulesPath}/profiles/qemu-guest.nix"
    "${toString modulesPath}/profiles/minimal.nix"
  ];

  boot.initrd.availableKernelModules = [ 
    "virtio_pci" "virtio_blk" "virtio_scsi" "virtio_net" "virtio_balloon"
    "9p" "9pnet_virtio"
  ];
  
  boot.kernelModules = [ "virtio_balloon" "virtio_console" ];
  boot.loader.grub.device = "/dev/vda";
  boot.loader.timeout = 1;

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };

  systemd.network.enable = true;
  networking.networkmanager.enable = false;
  networking.useDHCP = false;

  systemd.network = {
    enable = true;
    
    networks."10-eth0" = {
      matchConfig.Name = "eth0";
      networkConfig.DHCP = "yes";
      networkConfig.IPv6AcceptRA = true;
    };

    networks."20-wlan0" = {
      matchConfig.Name = "wlan0";
      networkConfig.DHCP = "yes";
      bridge = [ "br0" ];
    };

    netdevs."br0" = {
      netdevConfig = {
        Name = "br0";
        Kind = "bridge";
      };
    };

    networks."30-br0" = {
      matchConfig.Name = "br0";
      networkConfig = {
        DHCP = "no";
        IPForward = "yes";
        IPv6AcceptRA = false;
      };
      addresses = [
        {
          addressConfig.Address = "192.168.100.1/24";
        }
      ];
    };
  };

  services.hostapd = {
    enable = true;
    radios.wlan0 = {
      band = "2g";
      channel = 6;
      networks.wlan0 = {
        ssid = "RouterVM";
        authentication = {
          mode = "wpa2-sha256";
          wpaPassword = "changeme123";
        };
        bssid = "02:00:00:00:00:00";
      };
    };
  };

  services.dnsmasq = {
    enable = true;
    settings = {
      interface = "br0";
      dhcp-range = [ "192.168.100.100,192.168.100.200,12h" ];
      dhcp-option = [ "option:router,192.168.100.1" ];
      server = [ "1.1.1.1" "8.8.8.8" ];
    };
  };

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 53 ];
    allowedUDPPorts = [ 53 67 68 ];
    trustedInterfaces = [ "br0" ];
  };

  networking.nat = {
    enable = true;
    externalInterface = "eth0";
    internalInterfaces = [ "br0" ];
  };

  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    password = "admin";
  };

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
  };

  environment.systemPackages = with pkgs; [
    htop
    iw
    wireless-tools
    tcpdump
    iptables
    bridge-utils
  ];

  system.stateVersion = "24.11";
}
