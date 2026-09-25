# The flake's `checks` output. Everything here is either an evaluation-time
# assertion or a cheap build; none of it compiles a kernel or boots a system.
{
  # The flake itself, for the module under `nixosModules`.
  self,
  lib,
  system,
  # Pre-configured with this flake's unfree predicate.
  pkgs,
  # The same predicate, for the NixOS evaluation below.
  allowUnfreePredicate,
}: let
  series = import ../nix/lib/patch-series.nix {inherit lib;};
  pins = import ../nix/pins.nix;

  # Evaluating this list makes nix/lib/patch-series.nix throw if any series
  # file has drifted from its directory.
  allSeries = lib.concatMap series ["upstream" "others" "himax" "media" "el2"];

  # build.env still pins KERNEL_TAG/FEDORA_RELEASE for the Fedora pipeline.
  # Nothing parses one file from the other; this asserts they agree, and goes
  # away with build.env.
  buildEnvLines = lib.splitString "\n" (builtins.replaceStrings ["\r"] [""] (builtins.readFile ../build.env));
  pinsDrift =
    lib.filter (line: !(lib.elem line buildEnvLines)) [
      "KERNEL_TAG=${pins.kernelTag}"
      "FEDORA_RELEASE=${pins.fedoraRelease}"
    ];
in {
  # The throw in nix/lib/patch-series.nix already fails evaluation; this makes
  # it a named check as well.
  series-sync =
    pkgs.runCommand "gaokun3-series-sync" {} ''
      echo ${lib.escapeShellArgs (map (p: p.name) allSeries)} > $out
    '';

  pins-sync =
    if pinsDrift != []
    then throw "nix/pins.nix and build.env disagree; build.env has no line: ${lib.concatStringsSep ", " pinsDrift}"
    else pkgs.runCommand "gaokun3-pins-sync" {} "touch $out";

  # A dangling symlink under firmware/ also kills every Fedora job at
  # hashFiles, before it starts. `find -xtype l` is the exact test, and it has
  # to run at build time: Nix exposes no way to read a link's target during
  # evaluation, and builtins.pathExists returns true for a broken link.
  # Interpolating the link on its own would be useless anyway, since its
  # relative target only resolves next to its siblings.
  firmware-symlinks =
    pkgs.runCommand "gaokun3-firmware-symlinks" {} ''
      broken="$(find ${../firmware} -xtype l)"
      if [ -n "$broken" ]; then
        echo "dangling symlink(s) under firmware/:" >&2
        echo "$broken" >&2
        exit 1
      fi
      touch $out
    '';
}
// lib.optionalAttrs (system == "aarch64-linux") (let
  # The module is aarch64-only — it selects an aarch64 kernel and a device
  # tree — so this is the only system whose toplevel can be evaluated. Build it
  # once and reuse it for the checks below.
  evaluated = lib.nixosSystem {
    system = "aarch64-linux";
    modules = [
      self.nixosModules.gaokun3
      {
        hardware.gaokun3.enable = true;
        nixpkgs.config.allowUnfreePredicate = allowUnfreePredicate;
        # Just enough of a system for the toplevel assertions to pass. The
        # device boots through systemd-boot, see README.
        boot.loader.systemd-boot.enable = true;
        fileSystems."/" = {
          device = "/dev/disk/by-label/nixos";
          fsType = "ext4";
        };
        system.stateVersion = "26.11";
      }
    ];
  };

  # `hardware.firmware` builds a buildEnv with ignoreCollisions, and the winner
  # of a name present in several packages is decided by priority first and by
  # input order only when the priorities are equal (builder.pl:159). The module
  # uses mkBefore, but that alone is not the reason ours wins: linux-firmware
  # carries meta.priority = 6 and our package takes the default 5. This asserts
  # the outcome from those two facts, without building linux-firmware.
  firmwareNames = map (p: p.name or "") evaluated.config.hardware.firmware.paths;
  indexWhere = pred:
    lib.findFirst (i: pred (lib.elemAt firmwareNames i)) null
    (lib.range 0 (lib.length firmwareNames - 1));
  gaokun3Index = indexWhere (name: lib.hasPrefix "linux-firmware-gaokun3" name);
  stockIndex = indexWhere (
    name: lib.hasPrefix "linux-firmware-" name && !(lib.hasPrefix "linux-firmware-gaokun3" name)
  );
  firmwarePriorities = {
    gaokun3 = self.packages.${system}.firmware-gaokun3.meta.priority or lib.meta.defaultPriority;
    stock = pkgs.linux-firmware.meta.priority or lib.meta.defaultPriority;
  };
  firmwareWins =
    firmwarePriorities.gaokun3 < firmwarePriorities.stock
    || (firmwarePriorities.gaokun3 == firmwarePriorities.stock && gaokun3Index < stockIndex);

  # Keep only the toplevel drvPath, so the check builds a tiny script instead
  # of a kernel. The drvPath string carries a dependency context that would
  # otherwise make the whole system closure an input of the check.
  toplevel = builtins.unsafeDiscardStringContext evaluated.config.system.build.toplevel.drvPath;

  kernel = self.packages.${system}.linux-gaokun3;
