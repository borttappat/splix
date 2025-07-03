{
  description = "Nixarium - Hardware-Agnostic VM Router Setup";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        packages = {
          routerVM = self.nixosConfigurations.routerVM.config.system.build.qcow2;
        };

        apps = {
          detect = {
            type = "app";
            program = "${pkgs.bash}/bin/bash";
            args = [ "scripts/hardware-detect.sh" ];
          };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            jq
            libvirt
            qemu
            virt-manager
          ];
        };
      }
    ) // {
      nixosConfigurations = {
        routerVM = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./modules/router-vm.nix
          ];
        };

        vmRouter = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./modules/vm-router.nix
          ];
        };
      };
    };
}
