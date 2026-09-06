# starch

**St**art **Arch**. Install media that gets you to a working Arch + Hyprland
desktop, and then stops existing.

## The idea

Arch is worth running and painful to start. Hyprland is worth running and
fiddly to configure. starch does that first hour for you.

What it deliberately does *not* do is stay. Once the install finishes there is
no starch on the machine:

- **No custom repository.** Every package comes from the official Arch repos.
- **No branding.** `/etc/os-release` says Arch, because it is Arch.
- **No hooks, agents or self-updates.** Nothing runs that you did not put there.
- **No framework to learn.** Updates are `pacman -Syu`, the same as any Arch
  install, and the Arch wiki is the documentation.

The distinction that matters: an opinionated setup that keeps being opinionated
owns your system. starch hands it over. Everything it configured is a plain
file you can read, edit or delete, and the comments in those files explain what
each choice does and why — so the setup is a starting point you can learn from
rather than a black box you maintain around.

The repo lands in `~/hyprland-setup`, exactly where it would be if you had
cloned it yourself. Keep it to re-run pieces later, or delete it; nothing
depends on it being there.

## Build

```bash
sudo pacman -S archiso            # once
./build.sh --check                # verify prerequisites, build nothing
./build.sh --assemble             # assemble the profile, no root, no build
sudo ./build.sh                   # ~1GB download, 10-30 minutes
```

Test it without burning anything:

```bash
sudo pacman -S qemu-desktop edk2-ovmf
./test-boot.sh                    # UEFI, graphical
./test-boot.sh --bios             # legacy boot path
```

## What the ISO is

Install media, not a live desktop. It boots to a text menu on tty1 and carries
installer tooling only — `archinstall`, partitioning and filesystem tools, git.
The 118 desktop packages are installed onto the *target* during stage 2, not
shipped in the live image.

An earlier version booted into a live Hyprland session. That made the ISO 2.5GB
of packages that nothing on the ISO ever ran.

## The install, in two stages

1. **archinstall** does the base: partitioning, filesystems, LUKS, bootloader,
   user accounts. That is the part where a bug destroys data, so it stays with
   the upstream tool that is maintained and tested by people who do only that.
2. **`install.sh`** then runs inside the new system and applies the desktop.

They are not wired together through archinstall's JSON config. Its schema moves
between releases, and a silent mismatch would look like a working install right
up until first boot.

## How the profile is put together

`build.sh` copies archiso's stock `releng` profile and layers on top, rather
than this repo carrying its own copy. `releng` holds the bootloader
configuration for syslinux, GRUB and systemd-boot, and those change between
archiso releases. A vendored copy drifts silently and fails at boot, which is
the worst possible place to find out.

| Layer | Source |
|---|---|
| Installer packages | explicit list in `build.sh` |
| The repo | `/usr/local/share/hyprland-setup`, by allowlist |
| Installer | `installer/starch-install` |
| Live user | `live`, no password, passwordless sudo |
| Boot behaviour | tty1 runs the installer; other VTs are plain shells |

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

- The install path is **not yet tested end to end**. The ISO boots and the
  menu appears; a full disk install has not been exercised.
- `test-boot.sh` needs a display for the graphical mode.
