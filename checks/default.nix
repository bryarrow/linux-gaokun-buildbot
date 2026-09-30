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
  # The evaluated installation medium, or null on anything but aarch64. The
  # flake builds it; this file only asserts it is wired for the board.
  installer,
}: let
  series = import ../nix/lib/patch-series.nix {inherit lib;};

  # Evaluating this list makes nix/lib/patch-series.nix throw if any series
  # file has drifted from its directory.
  allSeries = lib.concatMap series ["upstream" "others" "camera" "himax" "media" "el2"];
in {
  # The throw in nix/lib/patch-series.nix already fails evaluation; this makes
  # it a named check as well.
  series-sync =
    pkgs.runCommand "gaokun3-series-sync" {} ''
      echo ${lib.escapeShellArgs (map (p: p.name) allSeries)} > $out
    '';

  # A dangling symlink under firmware/ makes every consumer that hashes the
  # tree fail before it starts. `find -xtype l` is the exact test, and it has
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

  # Crash logs cannot live in RAM on this board: the firmware reinitialises DRAM
  # on every reset, so a reserved-memory ramoops region registers and then reads
  # back empty after a reboot. The persistent backend is the EFI variable one
  # instead -- patches/others/0008 fixes its late bind and config-symbols asserts
  # it is built in -- and it advertises the dmesg record only. This fails if a
  # ramoops region, or the console front-end that only a RAM backend would feed,
  # comes back without the hardware evidence to support it.
  pstore-wiring =
    pkgs.runCommand "gaokun3-pstore-wiring" {} ''
      if grep -q 'compatible = "ramoops"' ${../dts}/sc8280xp-huawei-gaokun3.dts; then
        echo "dts/ reserves a ramoops region again; it does not survive this board's reset" >&2
        exit 1
      fi
      if grep -q 'PSTORE_CONSOLE =' ${../nix/config/gaokun3-extra.nix}; then
        echo "PSTORE_CONSOLE is back in the delta; no persistent backend here feeds it" >&2
        exit 1
      fi
      touch $out
    '';

  # The camera nodes are a contract with patches/camera: the board ships two
  # interchangeable rear modules, an OV13B10 at 0x36 and an S5K3L6 at 0x10, so
  # both are described, both stay disabled, and the selector registers whichever
  # one answered (gaokun3-camera-select.c). Both candidates hang off csiphy0 --
  # CAMSS takes the CSIPHY index from the endpoint's port -- so they are two
  # endpoints on port@0. The flash is the PMIC's, not the GPIO93 LED that never
  # lit. A wired-but-never-binding sensor blocks the whole camss notifier, which
  # is why the fallback patch exists as well.
  camera-wiring =
    pkgs.runCommand "gaokun3-camera-wiring" {} ''
      dts=${../dts}/sc8280xp-huawei-gaokun3-camera.dtsi

      # Both modules, both disabled, and the selector owning both.
      grep -q 'compatible = "samsung,s5k3l6xx"' "$dts"
      grep -q 'compatible = "ovti,ov13b10"' "$dts"
      grep -q 'reg = <0x10>;' "$dts"
      grep -q 'reg = <0x36>;' "$dts"
      if [ "$(grep -c 'status = "disabled";' "$dts")" -ne 2 ]; then
        echo "the two rear module nodes are not both disabled; an enabled one would claim the shared reset line and MCLK" >&2
        exit 1
      fi
      grep -q 'compatible = "huawei,gaokun3-rear-camera-select";' "$dts"
      grep -q 'sensors = <&camera_s5k3l6>, <&camera_ov13b10>;' "$dts"

      # csiphy0, one endpoint per candidate.
      grep -q 'csiphy0_ep: endpoint@0 {' "$dts"
      grep -q 'csiphy0_alt_ep: endpoint@1 {' "$dts"
      grep -q 'remote-endpoint = <&s5k3l6_ep>;' "$dts"
      grep -q 'remote-endpoint = <&ov13b10_ep>;' "$dts"

      grep -q 'compatible = "hynix,hi846"' "$dts"

      # Flash: PMIC channels 1 and 4, and no GPIO93 LED shadowing the name.
      grep -q 'led-sources = <1>, <4>;' "$dts"
      if grep -q 'gpios = <&tlmm 93' "$dts"; then
        echo "the GPIO93 flash LED is back; it does not light and shadows the PMIC flash name" >&2
        exit 1
      fi

      touch $out
    '';
}
// lib.optionalAttrs (system == "aarch64-linux") (let
  # The module is aarch64-only — it selects an aarch64 kernel and a device
  # tree — so this is the only system whose toplevel can be evaluated. Build it
  # once and reuse it for the checks below.
  baseModules = [
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

  evaluated = lib.nixosSystem {
    system = "aarch64-linux";
    modules = baseModules;
  };

  # The same system with the experimental variant on, so the option's wiring is
  # checked here rather than on the first device that turns it on.
  el2Evaluated = lib.nixosSystem {
    system = "aarch64-linux";
    modules = baseModules ++ [{hardware.gaokun3.el2.enable = true;}];
  };

  simpledrmBlacklisted = params: lib.elem "modprobe.blacklist=simpledrm" params;

  # Enabling the variant must not move the normal entry: it adds a
  # specialisation instead, so both entries exist side by side and EL1/EL2 is a
  # boot menu choice (slbounce's README describes the same shape). The four
  # values below are the whole contract.
  baseKernelName = lib.getName el2Evaluated.config.boot.kernelPackages.kernel;
  baseDeviceTree = el2Evaluated.config.hardware.deviceTree.name;
  baseBlacklistsSimpledrm = simpledrmBlacklisted el2Evaluated.config.boot.kernelParams;
  el2Specialisation =
    el2Evaluated.config.specialisation.el2.configuration or null;
  el2KernelName =
    if el2Specialisation == null
    then "none"
    else lib.getName el2Specialisation.boot.kernelPackages.kernel;
  el2DeviceTree =
    if el2Specialisation == null
    then "none"
    else el2Specialisation.hardware.deviceTree.name;
  el2BlacklistsSimpledrm =
    el2Specialisation != null && simpledrmBlacklisted el2Specialisation.boot.kernelParams;

  # The EL2 boot chain the module puts on the ESP, and the same list sorted (the
  # option is an attrset, so order is not meaningful).
  el2EspExpected = [
    "EFI/systemd/drivers/qebspilaa64.efi"
    "EFI/systemd/drivers/slbounceaa64.efi"
    "firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcadsp8280.mbn"
    "firmware/qcom/sc8280xp/HUAWEI/gaokun3/qccdsp8280.mbn"
    "firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcslpi8280.mbn"
    "tcblaunch.exe"
  ];
  el2EspFiles = builtins.attrNames el2Evaluated.config.boot.loader.systemd-boot.extraFiles;
  el2EspMissing = lib.subtractLists el2EspFiles el2EspExpected;
  el2EspUnexpected = lib.subtractLists el2EspExpected el2EspFiles;

  # `hardware.firmware` builds a buildEnv with ignoreCollisions, and the winner
  # of a name present in several packages is decided by priority first and by
  # input order only when the priorities are equal (builder.pl:159). The module
  # uses mkBefore, but that alone is not the reason ours wins: linux-firmware
  # carries meta.priority = 6 and our package takes the default 5. This asserts
  # the outcome from those two facts, without building linux-firmware.
  firmwareNames = map (p: p.name or "") evaluated.config.hardware.firmware.paths;
  indexWhere = pred:
    lib.findFirst (i: pred (lib.elemAt firmwareNames i)) null
    (lib.range 0 (lib.length firmwareNames - 1));
  gaokun3Index = indexWhere (name: lib.hasPrefix "linux-firmware-gaokun3" name);
  stockIndex = indexWhere (
    name: lib.hasPrefix "linux-firmware-" name && !(lib.hasPrefix "linux-firmware-gaokun3" name)
  );
  firmwarePriorities = {
    gaokun3 = self.packages.${system}.firmware-gaokun3.meta.priority or lib.meta.defaultPriority;
    stock = pkgs.linux-firmware.meta.priority or lib.meta.defaultPriority;
  };
  firmwareWins =
    firmwarePriorities.gaokun3 < firmwarePriorities.stock
    || (firmwarePriorities.gaokun3 == firmwarePriorities.stock && gaokun3Index < stockIndex);

  # Keep only the toplevel drvPath, so the check builds a tiny script instead
  # of a kernel. The drvPath string carries a dependency context that would
  # otherwise make the whole system closure an input of the check.
  toplevel = builtins.unsafeDiscardStringContext evaluated.config.system.build.toplevel.drvPath;

  kernel = self.packages.${system}.linux-gaokun3;
  el2Kernel = self.packages.${system}.linux-gaokun3-el2;

  # The installation medium. The board only boots if the entry that names the
  # kernel also names the device tree (`devicetree`, which systemd-boot passes
  # to the kernel), so the assertions below cover both the evaluation facts and
  # the entry as it is written into the ESP that nixos/installer.nix builds.
  installerKernel = installer.config.boot.kernelPackages.kernel;
  installerKernelName = lib.getName installerKernel;
  installerKernelFile = installer.config.system.boot.loader.kernelFile;
  installerInitrd = installer.config.system.build.initialRamdisk;
  installerInitrdFile = installer.config.system.boot.loader.initrdFile;
  installerDeviceTree = installer.config.hardware.deviceTree;
  installerToplevel =
    builtins.unsafeDiscardStringContext (toString installer.config.system.build.toplevel);
  installerEsp = installer.config.system.build.gaokun3InstallerEsp;
  installerMissingParams =
    lib.filter (p: !(lib.elem p installer.config.boot.kernelParams))
    [
      "clk_ignore_unused"
      "pd_ignore_unused"
      "arm64.nopauth"
      "efi=noruntime"
      "fbcon=rotate:1"
      "usbhid.quirks=0x12d1:0x10b8:0x20000000"
    ];
  installerProblems =
    lib.optional (installerKernelName != "linux-gaokun3")
      "installer kernel: ${installerKernelName} (want linux-gaokun3)"
    ++ lib.optional (!installerDeviceTree.enable)
      "installer does not enable hardware.deviceTree"
    ++ lib.optional (installerDeviceTree.name != "qcom/sc8280xp-huawei-gaokun3.dtb")
      "installer device tree: ${installerDeviceTree.name} (want qcom/sc8280xp-huawei-gaokun3.dtb)"
    ++ map (p: "installer command line is missing ${p}") installerMissingParams;
in {
  eval = pkgs.runCommand "gaokun3-eval" {} ''
    echo ${toplevel} > $out
  '';

  firmware-precedence =
    if gaokun3Index != null && stockIndex != null && firmwareWins
    then pkgs.runCommand "gaokun3-firmware-precedence" {} "touch $out"
    else throw ''
      gaokun3 firmware would lose to linux-firmware in hardware.firmware:
      priorities gaokun3=${toString firmwarePriorities.gaokun3} stock=${toString firmwarePriorities.stock},
      order gaokun3=${toString gaokun3Index} stock=${toString stockIndex},
      list: ${lib.concatStringsSep ", " firmwareNames}
    '';

  # hardware.gaokun3.el2.enable adds a boot menu entry and the ESP boot chain;
  # it must not move the normal entry, and with the option off neither may exist.
  # Comparing the two evaluations catches a specialisation that forgets one of the
  # three overrides, without building either kernel.
  el2-wiring =
    if el2KernelName == "linux-gaokun3-el2"
    && el2DeviceTree == "qcom/sc8280xp-huawei-gaokun3-el2.dtb"
    && el2BlacklistsSimpledrm
    && baseKernelName == "linux-gaokun3"
    && baseDeviceTree == "qcom/sc8280xp-huawei-gaokun3.dtb"
    && !baseBlacklistsSimpledrm
    && el2EspMissing == []
    && el2EspUnexpected == []
    && builtins.attrNames evaluated.config.boot.loader.systemd-boot.extraFiles == []
    && !(evaluated.config.specialisation ? el2)
    then pkgs.runCommand "gaokun3-el2-wiring" {} "touch $out"
    else throw ''
      hardware.gaokun3.el2.enable did not set up the entry it owns:
        el2 entry kernel: ${el2KernelName} (want linux-gaokun3-el2)
        el2 entry device tree: ${el2DeviceTree} (want qcom/sc8280xp-huawei-gaokun3-el2.dtb)
        el2 entry simpledrm blacklisted: ${lib.boolToString el2BlacklistsSimpledrm} (want true)
        base kernel: ${baseKernelName} (want linux-gaokun3)
        base device tree: ${baseDeviceTree} (want qcom/sc8280xp-huawei-gaokun3.dtb)
        base simpledrm blacklisted: ${lib.boolToString baseBlacklistsSimpledrm} (want false)
        ESP files missing: ${lib.concatStringsSep ", " el2EspMissing}
        ESP files not expected: ${lib.concatStringsSep ", " el2EspUnexpected}
        base ESP extra files: ${lib.concatStringsSep ", " (builtins.attrNames evaluated.config.boot.loader.systemd-boot.extraFiles)} (want none)
        base has an el2 specialisation: ${lib.boolToString (evaluated.config.specialisation ? el2)} (want false)
    '';

  # The installer has to start the same kernel and device tree the installed
  # system does, with the command line the hardware needs, and systemd-boot has
  # to hand the kernel that device tree. The evaluation facts are checked above;
  # this reads the boot entry back out of the ESP nixos/installer.nix builds,
  # which is the only place the wiring becomes real. Building the ESP pulls the
  # kernel, initrd and systemd-boot, all of which the cache already has; it does
  # not pull the live system, whose path the entry merely names.
  installer-wiring =
    if installerProblems == []
    then
      pkgs.runCommand "gaokun3-installer-wiring" {nativeBuildInputs = [pkgs.mtools];} ''
        mcopy -i ${installerEsp} ::/loader/entries/nixos.conf nixos.conf

        # The device tree line next to the kernel line is the whole point: the
        # firmware has no usable one to pass.
        grep -qF -- 'linux /EFI/nixos/${baseNameOf (toString installerKernel)}/${installerKernelFile}' nixos.conf
        grep -qF -- 'initrd /EFI/nixos/${baseNameOf (toString installerInitrd)}/${installerInitrdFile}' nixos.conf
        grep -qF -- 'devicetree /EFI/nixos/${baseNameOf (toString installerDeviceTree.package)}/${installerDeviceTree.name}' nixos.conf

        # The squashfs store is what provides this init; without it the kernel
        # would start and find no init.
        grep -qF -- 'init=${installerToplevel}/init' nixos.conf
        touch $out
      ''
    else throw ''
      the installation medium is not wired for this machine:
        ${lib.concatStringsSep "\n  " installerProblems}
    '';

  # generate-config.pl already fails the kernel build when a required option does
  # not land, but it cannot see the values inherited from the arm64 defconfig,
  # and nix/config/gaokun3-extra.nix declares two entries `optional`. This check
  # builds the configfile -- minutes, not a kernel compile -- and asserts the
  # delta and the assumptions behind it actually landed.
  #
  # The pull-request workflow builds this check explicitly, because
  # `nix flake check --no-build` only evaluates and would never catch a config
  # regression.
  config-symbols = pkgs.runCommand "gaokun3-config-symbols" {} ''
    cfg=${kernel.configfile}

    # nix/config/gaokun3-extra.nix
    grep -qx 'CONFIG_CMA_SIZE_MBYTES=128' "$cfg"
    grep -qx 'CONFIG_USB_PCI=y' "$cfg"
    grep -qx 'CONFIG_BT_LE=y' "$cfg"
    grep -qx '# CONFIG_VIDEO_QCOM_IRIS is not set' "$cfg"

    # The crash-log backend is inherited from nixpkgs' common config rather than
    # pinned in the delta, but it is the only persistent one on this machine
    # (dts/ reserves no ramoops region, see checks.pstore-wiring). Asserting it
    # here is what would catch a nixpkgs change that removes the backend.
    grep -qx 'CONFIG_EFI_VARS_PSTORE=y' "$cfg"

    # The camera stack: mostly inherited rather than pinned in the delta, plus
    # the two symbols that arrive with patches/camera (VIDEO_S5K3L6XX and the
    # module selector). The device tree names these drivers and patches/camera is
    # what makes the sensors bind; if a symbol silently disappears the cameras go
    # with it and nothing else here would notice.
    for sym in VIDEO_QCOM_CAMSS VIDEO_OV13B10 VIDEO_S5K3L6XX VIDEO_HI846 I2C_QCOM_CCI \
               SC_CAMCC_8280XP LEDS_QCOM_FLASH VIDEO_GAOKUN3_CAMERA_SELECT; do
      grep -qE "^CONFIG_$sym=(y|m)$" "$cfg" || {
        echo "camera symbol CONFIG_$sym is not enabled" >&2
        exit 1
      }
    done

    # TCG_TPM is pinned to a module and INTEGRITY stays off. A builtin TPM core
    # makes /sys/class/tpmrm exist from boot, and systemd's tpm2 generator then
    # waits the full 90 s device timeout for a /dev/tpm0 this machine cannot
    # provide (see nix/config/gaokun3-extra.nix).
    grep -qx '# CONFIG_INTEGRITY is not set' "$cfg"
    grep -qx 'CONFIG_TCG_TPM=m' "$cfg"

    # IMA is only reachable with INTEGRITY, so it must not be built. The
    # fragment marks nixpkgs' unusable answer `optional` to keep it a warning;
    # this is what makes sure the relaxation cannot become a silent "y".
    if grep -q '^CONFIG_IMA=' "$cfg"; then
      echo "IMA is built, which needs INTEGRITY and the builtin TPM core" >&2
      exit 1
    fi

    # Identity: the module directory and CONFIG_LOCALVERSION must agree.
    grep -qx 'CONFIG_LOCALVERSION="-gaokun3"' "$cfg"

    # TCG_CRB is built because the kernel's own arm64 defconfig sets ACPI. It
    # cannot bind on this machine: the bootloader passes a real device tree, so
    # `dt_is_stub()` is false and arch/arm64/kernel/acpi.c leaves ACPI disabled.
    # The load-bearing guard stays TCG_TPM=m above -- a builtin TPM core is what
    # put /sys/class/tpmrm in place before systemd's tpm2 generator ran.

    # CONFIG_LSM comes from the kernel default now; it must not name the
    # "integrity" LSM, which no longer exists in 7.2.
    if grep -q '^CONFIG_LSM=.*,integrity,' "$cfg"; then
      echo "CONFIG_LSM still names the removed integrity LSM" >&2
      exit 1
    fi

    # The EL2 variant is a variant, not a second distribution: patches/el2
    # changes no Kconfig file, so its config may differ from the base in
    # CONFIG_LOCALVERSION alone. A patch that starts carrying policy, or a
    # LOCALVERSION that drifts from the module directory, fails here.
    el2=${el2Kernel.configfile}
    grep -qx 'CONFIG_LOCALVERSION="-gaokun3-el2"' "$el2"
    if ! diff -q <(grep -v '^CONFIG_LOCALVERSION=' "$cfg") \
                 <(grep -v '^CONFIG_LOCALVERSION=' "$el2") > /dev/null; then
      echo "the EL2 kernel config differs from the base beyond LOCALVERSION:" >&2
      diff <(grep -v '^CONFIG_LOCALVERSION=' "$cfg") \
           <(grep -v '^CONFIG_LOCALVERSION=' "$el2") >&2 || true
      exit 1
    fi

    touch $out
  '';

  # Building this forces every package, and the kernel's `modules` output
  # explicitly. A linkFarm only realises each package's default output, so `out`
  # would be cached while `modules` — which the system closure and the initrd
  # need — was not, and a device would still compile the kernel to get it. The
  # `dev` output comes out of the same build but the workflow's pushFilter keeps
  # it out of the cache. A push to main builds this and cachix-action's daemon
  # pushes the store paths; pull requests only evaluate, which is why the
  # expensive part lives here rather than in evaluation. The cross-compiled
  # x86_64 packages are deliberately not part of it, and so is installer-iso:
  # it is a release artifact, not something a device substitutes, and a ~2 GB
  # image plus its squashfs would evict kernels from a 5 GB cache by design
  # (README's quota section). checks.installer-wiring still builds the ESP and
  # reads the entry back, which is what can actually be wrong in the installer.
  packages = pkgs.linkFarm "gaokun3-packages" (
    lib.mapAttrsToList (name: path: {inherit name path;})
    (lib.removeAttrs self.packages.${system} ["installer-iso"])
    ++ [
      {name = "linux-gaokun3-modules"; path = kernel.modules;}
      {name = "linux-gaokun3-el2-modules"; path = el2Kernel.modules;}
    ]
  );
})
