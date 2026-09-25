# The Gaokun3 deviation from nixpkgs' kernel policy.
#
# The kernel is built the way nixpkgs builds its own: the kernel's arm64
# defconfig as the base, nixpkgs' common config
# (pkgs/os-specific/linux/kernel/common-config.nix) as the distribution policy,
# and this file as the reviewed Gaokun deviation. Everything else -- the other
# arm64 platforms, the 52-bit VA layout, SELinux being off -- is nixpkgs'
# decision, inherited rather than restated.
#
# Keys are kernel_config.nix settings -- tristate / freeform / optional -- not
# raw CONFIG_ lines.
#
# generate-config.pl's fatal checks are left on, as nixpkgs leaves them, so an
# option that does not land fails the build. Only IMA below is declared
# `optional`; checks.config-symbols additionally builds the configfile and
# asserts every entry below actually landed, so a typo fails CI even where
# generate-config.pl would only warn.
{lib}: let
  # common-config.nix defines its options at priority 100, so overriding one
  # takes a lower priority number. 90 leaves mkForce (50) free for a user who
  # really wants to change it; this is the same idiom as zen-kernels.nix.
  hardwareOverride = lib.mkOverride 90;
in {
  # The kernel's arm64 defconfig carries no LOCALVERSION, and the module
  # directory is 7.2.0-gaokun3, so this is what modDirVersion is checked
  # against. The Fedora pipeline gets the same value from
  # defconfig/gaokun3_defconfig instead.
  LOCALVERSION = {freeform = "-gaokun3";};

  # nixpkgs' arm64 defconfig leaves Bluetooth LE off. The device pairs BLE
  # keyboards, mice and headsets, so this stays.
  BT_LE = {tristate = "y";};

  # Integrity defaults to "y" and the arm64 defconfig does not turn it off, so
  # common config's IMA request becomes visible and IMA's Kconfig selects
  # TCG_TPM builtin (security/integrity/ima/Kconfig:12). This machine has no
  # usable TPM under Linux -- it boots from the device tree, so ACPI stays
  # disabled at runtime and there is no microsoft,ftpm node -- so IMA would only
  # ever run in TPM-bypass, and the builtin TPM core costs 90 s of every boot
  # (see TCG_TPM below). Keep the pair off, as the pre-P3 defconfig did.
  INTEGRITY = {tristate = "n";};

  # common config asks for IMA, but IMA only exists when INTEGRITY is on, so with
  # INTEGRITY off nixpkgs' answer becomes an unreachable symbol -- and
  # generate-config.pl fails on an unused option that is not declared
  # `optional`. Relax that one check, restating nixpkgs' value so the override
  # changes nothing; the blunt ignoreConfigErrors would instead hide real
  # conflicts, as it did for the TCG_TPM=y that INTEGRITY once forced.
  IMA = hardwareOverride {
    tristate = "y";
    optional = true;
  };

  # The arm64 defconfig builds the TPM core in (arch/arm64/configs/defconfig
  # sets TCG_TPM=y). A builtin TPM core makes /sys/class/tpmrm exist from boot,
  # systemd's tpm2 generator then hooks tpm2.target -- whose unit says
  # Wants=dev-tpm0.device -- into sysinit.target, and the device never appears,
  # so the boot spends the full 90 s device timeout waiting. As a module the
  # class directory does not exist when the generator runs, which is how the
  # kernel behaved before P3. The override only sticks because INTEGRITY above
  # stops IMA from selecting it back to "y".
  TCG_TPM = hardwareOverride {tristate = "m";};

  # nixpkgs' 32 MiB is not enough for the panel and the camera pipeline.
  CMA_SIZE_MBYTES = hardwareOverride {freeform = "128";};

  # nixpkgs' default initrd module list names ehci_pci, ohci_pci and xhci_pci
  # (nixos/modules/system/boot/kernel.nix). They only exist when USB_PCI is
  # enabled, and the Gaokun3's own controllers are platform devices, so this is
  # explicit rather than inherited. It is what lets
  # boot.initrd.includeDefaultModules stay at its default.
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
