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

  # `hardware.firmware` builds a buildEnv with ignoreCollisions, and nixpkgs
  # resolves a name present in several packages to the first package in its
  # input list. The module uses mkBefore for that reason; this asserts the
  # outcome from the env's own input order, without building linux-firmware.
  firmwareNames = map (p: p.name or "") evaluated.config.hardware.firmware.paths;
  indexWhere = pred:
    lib.findFirst (i: pred (lib.elemAt firmwareNames i)) null
    (lib.range 0 (lib.length firmwareNames - 1));
  gaokun3Index = indexWhere (name: lib.hasPrefix "linux-firmware-gaokun3" name);
  stockIndex = indexWhere (
    name: lib.hasPrefix "linux-firmware-" name && !(lib.hasPrefix "linux-firmware-gaokun3" name)
  );

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
    if gaokun3Index != null && stockIndex != null && gaokun3Index < stockIndex
    then pkgs.runCommand "gaokun3-firmware-precedence" {} "touch $out"
    else throw "gaokun3 firmware must precede linux-firmware in hardware.firmware; got: ${lib.concatStringsSep ", " firmwareNames}";

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
