# The EL2 variant: Linux as a guest on the vendor hypervisor instead of taking
# the machine over. The same source, patches and kernel config as linux-gaokun3
# with patches/el2 appended and the module directory renamed, which is what the
# Fedora pipeline ships as kernel-gaokun3-el2. CLAUDE.md calls this path
# experimental, so hardware.gaokun3.el2.enable defaults to false.
#
# The wrapper goes through pkgs.callPackage rather than re-listing the base's
# arguments, so the two packages cannot drift apart: adding a dependency to
# pkgs/linux-gaokun3 needs no change here.
#
# `...@args` is not decoration. NixOS's boot.kernelPackages override re-calls
# whatever kernel it was given with `features`, `randstructSeed` and
# `kernelPatches`, so a wrapper that only took `pkgs` breaks the moment
# hardware.gaokun3.el2.enable is set; the base file carries the same warning.
# el2 stays forced: a caller that wants the base kernel asks for
# linux-gaokun3, and an override that could turn this back into it would make
# the two package names lie.
{pkgs, ...}@args:
pkgs.callPackage ../linux-gaokun3 (builtins.removeAttrs args ["pkgs"] // {el2 = true;})
