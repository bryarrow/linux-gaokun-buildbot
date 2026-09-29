# The rule "a patch directory is ordered by its series file, and that file
# lists every .patch in the directory exactly once", enforced at evaluation
# time: a patch added to a directory but left out of series (or listed twice)
# fails `nix flake check` before anything is compiled.
{lib}:
dir: let
  root = ../..;

  seriesFile = root + "/patches/${dir}/series";

  # Blank lines and comments are allowed; everything else names a patch.
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
