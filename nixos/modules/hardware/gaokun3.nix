{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hardware.gaokun3;

  # These names come from the flake's overlay, which points at the packages
  # this repository builds with its own pinned nixpkgs rather than at copies
  # rebuilt with the consumer's. That is what keeps the kernel's derivation —
  # and so its binary cache entry — identical for every consumer.
  firmware = pkgs.linux-firmware-gaokun3;
  tools = pkgs.gaokun3-tools;

  # Mirrors the Fedora image's dracut add_drivers, minus btrfs (NixOS stages
  # the root-filesystem driver itself) and the firmware_class path.
  initrdModules = [
    "nvme"
    "phy-qcom-qmp-pcie"
    "phy-qcom-qmp-combo"
    "phy-qcom-qmp-usb"
    "phy-qcom-snps-femto-v2"
    "usb-storage"
    "uas"
    "typec"
    "pci-pwrctrl-pwrseq"
    "ath11k"
    "ath11k_pci"
    "i2c-hid-of"
    "lpasscc_sc8280xp"
    "snd-soc-sc8280xp"
    "pinctrl_sc8280xp_lpass_lpi"
  ];

  # tools/image-assets/etc/modules-load.d, the desktop profile.
  bootModules = [
    "panel-himax-hx83121a"
    "himax_hx83121a_spi"
    "msm"
    "hid_multitouch"
    "pci-pwrctrl-pwrseq"
    "ath11k_pci"
    "btqca"
    "uhid"
    "lpasscc_sc8280xp"
    "snd-soc-sc8280xp"
  ];

  # Kernel command line from 50_make_image_fedora.sh, minus root= and
  # rootflags= which NixOS derives from its own configuration. The plymouth
  # entry is redundant with plymouth disabled on NixOS but harmless and
  # documents why the splash is off: plymouth draws through DRM and ignores
  # fbcon=rotate:1, so it comes out sideways on this portrait panel.
  kernelParams = [
    "clk_ignore_unused"
    "pd_ignore_unused"
    "arm64.nopauth"
    "pcie_aspm.policy=powersupersave"
    "efi=noruntime"
    "fbcon=rotate:1"
    "usbhid.quirks=0x12d1:0x10b8:0x20000000"
    "plymouth.enable=0"
  ];
in {
  options.hardware.gaokun3 = {
    enable = lib.mkEnableOption ''
      support for the Huawei MateBook E Go 2023 (gaokun3 / Qualcomm SC8280XP)
    '';

    kernelPackages = lib.mkOption {
      type = lib.types.unspecified;
      default = pkgs.linuxPackages_gaokun3;
      defaultText = lib.literalExpression "pkgs.linuxPackages_gaokun3";
      description = "The gaokun3 kernel package set to boot with.";
    };

    firmware = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [pkgs.linux-firmware-gaokun3];
      defaultText = lib.literalExpression "[ pkgs.linux-firmware-gaokun3 ]";
      description = ''
        Model-specific firmware packages, merged ahead of linux-firmware so the
        same name resolves to the gaokun3 copy.
      '';
    };

    binaryCache = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Use the project's Cachix cache as a substituter and trust its signing
          key, so the gaokun3 kernel is downloaded instead of compiled locally.

          Trusting a public key applies to every build on this machine, not
          only gaokun3's, which is why this is a switch. Turning it off leaves
          the system's substituter configuration untouched: the build still
          works, it just compiles the kernel here. See the README for the
          equivalent `nix.conf` and flake snippets.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    boot.kernelPackages = cfg.kernelPackages;

    boot.kernelParams = kernelParams;

    hardware.deviceTree = {
      enable = true;
      name = "qcom/sc8280xp-huawei-gaokun3.dtb";
    };

    # WCN6855, QCA Bluetooth and Adreno 660 firmware come from linux-firmware,
    # as on the Fedora image (atheros-firmware / qcom-firmware).
    hardware.enableRedistributableFirmware = lib.mkDefault true;
    # `hardware.firmware` resolves a name present in several packages to the
    # first one in its list, so our copy has to come before linux-firmware's.
    # mkBefore makes that ordering a guarantee instead of a by-product of the
    # module merge order. checks.firmware-precedence covers the result.
    hardware.firmware = lib.mkBefore cfg.firmware;

    hardware.bluetooth.enable = lib.mkDefault true;

    # The project's own cache, separate from any personal one, because its
    # beneficiaries are all gaokun3 owners and its kernel paths are long-lived
    # assets that should not be evicted with a system configuration.
    nix.settings = lib.mkIf cfg.binaryCache.enable {
      extra-substituters = ["https://gaokun3.cachix.org"];
      extra-trusted-public-keys = ["gaokun3.cachix.org-1:ikL6EofK55QEwKucrUo44SPKewscvAMJr7ibBxJtIsI="];
    };

    # The defconfig is an independent distribution kernel policy (the Fedora
    # build applies nothing on top of it), so several modules in NixOS's
    # default initrd list (ehci_pci, uhci_hcd, ohci_pci, hid_apple, sata_*,
    # ...) have no .ko here and would fail the modules-closure shrink. USB is
    # builtin xhci; the initrdModules list above is the complete set.
    boot.initrd.includeDefaultModules = false;
    boot.initrd.availableKernelModules = initrdModules;
    boot.kernelModules = bootModules;
    # The systemd initrd's default TPM2 support adds tpm-crb to the initrd
    # modules, but this kernel has no CRB driver (only tpm-tis / tpm_ftpm_tee)
    # and the plain NVMe root needs no initrd TPM; otherwise the modules-closure
    # shrink fails on the missing module.
    boot.initrd.systemd.tpm2.enable = false;
    # ath11k's probe synchronously request_module()s the QRTR family
    # (net-pf-42) from an async workqueue while qrtr.ko depends on ath11k and
    # mhi. When qrtr is not already loaded the modprobe chain can wedge the
    # module machinery in S-state for minutes, stalling the firewall service
    # and the udev event storm. Load the family before ath11k_pci.
    boot.extraModprobeConfig = ''
      softdep pinctrl_sc8280xp_lpass_lpi pre: lpasscc_sc8280xp
      softdep ath11k_pci pre: qrtr
    '';

    # The Fedora image's patch-nvm-bdaddr.service rewrites
    # /lib/firmware/qca/wcnhpnv21g.bin in place. NixOS firmware lives in the
    # read-only store, so copy the NVM to a writable dir, patch there, and make
    # the kernel look there first by prepending it to firmware_class.path.
    systemd.services.patch-nvm-bdaddr = {
      description = "Patch QCA Bluetooth NVM BDADDR";
      wantedBy = ["multi-user.target"];
      after = ["local-fs.target"];
      before = ["bluetooth.service"];
      path = [pkgs.coreutils];
      serviceConfig = {
        Type = "oneshot";
        ConditionPathExists = [
          "/sys/module/firmware_class/parameters/path"
          "/run/current-system/firmware/qca/wcnhpnv21g.bin"
        ];
        ExecStart = pkgs.writeShellScript "patch-nvm-bdaddr" ''
          set -eu
          dst=/var/lib/gaokun3/firmware/qca
          mkdir -p "$dst"
          cp -f /run/current-system/firmware/qca/wcnhpnv21g.bin "$dst/"
          GAOKUN_NVM_DIR="$dst" ${tools}/bin/patch-nvm-bdaddr.py
          echo -n "/var/lib/gaokun3/firmware:/run/current-system/firmware" \
            > /sys/module/firmware_class/parameters/path
        '';
      };
    };

    # pstore crash records live in the DT ramoops region (dts
    # ramoops@d0000000) and appear as files once the pstore filesystem is
    # mounted; systemd-pstore then dumps them to /var/lib/systemd/pstore on
    # the boot after a crash.
    fileSystems."/sys/fs/pstore" = {
      device = "pstore";
      fsType = "pstore";
    };

    # Portrait panel: mutter reads this system-level file in every session, so
    # first-boot setup, the login screen and later accounts all come out
    # rotated. A user choosing rotation in Settings writes
    # ~/.config/monitors.xml, which takes precedence.
    environment.etc."xdg/monitors.xml".source = ../../../tools/image-assets/etc/xdg/monitors.xml;

    # The EC temp sensor and the per-core tsens zones are known to fail and the
    # machine has sudden power-off history. Log
    # thermal and power-supply state periodically so crashes can be checked
    # against temperature and charger state afterwards.
    systemd.services.gaokun3-monitor = {
      description = "Log gaokun3 thermal and power-supply state";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "gaokun3-monitor" ''
          thermal=""
          for z in /sys/class/thermal/thermal_zone*; do
            t="$(cat "$z/type" 2>/dev/null)" || t="?"
            v="$(cat "$z/temp" 2>/dev/null)" || v="unreadable"
            thermal="$thermal $t=$v"
          done
          power=""
          for s in /sys/class/power_supply/*/; do
            [ -d "$s" ] || continue
            name="$(basename "$s")"
            type="$(cat "$s/type" 2>/dev/null)" || type="?"
            status="$(cat "$s/status" 2>/dev/null)" || status="?"
            cap="$(cat "$s/capacity" 2>/dev/null)" || cap="?"
            power="$power $name($type,$status,$cap%)"
          done
          echo "gaokun3-monitor: thermal:[$thermal] power:[$power]"
        '';
      };
    };

    systemd.timers.gaokun3-monitor = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "5min";
        Persistent = true;
      };
    };

    environment.sessionVariables.ALSA_CONFIG_UCM2 = "${pkgs.alsa-ucm-conf-gaokun3}";

    environment.systemPackages = [tools];
  };
}
