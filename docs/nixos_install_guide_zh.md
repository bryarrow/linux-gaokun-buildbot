[English](nixos_install_guide_en.md) | 中文

# 在 MateBook E Go 上安装 NixOS

本文用本仓库的安装镜像把 NixOS 装到内置硬盘。该镜像就是原版的 NixOS 最小安装器，
只是内核、设备树和内核命令行已经换成这台机器需要的，因此它可以直接启动 MateBook E
Go，不需要另外发行版的镜像。

NixOS 没有图形安装器：你需要自己分区、写配置，然后在 root shell 里跑
`nixos-install`。装过 NixOS 的话，这就是[标准手动安装流程](https://nixos.org/manual/nixos/stable/#sec-installation-manual)，
只多了一行配置。

## 需要准备

- 至少 4 GB 的 U 盘；8 GB 以上才有空间放 nix store。
- 安装镜像（见下）。
- **关闭 Secure Boot**。镜像没有签名，而且 EL2 变体本来也要求关闭。
- 网络。Wi-Fi 可用；这台机器没有有线网口。

## 一、取得安装镜像

在任何装了 Nix 的 aarch64 机器上（如果这台设备已经跑着 NixOS 或 Fedora，也可以就在
它上面）：

```bash
nix build github:bryarrow/linux-gaokun-buildbot#installer-iso
ls result/iso/nixos-gaokun3-*.iso
```

在 x86_64 机器上，先在 `configuration.nix` 里加上 aarch64 模拟
（`boot.binfmt.emulatedSystems = [ "aarch64-linux" ];`）或在 `/etc/nix/nix.conf` 里加
`extra-platforms = aarch64-linux`，然后显式指定 aarch64 的产物：

```bash
nix build github:bryarrow/linux-gaokun-buildbot#packages.aarch64-linux.installer-iso
```

没有模拟的话，同样的命令会从源码交叉编译整个 live 系统，不值得开始。构建本身要花些
时间：镜像约 1.7 GiB，带的是完整的安装器闭包。

## 二、写入 U 盘

```bash
sudo dd if=result/iso/nixos-gaokun3-*.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

`of=` 一定要确认：它会直接覆写整个设备，不问任何问题。镜像是 hybrid 镜像，这样写完
即可，不要先自己建分区表。

## 三、启动

1. 开机按 F2，把 Secure Boot 设为 **Disable**，保存并重启。
2. 按 F12，选择 U 盘启动。它走的是 U 盘上的 `\EFI\BOOT\BOOTAA64.EFI`，此时不会改动
   内置硬盘上的任何东西。
3. live 系统会自动以 `nixos` 登录（无密码），`sudo` 不需要密码。

控制台已经旋转为正向，且 Plymouth 关闭，所以内核日志可以直接看。确认跑的是 gaokun3
内核：

```bash
uname -r          # 7.2.0-gaokun3
```

继续之前先联网：

```bash
nmtui                              # 或：nmcli device wifi list
ip -4 addr show
```

想用 SSH 操作的话，先 `passwd` 设个密码（或把公钥加到 `~/.ssh/authorized_keys`），再
连 `ip` 打印出的地址。耗时较长的操作建议放在 `tmux` 里。

## 四、安装

以下命令都在 live 系统里以 root 执行：

```bash
sudo -i
```

### 4.1 分区

用 `lsblk` 确认内置硬盘的名字，通常是 `/dev/nvme0n1`。**下面的命令会清空它。** 这是
整盘安装的做法；要保留 Windows 或 Fedora，见[第七节](#七与-windows-或-fedora-共存)。

```bash
sgdisk --zap-all /dev/nvme0n1
sgdisk -n 1:0:+1GiB -t 1:ef00 -c 1:ESP   /dev/nvme0n1
sgdisk -n 2:0:0     -t 2:8300 -c 2:nixos /dev/nvme0n1
partprobe /dev/nvme0n1
```

格式化 ESP 和根文件系统：

```bash
mkfs.fat -F 32 -n ESP /dev/nvme0n1p1
mkfs.btrfs -L nixos /dev/nvme0n1p2
```

### 4.2 挂载

下面的布局与这台机器上现有的 NixOS 一致：`/`、`/home`、`/nix` 用 Btrfs 子卷，ESP 挂
在 `/boot`。不想要快照的话，`mkfs.ext4 /dev/nvme0n1p2` 加
`mount /dev/nvme0n1p2 /mnt` 同样可以。

```bash
mount /dev/nvme0n1p2 /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@nix
umount /mnt

mount -o subvol=@,compress=zstd,noatime       /dev/nvme0n1p2 /mnt
mkdir -p /mnt/{home,nix,boot}
mount -o subvol=@home,compress=zstd,noatime   /dev/nvme0n1p2 /mnt/home
mount -o subvol=@nix,compress=zstd,noatime    /dev/nvme0n1p2 /mnt/nix
mount /dev/nvme0n1p1 /mnt/boot
```

NixOS 默认把 ESP 挂在 `/boot`——不是 `/boot/efi`——安装器也会把 systemd-boot 写到那里。

### 4.3 生成硬件配置

```bash
nixos-generate-config --root /mnt
```

它按硬盘上的实际情况写出 `/mnt/etc/nixos/hardware-configuration.nix`，不要改它。

### 4.4 写配置

新建 `/mnt/etc/nixos/flake.nix`：

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
        ./hardware-configuration.nix
        gaokun3.nixosModules.gaokun3
        ({ lib, ... }: {
          # 硬件只需要这一行。
          hardware.gaokun3.enable = true;

          # 机型固件可以再分发但不可修改，原版 nixpkgs 会拒绝求值。
          nixpkgs.config.allowUnfreePredicate = pkg:
            builtins.elem (lib.getName pkg) [ "linux-firmware-gaokun3" ];

          # 这台机器通过 ESP 上的 systemd-boot 启动。固件不能写 EFI 变量
          # （命令行里有 `efi=noruntime`），所以安装器走可移动路径，这也是默认值。
          boot.loader.systemd-boot.enable = true;

          networking.hostName = "ego";
          system.stateVersion = "26.11";

          users.users.you = {
            isNormalUser = true;
            extraGroups = [ "wheel" "networkmanager" ];
            initialPassword = "change-me";
          };
        })
      ];
    };
  };
}
```

`hardware.gaokun3.enable` 特意是唯一一行硬件配置：它同时选定 gaokun3 内核及其二进制
缓存、板级设备树、内核命令行（屏幕旋转、键盘 quirk、8cx Gen 3 固件规避）、initrd 与
启动模块、蓝牙 NVM 补丁、音频 UCM 配置，以及定期的温度/电源日志。各部分的说明见
[README](../README.md#quickstart)。

**不要**加 `gaokun3.inputs.nixpkgs.follows = "nixpkgs"`；原因见
[README](../README.md#quickstart)：内核必须保留本仓库 pin 的 nixpkgs。

### 4.5 安装

```bash
nixos-install --flake /mnt/etc/nixos#ego
```

live 系统里已经带着构建这张镜像时用的内核。如果你把 flake 指到了别的 revision，或者
想让项目的公共缓存提供闭包而不是在这里构建，加上：

```bash
nixos-install --flake /mnt/etc/nixos#ego \
  --option extra-substituters https://gaokun3.cachix.org \
  --option extra-trusted-public-keys gaokun3.cachix.org-1:ikL6EofK55QEwKucrUo44SPKewscvAMJr7ibBxJtIsI=
```

完成后卸载并重启：

```bash
umount -R /mnt
reboot
```

## 五、首次启动

关机、拔掉 U 盘、再开机。systemd-boot 会给出 **NixOS** 条目，它加载 `linux-gaokun3`、
gaokun3 设备树和硬件命令行。条目编辑器是开着的，所以可以在启动菜单里改内核命令行。

进系统后确认一切正常：

```bash
uname -r                          # 7.2.0-gaokun3
cat /proc/device-tree/model       # Huawei MateBook E Go ...
nmcli device status               # wlP6p1s0 应该起来
bluetoothctl show                 # 每机地址，不是 00:00:00:00:5A:AD
getenforce 2>/dev/null || true
```

屏幕一开始就是正向的（`fbcon=rotate:1`），触屏、键盘、Wi-Fi、音频、GPU 都应可用。
`gaokun3-monitor` 定时服务每五分钟把温度和电源状态写进 journal，它的存在是为了在突然
断电之后能对照温度和充电状态排查。

把 `initialPassword` 设的密码改掉；`system.stateVersion` 除非你知道原因，否则别动。

以后的更新就是普通的 NixOS 操作：

```bash
sudo nixos-rebuild switch --flake /path/to/your#ego
```

### 固件报 `-ENOENT`

如果 Wi-Fi、音频和 GPU 同时失效，日志里都是 `Direct firmware load ... failed with
error -2`，说明内核的固件搜索路径被改坏了。`/lib/firmware` 必须指向
`/run/current-system/firmware`；模块用 `tmpfiles` 规则恢复它，而 `patch-nvm-bdaddr`
在没有它时会拒绝改写搜索参数。要抢救正在运行的系统：

```bash
echo -n "$(readlink -f /run/current-system/firmware)" \
  > /sys/module/firmware_class/parameters/path
```

Wi-Fi 和音频会立刻恢复，代价是蓝牙地址退回占位值。

## 六、EL2 变体（可选）

实验性的 EL2 内核只多一个选项。它是新增一个启动条目 **NixOS (el2)**，而不是换掉整个
系统：

```nix
{ hardware.gaokun3.el2.enable = true; }
```

两个条目都留在菜单里，EL1/EL2 在启动时选；把选项关回去会删掉该条目以及它为 ESP 装的
载荷。Secure Boot 必须保持关闭，并且 EL2 下视频编解码起不来。哪些能用、哪些不能用见
[el2_kvm_guide_en.md](el2_kvm_guide_en.md) 与
[README](../README.md#el2-variant-experimental)。

## 七、与 Windows 或 Fedora 共存

这台机器只有一个 ESP，由盘上所有系统共用；本仓库一直是往这个 ESP 里装，而不是重新给
它分区。这里用过的做法是：

1. 从 Windows 的磁盘管理里缩小 Windows 分区，或在 Fedora 里缩小 Fedora 分区。不要在
   NixOS 安装器里移动分区。
2. 只在空出来的空间里新建一个根分区；不要再建一个 ESP。
3. 把**已有的** ESP 挂到 `/mnt/boot`——不要格式化它——然后从
   [4.3](#43-生成硬件配置)继续。
4. `nixos-install` 会把 `EFI/nixos/`、`loader/entries/` 和它的 systemd-boot 写在已有的
   `EFI/Microsoft`、`EFI/fedora` 旁边，后者原样保留。

动手前要知道两件事：

- 固件不能写 EFI 变量，所以启动顺序来自可移动路径 `\EFI\BOOT\BOOTAA64.EFI`。安装
  NixOS 会用它的 systemd-boot 覆写这个文件。systemd-boot 仍会读取其它系统的条目，
  但如果在意旧的那份，先备份。
- EL2 载荷放在 ESP 上、是共享的：把 `hardware.gaokun3.el2.enable` 关掉会把它们删掉，
  包括别的安装可能正在用的副本。详见
  [README](../README.md#el2-variant-experimental)。

## 排错

- **启动菜单里看不到 U 盘。** Secure Boot 必须关闭；镜像必须写到整个设备
  （`of=/dev/sdX`，不是 `of=/dev/sdX1`）。F12 打开启动菜单，条目名可能显示为 U 盘本身
  而不是 "NixOS"。
- **内核起不来，或者机器立刻重启。** 安装器的启动条目里带 `devicetree` 行；少了它内核
  拿不到板级设备树，会直接 panic。构建镜像时这条路径是验证过的，所以这里失败意味着
  U 盘或写入有问题。
- **屏幕是横的。** 不应该：`fbcon=rotate:1` 是模块命令行的一部分，live 系统也在用。
  控制台横着，说明启动用的不是本仓库的条目。
- **`nixos-install` 拉不到 flake。** live 系统用的是 NetworkManager：
  用 `nmtui` 或 `nmcli`。
