# alsa-ucm-conf with this machine's Qualcomm/sc8280xp/sc8280xp.conf on top.
#
# NixOS finds UCM2 files at $ALSA_CONFIG_UCM2 (alsa-lib reads it), and the
# module points that at this package. The stock tree already ships a
# stock sc8280xp.conf, and the Fedora image resolves the conflict by
# installing its file over the packaged one; here the merged tree is a package
# of its own, so it can be cached and built once like any other.
{
  lib,
  stdenvNoCC,
  alsa-ucm-conf,
}:
stdenvNoCC.mkDerivation {
  pname = "alsa-ucm-conf-gaokun3";
  version = "0.1.0";

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -a ${alsa-ucm-conf}/share/alsa/ucm2/. $out/
    # cp -a preserves the store's read-only permissions (555 dirs, 444 files),
    # which makes both rm and install's unlink fail inside the sandbox.
    chmod -R u+w $out
    rm -f $out/Qualcomm/sc8280xp/sc8280xp.conf
    install -Dm644 ${../../tools/audio/sc8280xp.conf} $out/Qualcomm/sc8280xp/sc8280xp.conf

    runHook postInstall
  '';

  meta = {
    description = "ALSA UCM2 configuration for the Huawei MateBook E Go 2023 (gaokun3)";
    homepage = "https://github.com/bryarrow/linux-gaokun-buildbot";
    # The bulk is alsa-ucm-conf's BSD-3-Clause tree; sc8280xp.conf comes from
    # the same source as the module's audio configuration.
    license = [lib.licenses.bsd3 lib.licenses.gpl2Only];
    platforms = lib.platforms.linux;
  };
}
