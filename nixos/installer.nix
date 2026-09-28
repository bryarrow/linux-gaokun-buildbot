# The NixOS installation medium for this machine.
#
# The live system is stock NixOS' minimal installer profile
# (installation-cd-minimal.nix); this module only changes what boots it.
# iso-image.nix boots through GRUB, and nixpkgs' ISO module never tells GRUB
# about a device tree. This board's firmware supplies no usable one, so the
# kernel has to receive the gaokun3 DTB from the bootloader -- which is exactly
# what the installed system does through systemd-boot's `devicetree`
# (boot.loader.systemd-boot.installDeviceTree).
#
# Upstream's fix for GRUB is NixOS/nixpkgs#396334 and is still open. It is not
# carried here as an applyPatches patch: a module path inside a derivation makes
# `nix flake check --no-build`, the pull-request gate, build nixpkgs before it
# can evaluate anything. Instead this module builds the ESP itself -- the same
# systemd-boot tree the installed system gets, entries included -- and hands it
# to make-iso9660-image as the El Torito EFI image, which is how the stock
# module hands over GRUB's. Nothing else about the live system moves: the
# squashfs store, the `/iso` mount by volume label and the tmpfs root all stay
# as installation-cd-base.nix sets them up.
{
  config,
  lib,
  pkgs,
  ...
}: let
  deviceTree = config.hardware.deviceTree;
  kernel = config.boot.kernelPackages.kernel;
  kernelFile = config.system.boot.loader.kernelFile;
  initrd = config.system.build.initialRamdisk;
  initrdFile = config.system.boot.loader.initrdFile;

  # systemd-boot lays each kernel, initrd and device tree out under
  # EFI/nixos/<store-path basename> (systemd-boot-builder.py), and the ESP here
  # copies that shape. The paths only have to be consistent with the entry
  # below; nothing outside the ESP reads them.
  kernelDir = baseNameOf (toString kernel);
  initrdDir = baseNameOf (toString initrd);
  deviceTreeDir = baseNameOf (toString deviceTree.package);
  deviceTreeFile = deviceTree.name;

  systemdBootEfi = "${config.systemd.package}/lib/systemd/boot/efi/systemd-boot${pkgs.stdenv.hostPlatform.efiArch}.efi";
  bootEfiName = "BOOT${lib.toUpper pkgs.stdenv.hostPlatform.efiArch}.EFI";

  # The entry only has to *name* the system's init, which the squashfs store on
  # the ISO provides at boot. Interpolating the toplevel normally would make
  # this ESP -- and checks.installer-wiring, which reads it back -- depend on
  # the whole live closure.
  toplevel = builtins.unsafeDiscardStringContext (toString config.system.build.toplevel);

  # A FAT filesystem, not a directory: UEFI firmware maps the El Torito EFI
  # image as a disk. Built the way nixos/iso-image.nix builds its own (fixed
  # timestamps, fixed volume id, mcopy) so the ISO stays reproducible.
  esp = pkgs.runCommand "gaokun3-installer-esp" {
    nativeBuildInputs = [
      pkgs.coreutils
      pkgs.dosfstools
      pkgs.findutils
      pkgs.libfaketime
      pkgs.mtools
    ];
  } ''
    mkdir -p contents
    cd contents
    mkdir -p EFI/BOOT EFI/systemd
    mkdir -p "EFI/nixos/${kernelDir}" "EFI/nixos/${initrdDir}"
    mkdir -p "EFI/nixos/${deviceTreeDir}/${dirOf deviceTreeFile}"
    mkdir -p loader/entries

    cp "${kernel}/${kernelFile}" "EFI/nixos/${kernelDir}/${kernelFile}"
    cp "${initrd}/${initrdFile}" "EFI/nixos/${initrdDir}/${initrdFile}"
    cp "${deviceTree.package}/${deviceTreeFile}" "EFI/nixos/${deviceTreeDir}/${deviceTreeFile}"

    # EFI/BOOT/BOOTAA64.EFI is the removable-media default path, so this ESP
    # is bootable without an entry in the firmware's boot menu.
    cp "${systemdBootEfi}" "EFI/BOOT/${bootEfiName}"
    cp "${systemdBootEfi}" "EFI/systemd/systemd-boot${pkgs.stdenv.hostPlatform.efiArch}.efi"

    # systemd-boot reads loader.conf and loader/entries from the ESP; the entry
    # is the only place the device tree is attached to the kernel.
    cat > loader/loader.conf <<EOF
    default nixos.conf
    timeout 10
    editor yes
    EOF

    cat > loader/entries/nixos.conf <<EOF
    title NixOS gaokun3 installer
    version ${config.system.nixos.label}
    linux /EFI/nixos/${kernelDir}/${kernelFile}
    initrd /EFI/nixos/${initrdDir}/${initrdFile}
    devicetree /EFI/nixos/${deviceTreeDir}/${deviceTreeFile}
    options init=${toplevel}/init ${lib.concatStringsSep " " config.boot.kernelParams}
    EOF

    find . -exec touch --date=2000-01-01 {} +
    usage_size=$(( $(du -s --block-size=1M --apparent-size . | cut -f1) * 1024 * 1024 ))
    # 110% of the apparent size, rounded up to whole MiB, for FAT overhead.
    image_size=$(( ((usage_size * 110) / 100 / 1048576 + 1) * 1048576 ))
    truncate --size=$image_size "$out"
    mkfs.vfat --invariant -i 12345678 -n NIXOSINST "$out"

    for d in $(find . -mindepth 1 -type d -printf '%P\n' | sort); do
      faketime "2000-01-01 00:00:00" mmd -i "$out" "::$d"
    done
    for f in $(find . -type f -printf '%P\n' | sort); do
      mcopy -pvm -i "$out" "$f" "::$f"
    done
    fsck.vfat -vn "$out"
  '';

  # The stock module's contents minus what only GRUB reads: its EFI image, the
  # GRUB tree and theme it drops at the ISO root, and the splash. What is left
  # is the kernel, the initrd and version.txt on the ISO9660; the SQUASHFS store
  # is not part of `contents` at all. Ours goes in as /boot/efi.img, which is the
  # path make-iso9660-image is told to use as the El Torito image either way.
  contents =
    lib.filter (
      c: c.target != "/boot/efi.img" && !(lib.hasPrefix "/EFI" c.target)
    ) config.isoImage.contents
    ++ [{source = esp; target = "/boot/efi.img";}];
