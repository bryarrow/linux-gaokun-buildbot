# 将 NixOS 升为主产物的迁移设计

状态：**P0–P2 已实现；P3 代码已完成、待实机冷启动验证；P4–P6 待做。** 实现进展与偏差见 §11。
决策依据 revision：`a64790e`（`gaokun3-nix-debug`）。
实现起点：P0 = `9013b9a1`，P1 = `db75b4fa`，缓存补 `modules` = `9bfa8883`，
内核改用 flake 自己的 nixpkgs = `fcf63bf5`，P2 = `f9fc6b28`，P3 = `da1d7b36`。
正文（§1–§10）保持评审时的原样，未随实现回写；两者不一致之处由 §11 记录。

> 放置说明：`README.md` 与 `docs/*.md` 面向"想把机器刷起来/修好"的机主（见 `CLAUDE.md` 的 Audience split），
> 构建系统论证不属于那里。因此本文留在仓库根目录，与 `CLAUDE.md` 同级；评审通过后其结论并入
> `CLAUDE.md`，面向机主的部分才进 `README.md` / `docs/`。
>
> 语言：本文用中文书写以便评审。结论并入 `CLAUDE.md` 时需一并译成英文，与该文件现有语言一致。

---

## 1. 背景与已核实的事实

迁移的起点不是空白，而是**一套已经在这台机器上跑起来的 NixOS 支持**：

| 事实 | 证据 |
| --- | --- |
| 设备正在用本仓库的 flake | `/etc/nixos/flake.nix`：`gaokun3.url = github:bryarrow/linux-gaokun-buildbot/gaokun3-nix-debug` |
| 宿主已被 lock 到当前工作树 | `/etc/nixos/flake.lock` 的 gaokun3 rev = `a64790e`，与工作树 HEAD 相同 |
| 内核包真的在跑 | `uname -r` = `7.2.0-gaokun3`；`/run/current-system/kernel` → `/nix/store/7lx9x…-linux-gaokun3-7.2.0/Image` |
| 固件包生效且符号链接完好 | `…/firmware/qcom/sc8280xp/SC8280XP-HUAWEI-GAOKUN3-tplg.bin.zst` → `linux-firmware-gaokun3-0.1.0-zstd` |
| 模块输出 DTB | `/run/current-system/dtbs/qcom/sc8280xp-huawei-gaokun3.dtb` |
| 宿主是 aarch64 NixOS | `nixos-version` = `26.11.20260829.d2f6794`，`uname -m` = `aarch64` |
| 二进制缓存已配置但无人推送 | `/etc/nixos/flake.nix` 有 `berrys-nixos.cachix.org`；`.github/workflows/` 里没有任何 nix job |

三条 Fedora 工作流（`fedora-gaokun3-release.yml` / `gaokun3-package-rpms.yml` / `gaokun3-rescue-release.yml`）
与 `scripts/ci/*`、`packaging/rpm/*.spec.in` 目前仍是项目的默认叙事。

**结论：本设计要做的是"提升 + 反转主次"，不是从零重写。**

---

## 2. 目标

### 2.1 目标重述

`CLAUDE.md` 现有的三条目标里，第 2 条 "A stock Fedora experience" 在 NixOS 主产物下失效，
必须换成它在 NixOS 侧的对应物，而不是直接删掉——它的实质是"别人已经做的决定，继承而不是重述"，
这条原则与平台无关。

| 优先级 | 旧（Fedora 主产物） | 新（NixOS 主产物） |
| --- | --- | --- |
| 1 | 这台设备上的最佳体验 | **不变**：硬件支持优先，即使偏离 stock |
| 2 | stock Fedora 体验 | **stock NixOS 体验**：用 nixpkgs 造内核的方式造内核（`buildLinux` + `enableCommonConfig` + 经审查的增量），用 NixOS 模块的惯例写模块，不重复 nixpkgs/NixOS 已有的决定 |
| 3 | 可以日常使用 | **不变**，但载体从 `etc/dnf/protected.d` 等换成 NixOS 的 generation 回滚语义 |

第 2 条的新版本有一个立刻可检验的推论：**`boot.initrd.includeDefaultModules = false` 与
`boot.initrd.systemd.tpm2.enable = false` 是在补偿"内核不是按 nixpkgs 方式配置的"，
它们属于待消除的债务，不是设计选择。** 这直接决定了 P3 的性质：P3 不是"优化"，
而是达成目标 2 的必经步骤。

目标未变的部分仍受保护：`fbcon=rotate:1`、Huawei 键盘 quirk、机型固件、Gaokun3 专属 DTS 与补丁、
以及实验性 EL2 路径，都因为"硬件逼我们这么做"而保留。

### 2.2 完成判据

1. `nix flake check` 在主 CI（arm64）上绿，且内核包由项目自己的 cache 提供，
   设备侧无需本地编译。
2. `hardware.gaokun3.enable = true` 是普通用户唯一需要写的一行，且不再依赖相对路径 `callPackage`。
3. `enableCommonConfig = true`，`includeDefaultModules = false` 与 `tpm2.enable = false` 已删除。
4. 设备从 NixOS 安装介质全新安装成功，不经过任何 Fedora 产物。
5. `CLAUDE.md` / `README.md` 的叙事以 NixOS 为主，Fedora 明确标记 legacy 或已删除。

---

## 3. 目标架构

### 3.1 目录

单一仓库保留。`patches/ dts/ defconfig/ firmware/ tools/` 是 Nix 与（尚存的）Fedora
两条流水线**共同的唯一真相源**，这是不拆仓库的核心理由。

```
flake.nix                         # 一等入口：packages / overlays / nixosModules / checks / formatter
nix/
  pins.nix                        # 版本、tarball、hash 的 Nix 侧唯一来源
  config/gaokun3-extra.nix        # P3 产出的、经审查的 structuredExtraConfig 增量
  lib/patch-series.nix            # series 驱动 + eval 期一致性校验
pkgs/
  linux-gaokun3/default.nix
  linux-gaokun3-el2/default.nix   # P4
  firmware-gaokun3/default.nix
  tools-gaokun3/default.nix
  alsa-ucm-conf-gaokun3/default.nix
overlays/default.nix
nixos/modules/hardware/gaokun3.nix
checks/                           # eval / series / pins / firmware
.github/workflows/gaokun3-nix.yml # 主 CI
docs/nixos_install_guide_{en,zh}.md
```

**不移动 Fedora 目录。** `scripts/ci/`、`packaging/rpm/`、`scripts/local/` 原地不动，
只在文档里标记为 legacy。搬迁的唯一收益是目录好看，代价是工作流、`CLAUDE.md`、`docs/`
里所有路径引用一起返工，且 `70_build_package_rpms.sh` 的产物还被 `10_fetch_package_rpms.sh`
反向依赖。用状态标记代替物理搬迁。

### 3.2 flake 输出契约

| 输出 | 内容 | 备注 |
| --- | --- | --- |
| `packages.<sys>.linux-gaokun3` | 内核包 | `aarch64-linux` 原生；`x86_64-linux` 交叉 |
| `packages.<sys>.linux-firmware-gaokun3` | 机型固件 | 含 tplg 符号链接 |
| `packages.<sys>.gaokun3-tools` | 蓝牙 NVM patcher + 触屏调参 GUI | |
| `packages.<sys>.alsa-ucm-conf-gaokun3` | 合并后的 UCM2 树 | 从模块里搬出来，见 5.7 |
| `packages.<sys>.default` | **指向 `firmware` 或 `tools`，不再指向内核** | `nix build .` 不宜默认触发 1–3 小时内核编译 |
| `overlays.default` | 注入上述包 + `linuxPackages_gaokun3` | 下游可 `nixpkgs.overlays` |
| `nixosModules.default` = `nixosModules.gaokun3` | 自动应用 overlay 的模块包装 | 见 5.9 |
| `checks.<sys>.*` | 见 5.10 | `nix flake check` 可跑 |
| `formatter.<sys>` | `alejandra` 或 `nixfmt` | 与 `.editorconfig` 对齐后定 |

---

## 4. Fedora 流水线的退役路径

这一节回答"取代"到底取代什么。**退役的阻塞点不是内核包，是安装介质。**

现状：`gaokun3-rescue-release.yml` 产出的 CLI-only U 盘是当前唯一能把系统装到这块内部磁盘上的路径
（`docs/rescue_usb_guide_en.md`）。NixOS 这边的 `hardware.gaokun3` 只解决"系统已经在跑"之后的事，
没有任何东西能把 NixOS 装到一台空的 gaokun3 上。

因此退役分三步，且**在第 3 步之前 Fedora 流水线不能删**：

1. **冻结**：工作流保持 `workflow_dispatch`（已经是），不再主动 bump；`build.env` 的
   `KERNEL_TAG`/`FEDORA_RELEASE` 由 Nix 侧交叉校验（见 5.1），升内核时两者必须同 commit 改。
   同时把 `CLAUDE.md` 里"Fedora 是主产物"的叙事改写。
