{
description = "NixOS VM Router Setup";

inputs = {
nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
nixos-generators = {
url = "github:nix-community/nixos-generators";
inputs.nixpkgs.follows = "nixpkgs";
};
};

outputs = { self, nixpkgs, nixos-generators, ... }:
let
system = "x86_64-linux";
in
{
packages.${system} = {
router-vm-qcow = nixos-generators.nixosGenerate {
inherit system;
modules = [ 
  (if builtins.pathExists ./generated/temp/router-vm-config.nix 
   then ./generated/temp/router-vm-config.nix 
   else ./modules/router-vm-config.nix)
];
format = "qcow";
};
};
};
}
