{ config, lib, pkgs, ... }:

{
  imports = [
    <nixpkgs/nixos/modules/profiles/qemu-guest.nix>
  ];

  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/vda";
  
  networking.hostName = "router-vm";
  networking.networkmanager.enable = true;
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 53 80 443 ];
  networking.firewall.allowedUDPPorts = [ 53 67 68 ];
  
  boot.kernel.sysctl = {
    "net.ipv4.conf.all.forwarding" = true;
    "net.ipv6.conf.all.forwarding" = true;
  };
  
  networking.nat = {
    enable = true;
    externalInterface = "wlan0";
    internalInterfaces = [ "enp1s0" ];
  };
  
  services.dnsmasq = {
    enable = true;
    settings = {
      interface = "enp1s0";
      listen-address = "192.168.100.1";
      bind-interfaces = true;
      dhcp-range = "192.168.100.10,192.168.100.100,24h";
      dhcp-option = [
        "option:router,192.168.100.1"
        "option:dns-server,192.168.100.1"
      ];
      server = [ "8.8.8.8" "1.1.1.1" ];
      log-queries = true;
      log-dhcp = true;
    };
  };
  
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "yes";
    };
  };
  
  environment.systemPackages = with pkgs; [
    tcpdump
    wireshark-cli
    iptables
    bridge-utils
    iproute2
    bind.dnsutils
    curl
    wget
    htop
    iftop
  ];
  
  systemd.network.networks."10-wan" = {
    matchConfig.Name = "wlan0";
    networkConfig.DHCP = "yes";
    networkConfig.Priority = 10;
  };
  
  systemd.network.networks."20-lan" = {
    matchConfig.Name = "enp1s0";
    networkConfig.Address = "192.168.100.1/24";
    networkConfig.IPForward = "yes";
  };
  
  system.stateVersion = "24.05";
}
