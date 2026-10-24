# starch

**St**art **Arch**. Install media that gets you to a working Arch + Hyprland
desktop, and then stops existing.

## The idea

Arch is worth running and painful to start. Hyprland is worth running and
fiddly to configure. starch does that first hour for you.

What it deliberately does *not* do is stay. Once the install finishes there is
no starch on the machine:

- **No custom repository.** Every package comes from the official Arch repos,
  with one exception: on an Intel MacBook, the Broadcom bluetooth firmware,
  which only the AUR has. It is installed as an ordinary foreign package.
- **No branding.** `/etc/os-release` says Arch, because it is Arch.
- **No hooks, agents or self-updates.** Nothing runs that you did not put there.
- **No framework to learn.** Updates are `pacman -Syu`, the same as any Arch
  install, and the Arch wiki is the documentation.

The distinction that matters: an opinionated setup that keeps being opinionated
owns your system. starch hands it over. Everything it configured is a plain
file you can read, edit or delete, and the comments in those files explain what
each choice does and why — so the setup is a starting point you can learn from
rather than a black box you maintain around.

**The installed system is the one you would get by hand.** That is the design
principle, and it is not negotiable: the result must be the same as installing
Arch from the install guide and then running lucent's `install.sh`. The only
deliberate differences are the boot splash, a rescue shell that works with root
locked, a readable console font on high-density panels, and the Broadcom
bluetooth firmware on Intel MacBooks. The installer runs
pacstrap, then lucent's `install.sh` in a chroot — what someone following the
Arch install guide does before cloning the desktop and running its script. It
does not copy the medium onto the disk, so there is nothing of the medium to
remove afterwards.

The configuration lands in `~/.config`, where Hyprland and everything else
look for it. The repository it came from is left at `~/lucent`, owned by you,
so the source of every choice is readable on the installed machine and
`install.sh` can be re-run. Delete that directory and nothing stops working.

## Layout

The desktop half — `install.sh` and the Hyprland configuration — lives in its
own repository and is pinned here as a submodule:

```
build.sh              assembles the archiso profile and runs mkarchiso
extract-packages.sh   derives the package list from the submodule's install.sh
installer/            the installer: starch_installer (the Textual front end),
                      starch-backend (the install), starch-install and
                      starch-session (launchers); broadcom-live, for the
                      medium's own wireless
splash/               the Plymouth theme both boots wear
tools/build-aur.sh    builds what the official repos do not carry
test-boot.sh          boots the result in QEMU
lucent/               submodule: the desktop install and config
localrepo/            built packages (gitignored; make it with build-aur.sh)
```

Splitting them keeps the desktop usable on its own — clone that repo and run
`install.sh` on an existing system, no ISO involved — and pins exactly which
version of the config an ISO carries, since the submodule records a commit
rather than tracking a branch.

Used that way it is not Arch-only. `install.sh` also installs onto Fedora 41
or newer, including aarch64 and Fedora Asahi Remix on Apple silicon, and onto
Ubuntu 26.04 LTS or newer and the distributions built on it (Mint, Pop!_OS,
Zorin, elementary). It works out which of the three it is from
`/etc/os-release` and swaps the package names, the package manager and where
Hyprland comes from; everything it deploys is the same on all of them.

**This ISO is still Arch**, and that is the only thing it will ever install:
the package list `extract-packages.sh` derives from `install.sh` is the Arch
one, by column — the Fedora and Ubuntu lists are deliberately indented out of
its reach. The other two distributions matter only when the desktop repo is
used directly. Its README covers what differs on each.

Clone with the submodule:

```bash
git clone --recurse-submodules git@github.com:paulbeavers/starch.git
# or, in an existing clone:
git submodule update --init
```

Update the desktop config an ISO will ship:

```bash
git -C lucent pull
git add lucent && git commit -m "Bump lucent"
```

## Build

```bash
sudo pacman -S archiso base-devel   # once
./build-all.sh                      # everything, in the right order
```

`build-all.sh` takes no options — it runs the two builds in order and stops at
the first failure. It also checks out the `lucent` submodule if you
cloned without `--recurse-submodules`. Run it as yourself: `makepkg` refuses to
run as root, so the script calls `sudo` for the ISO step alone and asks then.
The scripts underneath keep their own options for when you need them, listed
below.

The order matters more than it looks. One package is not in the official
repositories — the Broadcom bluetooth firmware for Intel MacBooks — so it is
built first into `localrepo/`, and `build.sh` refuses to start without it.
`localrepo/` is gitignored because it holds built packages rather than source,
so a fresh clone has to build it before its first ISO. Both scripts skip it
when it is already built; `./tools/build-aur.sh --force` rebuilds anyway.

Everything else — including, perhaps surprisingly, `broadcom-wl-dkms` — comes
from the official repositories.

The real build needs root and a network: besides running `mkarchiso`, it
downloads every package the installer can ask for into the medium's offline
repository, about 2GB.

