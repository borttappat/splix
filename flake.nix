{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, nixos-generators, ... }: {
    packages.x86_64-linux = {
      router-vm = nixos-generators.nixosGenerate {
        system = "x86_64-linux";
        modules = [ ./modules/router-vm.nix ];
        format = "qcow";
      };
    };

    nixosConfigurations.router-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./modules/router-host.nix
        /etc/nixos/configuration.nix
        /etc/nixos/hardware-configuration.nix
      ];
    };
  };
}
