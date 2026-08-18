{
  lib,
  stdenv,
  python3,
  gtk4,
  libadwaita,
  pango,
  glib,
  gdk-pixbuf,
  dconf,
  wrapGAppsHook4,
  gobject-introspection,
}: let
  python = python3.withPackages (ps: [ps.pygobject3]);
in
  stdenv.mkDerivation {
    pname = "gaokun3-tools";
    version = "0.1.0";

    src = ../../tools;

    nativeBuildInputs = [
      wrapGAppsHook4
      gobject-introspection
    ];

    buildInputs = [
      gtk4
      libadwaita
      pango
      glib
      gdk-pixbuf
      dconf
    ];

    dontBuild = true;

    installPhase = ''
      runHook preInstall

      mkdir -p $out/bin $out/libexec/gaokun-touchscreen-tuner \
        $out/share/applications $out/share/icons/hicolor/scalable/apps

      # Bluetooth NVM BDADDR patching. The Fedora image patches /lib/firmware in
      # place; on NixOS firmware lives in the read-only store, so the service
      # points GAOKUN_NVM_DIR at a writable copy instead.
      install -Dm755 $src/bluetooth/patch-nvm-bdaddr.py $out/bin/patch-nvm-bdaddr.py
      substituteInPlace $out/bin/patch-nvm-bdaddr.py \
        --replace-fail 'FIRMWARE_DIR = Path("/lib/firmware/qca")' \
          'FIRMWARE_DIR = Path(os.environ.get("GAOKUN_NVM_DIR", "/lib/firmware/qca"))'

      # Touchscreen algorithm tuner (GTK4 GUI). The launcher is wrapped by
      # wrapGAppsHook, which injects the GI typelib, GSettings and GIO module
      # paths the python env does not carry on its own.
      install -Dm644 $src/touchscreen-tuner/tune.py $out/libexec/gaokun-touchscreen-tuner/tune.py
      install -Dm644 $src/touchscreen-tuner/tune-icon.svg \
        $out/share/icons/hicolor/scalable/apps/touchscreen-tune.svg
      cat > $out/bin/touchscreen-tune <<EOF
      #!/bin/sh
      exec '${python}/bin/python3' '$out/libexec/gaokun-touchscreen-tuner/tune.py' "\$@"
      EOF
      chmod +x $out/bin/touchscreen-tune

      install -Dm644 $src/touchscreen-tuner/touchscreen-tune.desktop $out/share/applications/touchscreen-tune.desktop
      substituteInPlace $out/share/applications/touchscreen-tune.desktop \
        --replace-fail "/usr/local/bin/touchscreen-tune" "$out/bin/touchscreen-tune" \
        --replace-fail "/usr/local/lib/gaokun-touchscreen-tuner/tune-icon.svg" \
          "$out/share/icons/hicolor/scalable/apps/touchscreen-tune.svg"

      runHook postInstall
    '';

    meta = {
      description = "Bluetooth NVM patcher and touchscreen tuner for the Huawei MateBook E Go 2023";
      homepage = "https://github.com/KawaiiHachimi/linux-gaokun-buildbot";
      license = lib.licenses.gpl2Plus;
      platforms = lib.platforms.linux;
    };
  }
