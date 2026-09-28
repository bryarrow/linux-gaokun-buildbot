# The Nix-side implementation of the rule "a patch directory is ordered by its
# series file, and that file lists every .patch in the directory exactly once".
#
# scripts/ci/20_build_kernel_variants.sh implements the same rule with
# apply_series() for the Fedora pipeline. The two have to agree: a patch added
# to a directory but left out of series would otherwise build in one pipeline
# and fail in the other. This one throws at evaluation time, so `nix flake
# check` rejects the tree before anything is compiled.
{lib}:
dir: let
  root = ../..;

  seriesFile = root + "/patches/${dir}/series";

  # Blank lines and comments are allowed; everything else names a patch.
  # scripts/ci/20_build_kernel_variants.sh's series_names() drops the same two,
  # so a series file one pipeline accepts the other accepts too.
  listed =
    lib.filter (line: line != "" && !(lib.hasPrefix "#" line))
    (lib.splitString "\n" (lib.replaceStrings ["\r"] [""] (builtins.readFile seriesFile)));

  present =
    lib.filter (lib.hasSuffix ".patch")
    (builtins.attrNames (builtins.readDir (root + "/patches/${dir}")));

  # lib.subtractLists x y is y without x, so these read "listed but absent" and
  # "present but not listed".
  missing = lib.subtractLists present listed;
  unlisted = lib.subtractLists listed present;
  # A set comparison cannot see a name listed twice, and duplicates would make
  # stdenv apply the same patch a second time and fail the build much later.
  duplicated = lib.unique (lib.filter (name: lib.count (other: other == name) listed > 1) listed);
in
  if missing != [] || unlisted != [] || duplicated != []
  then
    throw
    "patches/${dir}/series is out of sync with the directory: missing=[${lib.concatStringsSep " " missing}] unlisted=[${lib.concatStringsSep " " unlisted}] duplicated=[${lib.concatStringsSep " " duplicated}]"
  else
    map (name: {
      name = "${dir}/${lib.removeSuffix ".patch" name}";
      patch = root + "/patches/${dir}/${name}";
    })
    listed
