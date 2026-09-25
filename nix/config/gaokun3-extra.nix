# The Gaokun3 deviation from nixpkgs' kernel policy.
#
# P3 turns on nixpkgs' common config
# (pkgs/os-specific/linux/kernel/common-config.nix), which now owns the
# distribution policy. This file re-asserts only what the hardware or an
# explicit decision forces. Keys are kernel_config.nix settings -- tristate /
# freeform / optional -- not raw CONFIG_ lines.
#
# The base is still defconfig/gaokun3_defconfig, so a symbol neither nixpkgs nor
# this file mentions keeps its Gaokun3 value. Comparing that defconfig against
# the common config left twelve real conflicts; all but CMA_SIZE_MBYTES are
# inherited, and the divergences the Fedora audit listed -- tracing and whole
# driver families -- are nixpkgs' decisions now.
#
# The kernel package disables generate-config.pl's fatal checks because against
# 7.2.0 some common-config options are unused. checks.config-symbols is what
# puts a guarantee back: it builds the configfile and asserts every entry below
# (and the other deltas) actually landed, so a typo or an invisible symbol fails
# CI instead of silently doing nothing.
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

  # INTEGRITY is deliberately NOT set here, even though common-config.nix asks
  # for IMA and IMA is only visible under it. Enabling INTEGRITY makes IMA's
  # Kconfig select TCG_TPM (security/integrity/ima/Kconfig:12), which turns the
  # TPM core from a module into a builtin; /sys/class/tpmrm then exists from
  # boot, systemd's tpm2 generator hooks tpm2.target -- whose unit says
  # Wants=dev-tpm0.device -- into sysinit.target, and the boot spends the full
  # 90 s device timeout waiting for a TPM this machine does not have. That cost
  # 90 s of boot on 2026-09-25 and was reverted the same day. IMA would run in
  # TPM-bypass here anyway (device tree boot, no ACPI, no microsoft,ftpm node),
  # so nothing was gained. checks.config-symbols asserts both ends of the chain.

  # v7.2 guards the Venus IRIS2 resources (VPU_VERSION_IRIS2 and the sm8250
  # tables sc8280xp_res shares) behind !CONFIG_VIDEO_QCOM_IRIS, while
  # autoModules answers "m" to every tristate question and would re-enable IRIS,
  # breaking the Venus build. IRIS does not support sc8280xp.
  VIDEO_QCOM_IRIS = {
    tristate = "n";
    optional = true;
  };
}
