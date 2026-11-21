# Hardware that cannot exist on a MateBook E Go.
#
# The base is the kernel's arm64 defconfig, which is a distribution config for
# every arm64 machine in existence: it enables the SoC platforms, GPUs and
# platform drivers of dozens of boards. nixpkgs' common config then adds its
# distribution policy on top. That is the right base for a general-purpose
# arm64 kernel and the wrong one for a single board, because every other
# platform's built-in code is compiled into our kernel and its drivers are
# built as modules we can never load.
#
# This is the complement of gaokun3-extra.nix: that file enables what the board
# needs, this one removes what it cannot have. The rule for an entry here is
# "the hardware is not on this board and cannot be attached to it", not "the
# user probably does not need it" -- generic USB, PCIe, network and filesystem
# drivers stay, because a dock or a USB adapter can supply them.
#
# Priority 90 is the same idiom as gaokun3-extra.nix: nixpkgs' common config
# defines its options at priority 100, so overriding one of them takes a lower
# priority. Entries that common config asks for and that become invisible when
# their dependency is disabled are `optional`, which keeps generate-config.pl's
# fatal check from turning a deliberate removal into a build failure.
{lib}: let
  inherit (lib) genAttrs mkOverride;

  # A plain disable: the symbol exists and generate-config.pl should fail if it
  # does not land. Used for the arm64 platform menu entries and the GPUs, which
  # are visible independently of anything we turn off.
  off = mkOverride 90 {tristate = "n";};

  # A disable for a symbol that nixpkgs' common config names but that this file
  # makes unreachable. generate-config.pl reports an unreachable symbol as an
  # unused option, which is fatal unless it is declared optional.
  offUnreachable = mkOverride 90 {
    tristate = "n";
    optional = true;
  };

  # Every top-level arm64 platform menu entry except ARCH_QCOM. The entries
  # under the ARCH_BCM, ARCH_MICROCHIP and ARCH_NXP menuconfigs are not listed:
  # turning the menuconfig off already hides them, and naming a hidden symbol
  # would only be another unused option. ARCH_QCOM stays because the SC8280XP is
  # a Qualcomm SoC; everything else here is a different SoC family that this
  # board cannot contain.
  otherPlatforms = [
    "ARCH_ACTIONS"
    "ARCH_AIROHA"
    "ARCH_SUNXI"
    "ARCH_ALPINE"
    "ARCH_APPLE"
    "ARCH_ASPEED"
    "ARCH_AXIADO"
    "ARCH_BCM"
    "ARCH_BERLIN"
    "ARCH_BITMAIN"
    "ARCH_BLAIZE"
    "ARCH_BST"
    "ARCH_CIX"
    "ARCH_EXYNOS"
    "ARCH_K3"
    "ARCH_LG1K"
    "ARCH_HISI"
    "ARCH_KEEMBAY"
    "ARCH_MEDIATEK"
    "ARCH_MESON"
    "ARCH_MICROCHIP"
    "ARCH_MMP"
    "ARCH_MVEBU"
    "ARCH_NXP"
    "ARCH_MA35"
    "ARCH_NPCM"
    "ARCH_PENSANDO"
    "ARCH_REALTEK"
    "ARCH_RENESAS"
    "ARCH_ROCKCHIP"
    "ARCH_SEATTLE"
    "ARCH_INTEL_SOCFPGA"
    "ARCH_SOPHGO"
    "ARCH_STM32"
    "ARCH_SYNQUACER"
    "ARCH_TEGRA"
    "ARCH_SPRD"
    "ARCH_THUNDER"
    "ARCH_THUNDER2"
    "ARCH_UNIPHIER"
    "ARCH_VEXPRESS"
    "ARCH_VISCONTI"
    "ARCH_XGENE"
    "ARCH_ZYNQMP"
  ];

  # GPUs other than the board's Adreno. DRM_MSM drives the Adreno and stays;
  # these are discrete or other-SoC GPUs that cannot be present. Nouveau, amdgpu
  # and Xe are built by the arm64 defconfig even though they need PCIe NVIDIA,
  # AMD or Intel hardware, and Panfrost/Lima/etnaviv are the Mali and Vivante
  # drivers for other SoCs. The platform menu entries above already hide the
  # DRM drivers of the platforms they cover (Tegra, Rockchip, VC4, ...).
  gpus = [
    "DRM_NOUVEAU"
    "DRM_AMDGPU"
    "DRM_RADEON"
    "DRM_XE"
    "DRM_PANFROST"
    "DRM_LIMA"
    "DRM_ETNAVIV"
    # The legacy framebuffer drivers for the same discrete GPUs. They are the
    # pre-DRM path and the arm64 defconfig still enables all of them.
    "FB_NVIDIA"
    "FB_RIVA"
    "FB_RADEON"
    "FB_ATY"
    "FB_ATY128"
    "FB_SAVAGE"
    "FB_SIS"
    "FB_3DFX"
  ];
  # NVIDIA IP that is not gated by ARCH_TEGRA and has no consumer on this
  # board: the HDMI audio codecs, the Tegra USB controller, the GPU USB-C
  # alt-mode driver and the Grace/Tegra PMU blocks. HID_NVIDIA_SHIELD is
  # deliberately absent: it is a HID driver for a Shield controller, which can
  # be attached over Bluetooth or USB.
  nvidiaLeftovers = [
    "SND_HDA_CODEC_HDMI_NVIDIA"
    "SND_HDA_CODEC_HDMI_NVIDIA_MCP"
    "SND_HDA_CODEC_HDMI_TEGRA"
    "USB_CHIPIDEA_TEGRA"
    "TYPEC_NVIDIA_ALTMODE"
    "NVIDIA_CORESIGHT_PMU_ARCH_SYSTEM_PMU"
    "NVIDIA_TEGRA410_CMEM_LATENCY_PMU"
    "NVIDIA_TEGRA410_C2C_PMU"
  ];
