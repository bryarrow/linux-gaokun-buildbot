# AGENTS.md

## What this repo is

NixOS support for the Huawei MateBook E Go 2023 (Qualcomm SC8280XP / "Gaokun3"): a flake that builds the gaokun3 kernel, the model firmware, the device tools and an installer image, plus a NixOS module that wires them together.

Project uses jujutsu VCS.

`nix/pins.nix` is the single source of truth for the kernel tag, version, tarball and hash. A bump is not a per-run input: it belongs in the same commit as the patch refresh that depends on it.

**For full architecture, conventions, and gotchas, read `CLAUDE.md`.** What follows is the minimum an agent needs to avoid mistakes without it.

## Validation commands

```sh
nix flake check --no-build          # evaluation only; the pull-request gate
nix flake check                      # builds the checks, including the kernel
```

No test suite exists. The real verification is a CI run plus a boot on the device. `nix flake check --no-build` has to stay evaluation-only: the installer builds its own systemd-boot ESP instead of patching nixpkgs precisely so that this command keeps working.

## Key files and directories

- `flake.nix` — Outputs: packages, overlay, NixOS module, checks, installer ISO.
- `nix/pins.nix` — Kernel tag/version/tarball/hash, the single source of truth.
- `nix/lib/patch-series.nix` — Reads `patches/*/series`; throws at evaluation if a directory and its series disagree.
- `nix/config/gaokun3-extra.nix` — The reviewed kernel-config delta over nixpkgs' common config.
- `pkgs/` — Kernel, EL2 kernel, firmware, tools, ALSA UCM.
- `nixos/modules/hardware/gaokun3.nix` — The `hardware.gaokun3` module.
- `nixos/installer.nix` — The installation medium's systemd-boot ESP.
- `checks/default.nix` — What `nix flake check` runs.
- `patches/`, `dts/`, `firmware/`, `tools/` — The source of truth for the kernel patches, device tree, model firmware and device tools.

## Gotchas

- `patches/*/series` is the only ordering source and is checked by `nix/lib/patch-series.nix`; a patch must be listed exactly once.
- `firmware/` contains symlinks. Use `git ls-files` or `find -mindepth 1` to enumerate; `find -type f` misses them, and a dangling symlink breaks every CI job before it starts.
- `dts/` is copied into the kernel tree at build time, not carried as a patch; edit it directly.
- The installer must not depend on a patched nixpkgs, or `nix flake check --no-build` stops evaluating; see `CLAUDE.md`.