2. **降级为恢复工具**：Fedora 磁盘镜像工作流（`fedora-gaokun3-release.yml`）转 legacy；
   救援 U 盘保留，因为它是 brick 之后的兜底。
3. **替换安装介质**（P6）：用 NixOS 自己产出可启动的 aarch64 安装介质，内核就是 `linux-gaokun3`。
   一旦该介质在实机上被验证可用，`fedora-gaokun3-release.yml` 与 `gaokun3-rescue-release.yml`
   可以整体删除，`scripts/ci/`、`packaging/rpm/`、`tools/image-assets/` 随之评估去留。

`tools/image-assets/` 需要逐项判定归属：`etc/xdg/monitors.xml`、`etc/modprobe.d/audio-deps.conf`、
`etc/modules-load.d/*.conf` 的内容已经分别被模块的 `environment.etc`、`boot.extraModprobeConfig`、
`boot.kernelModules` 表达，是**重复的第二真相源**，退役后应删除，只留下 Nix 模块一处。
`tools/el2/*.efi` 与 `tools/audio/sc8280xp.conf`、`tools/bluetooth/*` 是真正的资产，保留。

---

## 5. 详细设计

### 5.1 供应链：`nix/pins.nix`

**问题。** 现状是两个真相源：`build.env` 写 `KERNEL_TAG=v7.2`，而
`pkgs/linux-gaokun3/default.nix` 第 13、33 行另写 `version = "7.2.0"` 与 `v7.2.tar.gz`。
升内核必须手改两处，漏一处不报错。

**做法。** `nix/pins.nix` 作为 Nix 侧唯一来源，字段 `kernelTag` / `kernelVersion` /
`kernelHash` / `fedoraRelease`。**不让 Nix 去 parse shell 文件**——hash 本来就必须手写，
与其做脆弱的文本解析，不如把"两处必须一致"变成一条会失败的 check（`checks.pins-sync`，
读 `build.env` 并断言相等）。

同时把 tarball 从 `https://git.kernel.org/…/snapshot/v7.2.tar.gz` 换成
`https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.tar.xz`。

**注意。** kernel.org 的 `snapshot/` URL 是即时打包的，不保证长期字节一致，
sha256 只能兜住"下载被篡改"，兜不住"上游重打包"。`cdn.kernel.org` 的发布 tarball 才是稳定地址。

**寿命。** 第 4 节第 3 步完成、Fedora 侧删除后，`build.env` 消失，`nix/pins.nix` 自动成为唯一来源，
`pins-sync` 这条 check 随之删除。这是有意的——它是一次性脚手架，不是永久约束。

### 5.2 补丁：`series` 驱动

**问题。** 现状分叉：CI 的 `apply_series()`（`scripts/ci/20_build_kernel_variants.sh`）
按 `series` 文件应用，并校验"series 恰好列出目录里每个 `.patch` 一次"；而 Nix 侧
（`pkgs/linux-gaokun3/default.nix:18-23`）用 `readDir` + `sort` 自行排序并**过滤掉** `series`。
一个补丁加进目录但忘了写进 `series`，在 Nix 下能建、在 CI 下会失败。且 `patches/el2/`
根本没有 `series` 文件（CI 用 glob 应用）。

**做法。** `nix/lib/patch-series.nix` 成为这条不变量的 Nix 实现，`series` 是唯一排序依据：

```nix
dir:
let
  listed  = lib.filter (l: l != "" && !(lib.hasPrefix "#" l))
              (lib.splitString "\n" (lib.replaceStrings ["\r"] [""]
                (builtins.readFile (root + "/patches/${dir}/series"))));
  present = lib.filter (lib.hasSuffix ".patch")
              (builtins.attrNames (builtins.readDir (root + "/patches/${dir}")));
  missing  = lib.subtractLists present listed;
  unlisted = lib.subtractLists listed present;
in
  if missing != [] || unlisted != []
  then throw "patches/${dir}/series 与目录不同步：missing=${toString missing} unlisted=${toString unlisted}"
  else map (n: { name = "${dir}/${lib.removeSuffix ".patch" n}";
                 patch = root + "/patches/${dir}/${n}"; }) listed;
```

**注意。** `throw` 在 eval 期触发，所以 `nix flake check` 就能拦住，不必等编译。
同时补齐 `patches/el2/series`，让四个目录（含 el2）规则一致。

**重复问题。** CI 侧的 `apply_series()` 与这份 Nix 实现是同一规则的两份代码。
第 4 节第 3 步之后 CI 侧连同 Fedora 流水线一起删除，重复自然消失；在那之前两边都保留。

### 5.3 内核包：改用 `buildLinux` 的补丁机制

**问题。** 现状（`default.nix:28-53`）用一个手写的 `stdenv.mkDerivation` 做 `src`：
fetch tarball、用 `patches` 属性打补丁、`cp -a . $out/` 把整棵 ~1.5 GB 内核树塞进 store，
然后交给 `buildLinux`。这等于手工重实现了 `applyPatches`，并且绕开了 nixpkgs 自己的补丁机制，
后果是 `boot.kernelPatches` 的组合与 `passthru` 语义都拿不到。

**已核对的 nixpkgs 事实**（`nixos-unstable` 的 `pkgs/os-specific/linux/kernel/generic.nix`）：

- `kernelPatches` 是 `{ name, patch, extraConfig?, structuredExtraConfig?, features? }` 的列表，
  由 `build.nix` 转成 stdenv 的 `patches` 应用；
- `enableCommonConfig ? true`，为 `false` 时只保留 `structuredExtraConfig`；
- `configfile` 派生 `inherit (kernel) src patches` 且 `postPatch = kernel.postPatch + …`，
  **所以内核上的 `postPatch` 会同时传给配置派生**——`gaokun3_defconfig` 必须在配置阶段就可见，
  这一点是当前设计能成立的前提；
- 存在 `extraPassthru`，是挂 `updateScript` 的正式位置。

**做法。** 把 `src` 直接设成 tarball，用 `kernelPatches` 承载补丁，用 `postPatch` 拷贝本地源：

```nix
buildLinux (base // {
  src = fetchurl { url = pins.kernelTarballUrl; hash = pins.kernelHash; };
  kernelPatches = series "upstream" ++ series "others" ++ series "himax" ++ series "media";
  postPatch = ''
    cp ${../../dts}/*.dts ${../../dts}/*.dtsi arch/arm64/boot/dts/qcom/
    cp ${../../defconfig}/gaokun3_defconfig arch/arm64/configs/
  '';
} // lib.optionalAttrs (args ? kernelPatches) { inherit (args) kernelPatches; }
  // lib.optionalAttrs (args ? randstructSeed) { inherit (args) randstructSeed; }
  // lib.optionalAttrs (args ? features)      { inherit (args) features; })
```

**注意（两点，都容易踩）：**

- **`…@args` 的转发不能省。** 现有注释解释了原因：`callPackage` 会把 `pkgs.kernelPatches`
  （补丁集 attrset，不是列表）注入同名形参，而 NixOS 的 `linuxPackagesFor` 会通过 override
  传真正的 `kernelPatches` / `randstructSeed` / `features`。这三者继续走 catch-all 转发，
  不声明为形参。
- **基础补丁要前置拼接**，即 `basePatches ++ (args.kernelPatches or [])`，
  否则用户从 `boot.kernelPatches` 追加的补丁会覆盖掉 gaokun3 自己的系列。
  这一点当前代码没有，是新增的正确性要求。

`linuxPackagesFor` 的正常工作、`modDirVersion = "${version}-gaokun3"`
（对应实测的 `7.2.0-gaokun3`）保持不变。

### 5.4 内核配置收敛（P3 的核心）

**问题。** 现状 `enableCommonConfig = false` + 509 行自带 defconfig，是一份**独立的发行版内核策略**。
代价是一串补偿性规避：

- `boot.initrd.includeDefaultModules = false`——默认列表里的 `ehci_pci`、`hid_apple`、`sata_*`
  等在本内核里没有 `.ko`，会让 modules-closure shrink 失败；
- `boot.initrd.systemd.tpm2.enable = false`——没有 CRB 驱动；
- `structuredExtraConfig` 里为绕过 nixpkgs `autoModules` 而钉死的 `VIDEO_QCOM_IRIS = "n"`。

**做法。** `enableCommonConfig = true` + nixpkgs aarch64 基线 +
`nix/config/gaokun3-extra.nix` 里一个**逐符号审查过**的 `structuredExtraConfig` 增量。
这与目标 2 的新版本直接对应，也正是 `CLAUDE.md` 已经为 Fedora 侧写下的目标
（"Fedora's config plus a small reviewed Gaokun fragment"）。

步骤：

1. 取 nixpkgs 的 aarch64 目标配置（`pkgs.linuxPackages.kernel.passthru.configfile`）。
2. 与 `defconfig/gaokun3_defconfig` 做 `diffconfig` / `merge_config.sh` 比对。
3. **逐个符号判定**去留，产出增量；每个保留项写明理由（这是评审的主要工作量）。
4. `enableCommonConfig = true`，删掉上面三项规避，实机冷启动验证。

