{ config, lib, pkgs, modulesPath, ... }:
{
  nixpkgs.config.allowUnfree = true;

  hardware.firmware = with pkgs; [
    linux-firmware
    (pkgs.stdenv.mkDerivation {
      pname = "intel-be201-firmware";
      version = "2024";
      src = pkgs.linux-firmware;
      installPhase = ''
        mkdir -p $out/lib/firmware
        cp -r lib/firmware/iwlwifi-* $out/lib/firmware/
      '';
    })
  ];

  imports = [ 
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  boot.initrd.availableKernelModules = [
    "virtio_balloon" "virtio_blk" "virtio_pci" "virtio_ring"
    "virtio_net" "virtio_scsi"
  ];

  boot.kernelParams = [ 
    "console=tty1" 
    "console=ttyS0,115200n8" 
  ];

  system.stateVersion = "25.05";

  networking = {
    hostName = "router-vm";
    useDHCP = false;
    enableIPv6 = false;
    
    networkmanager.enable = true;
    wireless.enable = false;
    
    interfaces.enp1s0 = {
      ipv4.addresses = [{
        address = "192.168.100.253";
        prefixLength = 24;
      }];
    };
    
    interfaces.enp2s0 = {
      ipv4.addresses = [{
        address = "192.168.101.253";
        prefixLength = 24;
      }];
    };
    
    interfaces.enp3s0 = {
      ipv4.addresses = [{
        address = "192.168.102.253";
        prefixLength = 24;
      }];
    };
    
    nat = {
      enable = true;
      externalInterface = "wlp5s0";
      internalInterfaces = [ "enp1s0" "enp2s0" "enp3s0" ];
    };
    
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 53 ];
      allowedUDPPorts = [ 53 67 68 ];
      extraCommands = ''
        iptables -t nat -A POSTROUTING -s 192.168.100.0/24 -o wlp5s0 -j MASQUERADE
        iptables -t nat -A POSTROUTING -s 192.168.101.0/24 -o wlp5s0 -j MASQUERADE
        iptables -t nat -A POSTROUTING -s 192.168.102.0/24 -o wlp5s0 -j MASQUERADE
        
        iptables -A FORWARD -i enp1s0 -o wlp5s0 -j ACCEPT
        iptables -A FORWARD -i enp2s0 -o wlp5s0 -j ACCEPT
        iptables -A FORWARD -i enp3s0 -o wlp5s0 -j ACCEPT
        
        iptables -A FORWARD -i wlp5s0 -o enp1s0 -m state --state RELATED,ESTABLISHED -j ACCEPT
        iptables -A FORWARD -i wlp5s0 -o enp2s0 -m state --state RELATED,ESTABLISHED -j ACCEPT
        iptables -A FORWARD -i wlp5s0 -o enp3s0 -m state --state RELATED,ESTABLISHED -j ACCEPT
        
        iptables -A FORWARD -i enp1s0 -o enp2s0 -j ACCEPT
        iptables -A FORWARD -i enp2s0 -o enp1s0 -j ACCEPT
        iptables -A FORWARD -i enp1s0 -o enp3s0 -j ACCEPT
        iptables -A FORWARD -i enp3s0 -o enp1s0 -j ACCEPT
        iptables -A FORWARD -i enp2s0 -o enp3s0 -j ACCEPT
        iptables -A FORWARD -i enp3s0 -o enp2s0 -j ACCEPT
      '';
    };
  };

  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.forwarding" = 1;
  };

  boot.kernelPackages = pkgs.linuxPackages_latest;

  hardware.enableAllFirmware = true;
  hardware.enableRedistributableFirmware = true;

  environment.systemPackages = with pkgs; [
    pciutils usbutils iw wirelesstools networkmanager
    dhcpcd iptables bridge-utils tcpdump nettools nano
  ];

  services.qemuGuest.enable = true;
  services.spice-vdagentd.enable = true;

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = true;
  };

  services.getty.autologinUser = "router";

  users.users.router = {
    isNormalUser = true;
    password = "router";
    extraGroups = [ "wheel" "networkmanager" ];
  };
}
