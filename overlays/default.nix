# This repository's packages, exposed for NixOS configurations. The names point
# at the flake's own builds rather than at copies rebuilt with the consumer's
# nixpkgs, so a derivation -- and with it its binary cache entry -- is the same
# for every consumer. That is the property a stock kernel gets from being part
# of one nixpkgs; a third-party kernel has to pin its own.
{self}: final: prev: {
  linux-gaokun3 = self.packages.${prev.system}.linux-gaokun3;
  linuxPackages_gaokun3 = prev.linuxPackagesFor final.linux-gaokun3;
  linux-firmware-gaokun3 = self.packages.${prev.system}.firmware-gaokun3;
  gaokun3-tools = self.packages.${prev.system}.tools-gaokun3;
  alsa-ucm-conf-gaokun3 = self.packages.${prev.system}.alsa-ucm-conf-gaokun3;
}