in
  # The arm64 platform menu, the GPUs and the NVIDIA leftovers above.
  genAttrs (otherPlatforms ++ gpus ++ nvidiaLeftovers) (_: off)
  // {
    # NVIDIA server/Grace interfaces that no platform menu entry gates: the
    # GHES record handler and the GPU's I2C controller. They are marked
    # unreachable because APEI may hide the first one on another config; the
    # Shield HID driver stays (see nvidiaLeftovers above).
    ACPI_APEI_GHES_NVIDIA = offUnreachable;
    I2C_NVIDIA_GPU = offUnreachable;
    NVIDIA_CARMEL_CNP_ERRATUM = off;

    # nixpkgs' common config names these directly, so disabling their
    # dependencies makes them unreachable rather than merely unused. Restating
    # them as `n` keeps generate-config.pl's fatal check meaningful for the
    # rest of the file instead of relaxing it globally.
    DRM_AMDGPU_SI = offUnreachable;
    DRM_AMDGPU_CIK = offUnreachable;
    DRM_AMDGPU_USERPTR = offUnreachable;
    DRM_AMD_DC_FP = offUnreachable;
    DRM_AMD_DC_SI = offUnreachable;
    DRM_AMD_ACP = offUnreachable;
    DRM_AMD_SECURE_DISPLAY = offUnreachable;
    DRM_AMD_ISP = offUnreachable;
    DRM_NOUVEAU_GSP_DEFAULT = offUnreachable;
    DRM_NOUVEAU_SVM = offUnreachable;
    HSA_AMD = offUnreachable;
    HSA_AMD_P2P = offUnreachable;
    FB_NVIDIA_I2C = offUnreachable;
    FB_RIVA_I2C = offUnreachable;
    FB_ATY_CT = offUnreachable;
    FB_ATY_GX = offUnreachable;
    FB_SAVAGE_I2C = offUnreachable;
    FB_SAVAGE_ACCEL = offUnreachable;
    FB_SIS_300 = offUnreachable;
    FB_SIS_315 = offUnreachable;
    FB_3DFX_ACCEL = offUnreachable;

    # The same for the aarch64-only entries common config adds for the platforms
    # above: the Raspberry Pi CEC, the RK3588 HDMI/DSI outputs, the MediaTek
    # Ethernet/WMAC pair and the Tegra XHCI host.
    DRM_VC4_HDMI_CEC = offUnreachable;
    ROCKCHIP_DW_HDMI_QP = offUnreachable;
    ROCKCHIP_DW_MIPI_DSI2 = offUnreachable;
    NET_VENDOR_MEDIATEK = offUnreachable;
    MT798X_WMAC = offUnreachable;
    USB_XHCI_TEGRA = offUnreachable;
    FSL_MC_UAPI_SUPPORT = offUnreachable;
    SUN8I_DE2_CCU = offUnreachable;
  }
