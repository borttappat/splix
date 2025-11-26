{
description = "NixOS VM Router Setup";

inputs = {
nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
nixos-generators = {
url = "github:nix-community/nixos-generators";
inputs.nixpkgs.follows = "nixpkgs";
};
dotfiles = {
url = "github:borttappat/dotfiles";
flake = false;
};
};

outputs = { self, nixpkgs, nixpkgs-unstable, nixos-generators, dotfiles, ... }:
let
system = "x86_64-linux";

# Overlay to make unstable packages available
overlay-unstable = final: prev: {
unstable = import nixpkgs-unstable {
inherit (prev) system;
config.allowUnfree = true;
};
};
in
{
packages.${system} = {
router-vm-qcow = nixos-generators.nixosGenerate {
inherit system;
modules = [ ./modules/router-vm-config.nix ];
format = "qcow";
};

# Pentest VM with basic config
pentest-vm = nixos-generators.nixosGenerate {
inherit system;
modules = [ 
./pentest-vm/pentest-vm-config.nix 
{ nixpkgs.overlays = [ overlay-unstable ]; }
];
format = "qcow";
};

# Pentest VM with complete dotfiles config (working target)
pentest-vm-full = nixos-generators.nixosGenerate {
inherit system;
specialArgs = { inherit dotfiles; };
modules = [ 
./pentest-vm/pentest-vm-config.nix
./pentest-vm/pentest-vm-dotfiles-config.nix
{ nixpkgs.overlays = [ overlay-unstable ]; }
];
format = "qcow";
};
};
};
}
