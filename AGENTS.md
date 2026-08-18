# AGENTS.md

## What this repo is

Build system for custom Linux kernel and Fedora images targeting the Huawei MateBook E Go (Qualcomm SC8280XP / "Gaokun3"). Produces kernel RPMs, Fedora Workstation disk images, and USB rescue images via GitHub Actions.

Project use jujutsu VCS.

`build.env` pins `KERNEL_TAG` and `FEDORA_RELEASE` for the entire build. These are not per-run inputs; bumping either belongs in the same commit as the change that depends on it.

**For full architecture, conventions, and gotchas, read `CLAUDE.md`.** What follows is the minimum an agent needs to avoid mistakes without it.

## Validation commands

```sh
shellcheck scripts/ci/*.sh scripts/ci/lib/*.sh scripts/lib/*.sh scripts/local/*.sh
bash -n <script>
```

No test suite exists. The real verification is a CI run plus a boot on the device.

## Key files and directories

- `scripts/ci/` — Numbered CI scripts, run in order (10→70). Each reads required env vars.
- `scripts/ci/lib/` — Shared shell libraries sourced by the CI scripts.
- `scripts/lib/import_local_sources.sh` — Copies `dts/` and `defconfig/` into the kernel tree.
- `scripts/local/build_kernel.sh` — Local kernel build helper; sources `build.env`.
- `defconfig/` and `dts/` — Maintained as standalone files, not patches. Edit directly.
- `packaging/rpm/*.spec.in` — RPM spec templates with `@PLACEHOLDER@` tokens. Rendered by `70_build_package_rpms.sh`, not parseable by `rpmspec`/`rpmlint` as-is.
- `firmware/` — Contains symlinks. Use `git ls-files` or `find -mindepth 1` to enumerate; `find -type f` misses them. Dangling symlinks break `hashFiles` in workflows.

## Gotchas

- `firmware/` symlinks: a dangling symlink breaks every CI job before it starts (kills `hashFiles`).
- RPM spec templates cannot be linted directly; validate by reading or by rendering first.
- Scripts use `: "${VAR:?}"` at the top to fail fast on missing env vars.
- Each CI script is self-contained with its own env requirements; there is no shared preamble that sets variables for you.