in {
  eval = pkgs.runCommand "gaokun3-eval" {} ''
    echo ${toplevel} > $out
  '';

  firmware-precedence =
    if gaokun3Index != null && stockIndex != null && firmwareWins
    then pkgs.runCommand "gaokun3-firmware-precedence" {} "touch $out"
    else throw ''
      gaokun3 firmware would lose to linux-firmware in hardware.firmware:
      priorities gaokun3=${toString firmwarePriorities.gaokun3} stock=${toString firmwarePriorities.stock},
      order gaokun3=${toString gaokun3Index} stock=${toString stockIndex},
      list: ${lib.concatStringsSep ", " firmwareNames}
    '';

  # generate-config.pl already fails the kernel build when a required option does
  # not land, but it cannot see the values inherited from the arm64 defconfig,
  # and nix/config/gaokun3-extra.nix declares one entry `optional`. This check
  # builds the configfile -- minutes, not a kernel compile -- and asserts the
  # delta and the assumptions behind it actually landed.
  #
  # The pull-request workflow builds this check explicitly, because
  # `nix flake check --no-build` only evaluates and would never catch a config
  # regression.
  config-symbols = pkgs.runCommand "gaokun3-config-symbols" {} ''
    cfg=${kernel.configfile}

    # nix/config/gaokun3-extra.nix
    grep -qx 'CONFIG_CMA_SIZE_MBYTES=128' "$cfg"
    grep -qx 'CONFIG_USB_PCI=y' "$cfg"
    grep -qx 'CONFIG_BT_LE=y' "$cfg"
    grep -qx '# CONFIG_VIDEO_QCOM_IRIS is not set' "$cfg"

    # TCG_TPM is pinned to a module and INTEGRITY stays off. A builtin TPM core
    # makes /sys/class/tpmrm exist from boot, and systemd's tpm2 generator then
    # waits the full 90 s device timeout for a /dev/tpm0 this machine cannot
    # provide (see nix/config/gaokun3-extra.nix).
    grep -qx '# CONFIG_INTEGRITY is not set' "$cfg"
    grep -qx 'CONFIG_TCG_TPM=m' "$cfg"

    # IMA is only reachable with INTEGRITY, so it must not be built. The
    # fragment marks nixpkgs' unusable answer `optional` to keep it a warning;
    # this is what makes sure the relaxation cannot become a silent "y".
    if grep -q '^CONFIG_IMA=' "$cfg"; then
      echo "IMA is built, which needs INTEGRITY and the builtin TPM core" >&2
      exit 1
    fi

    # Identity: the module directory and CONFIG_LOCALVERSION must agree.
    grep -qx 'CONFIG_LOCALVERSION="-gaokun3"' "$cfg"

    # TCG_CRB is built now, because the kernel's own arm64 defconfig sets ACPI
    # and the Gaokun defconfig did not. It cannot bind on this machine: the
    # bootloader passes a real device tree, so `dt_is_stub()` is false and
    # arch/arm64/kernel/acpi.c leaves ACPI disabled. The load-bearing guard
    # stays TCG_TPM=m above -- a builtin TPM core is what put
    # /sys/class/tpmrm in place before systemd's tpm2 generator ran.

    # CONFIG_LSM comes from the kernel default now; it must not name the
    # "integrity" LSM, which no longer exists in 7.2.
    if grep -q '^CONFIG_LSM=.*,integrity,' "$cfg"; then
      echo "CONFIG_LSM still names the removed integrity LSM" >&2
      exit 1
    fi

    touch $out
  '';

  # Building this forces every package, and the kernel's `modules` output
  # explicitly. A linkFarm only realises each package's default output, so `out`
  # would be cached while `modules` — which the system closure and the initrd
  # need — was not, and a device would still compile the kernel to get it. The
  # `dev` output comes out of the same build but the workflow's pushFilter keeps
  # it out of the cache. A push to main builds this and cachix-action's daemon
  # pushes the store paths; pull requests only evaluate, which is why the
  # expensive part lives here rather than in evaluation. The cross-compiled
  # x86_64 packages are deliberately not part of it.
  packages = pkgs.linkFarm "gaokun3-packages" (
    lib.mapAttrsToList (name: path: {inherit name path;}) self.packages.${system}
    ++ [{name = "linux-gaokun3-modules"; path = kernel.modules;}]
  );
})
