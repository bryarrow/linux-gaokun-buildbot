# linux-gaokun-buildbot

[English](../README.md) | 中文

为华为 MateBook E Go 2023（代号 `gaokun3`，高通骁龙 8cx Gen 3 / `SC8280XP`）
提供的 NixOS 支持：一个 flake，包含 gaokun3 内核、机型固件、设备工具、安装镜像，
以及一个把上述内容收在一个选项之后的 NixOS 模块。

## 目标

按优先级排列——冲突时以靠前者为准。

1. **在 MateBook E Go 上提供最好的体验。** 硬件支持优先于一切。设备树、内核配置、
   固件包，以及 `fbcon=rotate:1` 这类怪癖都会保留，即使它们与 stock NixOS 不同。
2. **stock NixOS 体验。** 内核按 nixpkgs 造内核的方式构建——`buildLinux`、common
   config，加上一小份经审查的 gaokun3 增量；模块按 NixOS 模块惯例编写，而不是重述
   nixpkgs 已经做出的决定。硬件没有逼我们偏离的地方，就跟随 NixOS，而不是自创。
3. **可以日常使用。** 不会比任何其他 NixOS 安装更容易坏：generation 和
   systemd-boot 菜单就是回滚路径，也不额外添加 NixOS 本身没有的护栏。

## 快速开始

安装介质就是原版的 NixOS 最小安装器，只是内核、设备树和内核命令行已经换成这台机器
需要的，因此它可以直接启动 MateBook E Go：

```bash
nix build github:bryarrow/linux-gaokun-buildbot#installer-iso
sudo dd if=result/iso/nixos-gaokun3-*.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

[在 MateBook E Go 上安装 NixOS](nixos_install_guide_zh.md)
（[English](nixos_install_guide_en.md)）是完整流程：写入 U 盘、分区、flake 与首次
启动。写盘之前请先读它；`dd` 不会询问就覆盖目标磁盘。

NixOS 跑起来之后，把本仓库作为 input 的配置只需要一行就能获得硬件支持：

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    gaokun3.url = "github:bryarrow/linux-gaokun-buildbot";
  };
  outputs = { nixpkgs, gaokun3, ... }: {
    nixosConfigurations.ego = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        gaokun3.nixosModules.gaokun3
        ({ ... }: { hardware.gaokun3.enable = true; })
      ];
    };
  };
}
```

该选项会启用 gaokun3 内核及其二进制缓存、板级设备树和内核命令行（面板旋转、键盘
quirk、8cx Gen 3 固件 workaround）、initrd 与启动模块、蓝牙 NVM 补丁、音频 UCM
配置、系统级显示旋转，以及周期性的温度/电源日志。请使用
`boot.loader.systemd-boot.enable = true`；设备树支持就是用这个 loader 测试的，而且
固件无法写 EFI 变量（`efi=noruntime`），所以 systemd-boot 会安装到可移动路径
`\EFI\BOOT\BOOTAA64.EFI`。

