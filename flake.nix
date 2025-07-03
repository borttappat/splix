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
          echo "  nixos-rebuild switch --flake .#router-host - Apply config"
          echo "  emergency-network - Emergency network recovery"
        '';
      };
    };
}
