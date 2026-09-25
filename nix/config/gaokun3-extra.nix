# The Gaokun3 deviation from nixpkgs' kernel policy.
#
# P3 turns on nixpkgs' common config
# (pkgs/os-specific/linux/kernel/common-config.nix), which now owns the
# distribution policy. This file re-asserts only what the hardware forces.
# Keys are kernel_config.nix settings -- tristate / freeform / optional -- not
# raw CONFIG_ lines.
#
# The base is still defconfig/gaokun3_defconfig, so a symbol neither nixpkgs nor
# this file mentions keeps its Gaokun3 value. Comparing that defconfig against
# the common config left twelve real conflicts (both sides set a different
# value); all but CMA_SIZE_MBYTES are inherited, which is what drops the
# divergences the Fedora audit listed -- LSM order, preemption, tracing and
# whole driver families are nixpkgs' decisions now.
{lib}: let
  # common-config.nix defines its options at priority 100, so overriding one
  # takes a lower priority number. 90 leaves mkForce (50) free for a user who
  # really wants to change it; this is the same idiom as zen-kernels.nix.
  hardwareOverride = lib.mkOverride 90;
in {
  # nixpkgs' 32 MiB is not enough for the panel and the camera pipeline.
  CMA_SIZE_MBYTES = hardwareOverride {freeform = "128";};

  # nixpkgs' default initrd module list names ehci_pci, ohci_pci and xhci_pci
  # (nixos/modules/system/boot/kernel.nix). They only exist when USB_PCI is
  # enabled, and the Gaokun3's own controllers are platform devices, so the
  # defconfig had it off. Turning it on is what lets
  # boot.initrd.includeDefaultModules go back to its default.
  USB_PCI = {tristate = "y";};

  # v7.2 guards the Venus IRIS2 resources (VPU_VERSION_IRIS2 and the sm8250
  # tables sc8280xp_res shares) behind !CONFIG_VIDEO_QCOM_IRIS, while
  # autoModules answers "m" to every tristate question and would re-enable IRIS,
  # breaking the Venus build. IRIS does not support sc8280xp.
  VIDEO_QCOM_IRIS = {
    tristate = "n";
    optional = true;
  };
}
