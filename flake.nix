{
  description = "NixOS support for the Huawei MateBook E Go 2023 (gaokun3 / Qualcomm SC8280XP)";

  # Honoured only when this flake is the top-level flake, e.g. a direct
  # `nix build github:KawaiiHachimi/linux-gaokun-buildbot` (which needs
  # --accept-flake-config unless the user is trusted). Someone who takes this
  # as an input has to configure the cache themselves, through the module's
  # hardware.gaokun3.binaryCache or nix.conf; see README.
  nixConfig = {
    extra-substituters = ["https://gaokun3.cachix.org"];
    extra-trusted-public-keys = ["gaokun3.cachix.org-1:ikL6EofK55QEwKucrUo44SPKewscvAMJr7ibBxJtIsI="];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    lib = nixpkgs.lib;
    systems = ["aarch64-linux" "x86_64-linux"];
    forAllSystems = lib.genAttrs systems;

    # linux-firmware-gaokun3 is redistributable but not modifiable, so a stock
    # nixpkgs refuses to evaluate it. Allow that one name for this flake's own
    # outputs; users of the module need the same predicate in their own
    # configuration, which README documents.
    allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) ["linux-firmware-gaokun3"];

    pkgsFor = system:
      import nixpkgs {
        inherit system;
        config.allowUnfreePredicate = allowUnfreePredicate;
      };

    # The kernel has to run on aarch64; on an x86_64 builder it is
    # cross-compiled, on aarch64 it builds natively.
    kernelPkgsFor = system:
      if system == "aarch64-linux"
      then pkgsFor system
      else
        import nixpkgs {
          system = "x86_64-linux";
          crossSystem = {system = "aarch64-linux";};
          config.allowUnfreePredicate = allowUnfreePredicate;
        };
  in {
    packages = forAllSystems (system: {
      linux-gaokun3 = (kernelPkgsFor system).callPackage ./pkgs/linux-gaokun3 {};
      firmware-gaokun3 = (pkgsFor system).callPackage ./pkgs/firmware-gaokun3 {};
      tools-gaokun3 = (pkgsFor system).callPackage ./pkgs/tools-gaokun3 {};
      default = self.packages.${system}.linux-gaokun3;
    });

    checks = forAllSystems (system:
      import ./checks {
        inherit self lib system allowUnfreePredicate;
        pkgs = pkgsFor system;
      });

    nixosModules = {
      gaokun3 = import ./nixos/modules/hardware/gaokun3.nix;
      default = self.nixosModules.gaokun3;
    };
  };
}