**注意。** P3 是本文里唯一**必须实机验证**的步骤，因此它与 P0–P2 分开提交、单独回滚。
判定依据是 `diffconfig` + `lsinitrd` + 一次冷启动日志；不能靠推理结案。

`VIDEO_QCOM_IRIS` 需在 P3 重新评估：当前钉死它是为了对抗 `autoModules` 对所有 tristate
问题回答 `m`，而 v7.2 把 Venus 的 IRIS2 资源放在 `!CONFIG_VIDEO_QCOM_IRIS` 之后，
IRIS 本身不支持 sc8280xp。若收敛后该冲突仍在，保留钉死并在此处记录。

### 5.5 固件包

现状基本正确，需补三项：

- `src = ../../firmware` 换成 `lib.cleanSource`，避免把无关文件带进 store，
  也让"哪些文件属于固件包"显式化；
- **保留并测试符号链接。** `SC8280XP-HUAWEI-GAOKUN3-tplg.bin` →
  `HUAWEI/gaokun3/audioreach-tplg.bin` 是声卡真正请求的名字，`cp -a` 已能保住它（实测生效）。
  加 `checks.firmware-symlinks` 防止断链回归——断链同时会打死 Fedora 侧工作流的 `hashFiles`；
- `version = "0.1.0"` 静态，建议改为由内容派生（如固件树 sha256 的前 7 位），
  这样"固件变了但版本没变"不会发生。

`meta.license = unfreeRedistributable` 保持，`allowUnfreePredicate` 的用法写进安装指南。

### 5.6 工具包

- `substituteInPlace` 从 `installPhase` 移到 `postPatch`，让替换在源码副本上发生
  （现行做法能工作，但改动的是已安装产物，语义上是绕过而非修补）；
- 补 `meta.mainProgram`、`meta.license`（SPDX 复核，当前 `gpl2Plus` 需确认与
  `chiyuki0325/EGoTouchRev-Linux` 的来源一致）；
- `src = lib.cleanSource ../../tools`；
- 触屏调参 GUI 的启动器已经很干净地手工生成，评估是否改用 `makeWrapper` 以获取正确的
  `GI_TYPELIB_PATH` / `GSETTINGS_SCHEMA_DIR` 语义
  （`wrapGAppsHook4` 已在其上，手工脚本目前够用）。

### 5.7 `alsa-ucm-conf-gaokun3` 独立成包

**问题。** 现状 `nixos/modules/hardware/gaokun3.nix:20-26` 在模块里做 `runCommand`：
拷整个 `alsa-ucm-conf`、`chmod -R u+w`、删掉 stock `sc8280xp.conf`、装自己的。
功能正确，但它是一个**构建**，藏在模块里，既不可缓存复用、也不可单独测试。

**做法。** 搬到 `pkgs/alsa-ucm-conf-gaokun3/`，模块通过 overlay 取用。
`ALSA_CONFIG_UCM2` 的环境变量注入留在模块。附带收益是多了一个可以写 `checks` 的单元。

### 5.8 overlay

```nix
overlays.default = final: prev: {
  linux-gaokun3          = final.callPackage ../pkgs/linux-gaokun3 { };
  linuxPackages_gaokun3  = final.linuxPackagesFor final.linux-gaokun3;
  linux-firmware-gaokun3 = final.callPackage ../pkgs/firmware-gaokun3 { };
  gaokun3-tools          = final.callPackage ../pkgs/tools-gaokun3 { };
  alsa-ucm-conf-gaokun3  = final.callPackage ../pkgs/alsa-ucm-conf-gaokun3 { };
};
```

这条同时解决"模块 re-`callPackage` 相对路径"的问题：模块不再自己构造包，而是消费 `pkgs`
里的名字，于是下游可以 override，`nixpkgs.follows` 与交叉编译也自然生效。

### 5.9 NixOS 模块契约

选项面：

| 选项 | 状态 | 说明 |
| --- | --- | --- |
| `hardware.gaokun3.enable` | 已有 | 总开关 |
| `hardware.gaokun3.kernelPackages` | 已有 | 默认 `pkgs.linuxPackages_gaokun3` |
| `hardware.gaokun3.firmware` | 已有 | 默认 `[ pkgs.linux-firmware-gaokun3 ]` |
| `hardware.gaokun3.binaryCache.enable` | 新增 | 见 5.11 |
| `hardware.gaokun3.el2.enable` | 新增（P4） | 切换到 EL2 内核包 |
| `hardware.gaokun3.tools.enable` | 新增 | 是否把调参 GUI 放进 `systemPackages` |

普通用户应只需要 `hardware.gaokun3.enable = true`。**不为每条 cmdline 造选项**——
那会变成"重述"，违反目标 2。cmdline 保持一份带理由注释的列表。

`nixosModules.default` 自动应用 `self.overlays.default`，用户不必手动加 overlay。
模块内部一律用 `pkgs.linux-gaokun3` 这类名字，不再出现 `../../../pkgs/...`。

**必须修正的一处语义。** `gaokun3.nix:113-114` 让 `hardware.firmware` 与
`hardware.enableRedistributableFirmware` 引入的 `linux-firmware` 争夺同名文件，
注释声称 "merged ahead of linux-firmware"，但那实际依赖模块定义的合并顺序。
实测当前解析正确（gaokun3 的 `HUAWEI/` 与 tplg 胜出），但这是巧合。
改为用 `lib.mkAfter`（或显式优先级）把顺序变成保证，并加一条 check 覆盖这个解析结果。

**被 P3 取代的规避**（届时删除，不作为长期设计）：
`boot.initrd.includeDefaultModules = false`、`boot.initrd.systemd.tpm2.enable = false`。

**保留的**：`boot.extraModprobeConfig` 里的 `softdep ath11k_pci pre: qrtr`
（ath11k 的 probe 同步 `request_module()` QRTR 族，未预载时会卡住模块机制数分钟，
这是有实测理由的，不是配置补偿）、pstore 挂载、`gaokun3-monitor` 定时记录、
`environment.etc."xdg/monitors.xml"`、`nixpkgs.config.allowUnfreePredicate` 的文档化。

### 5.10 `checks`

`nix flake check` 应能拦住以下几类回归，全部是 eval 期或廉价构建：

| check | 拦住什么 |
| --- | --- |
| `series-sync` | `patches/*/series` 与目录不一致（5.2 的 `throw` 已覆盖，这条做显式入口） |
| `pins-sync` | `nix/pins.nix` 与 `build.env` 漂移（Fedora 退役后删除） |
| `firmware-symlinks` | `firmware/` 下断链 |
| `firmware-precedence` | 同名的 gaokun3 文件确实胜出 `linux-firmware` |
| `eval` | `hardware.gaokun3.enable = true` 的 `nixosSystem` 能求值出 toplevel |
| `packages` | 包可构建（贵；只在 main 上跑） |

`eval` 的实现要点是让 check 只依赖 `drvPath` 而不是真的构建：

```nix
checks.eval = pkgs.runCommand "gaokun3-eval" { } ''
  echo ${nixosSystem.config.system.build.toplevel.drvPath} > $out
'';
```

### 5.11 二进制缓存：项目专属 cachix

**问题。** 宿主 `/etc/nixos/flake.nix` 已经配了 `berrys-nixos.cachix.org`，
但那是**整个 NixOS 配置的缓存**，而 `.github/workflows/` 里没有任何 nix job——
也就是说这个 substituter 目前是空的，这台骁龙每次内核改动都在本地重编。

**为什么必须独立一个 cache，而不是往 `berrys-nixos` 里推：**

1. **受益者不同。** `berrys-nixos` 服务一台机器；内核包的受益者是所有 gaokun3 用户。
2. **公钥是硬编码进别人配置的。** 第三方一旦把公钥写进自己的 `nixConfig`/`nix.conf`，
   你就**再也换不了这个 key**——换 key 等于打断所有人。个人 cache 的 key 会随个人折腾而变，
   这个耦合不能建立。
3. **淘汰策略不同。** 系统配置缓存随 generation 增删波动；内核是长期资产，
   不该被系统侧的清理连带淘汰。

#### 5.11.1 命名

cache 名会出现在：公钥、每个下游用户的 `flake.nix`、模块选项默认值、文档。所以选**项目域**
而不是个人域的名字：`gaokun3` 最自然（与模块名 `hardware.gaokun3` 一致），
被占用就退到 `linux-gaokun3`。**不要**用 `bryarrow-gaokun3`——下游不该在配置里写你的用户名。

#### 5.11.2 建 cache 与两个凭证

1. 用 GitHub 登录 cachix.org，建一个 **public** cache。
2. 拿两样东西：
   - **公钥** `gaokun3.cachix.org-1:…` —— 公开，进文档和 flake；
     cache 设置页可见，或 `cachix use gaokun3` 会打印。
   - **auth token** —— `cachix authtoken` 输出，存进仓库 secret `CACHIX_AUTH_TOKEN`。
     只有 CI 用，绝不入库。

