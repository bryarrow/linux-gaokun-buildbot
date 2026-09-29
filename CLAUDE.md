# CLAUDE.md

This file provides guidance to agents working in this repository.

## Audience split

`README.md`, its Chinese translation `docs/README_zh.md`, and `docs/*.md` are written for someone who owns a MateBook E Go and wants to install, boot, dual-boot or repair it. Keep them to what such a person acts on. Build-system rationale, upstream evidence and rejected alternatives belong here instead, and inline comments stay to a line or two of local "why". If a comment or doc paragraph explains a distribution-policy decision, move it into this file rather than growing the source.

## Project goals, in order

When these conflict, the earlier one wins.

1. **The best experience on the MateBook E Go.** Hardware enablement comes before everything else. The device tree, kernel config, firmware bundle and quirks like `fbcon=rotate:1` stay even where they are unlike a stock NixOS system.
2. **A stock NixOS experience.** Build the kernel the way nixpkgs builds kernels — `buildLinux`, `enableCommonConfig`, a small reviewed gaokun3 delta — and write the module the way NixOS modules are written. Where the hardware does not force our hand, inherit NixOS's decision instead of restating it: an explicit `systemctl enable` (or a hand-written boot entry, or a restated config symbol) for something nixpkgs already decides is dead weight at best and a silent divergence when nixpkgs changes its mind.
3. **Safe to daily drive.** No harder to break than any other NixOS install: generations and the systemd-boot menu are the rollback path, and no guard rails NixOS itself does not have.

## What gets built

Everything is in `flake.nix`. The outputs:

| Output | Content |
| --- | --- |
| `packages.<sys>.linux-gaokun3` | The kernel: gaokun3 patches, DTS, config; `aarch64-linux` native, `x86_64-linux` cross |
| `packages.<sys>.linux-gaokun3-el2` | The same kernel with `patches/el2` and `LOCALVERSION=-gaokun3-el2` |
| `packages.<sys>.linux-firmware-gaokun3` | Model firmware, including the tplg symlink |
| `packages.<sys>.gaokun3-tools` | Bluetooth NVM patcher and touchscreen tuner |
| `packages.<sys>.alsa-ucm-conf-gaokun3` | Merged UCM2 tree |
| `packages.aarch64-linux.installer-iso` | The installation medium |
| `packages.<sys>.default` | `firmware-gaokun3`, deliberately not the kernel |
| `overlays.default` | Injects the packages above plus `linuxPackages_gaokun3(el2)` |
| `nixosModules.gaokun3` (and `.default`) | The NixOS module, applying the overlay itself |
| `checks.<sys>.*` | See below; `nix flake check` runs them |

The source layout: `nix/pins.nix` (version, tarball, hash), `nix/lib/patch-series.nix`, `nix/config/gaokun3-extra.nix`, `pkgs/*/default.nix`, `nixos/modules/hardware/gaokun3.nix`, `nixos/installer.nix`, `checks/default.nix`. `patches/ dts/ firmware/ tools/` are the repository's source of truth and are consumed only by this flake.

