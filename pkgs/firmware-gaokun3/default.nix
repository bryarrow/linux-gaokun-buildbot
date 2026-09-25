{
  lib,
  stdenvNoCC,
}: let
  # Model-specific files only: the generic WCN6855, QCA Bluetooth and Adreno
  # firmware comes from linux-firmware (see the NixOS module). The store copy
  # keeps the SC8280XP-HUAWEI-GAOKUN3-tplg.bin symlink intact.
  #
  # cleanSource drops editor leftovers, and because it goes through
  # builtins.path it yields a store path carrying the tree's content hash.
  # Deriving the version from that hash means "firmware changed but the version
  # did not" cannot happen.
  src = lib.cleanSource ../../firmware;
  contentHash = builtins.substring 0 7 (baseNameOf (toString src));
in
  stdenvNoCC.mkDerivation {
    pname = "linux-firmware-gaokun3";
    version = "0.1.0-${contentHash}";
    inherit src;

    dontBuild = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/firmware
      cp -a $src/. $out/lib/firmware/
      runHook postInstall
    '';

    meta = {
      description = "Model-specific firmware for the Huawei MateBook E Go 2023 (gaokun3)";
      homepage = "https://github.com/KawaiiHachimi/linux-gaokun-buildbot";
      license = lib.licenses.unfreeRedistributable;
      platforms = lib.platforms.linux;
    };
  }
