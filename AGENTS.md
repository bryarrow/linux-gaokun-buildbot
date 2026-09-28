# AGENTS.md

## What this repo is

NixOS support for the Huawei MateBook E Go (Qualcomm SC8280XP / "Gaokun3"): a flake that builds the gaokun3 kernel, the model firmware, the device tools and an installer image, plus a NixOS module that wires them together. The repository also carries the earlier Fedora build system (kernel RPMs, a Workstation disk image, a rescue USB), which is frozen and kept only as a recovery route.

Project use jujutsu VCS.

`build.env` pins `KERNEL_TAG` and `FEDORA_RELEASE` for the legacy Fedora build only; `nix/pins.nix` pins the kernel for Nix, and `checks.pins-sync` asserts the two agree. These are not per-run inputs; bumping either belongs in the same commit as the change that depends on it.

**For full architecture, conventions, and gotchas, read `CLAUDE.md`.** What follows is the minimum an agent needs to avoid mistakes without it.

## Validation commands

```sh
shellcheck scripts/ci/*.sh scripts/ci/lib/*.sh scripts/lib/*.sh scripts/local/*.sh
bash -n <script>
nix flake check --no-build          # evaluation only; the pull-request gate
nix flake check                      # builds checks, including the kernel
```

No test suite exists. The real verification is a CI run plus a boot on the device. `nix flake check --no-build` has to stay evaluation-only: the installer builds its own systemd-boot ESP instead of patching nixpkgs precisely so that this command keeps working.

## Key files and directories

NixOS (the main product):

- `flake.nix` — Outputs: packages, overlay, NixOS module, checks, installer ISO.
- `nix/pins.nix` — Kernel tag/version/tarball/hash, Nix-side source of truth.
- `nix/lib/patch-series.nix` — Reads `patches/*/series`; throws at evaluation if a directory and its series disagree.
- `nix/config/gaokun3-extra.nix` — The reviewed kernel-config delta over nixpkgs' common config.
- `pkgs/` — Kernel, EL2 kernel, firmware, tools, ALSA UCM.
- `nixos/modules/hardware/gaokun3.nix` — The `hardware.gaokun3` module.
- `nixos/installer.nix` — The installation medium's systemd-boot ESP.
- `checks/default.nix` — What `nix flake check` runs.

Legacy Fedora pipeline:

- `scripts/ci/` — Numbered CI scripts, run in order (10→70). Each reads required env vars.
- `scripts/ci/lib/` — Shared shell libraries sourced by the CI scripts.
- `scripts/lib/import_local_sources.sh` — Copies `dts/` and `defconfig/` into the kernel tree.
- `scripts/local/build_kernel.sh` — Local kernel build helper; sources `build.env`.
- `packaging/rpm/*.spec.in` — RPM spec templates with `@PLACEHOLDER@` tokens. Rendered by `70_build_package_rpms.sh`, not parseable by `rpmspec`/`rpmlint` as-is.

Shared by both:

- `patches/`, `dts/`, `defconfig/`, `firmware/`, `tools/` — The single source of truth for both pipelines.
- `defconfig/` and `dts/` — Maintained as standalone files, not patches. Edit directly.
- `firmware/` — Contains symlinks. Use `git ls-files` or `find -mindepth 1` to enumerate; `find -type f` misses them. Dangling symlinks break `hashFiles` in workflows.

## Gotchas

- `patches/*/series` is the only ordering source and is checked by both `nix/lib/patch-series.nix` and the Fedora `apply_series`; a patch must be listed exactly once.
- `firmware/` symlinks: a dangling symlink breaks every CI job before it starts (kills `hashFiles`).
- RPM spec templates cannot be linted directly; validate by reading or by rendering first.
- Scripts use `: "${VAR:?}"` at the top to fail fast on missing env vars.
- Each CI script is self-contained with its own env requirements; there is no shared preamble that sets variables for you.
- The installer must not depend on a patched nixpkgs, or `nix flake check --no-build` stops evaluating; see `CLAUDE.md`.
