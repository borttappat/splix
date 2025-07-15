# hosts/router-host/configuration.nix - Host-specific configuration
{ config, lib, pkgs, ... }:

{
  # Host-specific settings - use mkForce to override /etc/nixos
  networking.hostName = lib.mkForce "router-host";
  
  # Additional packages for this host
  environment.systemPackages = with pkgs; [
    virt-manager virt-viewer bridge-utils iptables
    netcat wireshark tcpdump
  ];
  
  # Firewall configuration
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 16509 5900 5901 ];
    allowedUDPPorts = [ 67 68 ];
    trustedInterfaces = [ "virbr0" "virbr1" ];
  };
  
  # Performance optimizations for virtualization
  boot.kernel.sysctl = {
    "vm.swappiness" = 10;
    "net.core.rmem_max" = 134217728;
    "net.core.wmem_max" = 134217728;
  };
  
  # Virtualization support for VM router
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu;
      swtpm.enable = true;
      ovmf.enable = true;
    };
  };
}
