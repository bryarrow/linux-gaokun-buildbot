# linux-gaokun-buildbot

NixOS support for the Huawei MateBook E Go 2023 (codename `gaokun3`, Qualcomm
Snapdragon 8cx Gen 3 / `SC8280XP`): a flake with the gaokun3 kernel, the model
firmware, the device tools, an installer image and a NixOS module that wires
them together behind one option.

The repository also carries the earlier Fedora build system — kernel RPMs, a
Workstation disk image and a rescue USB. It is frozen and kept as the recovery
fallback only; the NixOS side is what is developed. See
[Legacy: the Fedora pipeline](#legacy-the-fedora-pipeline).

## Goals

Ordered — when they conflict, the earlier one wins.

1. **The best experience on the MateBook E Go.** Hardware enablement comes
   before everything else. The device tree, kernel config, firmware bundle and
   quirks like `fbcon=rotate:1` stay even where they are unlike stock NixOS.
2. **A stock NixOS experience.** The kernel is built the way nixpkgs builds
   kernels — `buildLinux`, the common config, a small reviewed gaokun3 delta —
   and the module follows NixOS module conventions instead of restating
   decisions nixpkgs already makes. Where the hardware does not force our hand,
   match NixOS rather than invent.
3. **Safe to daily drive.** No harder to break than any other NixOS install:
   generations and the systemd-boot menu are the rollback path, and no guard
   rails NixOS itself does not have.

## Quickstart

The installation medium is the stock NixOS minimal installer with this machine's
kernel, device tree and kernel command line, so it boots the MateBook E Go
directly, with no Fedora step:

```bash
nix build github:bryarrow/linux-gaokun-buildbot#installer-iso
sudo dd if=result/iso/nixos-gaokun3-*.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

[Installing NixOS on the MateBook E Go](docs/nixos_install_guide_en.md)
([中文](docs/nixos_install_guide_zh.md)) is the full procedure: booting the
stick, partitioning, the flake, and the first boot. Read it before writing a
stick; `dd` overwrites the target without asking.

Once NixOS is running, a configuration that takes this repository as an input
needs one line for the hardware:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    gaokun3.url = "github:bryarrow/linux-gaokun-buildbot";
  };
  outputs = { nixpkgs, gaokun3, ... }: {
    nixosConfigurations.ego = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        gaokun3.nixosModules.gaokun3
        ({ ... }: { hardware.gaokun3.enable = true; })
      ];
    };
  };
}
```

That option selects the gaokun3 kernel and its binary cache, the board device
tree and the kernel command line (panel rotation, keyboard quirk, 8cx Gen 3
firmware workarounds), the initrd and boot modules, Bluetooth NVM patching, the
audio UCM profile, the system-level display rotation and a periodic
thermal/power log. Use `boot.loader.systemd-boot.enable = true`; that is the
loader the device tree support is tested with, and the firmware cannot write EFI
variables (`efi=noruntime`), so systemd-boot installs to the removable path
`\EFI\BOOT\BOOTAA64.EFI`.

The kernel targets aarch64. On an x86_64 builder the flake's packages are
cross-compiled; to build the installer image there as well, see the
[install guide](docs/nixos_install_guide_en.md#1-get-the-installer-iso).

Three caveats worth knowing before you copy the snippet:

- Do **not** add `inputs.gaokun3.inputs.nixpkgs.follows = "nixpkgs"`. The
  kernel, firmware and tools are built from this repository's own pinned
  nixpkgs, which is what makes them the same derivation — and therefore the same
  binary-cache entry — for everyone. Making them follow your nixpkgs rebuilds
  them locally against it, so the cache no longer matches. Your system's own
  nixpkgs is unaffected.
- The module adds its packages through `nixpkgs.overlays`, so a configuration
  that sets `nixpkgs.pkgs` directly (which replaces the whole package set) does
  not get them. Apply `gaokun3.overlays.default` to that package set yourself,
  or use the plain `nixpkgs` module and let the module do it.
- The model firmware is redistributable but not modifiable, so evaluation
  refuses it under a stock `nixpkgs.config.allowUnfree = false`; allow it
  explicitly:

  ```nix
  { nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
      "linux-firmware-gaokun3"
    ]; }
  ```

### EL2 variant (experimental)

By default Linux takes the machine over. There is a second kernel that runs
Linux as a guest on the vendor hypervisor instead, the same one the legacy
Fedora pipeline ships as `kernel-gaokun3-el2`:

```nix
{ hardware.gaokun3.el2.enable = true; }
```

It adds a second boot entry, **NixOS (el2)**, which uses
`pkgs.linuxPackages_gaokun3-el2`, boots `sc8280xp-huawei-gaokun3-el2.dtb` and
adds that entry's kernel command line (`modprobe.blacklist=simpledrm`). The
normal entry keeps the stock kernel and device tree, so EL1 and EL2 are chosen
at boot and this can stay enabled; setting it to `false` again removes the entry.
This path is experimental and is not a supported configuration. In EL2 the
video codec does not come up — `qcom-venus` finds its firmware but fails to
initialise it (`-EINVAL`) — while everything else checked on the device (wifi,
audio, display, Bluetooth, and KVM itself) works. Secure Boot has to be off, and
`tcblaunch.exe` has to be an old enough build for slbounce, so do not replace the
copy this repository ships with the one from a Windows install.

The module also puts the EL2 boot chain on the ESP for you, through
`boot.loader.systemd-boot.extraFiles`: the two drivers under
`EFI/systemd/drivers/`, `tcblaunch.exe` at the ESP root, and the three DSP
images the hypervisor reads from `firmware/`. Nothing has to be copied or
cleaned up by hand. That is also why the option expects
`boot.loader.systemd-boot`: it is the loader that reads those drivers, and the
module warns when another one is configured.

Those paths live on the ESP, not inside one system, and the legacy Fedora EL2
image writes exactly the same ones. On a machine that boots both, `sd-boot`
loads the drivers for every entry it starts, so the files are shared — and
turning this option off removes them from the ESP, including the copy a Fedora
installation may be relying on. What the drivers *do* is decided by the device
tree they are given, so entries that are not EL2 are unaffected while the files
are present; only their presence is shared.

### Binary cache

The project publishes its kernel and firmware builds to a public Cachix cache,
so a rebuild downloads them instead of compiling the kernel on the device.
`hardware.gaokun3.enable = true` wires it up for you
(`hardware.gaokun3.binaryCache.enable`, on by default). Everything still works
without it; the kernel is just built locally.

Trusting a cache key applies to every build on the machine, not only gaokun3's,
so there is a switch:

```nix
{ hardware.gaokun3.binaryCache.enable = false; }
```

If you would rather configure Nix yourself, the equivalent is:

```ini
# /etc/nix/nix.conf, or run `cachix use gaokun3`
extra-substituters = https://gaokun3.cachix.org
extra-trusted-public-keys = gaokun3.cachix.org-1:ikL6EofK55QEwKucrUo44SPKewscvAMJr7ibBxJtIsI=
```

A flake that takes this repository as an input does not inherit its
`nixConfig` — Nix only honours that from the top-level flake — so use the
snippet above or the module option. When you build the flake directly, as in
`nix build github:bryarrow/linux-gaokun-buildbot`, its `nixConfig` does
apply, but Nix asks for `--accept-flake-config` unless you are a trusted user.

The cache is on Cachix's free open-source tier: 5 GB, with least-recently-used
entries evicted once it is full. Kernel paths for older versions can therefore
disappear, and a rebuild of one of those compiles locally instead. Nothing
breaks, it just takes longer. The kernel's `-dev` output, which carries the
whole source tree, is excluded from uploads for the same reason, and so is the
installer image: it is a release artifact, not something a device substitutes.

## Hardware support

For an overview of hardware support status on the device, see [right-0903/linux-gaokun `## Feature Support`](https://github.com/right-0903/linux-gaokun?tab=readme-ov-file#feature-support).

In addition, this repository enables the SC8280XP Venus hardware video codec (H.264/HEVC/VP9 encode and decode) via the `media/` patch series and the `CONFIG_VIDEO_QCOM_VENUS=m` module.

## Legacy: the Fedora pipeline

Before the NixOS support, this repository built Fedora images for the device.
That pipeline still exists, is frozen (no kernel or release bumps), and is kept
because the rescue USB is a working way to get a shell on a machine that no
longer boots. New work goes into the NixOS side; treat the Fedora artifacts as
recovery tools and prefer the [install guide](docs/nixos_install_guide_en.md)
for a new installation.

Three GitHub Actions workflows, all `workflow_dispatch`, all sharing the
numbered scripts in `scripts/ci/`:

| Workflow | Product |
| --- | --- |
| `gaokun3-package-rpms.yml` | `kernel-gaokun3`, `kernel-modules-gaokun3`, `kernel-devel-gaokun3`, `linux-firmware-gaokun3` (plus `*-el2` variants) |
| `fedora-gaokun3-release.yml` | Fedora Workstation disk image; optionally calls the RPM workflow first |
| `gaokun3-rescue-release.yml` | CLI-only USB rescue image |

Release assets:

- Fedora image releases contain compressed installable images.
- Gaokun rescue USB releases contain a CLI-only Fedora image that boots this
  device from a USB stick, for installing the image above onto the internal disk
  or repairing an installation that no longer boots. **It has a published
  password (`fedora` / `fedora`) and `sshd` enabled**, so anyone on the same
  network can log in while it is running. The procedure is
  [rescue_usb_guide_en.md](docs/rescue_usb_guide_en.md).
- Gaokun RPM releases contain the standalone kernel and firmware package sets
  used by the image workflow.

Installing or upgrading a kernel RPM refreshes the initramfs and the boot entry,
and makes that kernel the one that boots.

### Fedora boot artifact layout

The image boots through `systemd-boot` with standard BLS entries generated by
`kernel-install`.

- Entries are `loader/entries/fedora-<kernel-release>.conf` on the ESP, with the kernel, initrd and DTB under `fedora/<kernel-release>/` beside them. A copy of the DTB is kept in `/boot/dtb-<kernel-release>/qcom/` for anyone switching to GRUB later.
- The boot is verbose and Plymouth is off (`plymouth.enable=0`), where stock Fedora has `rhgb quiet`. Plymouth draws through DRM and ignores `fbcon=rotate:1`, so its splash and details view would come out sideways on this portrait panel; the kernel console honours the rotation.
- The entry editor is on (`editor yes`), so the kernel command line — `selinux=0` included — can be changed from the device instead of by mounting the ESP elsewhere.

### Fedora language and input

The Fedora image ships `LANG=en_US.UTF-8` and no input method, matching the
reference Workstation image. Add your language in GNOME Settings and Fedora
offers the matching translations and input method.

For Chinese specifically there are two reasonable paths, and an image cannot
pick between them for you:

- `fcitx5-chinese-addons` works immediately, and its Pinyin dictionary is
  usually paired with `fcitx5-pinyin-zhwiki`.
- `fcitx5-rime` with [rime-ice](https://github.com/iDvel/rime-ice) (雾凇拼音) is
  what most people who care end up on. It needs its own configuration, which is
  the point of it.

The Fedora build itself is documented in
[matebook_ego_build_guide_fedora44_en.md](docs/matebook_ego_build_guide_fedora44_en.md).

## Repository layout

- `patches/`: kernel patches and device support changes, applied by both pipelines
- `defconfig/`: local kernel configuration; the Fedora pipeline's input, kept for it
- `drivers/`: local mirrors of the patched driver sources kept in the patch series
- `dts/`: local mirrors of the patched device tree sources kept in the patch series
- `docs/`: installation, rescue, dual-boot and platform guides
- `firmware/`: minimal firmware bundle used by both pipelines
- `flake.nix` and `nixos/`: the NixOS side — flake, NixOS module and installer
- `pkgs/`: the Nix packages (kernel, EL2 kernel, firmware, tools, ALSA UCM)
- `checks/`: `nix flake check` checks
- `packaging/`: Fedora kernel and firmware RPM templates
- `tools/`: device-specific helper scripts, service files, and EL2 EFI payloads
- `scripts/ci/`: Fedora workflow build, image creation, and packaging scripts
- `scripts/local/`: scripts that can be run on the local device

### Patch sources

- `upstream/*` and `others/0005`: adapted from [right-0903/linux-gaokun](https://github.com/right-0903/linux-gaokun) for the base SC8280XP / gaokun3 enablement, display bring-up, EC suspend/resume, ADSP FastRPC, and DSI stability work
- `others/0001`: adapted from [whitelewi1-ctrl/matebook-e-go-linux](https://github.com/whitelewi1-ctrl/matebook-e-go-linux) to avoid setting `USE_BDADDR_PROPERTY` when the adapter address is invalid
- `others/0002`: local change in this repository to enable DSC and allow 60 Hz / 120 Hz switching
- `himax/0001`: adapted from [chiyuki0325/EGoTouchRev-Linux](https://github.com/chiyuki0325/EGoTouchRev-Linux) (revision `e738049`) to add the restructured Himax HX83121A SPI touchscreen driver
- `others/0004`: adapted from [TheUnknownThing/linux-gaokun](https://github.com/TheUnknownThing/linux-gaokun) to improve UCSI handling and module wiring for the Type-C path
- `others/0006`: from the [gaokun-android](https://github.com/vahiru/gaokun-android) port — mainline `sc8280xp.dtsi` has no CPU cooling maps (only a 110 °C critical trip per zone), so the CPUs run flat out until an emergency shutdown; this adds a 75 °C passive trip to each of the eight per-core zones bound to that cluster's cpufreq cooling device. The gap is not specific to this machine, so the patch is written for upstream
- `media/*`: from the [gaokun-android-kernel](https://github.com/pgs666/gaokun-android-kernel) port of the right-0903/linux-gaokun Venus series to enable the SC8280XP Venus hardware video codec (driver resources, dt-bindings, `videocc` and `video-codec` DT nodes). The gaokun3 board enablement — the `firmware-name` pointing at the already packaged `qcvss8280.mbn` and `status = "okay"` — lives in `dts/` instead of the patch
- `dts/` and `defconfig/`: copied into the kernel tree rather than carried as a patch, so they cannot conflict on a kernel bump
- **[Optional]** `el2/*`: adapted from [TravMurav/linux](https://github.com/TravMurav/linux/tree/x13s-6.18-v1.1-cxsd) for the EL2 boot path, including SMP2P handover, remoteproc attach/restart flow, SCM/SHM owner handling, and related rpmsg/QRTR/pmic_glink stability fixes

### Tool sources

- `tools/audio`, `tools/bluetooth`: adapted from [whitelewi1-ctrl/matebook-e-go-linux](https://github.com/whitelewi1-ctrl/matebook-e-go-linux)
- `tools/el2/qebspilaa64.efi`: sourced from [stephan-gh/qebspil](https://github.com/stephan-gh/qebspil)
- `tools/el2/slbounceaa64.efi`: sourced from [TravMurav/slbounce](https://github.com/TravMurav/slbounce)
- `tools/touchscreen-tuner`: adapted from [chiyuki0325/EGoTouchRev-Linux](https://github.com/chiyuki0325/EGoTouchRev-Linux), with GTK4 GUI improvements in this repository

## Getting started

- Releases: <https://github.com/bryarrow/linux-gaokun-buildbot/releases>
- [Installing NixOS on the MateBook E Go](docs/nixos_install_guide_en.md) ([中文](docs/nixos_install_guide_zh.md))
- [EL2 implementation notes](docs/el2_kvm_guide_en.md)
- [Rescue USB guide](docs/rescue_usb_guide_en.md) (legacy Fedora)
- [Dual-boot guide](docs/dual_boot_guide_en.md) (legacy Fedora)
- [Awesome Gaokun3](docs/awesome_gaokun3_en.md)
- [Build guide – Fedora 44](docs/matebook_ego_build_guide_fedora44_en.md) (legacy)

## References

- [right-0903/linux-gaokun](https://github.com/right-0903/linux-gaokun) : The main source of the kernel patches and device support work, with detailed commit messages and explanations.
- [TheUnknownThing/linux-gaokun](https://github.com/TheUnknownThing/linux-gaokun) : Another fork of the kernel patches and device support work, with some unique commits and explanations for Touchscreen and EC.
- [whitelewi1-ctrl/matebook-e-go-linux](https://github.com/whitelewi1-ctrl/matebook-e-go-linux) : The earliest repo to fix panel backlight problem, with some additional resources and modifications for Gaokun3 Linux support.
- [gaokun on AUR](https://aur.archlinux.org/packages?O=0&K=gaokun) : Several AUR packages built for Gaokun3, including kernel and firmware packages.
- [chenxuecong2/firmware-huawei-gaokun3](https://github.com/chenxuecong2/firmware-huawei-gaokun3) : A firmware bundle repository for Gaokun3.
- [chiyuki0325/EGoTouchRev-Linux](https://github.com/chiyuki0325/EGoTouchRev-Linux) : The upstream source for the directly integrated Himax HX83121A Linux touchscreen driver and tuning algorithm in this repository.
- [awarson2233/EGoTouchRev](https://github.com/awarson2233/EGoTouchRev) : The original Windows-side touchscreen algorithm project referenced by EGoTouchRev-Linux, and an important upstream reference for the Gaokun3 touchscreen tuning pipeline.
- [TravMurav/slbounce](https://github.com/TravMurav/slbounce) : A UEFI application that enables EL2 support and Secure Launch on Gaokun3.
- [TravMurav/linux](https://github.com/TravMurav/linux/tree/x13s-6.18-v1.1-cxsd) : A Linux kernel tree with some useful patches for EL2 support on sc8280xp platforms.
- [stephan-gh/qebspil](https://github.com/stephan-gh/qebspil) : A UEFI application that pre-launches the DSP firmware on Qualcomm platforms, which can be used in the boot chain before launching Linux.
