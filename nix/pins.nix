# Single source of truth, on the Nix side, for what this flake builds against.
#
# build.env pins the same kernel tag and Fedora release for the legacy Fedora
# pipeline. Nothing parses one from the other: the tarball hash has to be
# written by hand either way, and a text parse would only save `kernelTag`
# while adding a fragile coupling. `checks.pins-sync` asserts the two agree
# instead, and disappears together with the Fedora pipeline.
{
  # Tag and version are separate on purpose. The tag names the git ref the
  # release tarball was cut from; the version is what `make kernelrelease`
  # prints and what the module directory is named after.
  kernelTag = "v7.2";
  kernelVersion = "7.2.0";

  # kernel.org's /snapshot/ URLs are packaged on demand and are not guaranteed
  # to stay byte-identical, so their sha256 only proves the download was not
  # tampered with, not that it is the tree the patches were made against.
  # cdn.kernel.org's release tarball is the stable address.
  kernelTarballUrl = "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.tar.xz";
  kernelHash = "sha256-+f7z0UwN9TgZAm9L50RZg1wqCw3L9bW72eoZ8IKUArM=";

  fedoraRelease = "44";
}
