# modules/base.nix - Base system configuration
{ config, lib, pkgs, ... }:

{
  # System basics
  system.stateVersion = "24.05";
  
  # Boot configuration
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  
  # Network configuration
  networking.hostName = "router-host";
  networking.networkmanager.enable = lib.mkDefault true;
  
  # Timezone and locale
  time.timeZone = "Europe/Stockholm";
  i18n.defaultLocale = "en_US.UTF-8";
  
  # System packages
  environment.systemPackages = with pkgs; [
    git vim wget curl htop tree jq
  ];
  
  # SSH service
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };
  
  # User configuration
  users.users.${realUser} = {
    isNormalUser = true;
    description = "${realUser}";
    extraGroups = [ "networkmanager" "wheel" "libvirtd" "kvm" ];
    packages = with pkgs; [ firefox tree ];
  };
  
  # Sudo configuration
  security.sudo.wheelNeedsPassword = false;
}