内核只面向 aarch64。在 x86_64 构建机上，flake 的包会被交叉编译；要在那上面构建安装
镜像，见[安装指南](nixos_install_guide_zh.md#一取得安装镜像)。

抄这段配置之前，有三点值得知道：

- **不要**添加 `inputs.gaokun3.inputs.nixpkgs.follows = "nixpkgs"`。内核、固件和工具
  都是用本仓库自己 pin 住的 nixpkgs 构建的，这才让它们对所有人都是同一个 derivation，
  因而是同一个二进制缓存条目。让它们 follow 你的 nixpkgs 会在本地按你的 nixpkgs 重建，
  缓存就对不上了。你系统自己的 nixpkgs 不受影响。
- 模块通过 `nixpkgs.overlays` 加入它的包，因此直接用 `nixpkgs.pkgs`（会替换掉整套包）
  的配置拿不到它们。要么把 `gaokun3.overlays.default` 自己应用到那套包上，要么使用
  普通的 `nixpkgs` 模块并让模块自己处理。
- 机型固件可以再分发但不可修改，所以在 stock 的
  `nixpkgs.config.allowUnfree = false` 下求值会拒绝它；需要显式允许：

  ```nix
  {
    nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
      "linux-firmware-gaokun3"
    ];
  }
  ```

### EL2 变体（实验性）

默认情况下 Linux 会接管整台机器。还有一个内核让 Linux 作为厂商 hypervisor 的 guest
运行：

```nix
{ hardware.gaokun3.el2.enable = true; }
```

它会新增一个启动条目 **NixOS (el2)**，使用 `pkgs.linuxPackages_gaokun3-el2`，启动
`sc8280xp-huawei-gaokun3-el2.dtb`，并附加该条目自己的内核命令行
（`modprobe.blacklist=simpledrm`）。普通条目仍保留 stock 内核与设备树，所以 EL1 与
EL2 在启动时选择，这个选项可以一直开着；再把它设为 `false` 就会移除该条目。这条路径
是实验性的，不属于受支持的配置。在 EL2 下视频编解码起不来——`qcom-venus` 能找到固件
但初始化失败（`-EINVAL`）——而设备上验证过的其他部分（wifi、音频、显示、蓝牙以及
KVM 本身）都正常。Secure Boot 必须关闭，且 `tcblaunch.exe` 必须是足够旧、仍支持
slbounce 的版本，所以不要用 Windows 分区里的新版替换本仓库自带的那份。

模块还会通过 `boot.loader.systemd-boot.extraFiles` 帮你把 EL2 启动链放到 ESP 上：
`EFI/systemd/drivers/` 下的两个驱动、ESP 根目录的 `tcblaunch.exe`，以及 hypervisor 从
`firmware/` 读取的三个 DSP 镜像。不需要手工拷贝或清理。这也是该选项要求
`boot.loader.systemd-boot` 的原因：只有这个 loader 会读那些驱动，配置了别的 loader 时
模块会发出警告。

这些路径位于 ESP 上，而不属于某一个系统。`sd-boot` 会为它启动的每个条目加载这些驱动，
所以共用同一 ESP 的其他安装读到的是同一批文件——关闭该选项会把它们从 ESP 上删除，
包括别的安装可能正在依赖的那份。这些驱动的**行为**由传给它们的设备树决定，因此只要
文件在，非 EL2 的条目不受影响；共享的只是文件的存在与否。

### 二进制缓存

项目把内核和固件的构建结果发布到一个公开的 Cachix 缓存，因此重建时下载而不是在设备上
编译内核。`hardware.gaokun3.enable = true` 会帮你接好
（`hardware.gaokun3.binaryCache.enable`，默认开启）。不用它一切也能工作，只是内核会
在本地编译。

信任一个缓存签名密钥会影响这台机器上的所有构建，而不只是 gaokun3 的，所以留了一个
开关：

```nix
{ hardware.gaokun3.binaryCache.enable = false; }
```

如果你更愿意自己配置 Nix，等价的写法是：

```ini
# /etc/nix/nix.conf，或运行 `cachix use gaokun3`
extra-substituters = https://gaokun3.cachix.org
extra-trusted-public-keys = gaokun3.cachix.org-1:ikL6EofK55QEwKucrUo44SPKewscvAMJr7ibBxJtIsI=
```

把本仓库作为 input 的 flake 不会继承它的 `nixConfig`——Nix 只采纳顶层 flake 的该字段
——所以请使用上面的片段或模块选项。当你直接构建本 flake 时，比如
`nix build github:bryarrow/linux-gaokun-buildbot`，它的 `nixConfig` 是生效的，但除非你
是受信任用户，Nix 会要求加 `--accept-flake-config`。

该缓存位于 Cachix 的免费开源档：5 GB，满了之后按最近最少使用淘汰。旧版本的内核路径
因此可能消失，重建它时改为在本地编译。这不会弄坏任何东西，只是更慢。内核的 `-dev`
输出带着整棵源码树，出于同样的原因被排除在上传之外；安装镜像也被排除：它是发行产物，
不是设备要 substitute 的东西。

## 硬件支持

设备上硬件支持状态的概览见 [right-0903/linux-gaokun 的 `## Feature Support`](https://github.com/right-0903/linux-gaokun?tab=readme-ov-file#feature-support)。

此外，本仓库通过 `media/` 补丁系列和 `CONFIG_VIDEO_QCOM_VENUS=m` 模块启用了
SC8280XP 的 Venus 硬件视频编解码（H.264/HEVC/VP9 的编码与解码）。

前后两颗摄像头在内核侧都已启用：前摄 `hi846`，后摄模组这台机器是 **三星 S5K3L6**，板子
另外还出过 **OmniVision OV13B10** 的模组。两者共用一个 CSIPHY、一根 reset、一个 MCLK，
所以设备树把两种都写上，`patches/camera/` 里的选择器在启动时给模组上一次电、读 ID，
谁应答就驱动谁——同一份内核和设备树两种模组都能用。这个系列还补上了 S5K3L6 的驱动和
上电序列，并修好了相机电源域；闪光灯走 PMIC。仍需用户态的相机栈来真正取流。

## 仓库结构

- `patches/`：内核补丁与设备支持改动
- `drivers/`：补丁系列中所改驱动源码的本地镜像
- `dts/`：补丁系列中所改设备树源码的本地镜像
- `docs/`：安装、EL2 与平台指南，以及中文 README
- `firmware/`：最小机型固件包
- `flake.nix`、`nix/`、`nixos/`：flake、NixOS 模块与安装器
- `pkgs/`：各个 Nix 包（内核、EL2 内核、固件、工具、ALSA UCM）
- `checks/`：`nix flake check` 的检查项
- `tools/`：设备专用辅助脚本、服务文件，以及 EL2 EFI 负载

### 补丁来源

- `upstream/*` 与 `others/0005`：改编自 [right-0903/linux-gaokun](https://github.com/right-0903/linux-gaokun)，涵盖基础 SC8280XP / gaokun3 启用、显示 bring-up、EC 挂起/恢复、ADSP FastRPC 以及 DSI 稳定性工作
- `others/0001`：改编自 [whitelewi1-ctrl/matebook-e-go-linux](https://github.com/whitelewi1-ctrl/matebook-e-go-linux)，在适配器地址无效时不再设置 `USE_BDADDR_PROPERTY`
- `others/0002`：本仓库的本地改动，启用 DSC 并允许 60 Hz / 120 Hz 切换
- `himax/0001`：改编自 [chiyuki0325/EGoTouchRev-Linux](https://github.com/chiyuki0325/EGoTouchRev-Linux)（revision `e738049`），加入重构后的 Himax HX83121A SPI 触屏驱动
- `others/0004`：改编自 [TheUnknownThing/linux-gaokun](https://github.com/TheUnknownThing/linux-gaokun)，改进 Type-C 路径的 UCSI 处理与模块接线
- `others/0006`：来自 [gaokun-android](https://github.com/vahiru/gaokun-android) 移植——主线 `sc8280xp.dtsi` 没有 CPU cooling map（每个 zone 只有一个 110 °C 的 critical trip），于是 CPU 会一直满跑直到紧急关机；这个补丁给绑定到该 cluster cpufreq cooling device 的八个每核 zone 各加了一个 75 °C 的 passive trip。这个缺口不是本机特有的，所以补丁是按上游标准写的
- `others/0008`：同样来自 [gaokun-android](https://github.com/vahiru/gaokun-android) 移植——本机固件每次复位都会重新初始化 DRAM，崩溃日志没法留在内存区里，所以这个补丁让 `efi_pstore` 在 QSEECOM 后端的 `efivars`（约 0.76 s）就绪时注册，而不是让内置 initcall 错过这个窗口后永远放弃。设备树因此不再预留 `ramoops` 区，持久的崩溃记录走 EFI 变量
- `media/*`：来自 [gaokun-android-kernel](https://github.com/pgs666/gaokun-android-kernel) 对 right-0903/linux-gaokun Venus 系列的移植，用于启用 SC8280XP Venus 硬件视频编解码（驱动资源、dt-bindings、`videocc` 与 `video-codec` 设备树节点）。gaokun3 的板级启用——指向已打包的 `qcvss8280.mbn` 的 `firmware-name` 与 `status = "okay"`——放在 `dts/` 里而不是补丁里
- `camera/*`：来自 [gaokun-android](https://github.com/vahiru/gaokun-android) 移植——板子有两种可互换的后摄模组、共用一个 CSIPHY（OmniVision OV13B10 在 0x36，三星 S5K3L6 在 0x10，这台是后者）。`camera/0006` 补上 S5K3L6 的驱动（Librem5 那版 + 本机上电序列），`camera/0004` 让 OV13B10 也能绑定，`camera/0007` 是在启动时上电读 ID、只注册应答那颗的选择器，因此一份设备树两种模组都能用。这个系列还把三个 camcc RCG 标成 shared（否则相机电源域会指着已经断电的 PLL，每第二次取流都失败），并让 camss 只带真正绑上的传感器完成注册，避免绑不上的后摄把前摄也一起拖没。闪光灯走 PMIC，用设备树里自己的节点
- `dts/`：直接拷进内核树，而不是作为补丁携带，这样升级内核时不会冲突
- **[可选]** `el2/*`：改编自 [TravMurav/linux](https://github.com/TravMurav/linux/tree/x13s-6.18-v1.1-cxsd)，用于 EL2 启动路径，包括 SMP2P 交接、remoteproc attach/restart 流程、SCM/SHM owner 处理，以及相关的 rpmsg/QRTR/pmic_glink 稳定性修复

### 工具来源

- `tools/audio`、`tools/bluetooth`：改编自 [whitelewi1-ctrl/matebook-e-go-linux](https://github.com/whitelewi1-ctrl/matebook-e-go-linux)
- `tools/el2/qebspilaa64.efi`：取自 [stephan-gh/qebspil](https://github.com/stephan-gh/qebspil)
- `tools/el2/slbounceaa64.efi`：取自 [TravMurav/slbounce](https://github.com/TravMurav/slbounce)
- `tools/touchscreen-tuner`：改编自 [chiyuki0325/EGoTouchRev-Linux](https://github.com/chiyuki0325/EGoTouchRev-Linux)，并在本仓库中做了 GTK4 GUI 改进

## 相关入口

- Releases：<https://github.com/bryarrow/linux-gaokun-buildbot/releases>
- [在 MateBook E Go 上安装 NixOS](nixos_install_guide_zh.md)（[English](nixos_install_guide_en.md)）
- [EL2 实现说明](el2_kvm_guide_en.md)
- [Awesome Gaokun3](awesome_gaokun3_en.md)
- [README（English）](../README.md)

## 参考资料

- [right-0903/linux-gaokun](https://github.com/right-0903/linux-gaokun)：内核补丁与设备支持工作的主要来源，带有详细的提交说明与解释。
- [TheUnknownThing/linux-gaokun](https://github.com/TheUnknownThing/linux-gaokun)：内核补丁与设备支持工作的另一个 fork，包含一些独有的提交，以及对触屏和 EC 的说明。
- [whitelewi1-ctrl/matebook-e-go-linux](https://github.com/whitelewi1-ctrl/matebook-e-go-linux)：最早修复面板背光问题的仓库，还包含一些额外的资源与针对 Gaokun3 Linux 支持的修改。
- [gaokun on AUR](https://aur.archlinux.org/packages?O=0&K=gaokun)：为 Gaokun3 构建的几个 AUR 包，包括内核与固件包。
- [chenxuecong2/firmware-huawei-gaokun3](https://github.com/chenxuecong2/firmware-huawei-gaokun3)：Gaokun3 的固件包仓库。
- [chiyuki0325/EGoTouchRev-Linux](https://github.com/chiyuki0325/EGoTouchRev-Linux)：本仓库直接集成的 Himax HX83121A Linux 触屏驱动与调参算法的上游来源。
- [awarson2233/EGoTouchRev](https://github.com/awarson2233/EGoTouchRev)：EGoTouchRev-Linux 引用的原始 Windows 侧触屏算法项目，也是 Gaokun3 触屏调参流程的重要上游参考。
- [TravMurav/slbounce](https://github.com/TravMurav/slbounce)：一个 UEFI 应用，用于在 Gaokun3 上启用 EL2 支持与 Secure Launch。
- [TravMurav/linux](https://github.com/TravMurav/linux/tree/x13s-6.18-v1.1-cxsd)：一个 Linux 内核树，包含一些对 sc8280xp 平台 EL2 支持有用的补丁。
- [stephan-gh/qebspil](https://github.com/stephan-gh/qebspil)：一个在 Qualcomm 平台上预启动 DSP 固件的 UEFI 应用，可用于启动 Linux 之前的启动链中。

