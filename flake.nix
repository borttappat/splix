{
  description = "NixOS VM Router Setup";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
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
      nixosConfigurations = {
        router-host = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            /etc/nixos/hardware-configuration.nix
            ./modules/vm-router/host-passthrough.nix
          ];
        };

        router-vm = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            ./modules/router-vm-config.nix
            "${toString nixpkgs}/nixos/modules/profiles/qemu-guest.nix"
            {
              fileSystems."/" = {
                device = "/dev/disk/by-label/nixos";
                fsType = "ext4";
                autoResize = true;
              };
              boot.growPartition = true;
              boot.loader.grub.device = "/dev/vda";
              boot.loader.timeout = 0;
              system.stateVersion = "24.05";
            }
          ];
        };
      };

      packages.${system} = {
        router-vm-image = nixos-generators.nixosGenerate {
          system = "x86_64-linux";
          modules = [
            ./modules/router-vm-config.nix
            "${toString nixpkgs}/nixos/modules/profiles/qemu-guest.nix"
            {
              virtualisation.diskSize = 20 * 1024;
              boot.growPartition = true;
              boot.kernelParams = ["console=ttyS0"];
              boot.loader.grub.device = "/dev/vda";
              boot.loader.timeout = 0;
              fileSystems."/" = {
                device = "/dev/disk/by-label/nixos";
                fsType = "ext4";
                autoResize = true;
              };
              services.qemuGuest.enable = true;
              system.stateVersion = "24.05";
            }
          ];
          format = "qcow2";
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
