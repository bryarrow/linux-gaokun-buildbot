{
  description = "NixOS support for the Huawei MateBook E Go 2023 (gaokun3 / Qualcomm SC8280XP)";

  # Honoured only when this flake is the top-level flake, e.g. a direct
  # `nix build github:bryarrow/linux-gaokun-buildbot` (which needs
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

    # The installation medium: stock NixOS' minimal installer profile, made to
    # boot this board by hardware.gaokun3 (kernel, device tree, command line)
    # and by nixos/installer.nix, which replaces the stock GRUB EFI image with a
    # systemd-boot ESP carrying the device tree. aarch64 only, because both the
    # kernel and the module are.
    installerFor = system:
      if system != "aarch64-linux"
      then null
      else
        lib.nixosSystem {
          inherit system;
          modules = [
            "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
            self.nixosModules.gaokun3
            ./nixos/installer.nix
            ({lib, ...}: {
              nixpkgs.config.allowUnfreePredicate = allowUnfreePredicate;
              hardware.gaokun3.enable = true;
              # profiles/base.nix turns ZFS on by default; linux-gaokun3 has no
              # zfs or cifs module, and nixpkgs marks zfs-kernel broken against
              # this kernel, so the installer's initrd must not ask for them.
              # It needs neither to write a NixOS install.
              boot.supportedFilesystems.zfs = lib.mkForce false;
              boot.supportedFilesystems.cifs = lib.mkForce false;
              # Otherwise every image this flake makes is called
              # nixos-minimal-...; the edition is what lands in the file name.
              isoImage.edition = "gaokun3";
            })
          ];
        };

    # One evaluation of the medium, shared by the package and the checks below.
    # It is lazy, so systems that do not build the installer never force it.
    installer = installerFor "aarch64-linux";
  in {
    # See overlays/default.nix: the names point at this flake's own builds so
    # that every consumer gets the same derivations, and with them the same
    # binary cache entries, rather than one rebuild per consumer nixpkgs.
    overlays.default = import ./overlays {inherit self;};

    packages = forAllSystems (system:
      {
        linux-gaokun3 = (kernelPkgsFor system).callPackage ./pkgs/linux-gaokun3 {};
        linux-gaokun3-el2 = (kernelPkgsFor system).callPackage ./pkgs/linux-gaokun3-el2 {};
        firmware-gaokun3 = (pkgsFor system).callPackage ./pkgs/firmware-gaokun3 {};
        tools-gaokun3 = (pkgsFor system).callPackage ./pkgs/tools-gaokun3 {};
        alsa-ucm-conf-gaokun3 = (pkgsFor system).callPackage ./pkgs/alsa-ucm-conf-gaokun3 {};
        # Deliberately not the kernel: `nix build .` should not start a one to
        # three hour compile.
        default = self.packages.${system}.firmware-gaokun3;
      }
      // lib.optionalAttrs (system == "aarch64-linux") {
        # `nix build .#installer-iso`; dd the result to a USB stick and boot the
        # device from it. The live system is the stock minimal installer with
        # this flake's kernel, device tree and command line, so it can install
        # NixOS on the internal disk without any Fedora artifact.
        installer-iso = installer.config.system.build.isoImage;
      });

    checks = forAllSystems (system:
      import ./checks {
        inherit self lib system allowUnfreePredicate;
        pkgs = pkgsFor system;
        # Only evaluated for aarch64; null elsewhere.
        installer =
          if system == "aarch64-linux"
          then installer
          else null;
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
