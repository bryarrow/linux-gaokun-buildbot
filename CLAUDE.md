# CLAUDE.md

This file provides guidance to agents working in this repository.

## Audience split

`README.md` and `docs/*.md` are written for someone who owns a MateBook E Go and wants to install, boot, dual-boot or repair it. Keep them to what such a person acts on. Build-system rationale, upstream evidence and rejected alternatives belong here instead, and inline comments stay to a line or two of local "why". If a comment or doc paragraph explains a distribution-policy decision, move it into this file rather than growing the source.

## Project goals, in order

When these conflict, the earlier one wins.

1. **The best experience on the MateBook E Go.** Hardware enablement comes before everything else. The device tree, kernel config, firmware bundle and quirks like `fbcon=rotate:1` stay even where they are unlike a stock NixOS system.
2. **A stock NixOS experience.** Build the kernel the way nixpkgs builds kernels — `buildLinux`, `enableCommonConfig`, a small reviewed gaokun3 delta — and write the module the way NixOS modules are written. Where the hardware does not force our hand, inherit NixOS's decision instead of restating it. This is the NixOS counterpart of the old "stock Fedora experience" goal, and the principle is what carries over: an explicit `systemctl enable` (or a hand-written boot entry, or a restated config symbol) for something nixpkgs already decides is dead weight at best and a silent divergence when nixpkgs changes its mind.
3. **Safe to daily drive.** No harder to break than any other NixOS install: generations and the systemd-boot menu are the rollback path, and no guard rails NixOS itself does not have.

The Fedora pipeline is legacy (see below). It is frozen, not developed, and the goal that applies to it is only that it keeps working as a recovery route.

## What gets built

### NixOS — the main product

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
| `overlays.default` | Injects the packages above plus `linuxPackages_gaokun3` |
| `nixosModules.gaokun3` (and `.default`) | The NixOS module, applying the overlay itself |
| `checks.<sys>.*` | See below; `nix flake check` runs them |

The source layout: `nix/pins.nix` (version, tarball, hash), `nix/lib/patch-series.nix`, `nix/config/gaokun3-extra.nix`, `pkgs/*/default.nix`, `nixos/modules/hardware/gaokun3.nix`, `nixos/installer.nix`, `checks/default.nix`. `patches/ dts/ defconfig/ firmware/ tools/` are shared with the Fedora pipeline and are the only source of truth for both — that is why this stays a single repository.

