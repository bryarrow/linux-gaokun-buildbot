{
  lib,
  buildLinux,
  fetchurl,
  applyPatches,
  # The experimental variant where Linux runs as a guest on the vendor
  # hypervisor. It is the same tree with patches/el2 on top and its own
  # LOCALVERSION; pkgs/linux-gaokun3-el2 wraps this file with it set.
  el2 ? false,
  # NixOS's boot.kernelPackages apply function overrides the kernel with these
  # (randstruct seed, boot.kernelPatches, feature set). They must not be named
  # parameters: callPackage would inject pkgs.kernelPatches (the patch-set
  # attrset, not a list) into the first one. Catch them via the argset and
  # merge explicitly instead.
  ...
}@args: let
  pins = import ../../nix/pins.nix;
  series = import ../../nix/lib/patch-series.nix {inherit lib;};

  # kernel.release is <version> + CONFIG_LOCALVERSION, and the module directory
  # has to match it.
  localVersion = "-gaokun3" + lib.optionalString el2 "-el2";

  # Order comes from each directory's series file and nowhere else. The base
  # series is prepended to whatever the caller passes through
  # boot.kernelPatches, so appending a patch cannot displace ours. patches/el2
  # goes last, so it applies on top of the tree the other five directories
  # produced.
  basePatches =
    series "upstream"
    ++ series "others"
    ++ series "camera"
    ++ series "himax"
    ++ series "media"
    ++ lib.optionals el2 (series "el2");

  # dts/ is owned outright by this repository (not a diff against mainline), so
  # it is copied into the tree instead of carried as a patch.
  #
  # The copy has to happen on `src`, not on a postPatch handed to buildLinux:
  # generic.nix builds its configfile derivation with
  # `postPatch = kernel.postPatch + …`, where kernel.postPatch is build.nix's
  # own string. A postPatch passed to buildLinux is neither a parameter nor
  # forwarded, so it would be silently dropped and the board device tree would
  # not exist when the source is configured. applyPatches runs its postPatch
  # before both derivations inherit this src.
  src = applyPatches {
    name = "linux-${pins.kernelVersion}-gaokun3-source";

    src = fetchurl {
      url = pins.kernelTarballUrl;
      hash = pins.kernelHash;
    };

    postPatch = ''
      cp ${../../dts}/*.dts ${../../dts}/*.dtsi arch/arm64/boot/dts/qcom/
    '';
  };
in
  buildLinux (
    {
      pname = "linux-gaokun3" + lib.optionalString el2 "-el2";
      version = pins.kernelVersion;
      inherit src;

      # kernelPatches entries carry the series files' order; stdenv applies
      # them with `patch -p1`, the same content `git am` applies on the CI side.
      kernelPatches = basePatches ++ (args.kernelPatches or []);

      # kernel.release is "7.2.0" + CONFIG_LOCALVERSION, which the extra config
      # below sets; the module directory has to match it.
      modDirVersion = "${pins.kernelVersion}${localVersion}";

      # The kernel's own arm64 defconfig plus nixpkgs' common config is the
      # distribution policy; nix/config/gaokun3-extra.nix is the reviewed
      # Gaokun deviation.
      defconfig = "defconfig";
      enableCommonConfig = true;
      # The variant is the same distribution policy, so the reviewed deviation is
      # imported unchanged and only LOCALVERSION is restated: it is what makes
      # the module directory, and so the boot entry, distinct.
      structuredExtraConfig =
        (import ../../nix/config/gaokun3-extra.nix {inherit lib;})
        // {LOCALVERSION = {freeform = localVersion;};};

      # generate-config.pl's checks stay at their defaults, so an option that
      # does not land fails the build instead of vanishing into a log line.
      # nix/config/gaokun3-extra.nix declares the one unreachable symbol (IMA,
      # which INTEGRITY=n makes invisible) optional, which is what makes them
      # pass. ignoreConfigErrors is deliberately not set: as a global switch it
      # would hide real conflicts along with the unreachable ones.
      extraMeta = {
        description = "Huawei MateBook E Go 2023 (gaokun3 / SC8280XP) kernel, patched from v${pins.kernelVersion}"
          + lib.optionalString el2 " (EL2 guest variant)";
        homepage = "https://github.com/bryarrow/linux-gaokun-buildbot";
        platforms = lib.platforms.aarch64;
      };
    }
    // (lib.optionalAttrs (args ? randstructSeed) {inherit (args) randstructSeed;})
    // (lib.optionalAttrs (args ? features) {inherit (args) features;})
  )
