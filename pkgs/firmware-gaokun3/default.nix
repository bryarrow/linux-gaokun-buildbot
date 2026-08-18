{
  lib,
  stdenvNoCC,
}: let
  # Pinned alongside the kernel patch series; bump in the same commit that
  # refreshes what depends on it.
  version = "0.1.0";
in
  stdenvNoCC.mkDerivation {
    pname = "linux-firmware-gaokun3";
    inherit version;

    # Model-specific files only: the generic WCN6855, QCA Bluetooth and Adreno
    # firmware comes from linux-firmware (see the NixOS module). The store copy
    # keeps the SC8280XP-HUAWEI-GAOKUN3-tplg.bin symlink intact.
    src = ../../firmware;

    dontBuild = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/firmware
      cp -a $src/. $out/lib/firmware/
      runHook postInstall
    '';

    meta = {
      description = "Model-specific firmware for the Huawei MateBook E Go 2023 (gaokun3)";
      license = lib.licenses.unfreeRedistributable;
      platforms = lib.platforms.linux;
    };
  }
