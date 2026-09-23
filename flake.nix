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
    # The overlay exposes this flake's own builds rather than packages rebuilt
    # with the consumer's nixpkgs. A stock kernel is the same derivation for
    # everyone on one nixpkgs revision, which is why cache.nixos.org works; a
    # third-party kernel loses that as soon as it is rebuilt against each
    # consumer's nixpkgs. Pinning it to the flake's nixpkgs restores the
    # property: the derivation, and so the cache entry, is fixed by this
    # repository's commit for every consumer.
    overlays.default = final: prev: {
      linux-gaokun3 = self.packages.${prev.system}.linux-gaokun3;
      linuxPackages_gaokun3 = prev.linuxPackagesFor final.linux-gaokun3;
      linux-firmware-gaokun3 = self.packages.${prev.system}.firmware-gaokun3;
      gaokun3-tools = self.packages.${prev.system}.tools-gaokun3;
    };

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
      # The module consumes pkgs.linux-gaokun3 and friends, so the overlay has
      # to be applied for it to evaluate at all. Doing that here keeps
      # `hardware.gaokun3.enable = true` the only line a user writes.
      gaokun3 = { ... }: {
        imports = [ ./nixos/modules/hardware/gaokun3.nix ];
        nixpkgs.overlays = [ self.overlays.default ];
      };
      default = self.nixosModules.gaokun3;
    };
  };
}
