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

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };

  networking = {
    useDHCP = false;
    bridges.br0.interfaces = [];
    interfaces = {
      eth0.useDHCP = true;
      br0 = {
        ipv4.addresses = [{
          address = "192.168.100.1";
          prefixLength = 24;
        }];
      };
    };
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 53 ];
      allowedUDPPorts = [ 53 67 68 ];
      trustedInterfaces = [ "br0" ];
    };
    nat = {
      enable = true;
      externalInterface = "eth0";
      internalInterfaces = [ "br0" ];
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
    tcpdump
    iptables
    bridge-utils
  ];

  system.stateVersion = "24.11";
}
