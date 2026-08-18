{
  description = "NixOS support for the Huawei MateBook E Go 2023 (gaokun3 / Qualcomm SC8280XP)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
    }: let
      systems = ["aarch64-linux" "x86_64-linux"];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      pkgsFor = system: import nixpkgs {inherit system;};

      # The kernel has to run on aarch64; on an x86_64 builder it is
      # cross-compiled, on aarch64 it builds natively.
      kernelPkgsFor = system:
        if system == "aarch64-linux"
        then pkgsFor system
        else
          import nixpkgs {
            system = "x86_64-linux";
            crossSystem = {system = "aarch64-linux";};
          };
    in {
      packages = forAllSystems (system: {
        linux-gaokun3 = (kernelPkgsFor system).callPackage ./pkgs/linux-gaokun3 {};
        firmware-gaokun3 = (pkgsFor system).callPackage ./pkgs/firmware-gaokun3 {};
        tools-gaokun3 = (pkgsFor system).callPackage ./pkgs/tools-gaokun3 {};
        default = self.packages.${system}.linux-gaokun3;
      });

      nixosModules = {
        gaokun3 = import ./nixos/modules/hardware/gaokun3.nix;
        default = self.nixosModules.gaokun3;
      };
    };
}