in
  lib.mkIf (config.isoImage.makeEfiBootable && deviceTree.enable && deviceTree.name != null) {
    # checks.installer-wiring reads the entry back out of this image.
    system.build.gaokun3InstallerEsp = esp;

    # The same call iso-image.nix makes, with a different El Torito image. If
    # nixpkgs grows an argument here, evaluation fails on the missing one.
    system.build.isoImage = lib.mkForce (
      pkgs.callPackage "${pkgs.path}/nixos/lib/make-iso9660-image.nix" (
        {
          inherit (config.isoImage) compressImage volumeID squashfsCompression;
          isoName = "${config.image.baseName}.iso";
          bootable = config.isoImage.makeBiosBootable;
          bootImage = "/isolinux/isolinux.bin";
          syslinux =
            if config.isoImage.makeBiosBootable
            then pkgs.syslinux
            else null;
          squashfsContents = config.isoImage.storeContents;
          inherit contents;
        }
        // lib.optionalAttrs (config.isoImage.makeUsbBootable && config.isoImage.makeBiosBootable) {
          usbBootable = true;
          isohybridMbrImage = "${pkgs.syslinux}/share/syslinux/isohdpfx.bin";
        }
        // lib.optionalAttrs config.isoImage.makeEfiBootable {
          efiBootable = true;
          efiBootImage = "boot/efi.img";
        }
      )
    );
  }
