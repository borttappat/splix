{
description = "NixOS VM Router Setup";

inputs = {
nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
flake-utils.url = "github:numtide/flake-utils";
nixos-generators = {
url = "github:nix-community/nixos-generators";
inputs.nixpkgs.follows = "nixpkgs";
};
};

outputs = { self, nixpkgs, flake-utils, nixos-generators, ... }:
let
system = "x86_64-linux";
pkgs = nixpkgs.legacyPackages.${system};
in
{
packages.${system} = {
minimal-vm-qcow = nixos-generators.nixosGenerate {
inherit system;
modules = [ ./modules/minimal-vm-config.nix ];
format = "qcow";
};

router-vm-qcow = nixos-generators.nixosGenerate {
inherit system;
modules = [ ./modules/router-vm-config.nix ];
format = "qcow";
};
};

nixosConfigurations = {
router-host-import = nixpkgs.lib.nixosSystem {
inherit system;
modules = [
/etc/nixos/configuration.nix
/etc/nixos/hardware-configuration.nix
./modules/vm-router/host-test.nix
./hosts/router-host/configuration.nix
];
};

router-host = nixpkgs.lib.nixosSystem {
inherit system;
modules = [
/etc/nixos/hardware-configuration.nix
./modules/vm-router/host-passthrough-standalone.nix
];
};

router-vm = nixpkgs.lib.nixosSystem {
inherit system;
modules = [
./modules/router-vm-config.nix
{
fileSystems."/" = {
device = "/dev/vda";
fsType = "ext4";
};
boot.loader.grub.device = "/dev/vda";
system.stateVersion = "24.05";
}
];
};
};

devShells.${system}.default = pkgs.mkShell {
packages = with pkgs; [
pciutils usbutils iproute2 bridge-utils
qemu qemu-utils libvirt virt-manager
netcat nmap iperf3
git jq
];
};
};
}