CI is `.github/workflows/gaokun3-nix.yml`, on an arm64 runner (the kernel's `meta.platforms` is aarch64). Pull requests run `nix flake check --no-build` plus a build of `checks.config-symbols`; pushes to `main`/`gaokun3-nix` run the full `nix flake check` and push to the project's Cachix cache through `cachix-action`. `checks.packages` is the derivation that forces every package (and explicitly the kernel's `modules` output) so the daemon pushes them; `installer-iso` is excluded from it on purpose.

### Fedora — legacy

Three GitHub Actions workflows, all `workflow_dispatch`, all sharing the numbered scripts in `scripts/ci/`:

| Workflow | Product |
| --- | --- |
| `gaokun3-package-rpms.yml` | `kernel-gaokun3`, `kernel-modules-gaokun3`, `kernel-devel-gaokun3`, `linux-firmware-gaokun3` (plus `*-el2` variants) |
| `fedora-gaokun3-release.yml` | Fedora Workstation disk image; optionally calls the RPM workflow first |
| `gaokun3-rescue-release.yml` | CLI-only USB rescue image |

`build.env` pins `KERNEL_TAG` and `FEDORA_RELEASE` for all of them — workflows read it into `$GITHUB_ENV` right after checkout, `scripts/local/build_kernel.sh` sources it, and the build guide tells the reader to. Neither value is a dispatch input, because `patches/` applies to exactly one kernel tag and the package set to one Fedora release; bumping either belongs in the commit that refreshes what depends on it.

The Nix side has its own pin in `nix/pins.nix`, and `checks.pins-sync` asserts the two agree. Once the Fedora workflow and `build.env` are deleted, that check and `build.env` go with them and `nix/pins.nix` is the only source.

Script order is the numeric prefix: `10` fetch prebuilt RPMs from a release → `20` build kernel variants → `30` bootstrap the rootfs with dnf → `50`/`55` create the image → `60`/`65` compress and write release notes. `70` builds the RPMs and is what `10` later downloads. Each script takes its inputs as required environment variables checked with `: "${VAR:?}"` at the top; the workflow YAML is the only caller that sets them.

## Verifying a change

The Fedora build needs Linux, `sudo`, loop devices and `dnf --installroot`, and is not worth running by hand even where it can run. The Nix side is verified by evaluation and cheap builds. Run:

```sh
shellcheck scripts/ci/*.sh scripts/ci/lib/*.sh scripts/lib/*.sh scripts/local/*.sh
bash -n <script>
nix flake check --no-build          # evaluation only; the pull-request gate
nix flake check                      # builds checks, including the kernel
```

`.shellcheckrc` sets `external-sources`/`source-path=SCRIPTDIR` so sourced libs resolve. There is no test suite; the real check is a CI run plus a boot on the device, which only the user can do. Privileged commands are handed to the user rather than run here.

`nix flake check --no-build` is not only a speed shortcut: it is the constraint that keeps the installer buildable without patching nixpkgs (see the installer notes below). Nothing that needs a store path produced during evaluation may enter a flake output, or that command stops working.

Claims about what Fedora ships are settled against a `fedora:<release>` image with the repos this build uses — `dnf --assumeno install <the image's package set>` names every package that actually lands, and `repoquery --whatprovides` names the owner of a file. Do that before quoting dist-git: `rawhide` is a different Fedora than the one being built.

RPM specs are `packaging/rpm/*.spec.in` templates with `@PLACEHOLDER@` tokens substituted by `render_spec_template` in `70_build_package_rpms.sh`; `rpmspec`/`rpmlint` cannot parse them directly.

## Easy things to get wrong

NixOS first, then the Fedora-legacy traps.

- **`patches/*/series` is the only ordering source, and it is checked twice.** `nix/lib/patch-series.nix` (`throw` at evaluation) and `apply_series()` in `20_build_kernel_variants.sh` both insist that a `series` file lists every `.patch` in its directory exactly once. Adding a patch without listing it, or changing the order, fails one side or the other. `patches/el2/series` exists for the same reason.
- **The kernel `src` carries `dts/` and `defconfig/`, not a `postPatch` on the kernel.** `buildLinux`'s `postPatch` is neither a parameter nor forwarded to `build.nix`; the configfile derivation does `postPatch = kernel.postPatch + …`, so a `postPatch` handed to `buildLinux` would be dropped and `gaokun3_defconfig` would be missing at configuration time with no error. `pkgs/linux-gaokun3/default.nix` therefore sets `src = applyPatches { … postPatch = "cp …"; }`, which both derivations inherit.
- **Base patches are prepended, and `…@args` is forwarded.** `kernelPatches = basePatches ++ (args.kernelPatches or [])`, so a user's `boot.kernelPatches` cannot displace the gaokun3 series, and the catch-all `args` is what lets NixOS's `linuxPackagesFor` override pass `features`/`randstructSeed`/`kernelPatches`. Do not name those as parameters: `callPackage` would inject `pkgs.kernelPatches` (a patch-set attrset) into the first one.
- **The kernel policy is nixpkgs' common config plus a reviewed delta.** `defconfig = "defconfig"` is the kernel's own arm64 defconfig; nixpkgs' `enableCommonConfig` supplies the distribution policy; `nix/config/gaokun3-extra.nix` is the whole Gaokun deviation and is entered with `lib.mkOverride 90` because common-config options are priority 100 and a same-priority redefinition is an error. `ignoreConfigErrors` is deliberately not set. `IMA` is restated as `optional = true` because `INTEGRITY=n` makes it unreachable; `INTEGRITY` itself stays off, because a builtin TPM core (which `IMA` forces through `select TCG_TPM`) makes systemd's tpm2 generator wait out the 90 s device timeout on a machine with no TPM. `checks.config-symbols` pins these down.
- **The overlay points at `self.packages`, and consumers must not set `nixpkgs.follows`.** The kernel derivation — and therefore its cache entry — has to be identical for every consumer. `overlays/default.nix` forwards to `self.packages.${system}`, and README tells users not to add `gaokun3.inputs.nixpkgs.follows = "nixpkgs"`, which would undo that.
- **`firmware/` contains symlinks, and `find -type f` hides them.** `SC8280XP-HUAWEI-GAOKUN3-tplg.bin` is a link to `HUAWEI/gaokun3/audioreach-tplg.bin`, which is the name the sound card asks for. Enumerate that tree with `git ls-files` or `find -mindepth 1`; a dangling symlink left behind also makes `hashFiles` in the workflows fail, which kills every job before it starts. `checks.firmware-symlinks` covers the Nix side.
- **The installer must not need a nixpkgs patch.** `nixos/iso-image.nix` boots GRUB without a device tree, which cannot boot this board, and upstream's fix (NixOS/nixpkgs#396334) is unmerged. Carrying it as `applyPatches`/`builtins.toFile` fails `nix flake check --no-build`, because the patched module must be readable during evaluation and neither mechanism produces a store path there. `nixos/installer.nix` instead builds a systemd-boot ESP and passes it as the El Torito image. Do not reintroduce a patched-nixpkgs input.
- **`hardware.gaokun3.el2.enable` is a boot entry, not a system switch.** It is a `specialisation`, so the normal entry keeps the stock kernel and DTB and EL1/EL2 is a menu choice; it also installs the shared ESP payloads as `boot.loader.systemd-boot.extraFiles`. Write it as `specialisation = lib.optionalAttrs cfg.el2.enable { … }`, never `specialisation.el2.configuration = lib.mkIf cfg.el2.enable …`, which would produce an empty el2 entry. `checks.el2-wiring` checks the whole contract.
- **The image is not built from Fedora's Workstation disk image.** `30_bootstrap_rootfs.sh` runs `dnf --installroot` inside a `fedora:<release>` container and installs comps groups (`@core @standard @gnome-desktop @workstation-product` plus the workflow's extras). "Stock Workstation" is therefore an outcome to check, not a starting point — a package the real Workstation image gets through the installer or through a weak dependency may simply be absent here. Check with a resolve run before asserting either way.
- **Service enablement is preset-driven, and the presets are in the rootfs.** On F44 `fedora-release-identity-workstation` ships `81-desktop.preset` (`disable sshd.socket`, `disable sshd.service`, cups socket activation) and `fedora-release-common` ships `85-display-manager.preset` (`enable gdm.service`) and `90-default.preset` (`enable NetworkManager.service`, and `enable sshd.service`, which 81 overrides by sorting first). Both land in our transaction, so the only `systemctl enable` the image needs is for units this repo ships. `preset-all` on first boot is enable-only, so it never undoes a disable.
- **A wrong `install_items` path in a dracut fragment is silent.** `dracut` calls `inst_multiple` without checking its return value, so a missing file prints `FAILED:` in the build log and the initramfs is built without it. Nothing downstream fails. Firmware added there has to be verified with `lsinitrd`.
- **The firmware bundle is model-specific only.** Everything generic — WCN6855, QCA Bluetooth, Adreno 660 — comes from the distribution's `atheros-firmware`/`qcom-firmware` (Fedora) or `linux-firmware` (NixOS), which ship it identical or newer. Before adding a file under `firmware/`, check whether the distribution already has it; if a distribution file has to be overridden, record the reason.
- **Fedora's dist-git `rawhide` branch is not the release being built.** The `redhat-systemd-presets*` packages that own the presets in rawhide do not exist on F44, where the same files ship inside `fedora-release-*`.

## NixOS architecture notes that span files

**Flake contract and cache identity.** `packages.<sys>.*` are built with this flake's pinned nixpkgs; `overlays/default.nix` exposes those derivations rather than rebuilding them with the consumer's nixpkgs, so every consumer gets the same derivation — and therefore the same binary-cache entry — per package. `nixosModules.gaokun3` applies the overlay, which is what keeps `hardware.gaokun3.enable = true` the only line a user writes.

**Kernel package** (`pkgs/linux-gaokun3/default.nix`). Built with `buildLinux`. Patches come from `nix/lib/patch-series.nix` in `series` order: `upstream`, `others`, `himax`, `media`, then `el2` when the variant is on. `src` is the cdn.kernel.org release tarball plus `applyPatches`' `postPatch`, which copies `dts/` and `defconfig/` into the tree (they are owned outright, not diffs, so a kernel bump cannot conflict in them). `defconfig = "defconfig"` and `enableCommonConfig = true` mean the policy is nixpkgs', with `nix/config/gaokun3-extra.nix` as the reviewed deviation; `LOCALVERSION` is restated per variant so the module directory is distinct. `linux-gaokun3-el2` is a one-line wrapper around the same file, so the two cannot drift; `…@args` forwarding is what lets it survive `boot.kernelPackages` overrides. `checks.config-symbols` builds both configfiles and asserts the delta and that the EL2 config differs from the base in `CONFIG_LOCALVERSION` alone.

**The module** (`nixos/modules/hardware/gaokun3.nix`). Options: `enable`, `kernelPackages`, `firmware`, `binaryCache.enable`, `el2.enable`. There are deliberately no per-command-line options; the command line is one commented list, because inventing an option per parameter is restating a decision. `hardware.firmware` uses `mkBefore` so the model firmware wins a name collision, and `checks.firmware-precedence` asserts the outcome from priority (ours defaults to 5, `linux-firmware` is 6) and order. `boot.initrd.availableKernelModules` is the model's initrd set; `boot.initrd.systemd.tpm2.enable = false` keeps a TPM core out of the initrd; `boot.extraModprobeConfig` carries the ath11k/QRTR `softdep` (a measured workaround, not a config compensation) and the lpass softdep. The NVM patcher's failure history is worth reading before touching it: it needs `cp -fL`/`readlink -f` because firmware names are symlinks, an absolute python shebang because NixOS has no `/usr/bin/env`, and it must write only the override directory to `firmware_class.path` (that parameter is one directory, not a colon-separated list) while refusing to run if `/lib/firmware` is missing.

**The installer** (`nixos/installer.nix`). A stock `installation-cd-minimal` live system with `hardware.gaokun3.enable`; the module replaces the El Torito EFI image with a systemd-boot ESP it builds (kernel, initrd, DTB, one BLS entry with `devicetree`). This is the device's native boot path and the reason the ISO boots without patching nixpkgs. `init=` in the entry is context-discarded so the ESP does not depend on the live closure; `checks.installer-wiring` builds the ESP and reads the entry back. `zfs`/`cifs` are forced off because the live kernel has neither and nixpkgs marks `zfs-kernel` broken against it. The ISO is exposed as `packages.aarch64-linux.installer-iso` and deliberately kept out of `checks.packages`.

**Checks** (`checks/default.nix`). `series-sync`, `pins-sync`, `firmware-symlinks`, `firmware-precedence`, `eval`, `el2-wiring`, `installer-wiring`, `config-symbols`, and `packages`. All but `packages` and `config-symbols` are cheap; the pull-request workflow builds `config-symbols` explicitly so evaluation-only runs still catch a kernel-config regression.

**Binary cache.** `berrys-nixos` is one machine's cache and `gaokun3` is the project's; keep them separate (different beneficiaries, the public key gets hardcoded downstream, different eviction). `nixConfig` only applies when this flake is top-level, which is why the module option and README snippet exist. Cachix does not store paths `cache.nixos.org` already has, and the kernel `-dev` output is filtered out.

## Legacy Fedora architecture notes

**Kernel source assembly** (`20_build_kernel_variants.sh`): the same `patches/*/series` and the same `scripts/lib/import_local_sources.sh` copy of `dts/` and `defconfig/` as the Nix side uses. The base tree is snapshotted before `patches/el2/*` is applied, so the EL2 variant is a second build of the same source with `LOCALVERSION=-gaokun3-el2`.

**Boot layout** is BLS via `kernel-install` (`layout=bls`), with systemd-boot on a 1 GiB ESP; nothing boots out of `/boot`. Invariants that several files depend on together:

- `--entry-token=os-id` everywhere, recorded in `/etc/kernel/entry-token`. The default `machine-id` token would resolve differently on the device than at build time and orphan the entries. The rescue image uses its own token so a stick and a target install never collide.
- `kernel-install` owns the initramfs. Never call `dracut` before it: `50-dracut.install` builds into its own staging area and only reuses a pre-built image named `initrd` next to the kernel, which `dracut --force`'s `/boot/initramfs-<kver>.img` is not.
- `/etc/machine-id` ships as `uninitialized`, matching Fedora's kiwi `config.sh`. systemd treats missing or `uninitialized` as first boot; an *empty* file gets an id but is explicitly not a first boot. Because first boot now really fires, `systemd-firstboot` pre-answers locale/keymap/timezone at build time (as kiwi does for `<locale>/<keytable>/<timezone>`), or `systemd-firstboot.service` — ordered before `sysinit.target` with `StandardInput=tty` — would block the boot in front of gdm.
- `kernel-gaokun3`'s `%posttrans` rewrites `loader.conf`'s `default` so an installed kernel becomes the booting one; the EL2 package must never claim it.
- Fedora's `51-dracut-rescue.install` is symlinked to `/dev/null`: its `0-rescue` entry carries no `devicetree` and cannot boot this device.

**Image assets** shared by both Fedora images live in `tools/image-assets/` and are installed by `scripts/ci/lib/common_image.sh`, which also selects the `desktop` or `rescue` module-load profile. Adding a file under `modules-load.d/` requires updating the `rescue` profile's explicit list. The Nix module expresses the same values as `environment.etc`, `boot.extraModprobeConfig` and `boot.kernelModules`; if the Fedora side is ever deleted, the duplicated files under `tools/image-assets/` should go with it.

## Legacy Fedora alignment

The ownership boundary on the Fedora side: Fedora owns distribution policy, boot layout, kernel lifecycle, package composition, security defaults and generic firmware. This repository owns the Gaokun3 DTB, the drivers and fixes that are not upstream yet, model firmware, physical display/input quirks, and the experimental EL2 path. When something here answers a question Fedora already answers, match Fedora. The NixOS side draws the same line against nixpkgs and NixOS.

Reference points worth re-reading before changing Fedora boot or image behaviour: Fedora's [`fedora-kiwi-descriptions`](https://pagure.io/fedora-kiwi-descriptions) `config.sh` and `Fedora.kiwi`, the [Snapdragon WoA install page](https://fedoraproject.org/wiki/Snapdragon_WoA_Laptop_Install), and Fedora's kernel dist-git scriptlets.

### Kernel command line

The authoritative NixOS list is the `kernelParams` list in `nixos/modules/hardware/gaokun3.nix`; the Fedora images set the same entries in `50_make_image_fedora.sh` and `55_make_image_rescue.sh`. Every entry needs a reason:

| Parameter | Why |
| --- | --- |
| `clk_ignore_unused`, `pd_ignore_unused` | Fedora-documented SC8280XP workarounds. `pd_ignore_unused` may be obsolete since power-domain `sync_state` landed — untested here. |
| `arm64.nopauth`, `efi=noruntime` | Fedora-documented 8cx Gen 3 firmware workarounds |
| `fbcon=rotate:1` | Portrait panel |
| `usbhid.quirks=0x12d1:0x10b8:0x20000000` | Huawei keyboard |
| `plymouth.enable=0` | Plymouth draws through DRM and ignores `fbcon=rotate:1`, so splash and details view come out sideways. UX, not boot safety. Redundant on NixOS, where Plymouth is not enabled, but harmless. |
| `pcie_aspm.policy=powersupersave` | Global policy override with no precedent and no measurement behind it. Candidate for removal. |
| `modprobe.blacklist=simpledrm` | EL2 entry only |

Removed as no-ops and not to be reintroduced: `consoleblank=0` (`blankinterval` starts at 0 in `drivers/tty/vt/vt.c`) and `psi=1` (`CONFIG_PSI=y`, `PSI_DEFAULT_DISABLED` unset). `systemd.tpm2_wait=0` is documented by Fedora for 8cx Gen 3 but has never been shown necessary here.

### Known Fedora divergences not yet addressed

An external audit (2026-08-13, against `f224d2f`) catalogued these. Fixed since: machine-id first-boot semantics, the duplicate `dracut` run, dead cmdline entries, a `modules-load.d/battery.conf` naming built-in drivers, `systemctl` calls restating Fedora presets, the firmware package's forced erasure of Fedora's, the triplicated dracut fragment, and `%posttrans` doing boot-entry work with no ESP. What remains, roughly by value — none of it blocks the legacy pipeline's only remaining job, which is the rescue USB:

- `defconfig/gaokun3_defconfig` is an independent distribution kernel policy, not a delta over Fedora's aarch64 config. The Nix kernel no longer uses it (`defconfig = "defconfig"`); it is kept because the Fedora pipeline still selects it.
- The kernel RPMs do not implement Fedora's kernel package semantics (`installonlypkg(kernel)`, `kernel-uname-r` provides, module-tree layout), and compensate with `/etc/dnf/protected.d` and a global `excludepkgs`. The Fedora-kernel exclusion itself is justified — stock kernels cannot boot this device.
- The `add_drivers` list in the packaged dracut fragment is unpruned: with `hostonly=no`, most of it is redundant, and only what is needed before switch-root belongs there. Trimming it needs `lsinitrd` plus a cold boot.
- The remaining `modules-load.d` files force modules that should autoload from DT/PCI/HID aliases. Each removal needs a cold-boot log, not reasoning.
- The package selection is a curated remix (pruned Workstation plus RPM Fusion and `libavcodec-freeworld`), which is not stock Workstation.
- The standard image uses systemd-boot where Fedora aarch64 uses GRUB+BLS; that choice is what creates the ESP-copy, entry-token, rescue-entry and default-selection machinery.

Anything requiring hardware evidence (module autoload, ASPM, `pd_ignore_unused`) can only be settled by the user on the device — ask for a cold-boot log rather than guessing.

### Known NixOS divergences not yet addressed

Catalogued in `NIXOS-MIGRATION.md` §11.4, which is the live list: the backlight unit after the P3 base switch, USB-C/UCSI noise, the untested ESP side of the EL2 payload install, and what `modprobe.blacklist=simpledrm` actually fixes. The `-dev` output needs re-measuring now that `DEBUG_INFO`/BTF are on. Anything needing hardware evidence goes to the user, as above.

## Conventions

Commit subjects are plain sentences in the imperative with no `type:` prefix, e.g. "Mount the ESP the way Fedora does, and stop building initramfses twice". The body carries the evidence: what upstream says, what was measured, what was rejected. `main` is the working branch; the user pushes.