CI is `.github/workflows/gaokun3-nix.yml`, on an arm64 runner (the kernel's `meta.platforms` is aarch64). Pull requests run `nix flake check --no-build` plus a build of `checks.config-symbols`; pushes to `main`/`gaokun3-nix` run the full `nix flake check` and push to the project's Cachix cache through `cachix-action`. `checks.packages` is the derivation that forces every package (and explicitly the kernel's `modules` output) so the daemon pushes them; `installer-iso` is excluded from it on purpose.

## Verifying a change

There is no test suite. The Nix side is verified by evaluation and cheap builds. Run:

```sh
nix flake check --no-build          # evaluation only; the pull-request gate
nix flake check                      # builds the checks, including the kernel
```

`nix flake check --no-build` is not only a speed shortcut: it is the constraint that keeps the installer buildable without patching nixpkgs (see the installer notes below). Nothing that needs a store path produced during evaluation may enter a flake output, or that command stops working.

The real check is a CI run plus a boot on the device, which only the user can do. Anything that needs hardware evidence — module autoload, ASPM, `pd_ignore_unused`, a backlight unit, USB-C/PD behaviour — is settled by asking the user for a cold-boot log, a `journalctl` excerpt or a `/proc/config.gz`, not by reasoning. Privileged commands are handed to the user rather than run here.

## Easy things to get wrong

- **`patches/*/series` is the only ordering source.** `nix/lib/patch-series.nix` throws at evaluation if a series file omits a `.patch`, names one that is not there, or lists a name twice (a duplicate would make stdenv apply the same patch again and fail much later). `checks.series-sync` makes the same list a named check. Every directory has a `series`, `patches/el2` included.
- **The kernel `src` carries `dts/`, not a `postPatch` on the kernel.** `buildLinux`'s `postPatch` is neither a parameter nor forwarded to `build.nix`; the configfile derivation does `postPatch = kernel.postPatch + …`, so a `postPatch` handed to `buildLinux` would be dropped and the board device tree would be missing when the source is configured, with no error. `pkgs/linux-gaokun3/default.nix` therefore sets `src = applyPatches { … postPatch = "cp … dts …"; }`, which both derivations inherit. `dts/` is owned outright (not a diff), so a kernel bump cannot conflict in it.
- **Base patches are prepended, and `…@args` is forwarded.** `kernelPatches = basePatches ++ (args.kernelPatches or [])`, so a user's `boot.kernelPatches` cannot displace the gaokun3 series, and the catch-all `args` is what lets NixOS's `linuxPackagesFor` override pass `features`/`randstructSeed`/`kernelPatches`. Do not name those as parameters: `callPackage` would inject `pkgs.kernelPatches` (a patch-set attrset) into the first one. `linux-gaokun3-el2` wraps the same file and inherits the same requirement.
- **The kernel policy is nixpkgs' common config plus a reviewed delta.** `defconfig = "defconfig"` is the kernel's own arm64 defconfig; nixpkgs' `enableCommonConfig` supplies the distribution policy; `nix/config/gaokun3-extra.nix` is the whole Gaokun deviation and is entered with `lib.mkOverride 90` because common-config options are priority 100 and a same-priority redefinition is an error. `ignoreConfigErrors` is deliberately not set. `IMA` is restated as `optional = true` because `INTEGRITY=n` makes it unreachable; `INTEGRITY` itself stays off, because a builtin TPM core (which `IMA` forces through `select TCG_TPM`) makes systemd's tpm2 generator wait out the 90 s device timeout on a machine with no TPM. `checks.config-symbols` pins these down.
- **The overlay points at `self.packages`, and consumers must not set `nixpkgs.follows`.** The kernel derivation — and therefore its cache entry — has to be identical for every consumer. `overlays/default.nix` forwards to `self.packages.${system}` rather than rebuilding with the consumer's nixpkgs; a consumer that added `gaokun3.inputs.nixpkgs.follows = "nixpkgs"` would put the consumer's nixpkgs back into `self.packages` and undo that, so README tells users not to.
- **`firmware/` contains symlinks, and `find -type f` hides them.** `SC8280XP-HUAWEI-GAOKUN3-tplg.bin` is a link to `HUAWEI/gaokun3/audioreach-tplg.bin`, which is the name the sound card asks for. Enumerate that tree with `git ls-files` or `find -mindepth 1`; a dangling symlink also makes anything that hashes the tree fail before it starts. `checks.firmware-symlinks` covers it.
- **The installer must not need a nixpkgs patch.** `nixos/iso-image.nix` boots GRUB without a device tree, which cannot boot this board, and upstream's fix (NixOS/nixpkgs#396334) is unmerged. Carrying it as `applyPatches`/`builtins.toFile` fails `nix flake check --no-build`, because the patched module must be readable during evaluation and neither mechanism produces a store path there. `nixos/installer.nix` instead builds a systemd-boot ESP and passes it as the El Torito image. Do not reintroduce a patched-nixpkgs input.
- **`hardware.gaokun3.el2.enable` is a boot entry, not a system switch.** It is a `specialisation`, so the normal entry keeps the stock kernel and DTB and EL1/EL2 is a menu choice; it also installs the shared ESP payloads as `boot.loader.systemd-boot.extraFiles`. Write it as `specialisation = lib.optionalAttrs cfg.el2.enable { … }`, never `specialisation.el2.configuration = lib.mkIf cfg.el2.enable …`, which would produce an empty el2 entry. `checks.el2-wiring` checks the whole contract.
- **The firmware bundle is model-specific only.** Everything generic — WCN6855, QCA Bluetooth, Adreno 660 — comes from `linux-firmware`. Before adding a file under `firmware/`, check whether nixpkgs already ships it identical or newer; if a distribution file has to be overridden, record the reason.
- **`hardware.firmware` resolves a collision by priority first, then order.** `buildEnv`'s `builder.pl` compares `meta.priority` (smaller wins) and only falls back to input order when they are equal. `linux-firmware` carries priority 6 and our package takes the default 5, so `mkBefore` is a second guarantee rather than the reason. `checks.firmware-precedence` asserts the outcome from both facts without building `linux-firmware`.
- **`firmware_class.path` is one directory name, not a list.** The kernel uses the parameter verbatim as `fw_path[0]` and only then falls back to `/lib/firmware` (`drivers/base/firmware_loader/main.c`), so a colon-separated value matches nothing at all. NixOS has no `/lib/firmware` of its own, so the module restores it as a symlink to the firmware environment; the NVM patcher points the parameter at its override directory alone.

## NixOS architecture notes that span files

**Flake contract and cache identity.** `packages.<sys>.*` are built with this flake's pinned nixpkgs; `overlays/default.nix` exposes those derivations rather than rebuilding them with the consumer's nixpkgs, so every consumer gets the same derivation — and therefore the same binary-cache entry — per package. `nixosModules.gaokun3` applies the overlay, which is what keeps `hardware.gaokun3.enable = true` the only line a user writes.

**Supply chain** (`nix/pins.nix`, `nix/lib/patch-series.nix`). `nix/pins.nix` is the single source for `kernelTag`, `kernelVersion`, the tarball URL and its hash; a kernel bump is one edit there, in the same commit as the patch refresh that needs it. The tarball is cdn.kernel.org's release tarball, not kernel.org's on-demand `/snapshot/`: a snapshot URL is not guaranteed to stay byte-identical, so its sha256 only proves the download was not tampered with, not that it is the tree the patches were made against. Patch order comes from each directory's `series` file and nowhere else.

**Kernel package** (`pkgs/linux-gaokun3/default.nix`). Built with `buildLinux`. Patches come from `nix/lib/patch-series.nix` in `series` order: `upstream`, `others`, `himax`, `media`, then `el2` when the variant is on. `src` is the release tarball plus `applyPatches`' `postPatch`, which copies `dts/` into the tree. `defconfig = "defconfig"` and `enableCommonConfig = true` mean the policy is nixpkgs', with `nix/config/gaokun3-extra.nix` as the reviewed deviation; `LOCALVERSION` is restated per variant so the module directory is distinct. `linux-gaokun3-el2` is a one-line wrapper around the same file, so the two cannot drift; `…@args` forwarding is what lets it survive `boot.kernelPackages` overrides. `checks.config-symbols` builds both configfiles and asserts the delta and that the EL2 config differs from the base in `CONFIG_LOCALVERSION` alone.

**Kernel config** (`nix/config/gaokun3-extra.nix`). Nine entries: `LOCALVERSION`, `BT_LE`, `INTEGRITY`, `IMA`, `TCG_TPM`, `CMA_SIZE_MBYTES`, `USB_PCI`, `VIDEO_QCOM_IRIS`, `PSTORE_CONSOLE`. The rest is inherited from the kernel's arm64 defconfig and nixpkgs' common config, and the switch to that base had three consequences worth remembering: `ARM64_VA_BITS`/`PA_BITS` became 52; SELinux is off (nixpkgs' arm64 config never sets `SECURITY_SELINUX`, and NixOS does not enable it either); and ACPI is compiled in but stays disabled at runtime because systemd-boot passes a real device tree, so `dt_is_stub()` is false and `acpi_disabled` is set before drivers probe. `PSTORE_CONSOLE` is the one entry the base switch would otherwise have lost: the defconfig leaves it off while `dts/` reserves a ramoops console region and the module mounts `/sys/fs/pstore`, so it is pinned in the delta and asserted by `checks.config-symbols`. `DEBUG_INFO`/BTF and `CONFIG_RUST=y` also came with the base, which grows the `-dev` output and CI time. `BLK_DEV_NVME` and `BTRFS_FS` are modules now; both are in the initrd (the former in `initrdModules`, the latter through `boot.initrd.supportedFilesystems`) and were confirmed by a cold boot.

**Firmware package** (`pkgs/firmware-gaokun3/default.nix`). Model-specific files only, sourced through `lib.cleanSource`; the version is derived from the tree's content hash, so "the firmware changed but the version did not" cannot happen. The store copy keeps the tplg symlink. The licence is `unfreeRedistributable`, which is why the flake carries an `allowUnfreePredicate` for this one name and README documents the consumer-side equivalent.

**Tools package** (`pkgs/tools-gaokun3/default.nix`). `substituteInPlace` runs in `postPatch` on the source copy rather than on the installed output. Two hard-won details: `wrapGAppsHook4` moves the script to `.patch-nvm-bdaddr.py-wrapped` and execs it through an ELF stub, so the shebang has to be an absolute store path because NixOS has no `/usr/bin/env`; and the patcher takes the bare `python3` (standard library only) while the tuner takes the `pygobject3`-carrying interpreter. There is deliberately no `meta.license`: the patcher is GPL-2.0 but the tuner upstream declares no license at all, so no single SPDX identifier is true; a maintainer decision is still owed.

**ALSA UCM package** (`pkgs/alsa-ucm-conf-gaokun3/default.nix`). The merged tree is a package rather than a `runCommand` hidden inside the module, so it can be cached, overridden and asserted on. The module only sets `ALSA_CONFIG_UCM2` to it.

**The module** (`nixos/modules/hardware/gaokun3.nix`). Options: `enable`, `kernelPackages`, `firmware`, `binaryCache.enable`, `el2.enable`. There are deliberately no per-command-line options; the command line is one commented list, because inventing an option per parameter is restating a decision. `hardware.firmware` uses `mkBefore` (see the precedence trap). `boot.initrd.availableKernelModules` is the board's initrd set; `boot.kernelModules` its early-load set; `boot.extraModprobeConfig` carries the ath11k/QRTR `softdep` (a measured workaround for a multi-minute modprobe wedge, not a config compensation) and the lpass softdep. `boot.initrd.systemd.tpm2.enable = false` keeps a TPM core out of the initrd; `TCG_TPM=m` is what actually keeps systemd's generator from waiting. The NVM patcher's failure history is worth reading before touching it: it needs `cp -fL`/`readlink -f` because firmware names are symlinks (and `zstd` refuses a symlink), an absolute python shebang, a `systemd.tmpfiles` `/lib/firmware` symlink, and a write of only the override directory to `firmware_class.path` while refusing to run if `/lib/firmware` is missing.

**The installer** (`nixos/installer.nix`). A stock `installation-cd-minimal` live system with `hardware.gaokun3.enable`; the module replaces the El Torito EFI image with a systemd-boot ESP it builds (kernel, initrd, DTB, one BLS entry with `devicetree`). This is the device's native boot path and the reason the ISO boots without patching nixpkgs. `init=` in the entry is context-discarded so the ESP does not depend on the live closure; `checks.installer-wiring` builds the ESP and reads the entry back. `zfs`/`cifs` are forced off because the live kernel has neither and nixpkgs marks `zfs-kernel` broken against it. The ISO is exposed as `packages.aarch64-linux.installer-iso` and deliberately kept out of `checks.packages`.

**Checks** (`checks/default.nix`). `series-sync`, `firmware-symlinks`, `firmware-precedence`, `eval`, `el2-wiring`, `installer-wiring`, `config-symbols`, and `packages`. Only the aarch64 toplevel can be evaluated, so the module-facing checks exist for that system alone. `eval` keeps `builtins.unsafeDiscardStringContext` on the toplevel `drvPath`: without it the whole system closure becomes an input of a check that should build a one-line script. All but `packages` and `config-symbols` are cheap; the pull-request workflow builds `config-symbols` explicitly so evaluation-only runs still catch a kernel-config regression.

**Binary cache.** `gaokun3` is the project's cache; anyone's personal cache is a separate thing and the two should not be merged (different beneficiaries, the public key gets hardcoded downstream, different eviction). `nixConfig` only applies when this flake is top-level, which is why the module option and the README snippet exist. Cachix does not store paths `cache.nixos.org` already has, so the nixpkgs closure does not count against the quota; the cache is the free 5 GB tier and evicts by LRU, so old kernel versions can disappear and a rebuild falls back to compiling locally. The kernel's `-dev` output is filtered out of pushes for the same reason, and `installer-iso` is kept out of `checks.packages`: a ~2 GB image plus its squashfs would evict kernels by design.

## Kernel command line

The authoritative list is `kernelParams` in `nixos/modules/hardware/gaokun3.nix`. Every entry needs a reason:

| Parameter | Why |
| --- | --- |
| `clk_ignore_unused`, `pd_ignore_unused` | Documented SC8280XP workarounds. `pd_ignore_unused` may be obsolete since power-domain `sync_state` landed — untested here. |
| `arm64.nopauth`, `efi=noruntime` | Documented 8cx Gen 3 firmware workarounds. The firmware also cannot write EFI variables, which is why systemd-boot installs to the removable path. |
| `fbcon=rotate:1` | Portrait panel. |
| `usbhid.quirks=0x12d1:0x10b8:0x20000000` | Huawei keyboard. |
| `plymouth.enable=0` | Plymouth draws through DRM and ignores `fbcon=rotate:1`, so splash and details view come out sideways. UX, not boot safety. Redundant on NixOS, where Plymouth is not enabled, but harmless. |
| `pcie_aspm.policy=powersupersave` | Global policy override with no precedent and no measurement behind it. Candidate for removal. |
| `modprobe.blacklist=simpledrm` | EL2 entry only; what it fixes is not recorded (see below). |

Removed as no-ops and not to be reintroduced: `consoleblank=0` (`blankinterval` starts at 0 in `drivers/tty/vt/vt.c`) and `psi=1` (`CONFIG_PSI=y`, `PSI_DEFAULT_DISABLED` unset). `systemd.tpm2_wait=0` has been documented for 8cx Gen 3 but has never been shown necessary here.

## Known divergences not yet addressed

The live list. Anything needing hardware evidence goes to the user.

- **`systemd-backlight@backlight:ae96000.dsi.0` fails on the current base** with `Failed to write system 'brightness' attribute: Invalid argument`, so the panel brightness is not restored after a reboot. The panel driver itself is fine. Whether it is a race (the unit run before the panel is ready) or a deterministic regression is undecided: `systemctl restart 'systemd-backlight@backlight:ae96000.dsi.0'` on the device settles it — still failing means the driver, succeeding means the unit needs `After=` or a retry.
- **USB-C/UCSI noise.** `ucsi_huawei_gaokun` logs `connector is not initialized yet` on some boots, with occasional `PPM init failed` and `failed to register alt modes`. It predates the kernel-config change and is not a regression, but PD/alt-mode behaviour with a dock or a DP monitor has not been checked.
- **The EL2 ESP payload install has only been checked at evaluation.** The device run of the EL2 entry used payloads an earlier install had already put on the shared ESP, so the module's own `extraFiles` copy and its removal are covered by `checks.el2-wiring` but not by a device boot. It is worth exercising both directions once.
- **What `modprobe.blacklist=simpledrm` actually fixes** is recorded nowhere. Comparing the EL2 boot with and without it (`dmesg | grep -i simpledrm`, `/sys/class/drm/`, whether anything appears) settles it; until then it is reproduced as-is.
- **`boot.initrd.systemd.tpm2.enable = false` may be droppable.** Its remaining job is only to keep a TPM core out of the initrd, which needs a cold boot to confirm.
- **The `-dev` output size needs re-measuring** now that the base enables `DEBUG_INFO`/BTF, both for the cache quota and for CI time.
- **`gaokun3-tools` has no `meta.license`** and needs a maintainer decision (see the package notes).

## Rejected alternatives

- **A second repository for the NixOS side.** `patches/ dts/ firmware/ tools/` are the single source of truth, so splitting either duplicates them or turns this repository into a flake input. The independent lock and CI are not worth the synchronisation cost at this size.
- **Pushing the gaokun3 packages to a personal cache.** The beneficiaries are all gaokun3 owners, the public key gets hardcoded in other people's configurations (so it can never be rotated without breaking them), and a personal cache's eviction policy is tied to one machine's generations.
- **An option per kernel command line parameter.** It restates decisions the module already makes and makes the module API drift with the kernel; the command line stays one commented list.
- **Opening `enableCommonConfig` in the same change as the packaging rework.** The two risks are independent; keeping the kernel-config change in its own commit is what made the one failure it did have (the 90 s TPM regression) attributable and revertible.

## Conventions

Commit subjects are plain sentences in the imperative with no `type:` prefix, e.g. "Make EL2 a boot entry instead of a different system". The body carries the evidence: what upstream says, what was measured, what was rejected. `main` is the working branch; `main` and `gaokun3-nix` are the branches CI builds and caches. The user pushes.