#### 5.11.3 CI 推送

已核对 [`cachix-action` 的 `action.yml`](https://code.forgejo.org/PopeRigby/cachix-action/src/branch/master/action.yml)，
它的真实行为是：

- `skipPush` 默认 `false` → **默认就会推**；
- `useDaemon` 默认 `true` → 后台 daemon 把构建产生的 store path **边建边推**，
  不需要手写 `cachix push`；
- 想收窄用 `pathsToPush`（空白分隔的 path 列表，留空=推所有构建结果）
  或 `pushFilter`（正则排除）。

```yaml
- uses: cachix/cachix-action@v15
  with:
    name: gaokun3
    authToken: ${{ secrets.CACHIX_AUTH_TOKEN }}
    # NixOS 内核的 -dev 输出挂着整棵源码树，日常设备不需要它
    # （只有编 out-of-tree 模块才要）。它是这个 cache 里最大的单项。
    pushFilter: '(-dev$|-source$|linux-gaokun3-src)'
```

**注意。** 不必担心"把整个 nixpkgs closure 推上去"——[Cachix 定价页](https://www.cachix.org/pricing)
明确写着 **`cache.nixos.org` 里已有的条目默认不会存进 Cachix**。
所以推送内核的运行闭包时，nixpkgs 那部分不占额度。

#### 5.11.4 消费侧：最容易搞错的一步

**本项目 `flake.nix` 里写 `nixConfig.extra-substituters` 对 `/etc/nixos` 无效。**
`nixConfig` 只在**顶层 flake** 被采纳，而 `gaokun3` 是它的 input
（见 [Nix #6752](https://github.com/NixOS/nix/issues/6752) 与
[相关讨论](https://github.com/ryan4yin/nixos-and-flakes-book/discussions/62)）。

三个层次要分开处理：

**(a) 本机**——改 `/etc/nixos/flake.nix`，两个 cache 并列：

```nix
nixConfig = {
  extra-substituters = [
    "https://berrys-nixos.cachix.org"
    "https://gaokun3.cachix.org"
  ];
  extra-trusted-public-keys = [
    "berrys-nixos.cachix.org-1:N4MjZIxrYDxyIQwm+95J63GhYehDnqs+LBLQUMtXkaY="
    "gaokun3.cachix.org-1:<新公钥>"
  ];
};
```

Nix 会依次查两个 substituter，互不干扰。

**(b) 第三方用户**——README / `docs/nixos_install_guide_*.md` 里给出同一段片段；
或更省事，让他们 `cachix use gaokun3` 一次写进 `/etc/nix/nix.conf`。

**(c) 项目 flake 自己仍应写 `nixConfig`**——因为当有人直接
`nix build github:bryarrow/linux-gaokun-buildbot` 时，**它就是顶层 flake**，此时 `nixConfig` 生效。
非 trusted 用户需要 `--accept-flake-config`，这是 Nix 的设计。

**(d) 模块选项**——给用户一条不必手改 flake 的路径：

```nix
hardware.gaokun3.binaryCache.enable = lib.mkDefault true;
# → nix.settings.extra-substituters / extra-trusted-public-keys
```

**注意。** 要有开关而不是无条件注入——替用户新增一个受信任签名 key 是信任决定，
而且它会影响这台机器上**所有**构建，不只 gaokun3 的。文档写清楚。

#### 5.11.5 配额与淘汰

按[定价页](https://www.cachix.org/pricing)：开源项目免费 **5 GB**；到 85% 发警告邮件；
到上限后**按 LRU 淘汰**。含义：

- 内核 `out` + `modules` 压缩后每个版本大概几百 MB，5 GB 能放好几个版本；
- **旧版本会被自动清掉**，用户若停在旧版本上会回落到本地编译。这可接受，但必须写进文档，
  别让人以为是 bug；
- 这也是 5.11.3 要排掉 `-dev` 的原因：它是这个 cache 里最容易把额度吃光的单项。

若 5 GB 不够，出路是自建 `attic`/`harmonia`，但那是另一个量级的运维投入，现阶段不值得。

#### 5.11.6 与本机 `berrys-nixos` 的关系

宿主的推送逻辑（若有）会把整个系统闭包推给 `berrys-nixos`，其中**也包含 gaokun3 那几个 path**，
于是两个 cache 里各存一份。省这点空间不值得动 CI，但如果 `berrys-nixos` 的推送逻辑好改，
加一条 `pushFilter` 排掉 `linux-gaokun3` 更干净。

### 5.12 CI

新增 `.github/workflows/gaokun3-nix.yml`，这是主 CI：

- **runner 必须用 arm64**（`ubuntu-24.04-arm`）。内核包的 `meta.platforms = aarch64`，
  在 x86_64 runner 上 `nix flake check` 会因平台不符而跳过或失败；
  交叉构建虽然可行但要在慢速模拟下编内核。**注意 arm64 runner 对 private 仓库计费。**
- 触发：`pull_request` 跑 `nix flake check --no-build`（eval 类，秒级）；
  `push` 到 `main` 且 `paths` 命中 `**.nix` / `flake.lock` / `patches/**` / `dts/**` /
  `defconfig/**` / `firmware/**` / `tools/**` 时跑全量并推送缓存。
- 缓存：按 5.11.3 接 `cachix-action`。
- Fedora 三条工作流保持不变，但按第 4 节冻结、按 5.13 打 tag。

### 5.13 版本与发布

- 给 NixOS 主产物打 tag（如 `v7.2-gaokun3.1`），宿主 flake 从 `gaokun3-nix-debug` 分支
  改为跟 `main` 上的 tag。**当前跟可变 debug 分支是生产用法里最该先修的一条**，
  且它与代码改动无关，可以立刻做。
- 内核 `passthru.updateScript` 挂在 `extraPassthru` 上：脚本从 `cdn.kernel.org` 的
  `sha256sums.asc` 取新 hash 并改写 `nix/pins.nix`。不指望 `nix-update` 能处理这种
  "tarball 版本 + 本地补丁系列"的组合。

---

## 6. 步骤：分阶段计划

每阶段都可独立提交、独立回滚。P1 与 P0 无依赖关系，可并行甚至先做。
P3 是唯一需要实机冷启动验证的。

> 各阶段实现状态见 §11.1。

### P0 — 供应链与不变量（低风险）

**改动**：`nix/pins.nix`；`nix/lib/patch-series.nix`；`patches/el2/series`；
`pkgs/linux-gaokun3/default.nix` 改用 `src = fetchurl` + `kernelPatches` + `postPatch`，
并把基础补丁前置拼接；`checks/` 里的 `series-sync` / `pins-sync` / `firmware-symlinks` / `eval`。

**验证**：`nix flake check --no-build`；
`nix build .#packages.aarch64-linux.linux-gaokun3`（本机是 aarch64，可原生验证）。

**注意**：`kernelPatches` 与 `postPatch` 的交互已在 `generic.nix` 中核对，见 5.3 的两条注意。
回滚：单 commit。

### P1 — CI 与二进制缓存（收益最大）

**改动**：按 5.11 建 cache 与 secret；`.github/workflows/gaokun3-nix.yml`；
模块的 `hardware.gaokun3.binaryCache.enable`；README / 安装指南的 `nixConfig` 片段；
本机 `/etc/nixos/flake.nix` 增加第二个 substituter。

**验证**：`nix path-info --store https://gaokun3.cachix.org /nix/store/…-linux-gaokun3-…` 命中；
设备上 `nixos-rebuild` 不再本地编内核。

### P2 — 包与模块架构

**改动**：`overlays/default.nix`；`pkgs/alsa-ucm-conf-gaokun3/`；模块改用 `pkgs.*`；
`lib.mkAfter` 固定 firmware 优先级；补齐 `meta` / `passthru` / `mainProgram`；
`packages.default` 不再指向内核。

**验证**：`nixos-rebuild dry-build --flake /etc/nixos#berrysEGO`；
与当前 generation 做 `nix store diff-closures`，确认只有预期差异。

### P3 — 内核配置收敛（独立提交，实机验证）

**改动**：`nix/config/gaokun3-extra.nix`；`enableCommonConfig = true`；
删除 `includeDefaultModules = false` 与 `systemd.tpm2.enable = false`。

**验证**：`diffconfig` 逐符号复核；`lsinitrd` 确认所需模块与固件在 initramfs 内；
一次冷启动。

**注意**：失败即回滚到 P2 状态，不影响其他阶段。P3 前先确认
`boot.loader.systemd-boot.configurationLimit = 5`（已是）留有足够旧 generation 可回滚。

### P4 — EL2 变体

**改动**：`pkgs/linux-gaokun3-el2/`（追加 `patches/el2/*`，`LOCALVERSION=-gaokun3-el2`）；
`hardware.gaokun3.el2.enable`。

**注意**：这是功能对等项——Fedora 侧建 `*-el2`，Nix 侧目前完全没有，
尽管 store 里已存在上游的 `sc8280xp-huawei-gaokun3-el2.dtb`。
EL2 路径在 `CLAUDE.md` 里被定位为实验性，因此选项默认关闭。

### P5 — 文档与叙事反写

**改动**：`README.md` 的 NixOS 段升为 Quickstart 主体，Fedora 部分收进 legacy 小节；
新增 `docs/nixos_install_guide_{en,zh}.md`；
**重写 `CLAUDE.md` 的目标章节与 "What gets built" 表**，把 NixOS 放在前面；
`AGENTS.md` 的 Validating commands 增加 `nix flake check --no-build`。

**注意**：这是"取代"在文档层面的落地。不做这一步，后来者读到的仍是 Fedora 主产物。

### P6 — NixOS 安装介质（Fedora 能否退役的前提）

**改动**：从本 flake 产出可启动的 aarch64 安装介质，内核为 `linux-gaokun3`。
候选是 `nixosSystem.config.system.build.isoImage` 或 `nixos-generators` 的 `install-iso`。

**验证**：写 U 盘，在实机上完成一次全新安装。

**注意**：只有这一步完成后，第 4 节的第 3 步才成立，Fedora 三条工作流才可删除。

---

## 7. 注意事项汇总

按"最容易踩"排序，前面章节的注意点在此集中列出：

1. **安装介质是退役的阻塞点。** 设备能跑 NixOS ≠ 能把 NixOS 装上去。P6 不完成，
   Fedora 的救援 U 盘就删不掉（第 4 节）。
2. **`nixConfig` 只认顶层 flake。** 项目 flake 里写 substituter 对把它当 input 的用户无效（5.11.4）。
3. **cache 名与公钥一次性。** 下游会硬编码，改名/换 key 等于打断所有人（5.11.1、5.11.2）。
4. **`includeDefaultModules = false` 是债务不是设计。** 它是 `enableCommonConfig = false`
   的后果，P3 应消除它（2.1、5.4）。
5. **`…@args` 转发不能省，基础补丁必须前置拼接。** 省了前者会让 `callPackage` 注入错的
   `kernelPatches`；漏了后者会让用户的 `boot.kernelPatches` 覆盖掉 gaokun3 自己的系列（5.3）。
6. **`series` 是唯一排序依据。** 两个实现（CI / Nix）必须行为一致，否则一个补丁能在一边过、
   在另一边失败（5.2）。
7. **`postPatch` 会同时作用于内核与 configfile 派生**，`defconfig` 必须在配置阶段就可见（5.3）。
8. **firmware 里不能有断链。** 断链会让所有 Fedora CI 任务在 `hashFiles` 处直接死掉（5.5）。
9. **`-dev` 输出会吃掉 cache 额度。** 排掉它（5.11.3）。
10. **cache 到 5 GB 后按 LRU 淘汰**，旧内核版本会消失，这是预期行为，需写进文档（5.11.5）。
11. **`enableCommonConfig` 不能一开始就打开。** 否则"打包机制改造"与"内核配置变更"两个
    独立风险耦合进同一提交，出问题分不清是哪一个（第 10 节）。
12. **宿主跟的是可变 debug 分支。** 这是与代码无关、可立刻修的一条（5.13）。

---

## 8. 风险与回滚

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| P3 配置收敛导致无法启动 | 高 | 独立提交；`configurationLimit = 5` 留有旧 generation 可回滚 |
| 宿主 flake 跟 `gaokun3-nix-debug` 分支 | 中 | 5.13 的 tag 化，与代码改动无关 |
| `kernelPatches` 替换 `src` 后补丁语义变化 | 中 | P0 验证时对比 `git am` 与 stdenv `patch -p1` 后的树 |
| cache 被 LRU 淘汰掉旧内核 | 低 | 文档说明；必要时自建 attic |
| arm64 runner 计费或不可用 | 低 | 退回自托管或 x86_64 交叉构建，代价是时长 |
| Fedora 安装/救援路径在 P6 完成前失效 | 高 | 第 4 节的顺序约束：P6 之前不删任何 Fedora 工作流 |

---

## 9. 未决问题

1. **`defconfig/gaokun3_defconfig` 的最终归属。** P3 之后它是被删除（差异全部进入
   `nix/config/gaokun3-extra.nix`），还是保留为 Fedora 侧的输入？后者意味着它继续存在到 Fedora 退役。
2. **模块是否最终上游到 `nixos-hardware`。** 这是"生产 NixOS 包"的自然终点，
   但会改变 `patches/` 的供给方式，需要单独设计。
3. **是否保留 `checks.vm`。** VM 抓不到任何硬件问题（显示、触屏、EC、音频），
   它能抓的只是 eval 与 initrd 组装类错误。是否值得在 arm64 runner 上付出构建时间，
   取决于 P0 之后这类错误出现的频率。
4. **`packages.default` 指向什么。** 本文建议不指向内核，但若下游习惯
   `nix build github:…` 取内核，需要重新权衡。

---

## 10. 拒绝的替代方案

- **拆成独立的 `linux-gaokun-nix` 仓库。** 拒绝理由：`patches/ dts/ defconfig/ firmware/ tools/`
  是 Nix 与 CI 的共同真相源，分仓要么复制它们、要么把本仓库降级成 flake input，
  两者都引入同步成本，而收益（独立的 lock 与 CI）在当前规模下不成立。
- **物理搬迁 Fedora 目录到 `legacy/`。** 拒绝理由：见 3.1，收益是观感，成本是全仓路径引用返工。
- **让 Nix 直接 parse `build.env`。** 拒绝理由：hash 必须手写，parse shell 只能省掉 `kernelTag`
  一项，却引入脆弱的文本解析；用一条 check 断言一致性更稳。
- **把 gaokun3 的包推进个人 `berrys-nixos` cache。** 拒绝理由：见 5.11，受益者不同、
  公钥会被下游硬编码、淘汰策略不同。
- **一开始就把 `enableCommonConfig` 打开。** 拒绝理由：会把两个独立风险耦合进同一提交。
- **在模块里为每条内核参数造选项。** 拒绝理由：违反目标 2 的"继承而非重述"，
  且会让模块 API 随内核版本漂移。

---

## 11. 实现进展与偏差

本节记录落地情况与设计正文的差异。设计正文保持评审时的原样，不回写。

### 11.1 状态

| 阶段 | 状态 | 落点 |
| --- | --- | --- |
| P0 供应链与不变量 | 已完成，逐项验证 | `9013b9a1` |
| P1 CI 与二进制缓存 | 代码已完成（`9bfa8883` 补上内核 `modules` 输出）；用户侧待办见 11.4 | `db75b4fa` |
| P2 包与模块架构 | 已完成（overlay、alsa 包、`pkgs.*`、`mkBefore`、meta、`packages.default`） | `f9fc6b28` |
| P3 内核配置收敛 | 代码已完成（基底已换成内核 `defconfig`，第 24 条），待实机冷启动验证 | `da1d7b36`、`3844f77b`、`1f970437` |
| P4 EL2 变体 | 未开始 | — |
| P5 文档与叙事反写 | 未开始 | — |
| P6 NixOS 安装介质 | 未开始（Fedora 能否退役的前提） | — |

### 11.2 实现偏差

1. **§5.3 的 `postPatch` 机制不成立。** 核对的 nixpkgs（`e5bdc4a41d4c`）里 `generic.nix`
   既没有 `postPatch` 形参，也不把它转发给 `build.nix`；`configfile` 的
   `postPatch = kernel.postPatch + …` 取的是 build.nix 自己那段字符串。照原设计写，
   `gaokun3_defconfig` 会在配置阶段缺失且不报错。实现改为用 `applyPatches` 的 `postPatch`
   在 `src` 层拷贝 `dts/` 与 `defconfig/`，内核与配置派生都能看到；`kernelPatches` 承载补丁、
   基础补丁前置拼接这两点按原设计保留。
2. **`checks.firmware-symlinks` 只能在构建期做。** Nix 2.34 没有读取链接目标的 builtin，
   且 `builtins.pathExists` 对断链返回 `true`，eval 期无法判定；实现改为在 runCommand 里
   `find ${../firmware} -xtype l`。
3. **`checks.eval` 只对 `aarch64-linux` 定义。** 模块本身只在 aarch64 可求值；若按
   `checks.<sys>` 对 x86_64 求值，会因 `linux-gaokun3` 的 `meta.platforms = aarch64` 失败
   （`--all-systems` 实测）。
4. **`.drvPath` 带 context。** 直接插值会把整个系统闭包变成 check 的构建输入；实现用
   `builtins.unsafeDiscardStringContext` 只保留文本，check 才不会把内核拖进来。
5. **`checks.packages` 落在 P1 而非 P0。** §5.10 把它列为 check，但 P0 的改动清单没有它，
   而 P1 的缓存推送需要它在 main 上真正构建内核；因此 P1 添加，并同样只在 aarch64 定义。
6. **`nix flake check` 的 unfree 问题。** 原实现下 `linux-firmware-gaokun3` 的 unfree license
   会让 `nix flake check` 在 `packages` 输出处直接失败；P0 在 flake 自己的 pkgs 里加了
   `allowUnfreePredicate`（消费侧仍需自行允许，README 已写）。
7. **CI action 版本与触发路径。** §5.12 写 `cachix-action@v15`；实现用当前 `@v17`
   （`pushFilter`/`skipPush`/`useDaemon` 未变）与 `install-nix-action@v31`（默认启用
   `nix-command flakes`）。push 的 `paths` 额外包含 workflow 文件自身。
8. **`checks/` 目录化。** §3.1 把 checks 放在 `checks/`；实现为 `checks/default.nix`，
   由 flake 传入 `self` / `lib` / `system` / `pkgs` / `allowUnfreePredicate`。
9. **§5.8 的 overlay 改为指向 flake 自己的构建。** 原设计
   `linux-gaokun3 = final.callPackage ../pkgs/linux-gaokun3 {}` 会用消费方的 nixpkgs
   重建内核，于是缓存按消费方 nixpkgs 分叉：`e5bdc4a` 出 `w674i7r…`、`6774f7bc` 出
   `g2sa2ww1…`，都是 `7.2.0-gaokun3`。改为 `self.packages.${prev.system}.*`，由
   `nixosModules.gaokun3` 应用 overlay；官方内核之所以没有这个问题，是因为内核和消费它的
   系统共用同一个 nixpkgs，C 把这个不变量换成"共用 flake pin 住的 nixpkgs"。
   **推论：消费方不能再写 `gaokun3.inputs.nixpkgs.follows`**，否则 `self.packages` 里的
   nixpkgs 又变回消费方的，C 失效；README 已改。
10. **`checks.packages` 只 realise 默认输出。** `linkFarm` 只引用每个包的默认输出，CI 因此
    只构建并推送了内核的 `out`，`modules`（system closure 与 initramfs 需要）从未构建，
    设备即使替换了镜像仍要整编。现已显式引用 `linux-gaokun3.modules`（`9bfa8883`）。这也是
    官方缓存里 `out`/`modules`/`dev` 齐全的原因：Hydra realise 整条 derivation。
11. **§5.9 的固件优先级方向写反。** nixpkgs 的 `hardware.firmware` 文档说**列表中第一个包胜出**；
    `buildEnv` 的实现更细：先比 `meta.priority`（小者胜），priority 相等才先入者胜
    （`builder.pl:159`）。`linux-firmware` 的 `meta.priority = 6`，我们的 firmware 未设 →
    `lib.meta.defaultPriority = 5`，所以**今天本来就赢**，`lib.mkBefore`（`f9fc6b28`）是双保险。
    `checks.firmware-precedence` 现在按"priority + 顺序"断言胜出，而不只断言顺序。
12. **tools 包的许可已从 `meta.license` 移除。** `patch-nvm-bdaddr.py` 上游（whitelewi1-ctrl）
    是 GPL-2.0，而 `chiyuki0325/EGoTouchRev-Linux` 没有 license 文件（GitHub license API 404），
    组合作品没有任何单一 SPDX 标识成立。`meta.license` 本就是可选的，因此去掉字段、只留注释，
    等维护者裁定。
13. **（已由第 24 条取代）P3 的基底暂时仍是 `gaokun3_defconfig`。** 设计 §5.4 的终点是 `defconfig = "defconfig"`
    加一份经审查的 Gaokun 片段。把 defconfig 与 nixpkgs `common-config.nix` 的**显式**符号集
    比对后，真正"两边都设了但值不同"的只有 12 个（LSM order、preemption、tracing、驱动家族
    这些并不是冲突，只是 common config 不设，会自动继承 nixpkgs/autoModules 的缺省）。
    因此本轮先开启 `enableCommonConfig` 并保留 defconfig 作为基底：既拿到 nixpkgs 策略，
    又让"两个策略都没提到"的 Gaokun 值原样保留，风险最小。把基底换成 `defconfig` 并删除
    defconfig 需要逐符号重审整份片段，留待实机迭代。
14. **覆盖 common config 需要显式优先级。** `common-config.nix` 的选项是优先级 100 的普通
    定义，同优先级的第二个定义会直接报冲突（`CMA_SIZE_MBYTES` 实测）。`nix/config/gaokun3-extra.nix`
    用 `lib.mkOverride 90` 覆盖，并保留 `mkForce`(50) 给用户——与 `zen-kernels.nix` 同一惯例。
15. **（定性已由第 24、25 条取代，`ignoreConfigErrors` 已删除）P3 首次 CI 失败于 configfile，需要 `ignoreConfigErrors`。** `generate-config.pl` 在
    aarch64 上把"common config 设了但用不上"的选项当致命错误，7.2.0 下有 27 个：多数是别的
    平台的驱动，其父 menu 被 gaokun3_defconfig 关掉（`RTW88`、`ROCKCHIP_*`、`SUN8I_*`……），
    外加 `IMA`、以及 `NVME_AUTH`（common 要 `m`、基底是 `y`）。**`IMA` 不是"别的平台的驱动"**：
    common config 要求 `IMA = yes`，它只是因为 defconfig 写了 `# CONFIG_INTEGRITY is not set`
    而不可见（上游 arm64 defconfig 没有这一行）。曾因此开启 `INTEGRITY`，后因 90 秒启动回归撤销，
    经过见第 22 条。其余不是本树的错误，因此设
    `ignoreConfigErrors = true`（`3844f77b`），与 `linux-rpi.nix` 同理；代价由
    `checks.config-symbols`（第 20 条）补回。
16. **`tpm2.enable = false` 不能删。** 设计 §6 P3 把它列为要删除的补偿之一，但本机是**设备树
    启动**，`CONFIG_ACPI` 关闭 → `TCG_CRB` 从不构建；而 nixpkgs 的 systemd initrd 在 aarch64
    上无条件加 `tpm-crb`（`nixos/modules/system/boot/systemd/tpm2.nix`），modules-closure 会失败。
    依据是**现行内核实测**：`/run/current-system/kernel`（P3 前的 `w674i7r…`）的 modules 里有
    `tpm_tis.ko`/`tpm_ftpm_tee.ko`、没有 `tpm_crb.ko`；不是 P3 的实机验证（尚无该 generation）。
    P3 真正删掉的只有 `includeDefaultModules = false`。
    （第 25 条更新：基底换成内核 `defconfig` 后 `CONFIG_ACPI=y`、`TCG_CRB=m`，"`tpm-crb` 从不
    构建"这个前提已经变了。这行仍然保留，但它的作用收窄成"initrd 里不放 TPM"，见 11.4 第 9 条。）
17. **删掉 defconfig 的 `CONFIG_LSM`。** 该串里写的 `integrity` 在 7.2 已不是 LSM，且非默认
    `CONFIG_LSM` 会覆盖 `DEFAULT_SECURITY_*`，所以旧的那行既过时又让默认选择失效。改用内核默认：
    实测得到 `landlock,lockdown,yama,loadpin,safesetid,selinux,smack,tomoyo,apparmor,ipe,bpf`
    ——**AppArmor 因此才真正进入列表**（旧串里没有它）。注意 `defconfig/` 与 Fedora 流水线共用，
    这次改动同样作用于 Fedora 侧。
18. **调试信息改用 nixpkgs 策略。** common config 打开 `DEBUG_INFO=y` +
    `DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT=y` + `DEBUG_INFO_BTF(_MODULES)=y`（P3 前是
    `DEBUG_INFO_NONE=y`）。安装时会 strip、`-dev` 又被 pushFilter 排除，缓存体积增长有限，但
    CI 时长与 `dev` 输出会增加。§5.11.5 与 README 的"每个版本几百 MB、5 GB 能放几个版本"需要
    按新配置重新量一次（尚未做）。
19. **`CONFIG_RUST=y`。** common config 在 aarch64 + ≥6.12 + rustc 可用时开 `RUST`；新配置确认
    为 `y`，内核构建因此需要 rustc/bindgen，并有 `RUST_IS_AVAILABLE` 断言与额外时长。
20. **新增 `checks.config-symbols`，PR 也构建它。** 它构建 configfile（分钟级，不编译内核）并
    断言 delta 的每一条、`CONFIG_LOCALVERSION`、`INTEGRITY` 未开、`TCG_TPM=m`、无 `TCG_CRB`、
    `CONFIG_LSM` 不再含 `integrity`。这样 `ignoreConfigErrors` 的降级被补回可控保证，配置类
    回归在 PR 就拦住（此前 PR 只 `--no-build`）。
21. **仓库 URL 统一到 `bryarrow/linux-gaokun-buildbot`**（README 的 flake input/release/
    `nix build` 三处与 4 个包的 `meta.homepage`），与 git remote、宿主 flake 实际拉取一致。
    CI action 仍是可变 tag（`checkout@v6`、`install-nix-action@v31`、`cachix-action@v17`），与仓库
    其它 workflow 风格一致，暂不 pin 到 SHA。
22. **`INTEGRITY` 曾按第 15 条开启，因 90 秒启动回归撤销。** 链条每一环都已实测：
    `INTEGRITY=y` + common config 的 `IMA = yes` → `security/integrity/ima/Kconfig:12` 的
    `select TCG_TPM if HAS_IOMEM` 把 `CONFIG_TCG_TPM` 从 autoModules 的 `m` 变成 **`y`（内建）**
    → `/sys/class/tpmrm` 开机即存在（空）→ systemd `tpm2_support_full()` 置
    `TPM2_SUPPORT_SUBSYSTEM`，`efi_has_tpm2()` 又因固件给了 `TPMEventLog=0xfff64018` 为真 →
    `systemd-tpm2-generator` 把 `tpm2.target`（`Wants=dev-tpm0.device dev-tpmrm0.device`）
    挂进 `sysinit.target.wants` → 设备不存在，走满 90 秒设备超时。
    实测：旧内核（`TCG_TPM=m`）userspace 2.7–3.5 s、总启动 15–17 s；新内核 userspace
    **91.8 s**、总启动 1 min 46 s；`/proc/config.gz` 为 `TCG_TPM=y`/`INTEGRITY=y`/`IMA=y`。
    这台机器在 Linux 下没有可用 TPM（DT 启动、无 `microsoft,ftpm` 节点、`tpm_ftpm_tee` 未绑定），
    IMA 本来就在 TPM-bypass，等这 90 秒换不到任何东西，因此撤销 delta 里的 `INTEGRITY` 条目，
    并在 `checks.config-symbols` 里把"`INTEGRITY` 未开、`TCG_TPM=m`"钉死。
23. **`patch-nvm-bdaddr.service` 的既有 bug 一并修掉。** 它自本模块写就起就没成功过
    （boot -1/-2/-3 同样失败）：`ConditionPathExists` 被放进 `serviceConfig`，systemd 报
    `Unknown key 'ConditionPathExists' in section [Service], ignoring` 于是一直无条件运行；
    而 `hardware.firmware` 在 ≥5.19 上压缩成 `.zst`，脚本 `cp` 的 `wcnhpnv21g.bin` 根本不存在。
    修法：条件移到 `unitConfig`，脚本按实际存在的 `.bin`/`.bin.zst` 取源，`.zst` 用 `zstd -d`
    解压到可写目录再 patch，`path` 加上 `pkgs.zstd`。
24. **P3 的基底已换成内核自己的 `defconfig`（第 13 条的终点，`1f970437`）。** 改动三处：
    `pkgs/linux-gaokun3/default.nix` 的 `defconfig = "defconfig"`；
    `nix/config/gaokun3-extra.nix` 收敛到 8 条（`LOCALVERSION`、`BT_LE`、`INTEGRITY`、`IMA`、
    `TCG_TPM`、`CMA_SIZE_MBYTES`、`USB_PCI`、`VIDEO_QCOM_IRIS`）；`checks.config-symbols` 按新
    delta 重排。`defconfig/gaokun3_defconfig` 仍拷进内核树并继续驱动 Fedora 流水线，只是 Nix
    内核不再选它。**同片段下**与旧基底逐符号比对：4288 行取值不同、2893 个符号只在 nixpkgs 侧、
    155 个只在旧侧；旧配置 `=y`/`=m` 而新配置不再启用的有 195 个，逐个看全是别的平台的网卡
    （Starfire、NetXen、QLCNIC、SFC、TEHUTI……）、PCMCIA、`DVB_NET`，加上
    `ARM64_VA_BITS_48`/`PA_BITS_48`（换成 52 位）、`SECURITY_SELINUX*`、`NETFILTER_*_LEGACY`、
    `SYSFS_SYSCALL` 这类策略项。**没有本机用到的驱动消失**：`DRM_MSM`、`ATH11K(_PCI)`、
    `BT_QCA`、`SND_SOC_SC8280XP`、`EC_HUAWEI_GAOKUN`、`UCSI_HUAWEI_GAOKUN`、
    `TOUCHSCREEN_HIMAX_HX83121A_SPI`、`SCSI_UFS_QCOM` 等仍是 `m`/`y`。采纳 nixpkgs 的三项
    副作用要记住：`ARM64_VA_BITS=52`（连带 `PA_BITS=52`）、SELinux 关闭（nixpkgs 的 arm64
    defconfig 不设 `SECURITY_SELINUX`，common config 只设 `SECURITY_APPARMOR`；NixOS 本来也不
    开 SELinux）、ACPI 打开（第 25 条）。`ignoreConfigErrors = true` 随之删除：
    `generate-config.pl` 的致命检查恢复，第 15 条那 27 条现在只剩 `IMA` 一条需要处理。
25. **ACPI 随基底打开了，但运行期仍是设备树；`ignoreConfigErrors` 换成一条窄的 `optional`。**
    两件事都是第 24 条的直接后果：
    1. `TCG_CRB=m` 出现（内核自己的 arm64 `defconfig` 有 `CONFIG_ACPI=y`，而
       `gaokun3_defconfig` 没有这一行、arm64 上 ACPI 的 Kconfig 默认是 n），把
       `checks.config-symbols` 里"TCG_CRB 不应被构建"那条断言打红——这条 check 因此换成注释。
       判定**不必把 ACPI 关回去**：`arch/arm64/kernel/acpi.c:198` 的规则是"只有设备树是 stub
       时才启用 ACPI"，`dt_is_stub()`（同文件 71 行）除 `/chosen` 与 Xen 的 `/hypervisor`
       外只要还有任何一个顶层节点就返回 false；本机由 BLS 条目传入完整 gaokun3 DTB，cmdline
       里也没有 `acpi=on|force`，因此 `acpi_disabled` 在驱动初始化前就置位，`tpm_crb` 只是编
       进来、不会绑定。真正的守卫仍是 `TCG_TPM=m`（第 22 条）。
    2. `IMA = yes` 是 common config 里**没有**标 `optional` 的策略项，而 `INTEGRITY=n` 让 IMA
       不可见，`generate-config.pl` 因此把它当致命错误（`optional` 的合并规则是"mandatory 胜"，
       `kernel_config.nix` 的 `mergeFalseByDefault`）。修法是在片段里用 `hardwareOverride`
       （90 < common config 的 100，整条定义替换掉它的）重述 nixpkgs 的值并只加
       `optional = true`：既不改值，也只放过这一条。第 15 条的 `ignoreConfigErrors` 是全局
       开关，实测正是它把 `TCG_TPM (wanted 'm', got 'y')` 压成 warning、让 90 秒那次回归
       上了设备，因此不再使用。`checks.config-symbols` 增加"`IMA` 不得被构建"作为对这条放宽
       的负向断言。

### 11.3 验证记录（本机 aarch64 原生）

- `nix flake check --no-build --all-systems`、`nix flake check` 均通过；四个 eval 类 check
  与 `checks.packages` 可构建。
- 内核 `configfile` 派生与完整内核构建成功：`linux-gaokun3-7.2.0`（`Image`、
  `dtbs/qcom/sc8280xp-huawei-gaokun3.dtb`、模块输出 `7.2.0-gaokun3`，含 himax 触屏、
  `panel-himax-hx83121a`、`venus-*`）；固件包的 tplg 符号链接解析正常。
- 负向测试：未登记补丁、`nix/pins.nix` 与 `build.env` 漂移、`firmware/` 断链三类回归都被拦下。
- `nix/pins.nix` 的 hash 对应 `cdn.kernel.org` 的 `linux-7.2.tar.xz`；
  `https://gaokun3.cachix.org/nix-cache-info` 返回 200。
- C 的效果：把消费方 nixpkgs 设为 `6774f7bc`，`config.boot.kernelPackages.kernel.outPath`
  仍是 `w674i7r…`（改前为 `g2sa2ww1…`），即只由 flake 的 commit 决定。
- 缓存覆盖：`w674i7r…-linux-gaokun3-7.2.0` present，`99bqx8c4…-modules` 在 `9bfa8883`
  之前 MISS，已由 `checks.packages` 显式引用后交给 CI 补齐。
- P2 验证：`nix flake check --all-systems` 与全部 check 构建通过；新增的
  `alsa-ucm-conf-gaokun3`、重写的 firmware（`0.1.0-5wp9jc4`，版本由固件树内容哈希派生）、
  tools 均可构建；tools 的 `postPatch` 替换出现在 `.patch-nvm-bdaddr.py-wrapped`；
  UCM 包的 `sc8280xp.conf` 与 `tools/audio/sc8280xp.conf` 一致；`nix build .` 现在产出
  firmware 而非内核；`firmware-precedence` 用 `mkAfter` 负向测试确认会失败。
- P3 分析（纯求值，未构建）：与 `gaokun3_defconfig` 比对，504 个符号里 110 个与 nixpkgs
  显式策略重叠、其中仅 12 个值冲突。`nix flake check --no-build --all-systems` 在开启
  `enableCommonConfig` 后仍通过。
- P3 configfile：本地构建成功（`2i8c4833…`）。逐个核对 NixOS 默认 initrd 列表的模块，全部以
  `m` 或内建存在（`sata_*`/`ata_piix`/`pata_marvell`=m、`sd_mod`/`nvme`/`usbhid`/`hid_generic`/
  `xhci_hcd`/`xhci_pci` 内建、`ehci`/`ohci`/`uhci`/`hid_*`/`mmc_block`=m），自有的 initrdModules
  也都在。与 P3 前的配置逐符号 diff：**没有硬件驱动丢失**。差异分三类：
  1. nixpkgs 策略：抢占变 `PREEMPT_LAZY`、`NO_HZ_FULL`（取代 `NO_HZ_IDLE`）、`CONFIG_RUST=y`、
     `DEBUG_INFO`+`DWARF`+`BTF`、autoModules 之前打开的 KUNIT/自测模块被关掉；
  2. 本轮决定：`CONFIG_LSM` 改用内核默认
     `landlock,lockdown,yama,loadpin,safesetid,selinux,smack,tomoyo,apparmor,ipe,bpf`
     （旧串只有 `selinux`，**没有 `apparmor`**；又因非默认 `CONFIG_LSM` 会覆盖
     `DEFAULT_SECURITY_*`，"LSM 默认变 AppArmor"那句原本无效）；
  3. 无实际影响：`SND_AC97_POWER_SAVE`（`depends on SND_AC97_CODEC`，与 `SND_PCI` 无关）、
     `HID_PICOLCD_*` 之类。
- TPM 回归的实测（见 11.2 第 22 条）：同一固件、同一 systemd/配置，仅换内核，启动从 15–17 s
  变成 1 min 46 s；`/proc/config.gz` 的 `TCG_TPM` 由 `m` 变 `y`。撤销 `INTEGRITY` 后重跑
  configfile（`84cd8pnd…`）确认回到 `TCG_TPM=m`、`# CONFIG_INTEGRITY is not set`，delta 其余
  （`CMA_SIZE_MBYTES=128`、`USB_PCI=y`、IRIS 未设）不变。
- 新增的 `checks.config-symbols` 与 priority-aware 的 `checks.firmware-precedence` 均构建通过；
  `nix flake check --no-build --all-systems` 全绿。
- P3 基底的真实验收（本机 aarch64，只构建 configfile，不编译内核）：最终配置
  `/nix/store/yp29wzznn09j84xy6wil1yajzrjyanzd-linux-config-7.2.0`，`generate-config.pl`
  **0 个 error、15 条 warning**（14 条是 nixpkgs 自己标了 `optional` 的
  `XEN_*`/`KEXEC_JUMP`/`PARAVIRT_SPINLOCKS`/`PCI_XEN`/`EXT3_FS_*`/`GLOB_SELFTEST`/
  `CRC32_SELFTEST`/`CRYPTO_TEST`/`PERF_EVENTS_AMD_BRS`，第 15 条是本树新加的 `IMA`）。
  `checks.aarch64-linux.config-symbols` 与 `nix flake check --no-build --all-systems` 均通过。
- 负向测试：把 `ignoreConfigErrors` 删掉后构建，只报 `IMA` 一条 error；加上片段里的
  `optional` 后归零。这正是第 25 条第 2 点的依据。
- 新配置的关键取值：`ARM64_VA_BITS=52`/`ARM64_PA_BITS=52`、`# CONFIG_INTEGRITY is not set`、
  `CONFIG_TCG_TPM=m`、`CONFIG_IMA` 不存在（只剩无关的
  `# CONFIG_IMA_SECURE_AND_OR_TRUSTED_BOOT is not set`）、`CONFIG_LOCALVERSION="-gaokun3"`、
  `CONFIG_BT_LE=y`、`CONFIG_CMA_SIZE_MBYTES=128`、`CONFIG_USB_PCI=y`、
  `# CONFIG_VIDEO_QCOM_IRIS is not set`、`CONFIG_ACPI=y`/`CONFIG_TCG_CRB=m`、
  `CONFIG_SECURITY_SELINUX` 未设、`CONFIG_SECURITY_APPARMOR=y`/`DEFAULT_SECURITY_APPARMOR=y`。
- initrd 关心的模块在新配置里都在（名称换成 Kconfig 符号后核对）：`BLK_DEV_NVME`、
  `PHY_QCOM_QMP_{PCIE,COMBO,USB}`、`PHY_QCOM_USB_SNPS_FEMTO_V2`、`USB_UAS`、`TYPEC`、
  `PCI_PWRCTRL_PWRSEQ`、`ATH11K`、`ATH11K_PCI`、`I2C_HID_OF`、`SND_SOC_SC8280XP`、
  `PINCTRL_SC8280XP_LPASS_LPI`、`SC_LPASSCC_8280XP`、`HID_MULTITOUCH`、
  `DRM_PANEL_HIMAX_HX83121A`、`TOUCHSCREEN_HIMAX_HX83121A_SPI`、`BT_QCA`、`UHID` 为 `m`，
  `EXT4_FS`、`USB_STORAGE`、`BLK_DEV_SD`、`USB_HID` 为 `y`。`BLK_DEV_NVME` 由 `y` 变 `m`
  是这次唯一的启动路径变化，而 `nvme` 本来就在 `initrdModules` 和 nixpkgs 默认列表里；
  `BTRFS_FS` 也由 `y` 变 `m`，NixOS 由 `boot.initrd.supportedFilesystems`（取自根分区类型，
  `stage-1.nix:791`）自动加进 initrd。这两点仍要冷启动确认，见 11.4 第 7 条。

### 11.4 待办（用户侧）

1. 仓库 secret `CACHIX_AUTH_TOKEN`，值为 `cachix authtoken` 的输出。
2. （已完成）`/etc/nixos/flake.nix` 的 `nixConfig` 已加 `https://gaokun3.cachix.org`
   与公钥 `gaokun3.cachix.org-1:ikL6EofK55QEwKucrUo44SPKewscvAMJr7ibBxJtIsI=`。
3. **去掉 `/etc/nixos/flake.nix` 的 `gaokun3.inputs.nixpkgs.follows = "nixpkgs";`**：
   这是 C 生效的前提，否则 `self.packages` 又用消费方的 nixpkgs。
4. §5.13 的 tag 化：宿主已改为跟 `main`，但仍是一个可变分支，需要一个不可变 tag。
5. CI 跑过一次后，用 `nix path-info --store https://gaokun3.cachix.org <kernel-path>`
   确认 `out` 与 `modules` 都命中。
6. （字段已移除）tools 包的 `meta.license` 已删掉、只留注释；将来若要写，需要先确认
   `chiyuki0325/EGoTouchRev-Linux` 的授权状态。
7. **实机冷启动验证 P3，并观察这些行为差异**：`includeDefaultModules` 删除后的
   modules-closure/initrd、`NO_HZ_FULL` 取代 `NO_HZ_IDLE` 后的功耗与计时、新的 `CONFIG_LSM`。
   TPM 那 90 秒已在撤销 `INTEGRITY` 后消失，重启时应确认总启动回到 ~15 s；蓝牙侧确认
   `patch-nvm-bdaddr.service` 成功且 `bluetooth.service` 拿到 patch 后的 BDADDR。CI 只构建内核，
   这些都测不到。失败就回滚到 P2：`boot.loader.systemd-boot.configurationLimit = 5` 已留有旧
   generation。
   **基底已按第 24 条换成 `defconfig`**，`defconfig/gaokun3_defconfig` 因 Fedora 流水线保留，
   所以这次冷启动还要多确认三件事：(a) DT 启动没有被 ACPI 抢走——`dmesg` 里应出现
   `ACPI: Interpreter disabled.`（`drivers/acpi/bus.c:1580`，即编进来但没启用）、不应出现
   `ACPI: Core revision`，`/sys/firmware/acpi` 不应存在（第 25 条）；(b) `nvme` 与（若根是 btrfs）
   `btrfs` 已由 initrd 加载、根正常挂载（`BLK_DEV_NVME`/`BTRFS_FS` 由内建变模块）；
   (c) 蓝牙、触屏、显示、音频这些 `=m` 的设备驱动仍按 DT 自动加载。
8. 按新配置（`DEBUG_INFO`+`BTF`）重新量一次内核 `out`/`modules` 的压缩体积，更新 §5.11.5 与
   README 关于 5 GB 配额的估计。基底换成 `defconfig` 后平台驱动也多了，这次测量要一并覆盖。
9. `boot.initrd.systemd.tpm2.enable = false`（第 16、25 条）现在只剩"initrd 里不放 TPM"这一个
   作用：基底换成 nixpkgs defconfig 后 `TCG_CRB` 会被构建，当初"modules-closure 缺 `tpm-crb`"
   的理由已消失。删掉它就回到 nixpkgs 默认（initrd 带上 `tpm-tis`/`tpm-crb` 与 tpm2 单元；
   真正决定是否等待的是 `systemd-tpm2-generator`，而它在 `TCG_TPM=m` 下看不到
   `/sys/class/tpmrm`）。这需要一次冷启动确认 `systemd-tpm2-generator` 没有把 `tpm2.target`
   挂进 `sysinit.target`，不在本轮 P3 范围内。
