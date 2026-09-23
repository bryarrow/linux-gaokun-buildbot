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
// lib.optionalAttrs (system == "aarch64-linux") {
  # The module is aarch64-only — it selects an aarch64 kernel and a device
  # tree — so this is the only system whose toplevel can be evaluated.
  #
  # Evaluate the module the way a user would and keep only the toplevel
  # drvPath, so the check builds a tiny script instead of a kernel. The
  # drvPath string carries a dependency context, which would otherwise make
  # the whole system closure an input of this check; discard it.
  eval = let
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
    toplevel = builtins.unsafeDiscardStringContext evaluated.config.system.build.toplevel.drvPath;
  in
    pkgs.runCommand "gaokun3-eval" {} ''
      echo ${toplevel} > $out
    '';

  # Building this forces every package output, which is the point: a push to
  # main builds the kernel here and cachix-action pushes it to the cache. It is
  # far too expensive for a pull request, which is why CI only evaluates there.
  # The cross-compiled x86_64 packages are deliberately not part of it.
  packages = pkgs.linkFarm "gaokun3-packages" (
    lib.mapAttrsToList (name: path: {inherit name path;}) self.packages.${system}
  );
}
