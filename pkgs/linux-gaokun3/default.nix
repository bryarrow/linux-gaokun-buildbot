{
  lib,
  stdenv,
  buildLinux,
  fetchurl,
  # NixOS's boot.kernelPackages apply function overrides the kernel with these
  # (randstruct seed, boot.kernelPatches, feature set). They must not be named
  # parameters: callPackage would inject pkgs.kernelPatches (the patch-set
  # attrset, not a list) into the first one. Catch them via the argset and
  # forward explicitly instead.
  ...
}@args: let
  version = "7.2.0-rc2";

  # The patch series is git format-patch output; mkDerivation applies them with
  # `patch -p1` in list order, the same content `git am` applies on the CI side.
  patchFiles = dir:
    builtins.map (n: "${../../patches}/${dir}/${n}") (
      builtins.sort builtins.lessThan (builtins.attrNames (builtins.readDir ../../patches/${dir}))
    );

  # dts/ and defconfig/ are owned outright by this repository (not diffs against
  # mainline), so they are copied into the tree instead of carried as patches —
  # see scripts/lib/import_local_sources.sh.
  src = stdenv.mkDerivation {
    pname = "linux-gaokun3-src";
    inherit version;

    src = fetchurl {
      url = "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/snapshot/v7.2-rc2.tar.gz";
      sha256 = "1xgz858gjbfczcgrrdrzyf9rndd7n5b9xiy2x22vxl46cjs12awm";
    };

    patches = patchFiles "upstream" ++ patchFiles "others";

    postPatch = ''
      cp ${../../dts}/*.dts ${../../dts}/*.dtsi arch/arm64/boot/dts/qcom/
      cp ${../../defconfig}/gaokun3_defconfig arch/arm64/configs/
    '';

    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -a . $out/
      runHook postInstall
    '';
  };
in
  buildLinux (
    {
      pname = "linux-gaokun3";
      inherit version src;

      # kernel.release is "7.2.0-rc2" + CONFIG_LOCALVERSION="-gaokun3".
      modDirVersion = "${version}-gaokun3";
      defconfig = "gaokun3_defconfig";
      # gaokun3_defconfig is an independent distribution kernel policy (the
      # Fedora build applies nothing on top of it), and nixpkgs' common-config
      # demands values for several symbols this defconfig sets differently
      # (e.g. NVME_AUTH). Skip the common config; structuredExtraConfig and
      # boot.kernelPatches still apply.
      enableCommonConfig = false;

      extraMeta = {
        description = "Huawei MateBook E Go 2023 (gaokun3 / SC8280XP) kernel, patched from v${version}";
        homepage = "https://github.com/KawaiiHachimi/linux-gaokun-buildbot";
        platforms = lib.platforms.aarch64;
      };
    }
    // (lib.optionalAttrs (args ? kernelPatches) {inherit (args) kernelPatches;})
    // (lib.optionalAttrs (args ? randstructSeed) {inherit (args) randstructSeed;})
    // (lib.optionalAttrs (args ? features) {inherit (args) features;})
  )
