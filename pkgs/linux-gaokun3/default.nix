{
  lib,
  buildLinux,
  fetchurl,
  applyPatches,
  # NixOS's boot.kernelPackages apply function overrides the kernel with these
  # (randstruct seed, boot.kernelPatches, feature set). They must not be named
  # parameters: callPackage would inject pkgs.kernelPatches (the patch-set
  # attrset, not a list) into the first one. Catch them via the argset and
  # merge explicitly instead.
  ...
}@args: let
  pins = import ../../nix/pins.nix;
  series = import ../../nix/lib/patch-series.nix {inherit lib;};

  # Order comes from each directory's series file and nowhere else. The base
  # series is prepended to whatever the caller passes through
  # boot.kernelPatches, so appending a patch cannot displace ours.
  basePatches =
    series "upstream"
    ++ series "others"
    ++ series "himax"
    ++ series "media";

  # dts/ and defconfig/ are owned outright by this repository (not diffs
  # against mainline), so they are copied into the tree instead of carried as
  # patches — see scripts/lib/import_local_sources.sh.
  #
  # The copy has to happen on `src`, not on a postPatch handed to buildLinux:
  # generic.nix builds its configfile derivation with
  # `postPatch = kernel.postPatch + …`, where kernel.postPatch is build.nix's
  # own string. A postPatch passed to buildLinux is neither a parameter nor
  # forwarded, so it would be silently dropped and gaokun3_defconfig would not
  # exist when the config is generated. applyPatches runs its postPatch before
  # both derivations inherit this src, which is what makes the defconfig
  # visible at configuration time.
  src = applyPatches {
    name = "linux-${pins.kernelVersion}-gaokun3-source";

    src = fetchurl {
      url = pins.kernelTarballUrl;
      hash = pins.kernelHash;
    };

    postPatch = ''
      cp ${../../dts}/*.dts ${../../dts}/*.dtsi arch/arm64/boot/dts/qcom/
      cp ${../../defconfig}/gaokun3_defconfig arch/arm64/configs/
    '';
  };
in
  buildLinux (
    {
      pname = "linux-gaokun3";
      version = pins.kernelVersion;
      inherit src;

      # kernelPatches entries carry the series files' order; stdenv applies
      # them with `patch -p1`, the same content `git am` applies on the CI side.
      kernelPatches = basePatches ++ (args.kernelPatches or []);

      # kernel.release is "7.2.0" + CONFIG_LOCALVERSION="-gaokun3".
      modDirVersion = "${pins.kernelVersion}-gaokun3";
      defconfig = "gaokun3_defconfig";

      # nixpkgs' common config now owns the distribution policy; the delta in
      # nix/config/gaokun3-extra.nix re-asserts only what the hardware forces.
      # gaokun3_defconfig stays the base for now, so Gaokun3 values that neither
      # policy mentions survive. Moving the base to the kernel's own defconfig
      # and deleting the fragment is a follow-up that needs the whole fragment
      # reviewed against hardware.
      enableCommonConfig = true;
      structuredExtraConfig = import ../../nix/config/gaokun3-extra.nix {inherit lib;};

      # common-config.nix is written for the kernel nixpkgs ships, so against
      # 7.2.0 some of its options are unused: the Gaokun3 defconfig deliberately
      # leaves other platforms' vendor menus closed and those options live under
      # them (RTW88 under WLAN_VENDOR_REALTEK, SND_AC97 under SND_PCI, ...).
      # NVME_AUTH is the reverse case, where common config asks for "m" and the
      # base has "y". Neither is a mistake in this tree, so the generate-config
      # checks are warnings here; linux-rpi.nix does the same for the same
      # reason. nixpkgs leaves this false on aarch64 so that a typo in
      # structuredExtraConfig is fatal, which is why that delta stays small and
      # reviewed.
      ignoreConfigErrors = true;

      extraMeta = {
        description = "Huawei MateBook E Go 2023 (gaokun3 / SC8280XP) kernel, patched from v${pins.kernelVersion}";
        homepage = "https://github.com/KawaiiHachimi/linux-gaokun-buildbot";
        platforms = lib.platforms.aarch64;
      };
    }
    // (lib.optionalAttrs (args ? randstructSeed) {inherit (args) randstructSeed;})
    // (lib.optionalAttrs (args ? features) {inherit (args) features;})
  )
