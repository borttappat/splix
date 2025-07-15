{
  description = "NixOS VM Router Setup";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      nixosConfigurations = {
        # Option 1: Import from /etc/nixos (for initial testing)
        router-host-import = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            # Import existing system configuration
            /etc/nixos/configuration.nix
            /etc/nixos/hardware-configuration.nix
            
            # VM router TEST configuration (keeps NetworkManager)
            ./modules/vm-router/host-test.nix
            
            # Host-specific configuration with mkForce
            ./hosts/router-host/configuration.nix
          ];
        };

        # Option 2: Standalone configuration (recommended for passthrough)
        router-host = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            # Hardware configuration - generate this or import from /etc/nixos
            /etc/nixos/hardware-configuration.nix
            
            # Complete standalone passthrough configuration
            ./modules/vm-router/host-passthrough-standalone.nix
          ];
        };

        # Router VM configuration
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
