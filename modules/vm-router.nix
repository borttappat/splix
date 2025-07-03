{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.vm-router;
in

{
  options.services.vm-router = {
    enable = mkEnableOption "VM Router with WiFi passthrough";
    
    vmName = mkOption {
      type = types.str;
      default = "router-vm";
      description = "Name of the router VM";
    };
    
    enableMonitoring = mkOption {
      type = types.bool;
      default = true;
      description = "Enable automatic VM monitoring and recovery";
    };
  };
  
  config = mkIf cfg.enable {
    virtualisation.libvirtd.enable = true;
    virtualisation.libvirtd.qemu.ovmf.enable = true;
    virtualisation.libvirtd.qemu.ovmf.packages = [ pkgs.OVMF ];
    
    networking.networkmanager.enable = mkForce false;
    networking.useNetworkd = true;
    networking.firewall.enable = false;
    
    environment.systemPackages = with pkgs; [
      virt-manager
      virt-viewer
      spice
      spice-gtk
      spice-protocol
    ];
    
    users.groups.libvirtd = {};
  };
}
