{ config, lib, pkgs, modulesPath, ... }:
{
  nixpkgs.config.allowUnfree = true;

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

    interfaces.enp4s0 = {
      ipv4.addresses = [{
        address = "192.168.103.253";
        prefixLength = 24;
      }];
    };

    interfaces.enp5s0 = {
      ipv4.addresses = [{
        address = "192.168.104.253";
        prefixLength = 24;
      }];
    };
    
    nat = {
      enable = true;
      externalInterface = "";
      internalInterfaces = [ "enp1s0" "enp2s0" "enp3s0" "enp4s0" "enp5s0" ];
    };
    
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 53 ];
      allowedUDPPorts = [ 53 67 68 ];
    };
  };

  systemd.services.wifi-detect-and-configure = {
    description = "Detect WiFi interface and configure NAT";
    after = [ "network.target" ];
    before = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      WIFI_IFACE=$(ls /sys/class/net/ | grep -E '^wl' | head -1)
      if [ -z "$WIFI_IFACE" ]; then
        echo "ERROR: No WiFi interface found!"
        exit 1
      fi
      echo "Found WiFi interface: $WIFI_IFACE"
      
      # Clear existing NAT rules
      ${pkgs.iptables}/bin/iptables -t nat -F POSTROUTING
      ${pkgs.iptables}/bin/iptables -F FORWARD
      
      # NAT rules for all networks to WiFi
      ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s 192.168.100.0/24 -o "$WIFI_IFACE" -j MASQUERADE
      ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s 192.168.101.0/24 -o "$WIFI_IFACE" -j MASQUERADE
      ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s 192.168.102.0/24 -o "$WIFI_IFACE" -j MASQUERADE
      ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s 192.168.103.0/24 -o "$WIFI_IFACE" -j MASQUERADE
      ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s 192.168.104.0/24 -o "$WIFI_IFACE" -j MASQUERADE
      
      # SMART BRIDGES (virbr1, virbr2, virbr3) - Full connectivity
      # Host management network
      ${pkgs.iptables}/bin/iptables -A FORWARD -i enp1s0 -o "$WIFI_IFACE" -j ACCEPT
      ${pkgs.iptables}/bin/iptables -A FORWARD -i "$WIFI_IFACE" -o enp1s0 -m state --state RELATED,ESTABLISHED -j ACCEPT
      
      # Smart guest networks - allow inter-VM communication + internet
      ${pkgs.iptables}/bin/iptables -A FORWARD -i enp2s0 -o "$WIFI_IFACE" -j ACCEPT
      ${pkgs.iptables}/bin/iptables -A FORWARD -i "$WIFI_IFACE" -o enp2s0 -m state --state RELATED,ESTABLISHED -j ACCEPT
      ${pkgs.iptables}/bin/iptables -A FORWARD -i enp2s0 -o enp3s0 -j ACCEPT
      ${pkgs.iptables}/bin/iptables -A FORWARD -i enp3s0 -o enp2s0 -j ACCEPT
      
      ${pkgs.iptables}/bin/iptables -A FORWARD -i enp3s0 -o "$WIFI_IFACE" -j ACCEPT
      ${pkgs.iptables}/bin/iptables -A FORWARD -i "$WIFI_IFACE" -o enp3s0 -m state --state RELATED,ESTABLISHED -j ACCEPT
      
      # DUMB BRIDGES (virbr4, virbr5) - Internet-only, no inter-VM communication
      # Internet access only - no communication between VMs or with smart networks
      ${pkgs.iptables}/bin/iptables -A FORWARD -i enp4s0 -o "$WIFI_IFACE" -j ACCEPT
      ${pkgs.iptables}/bin/iptables -A FORWARD -i "$WIFI_IFACE" -o enp4s0 -m state --state RELATED,ESTABLISHED -j ACCEPT
      ${pkgs.iptables}/bin/iptables -A FORWARD -i enp4s0 -o enp2s0 -j DROP
      ${pkgs.iptables}/bin/iptables -A FORWARD -i enp4s0 -o enp3s0 -j DROP
      ${pkgs.iptables}/bin/iptables -A FORWARD -i enp4s0 -o enp5s0 -j DROP
      
      ${pkgs.iptables}/bin/iptables -A FORWARD -i enp5s0 -o "$WIFI_IFACE" -j ACCEPT
      ${pkgs.iptables}/bin/iptables -A FORWARD -i "$WIFI_IFACE" -o enp5s0 -m state --state RELATED,ESTABLISHED -j ACCEPT
      ${pkgs.iptables}/bin/iptables -A FORWARD -i enp5s0 -o enp2s0 -j DROP
      ${pkgs.iptables}/bin/iptables -A FORWARD -i enp5s0 -o enp3s0 -j DROP
      ${pkgs.iptables}/bin/iptables -A FORWARD -i enp5s0 -o enp4s0 -j DROP
      
      echo "Network configuration complete:"
      echo "  SMART: virbr1 (host), virbr2-3 (guest networks with inter-VM communication)"
      echo "  DUMB:  virbr4-5 (isolated guest networks, internet-only)"
    '';
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
    dnsmasq
  ];

  services.qemuGuest.enable = true;
  services.spice-vdagentd.enable = true;

services.dnsmasq = {
  enable = true;
  settings = {
    # Serve DHCP on all guest networks
    interface = ["enp2s0" "enp3s0" "enp4s0" "enp5s0"];
    dhcp-range = [
      # SMART networks - normal DHCP ranges
      "enp2s0,192.168.101.10,192.168.101.100,24h"
      "enp3s0,192.168.102.10,192.168.102.100,24h"
      # DUMB networks - isolated DHCP ranges  
      "enp4s0,192.168.103.10,192.168.103.100,24h"
      "enp5s0,192.168.104.10,192.168.104.100,24h"
    ];
    dhcp-option = [
      # SMART networks - standard options
      "enp2s0,option:router,192.168.101.253"
      "enp2s0,option:dns-server,192.168.101.253"
      "enp3s0,option:router,192.168.102.253"
      "enp3s0,option:dns-server,192.168.102.253"
      # DUMB networks - same router/DNS but firewalled
      "enp4s0,option:router,192.168.103.253"
      "enp4s0,option:dns-server,192.168.103.253"
      "enp5s0,option:router,192.168.104.253"
      "enp5s0,option:dns-server,192.168.104.253"
    ];
    # Upstream DNS servers
    server = ["8.8.8.8" "1.1.1.1"];
    bind-interfaces = true;
    log-dhcp = true;
    log-queries = true;
  };
};

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = __SSH_PASSWORD_AUTH__;
  };

  services.getty.autologinUser = "{{ROUTER_USER}}";

  users.users.{{ROUTER_USER}} = {
    isNormalUser = true;
    password = "{{ROUTER_PASSWORD}}";
    extraGroups = [ "wheel" "networkmanager" ];
    {{SSH_KEYS_CONFIG}}
  };
}
