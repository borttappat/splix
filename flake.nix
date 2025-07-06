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
      # NixOS configurations
      nixosConfigurations = {
        # VM Router Host configuration
        router-host = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            # Import local hardware config
            ./hosts/router-host/hardware-configuration.nix
            
            # Base system configuration
            ./modules/base.nix
            
            # VM router passthrough configuration
            ./modules/vm-router/host-passthrough.nix
            
            # Host-specific configuration
            ./hosts/router-host/configuration.nix
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

      # Packages for building VM images
      packages.${system} = {
        router-vm-image = self.nixosConfigurations.router-vm.config.system.build.qcow2;
      };

      # Development shell
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          pciutils usbutils iproute2 bridge-utils
          qemu libvirt virt-manager
          netcat nmap iperf3
          git jq
        ];
        
        shellHook = ''
          echo "NixOS VM Router Development Environment"
          echo "Commands:"
          echo "  nix build .#router-vm-image - Build router VM"
          echo "  nixos-rebuild switch --flake .#router-host - Apply config"
          echo "  emergency-network - Emergency network recovery"
        '';
      };
    };
}