Other useful modes:

```bash
./build.sh --check                # verify prerequisites, build nothing
./build.sh --assemble             # lay out the profile, no root, no build
```

Test it without burning anything:

```bash
sudo pacman -S qemu-desktop edk2-ovmf
./test-boot.sh                    # UEFI, graphical
./test-boot.sh --bios             # legacy boot path
./test-boot.sh --monitor          # expose QEMU's monitor on a socket, for
                                  # driving it and taking screenshots
```

## What the ISO is

A full-screen text installer that needs no network. The medium boots straight
into it on tty1: a [Textual](https://textual.textualize.io) app drawn on
[kmscon](https://github.com/kmscon/kmscon), so it has real fonts sized to the
panel, full colour and the mouse rather than the Linux console's bitmap font.
It walks through four steps with a sidebar, shows every answer back on a review
page, and writes nothing to any disk until you confirm. The install then runs
with a step list, a progress bar and its log streaming beside them. Quitting
leaves a root shell, as on any Arch medium; `starch-install` starts it again.

It asks for the keyboard layout, the disk, and how to use it — the whole disk,
or the largest block of free space with every existing partition left alone —
then the filesystem (ext4, or btrfs with `@` and `@home`), whether to encrypt
it with LUKS, a hostname, a user and password, and the timezone.

Installing alongside another system never shrinks or moves anything: the free
space has to exist already, made with that system's own tools. The existing
EFI system partition is shared. Windows makes its ESP 100MB, which a kernel and
its initramfs do not fit beside, so when it is short of room `/boot` goes on a
1GB XBOOTLDR partition of its own, which systemd-boot reads natively.

## How the install works

The installer does what the Arch install guide does, in its order: partition,
`pacstrap` the base system (`base linux linux-firmware`, the CPU's microcode,
`sudo`, NetworkManager), `genfstab`, timezone, locale, hostname, a user in
`wheel`, systemd-boot, and then lucent's `install.sh --for-user` in a chroot for
the desktop.

The packages come from the medium. `build.sh` downloads every package the
installer or `install.sh` could ask for, with their dependencies, into
`/usr/share/starch/repo`, beside copies of the official `core` and `extra`
databases they were resolved against. pacstrap and `install.sh` read them
through `file://` servers and check signatures exactly as they would from a
mirror: they are the same files, frozen at build time. While `install.sh` runs,
only the target's mirrorlist points at the medium; pacman.conf is the stock one,
so whatever `install.sh` tunes in it is what the installed system keeps. The
real mirrorlist is written last.

That is why the ISO is ~3GB. The repository carries every graphics vendor's
driver and the Broadcom wireless one, because it cannot know what it will be
installed onto — and `install.sh` installs only what the hardware in front of
it needs.

The boot entries name `/vmlinuz-linux` and `/initramfs-linux.img`, the files
mkinitcpio's pacman hooks rewrite on every kernel upgrade, so `pacman -Syu`
never leaves the machine booting a kernel it has deleted the modules of.
Emergency mode opens a shell even though root has no password.

## How the profile is put together

`build.sh` copies archiso's stock `releng` profile and layers on top, rather
than this repo carrying its own copy. `releng` holds the bootloader
configuration for syslinux, GRUB and systemd-boot, and those change between
archiso releases. A vendored copy drifts silently and fails at boot, which is
the worst possible place to find out.

| Layer | Source |
|---|---|
| Live system | releng, plus Textual, kmscon, the disk tools and the splash |
| Offline repository | `extract-packages.sh` (from `install.sh`) and the installer's own list, resolved by pacman at build time |
| AUR packages | `localrepo/`, built by `tools/build-aur.sh` |
| The installer | `installer/` — Textual front end, bash back end |
| The desktop repo | the `lucent` submodule, by allowlist |
| Boot behaviour | tty1 runs the installer; other VTs are root shells |

## Rebuilding later

```bash
./build.sh --clean && sudo ./build.sh
```

Cleaning matters. `mkarchiso` records finished steps in the work directory and
skips them on a rerun, so reusing one silently repackages the previous
download. `build.sh` clears it by default; `--reuse` opts back in when you are
iterating on something other than the package set.

A clean rebuild picks up current Arch packages automatically, and picks up new
bootloader configs whenever `archiso` itself is updated.

## Caveats

- Requires **UEFI**. The installer writes GPT and installs systemd-boot; there
  is no BIOS path, and it says so before touching a disk.
- Installing alongside another system needs at least 20GB of unallocated space
  on a GPT disk. Nothing is ever resized.
- `test-boot.sh` needs a display for the graphical mode. `--monitor` drops back
  to a plain framebuffer, because QEMU cannot screenshot a GL surface.
- The Broadcom driver is chosen from a list of eight PCI IDs. Anything else is
  left to the in-kernel drivers, which handle most modern Broadcom parts.
