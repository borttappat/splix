{ config, lib, pkgs, modulesPath, ... }:
{
imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

boot.loader.grub.enable = true;
boot.loader.grub.device = "/dev/vda";
boot.loader.timeout = 5;
boot.growPartition = true;

boot.kernelParams = [ 
"console=tty1" 
"console=ttyS0,115200n8" 
];

boot.initrd.availableKernelModules = [
"xhci_pci" "ehci_pci" "ahci" "usbhid" "usb_storage" "sd_mod"
"virtio_balloon" "virtio_blk" "virtio_pci" "virtio_ring"
"virtio_net" "virtio_scsi"
];

fileSystems."/" = {
device = "/dev/disk/by-label/nixos";
autoResize = true;
fsType = "ext4";
};

networking.hostName = "nixos-vm";
networking.usePredictableInterfaceNames = false;
networking.interfaces.eth0.useDHCP = true;
networking.dhcpcd.extraConfig = "noarp";

services.openssh.enable = true;
services.qemuGuest.enable = true;
services.spice-vdagentd.enable = true;

systemd.services."serial-getty@ttyS0" = {
enable = true;
wantedBy = [ "getty.target" ];
};

users.users.root = {
password = "nixos";
openssh.authorizedKeys.keys = [ ];
};

users.users.nixos = {
isNormalUser = true;
password = "nixos";
extraGroups = [ "wheel" ];
};

security.sudo.wheelNeedsPassword = false;

documentation.enable = false;
services.xserver.enable = false;

system.stateVersion = "24.05";
}
