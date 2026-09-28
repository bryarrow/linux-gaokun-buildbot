English | [中文](nixos_install_guide_zh.md)

# Installing NixOS on the MateBook E Go

This installs NixOS on the internal disk from this repository's installer image.
The image is the stock NixOS minimal installer with the gaokun3 kernel, device
tree and kernel command line already in place, so it boots this machine directly
and needs no Fedora step.

If you already run NixOS and only want a recovery environment, the older
[rescue USB guide](rescue_usb_guide_en.md) still works; this guide is what
replaces it.

NixOS has no graphical installer: you partition the disk, write a configuration
and run `nixos-install` from a root shell. If you have installed NixOS before,
this is the [standard manual
procedure](https://nixos.org/manual/nixos/stable/#sec-installation-manual) with
one line added.

## What you need

- A USB stick of at least 4 GB; 8 GB or more leaves room for the nix store.
- The installer ISO, built below or from a release asset.
- Secure Boot **off**. The image is unsigned, and the EL2 variant needs it off
  anyway.
- A network. Wi-Fi works; there is no wired port on this device.

## 1. Get the installer ISO

On any aarch64 machine with Nix, including this device if it already runs
NixOS or Fedora:

```bash
nix build github:bryarrow/linux-gaokun-buildbot#installer-iso
ls result/iso/nixos-gaokun3-*.iso
```

On an x86_64 machine, add aarch64 emulation to `configuration.nix`
(`boot.binfmt.emulatedSystems = [ "aarch64-linux" ];`) or `/etc/nix/nix.conf`
(`extra-platforms = aarch64-linux`) first, then ask for the aarch64 output
explicitly:

```bash
nix build github:bryarrow/linux-gaokun-buildbot#packages.aarch64-linux.installer-iso
```

Without emulation, the same command cross-compiles the whole live system from
source, which is not worth starting. A build takes a while: the ISO is about
1.7 GiB and carries the full installer closure.

## 2. Write the stick

```bash
sudo dd if=result/iso/nixos-gaokun3-*.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

Double-check `of=`: it overwrites the whole device without asking. The ISO is a
hybrid image, so this is all that is needed; do not create a partition table
first.

## 3. Boot it

1. Press F2 at startup, set Secure Boot to **Disable**, save and reboot.
2. Press F12 and pick the USB stick. It boots through
   `\EFI\BOOT\BOOTAA64.EFI` on the stick, so nothing on the internal disk is
   touched yet.
3. The live system logs in as `nixos` with no password; `sudo` asks for nothing.

The console is rotated upright and Plymouth is off, so the kernel log is
readable. You should see the gaokun3 kernel in it:

```bash
uname -r          # 7.2.0-gaokun3
```

Connect to the network before continuing:

```bash
nmtui                              # or: nmcli device wifi list
ip -4 addr show
```

If you would rather work over SSH, set a password with `passwd` (or add a key to
`~/.ssh/authorized_keys`) and use the address `ip` prints. Long operations are
worth running under `tmux`.

## 4. Install

Everything below runs from the live system as root:

```bash
sudo -i
```

### 4.1 Partition

`lsblk` names the internal disk, usually `/dev/nvme0n1`. **The next commands
destroy whatever is on it.** This is the whole-disk recipe; to keep Windows or
Fedora, see [Alongside another system](#7-alongside-windows-or-fedora).

```bash
sgdisk --zap-all /dev/nvme0n1
sgdisk -n 1:0:+1GiB -t 1:ef00 -c 1:ESP   /dev/nvme0n1
sgdisk -n 2:0:0     -t 2:8300 -c 2:nixos /dev/nvme0n1
partprobe /dev/nvme0n1
```

Format the ESP and the root filesystem:

```bash
mkfs.fat -F 32 -n ESP /dev/nvme0n1p1
mkfs.btrfs -L nixos /dev/nvme0n1p2
```

### 4.2 Mount

The layout below is what the existing NixOS install on this machine uses:
Btrfs subvolumes for `/`, `/home` and `/nix`, with the ESP at `/boot`. A single
`mkfs.ext4 /dev/nvme0n1p2` plus `mount /dev/nvme0n1p2 /mnt` works just as well
if you do not want snapshots.

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

`/boot` — not `/boot/efi` — is where NixOS mounts the ESP by default, and it is
where the installer will write systemd-boot.

### 4.3 Generate the hardware configuration

```bash
nixos-generate-config --root /mnt
```

That writes `/mnt/etc/nixos/hardware-configuration.nix` from what is actually on
the disk. Leave it alone.

### 4.4 Write the configuration

Create `/mnt/etc/nixos/flake.nix`:

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
          # The one line the hardware needs.
          hardware.gaokun3.enable = true;

          # The model firmware is redistributable but not modifiable, so a
          # stock nixpkgs refuses to evaluate it.
          nixpkgs.config.allowUnfreePredicate = pkg:
            builtins.elem (lib.getName pkg) [ "linux-firmware-gaokun3" ];

          # This machine boots through systemd-boot on the ESP. The firmware
          # cannot write EFI variables (`efi=noruntime`), so the installer
          # uses the removable path, which is the default.
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

`hardware.gaokun3.enable` is deliberately the only hardware line: it selects the
gaokun3 kernel and its binary cache, the board device tree, the kernel command
line (panel rotation, keyboard quirk, 8cx Gen 3 firmware workarounds), the
initrd and boot modules, Bluetooth NVM patching, the audio UCM profile and the
periodic thermal/power log. [README](../README.md#quickstart) describes the
individual pieces.

Do **not** add `gaokun3.inputs.nixpkgs.follows = "nixpkgs"`; see
[README](../README.md#quickstart) for why the kernel has to keep this repository's
nixpkgs pin.

### 4.5 Install

```bash
nixos-install --flake /mnt/etc/nixos#ego
```

The live system already carries the kernel this ISO was built with. If you point
the flake at a different revision, or want the project's public cache to supply
the closure instead of building it here, add:

```bash
nixos-install --flake /mnt/etc/nixos#ego \
  --option extra-substituters https://gaokun3.cachix.org \
  --option extra-trusted-public-keys gaokun3.cachix.org-1:ikL6EofK55QEwKucrUo44SPKewscvAMJr7ibBxJtIsI=
```

When it finishes, unmount and reboot:

```bash
umount -R /mnt
reboot
```

## 5. First boot

Turn the machine off, remove the stick, and boot. systemd-boot offers **NixOS**;
it loads `linux-gaokun3`, the gaokun3 device tree and the hardware command line.
The entry editor is on, so a kernel command line can be edited at the menu.

Then check the machine came up the way it should:

```bash
uname -r                          # 7.2.0-gaokun3
cat /proc/device-tree/model       # Huawei MateBook E Go ...
nmcli device status               # wlP6p1s0 should come up
bluetoothctl show                 # a per-device address, not 00:00:00:00:5A:AD
getenforce 2>/dev/null || true
```

The display is upright from the start (`fbcon=rotate:1`), and the touchscreen,
keyboard, Wi-Fi, audio and GPU should all work. The periodic
`gaokun3-monitor` service writes thermal and power-supply state to the journal
every five minutes; it exists so that a sudden power-off can be checked against
temperature and charger state afterwards.

Change the password you set in `initialPassword`, and adjust
`system.stateVersion` only if you know why.

Later rebuilds are ordinary NixOS ones:

```bash
sudo nixos-rebuild switch --flake /path/to/your#ego
```

### Error `-ENOENT` for firmware

If Wi-Fi, audio and the GPU all stop working with `Direct firmware load ...
failed with error -2`, the kernel's firmware search path has been broken.
`/lib/firmware` must point at `/run/current-system/firmware`; the module restores
it with a `tmpfiles` rule, and `patch-nvm-bdaddr` refuses to touch the search
parameter without it. To recover a running system:

```bash
echo -n "$(readlink -f /run/current-system/firmware)" \
  > /sys/module/firmware_class/parameters/path
```

That brings Wi-Fi and audio back immediately, at the cost of the Bluetooth
address falling back to the placeholder.

## 6. EL2 variant (optional)

The experimental EL2 kernel is one option more. It adds a second boot entry,
**NixOS (el2)**, rather than changing the system:

```nix
{ hardware.gaokun3.el2.enable = true; }
```

Both entries stay in the menu, so EL1 and EL2 are chosen at boot, and turning the
option off again removes the entry and the ESP payloads it installed. Secure Boot
has to stay off, and the video codec does not come up under EL2. See
[el2_kvm_guide_en.md](el2_kvm_guide_en.md) and the
[README](../README.md#el2-variant-experimental) for what works and what does
not.

## 7. Alongside Windows or Fedora

This machine has one ESP shared by every system on the disk, and this repository
has always installed into that ESP rather than repartitioning it. The route that
has been used here is:

1. Shrink the Windows partition from Windows' own Disk Management, or Fedora's
   partition from Fedora. Do not move a partition from the NixOS installer.
2. Create one root partition in the free space; do not create a second ESP.
3. Mount the **existing** ESP at `/mnt/boot` — do not format it — and continue
   from [4.3](#43-generate-the-hardware-configuration).
4. `nixos-install` writes `EFI/nixos/`, `loader/entries/` and its systemd-boot
   next to the existing `EFI/Microsoft` and `EFI/fedora`, which stay in place.

Two things to know before you do this:

- Because the firmware cannot write EFI variables, the boot order comes from the
  removable path `\EFI\BOOT\BOOTAA64.EFI`. Installing NixOS overwrites that file
  with its own systemd-boot. systemd-boot still reads the other systems'
  entries, but back the file up first if you care about the old one.
- The EL2 payloads live on the ESP and are shared: turning
  `hardware.gaokun3.el2.enable` off deletes them, including a copy a Fedora
  install may rely on. See the [dual-boot guide](dual_boot_guide_en.md) and the
  [README](../README.md#el2-variant-experimental).

## Troubleshooting

- **The stick does not appear in the boot menu.** Secure Boot must be off, and
  the ISO must have been written to the whole device (`of=/dev/sdX`, not
  `of=/dev/sdX1`). F12 opens the boot menu; the entry may be named after the
  stick rather than "NixOS".
- **The kernel does not start, or the machine resets immediately.** The
  installer adds a `devicetree` line to its boot entry; if it were missing the
  kernel would have no board tree and panic. This is the path that was verified
  when the ISO was built, so a failure here means the stick or the write is
  wrong.
- **The screen is sideways.** It should not be: `fbcon=rotate:1` is part of the
  module's command line, and the live system uses it too. A sideways console
  means the entry in use is not this repository's.
- **`nixos-install` cannot fetch the flake.** The live system has NetworkManager,
  not the Fedora tools: use `nmtui` or `nmcli`.
- **You want the Fedora rescue environment instead.** It is still documented in
  [rescue_usb_guide_en.md](rescue_usb_guide_en.md) and still built by CI.
