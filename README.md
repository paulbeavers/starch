# Building an ISO

Bootable live/install media carrying this desktop. Boots straight into
Hyprland as a passwordless `live` user, with `install-hyprarch` on `$PATH`
to put it on a disk.

## Build

```bash
sudo pacman -S archiso            # once
./build.sh --check                # verify prerequisites, build nothing
sudo ./build.sh                   # ~2GB download, 10-30 minutes
```

The ISO lands in `out/`. Test it without burning anything:

```bash
sudo pacman -S qemu-desktop edk2-ovmf
./test-boot.sh                    # UEFI, graphical
./test-boot.sh --bios             # legacy boot path
```

## How the profile is put together

`build.sh` copies archiso's stock `releng` profile and layers on top of it,
rather than this repo carrying its own copy.

That is deliberate. `releng` holds the bootloader configuration for syslinux,
GRUB and systemd-boot, and those change between archiso releases. A vendored
copy drifts silently and the failure shows up at boot, which is the worst
possible place to discover it. Copying at build time means the bootloader is
always the one that matches the installed archiso.

What gets layered on:

| Layer | Source |
|---|---|
| Package list | `extract-packages.sh`, read out of `install.sh` |
| Desktop config | `../config/` into the live home and `/etc/skel` |
| The repo itself | `/usr/local/share/hyprland-setup` |
| Live user | `live`, no password, passwordless sudo |
| Autologin | `getty@tty1` override, `.bash_profile` starts uwsm |
| Branding | `iso_name`, `iso_label`, publisher in `profiledef.sh` |

## Packages

`extract-packages.sh` parses the `PKGS_*` arrays out of `install.sh` so the
ISO and the installer can never disagree about what a working desktop needs.
It reads the declarations rather than sourcing the script — running the
installer as a side effect of listing packages would be a bad day.

Two deliberate differences from an installed system:

- **Every GPU vendor's driver ships**, not just this machine's. Live media
  cannot know what it will boot on. `install.sh` still picks per-host at
  install time.
- **Installer tooling is added** (`archinstall`, `gparted`, filesystem tools),
  which an installed system has no use for.

## Caveats

- `archinstall.json` is a starting point. archinstall's schema moves between
  releases; validate with `archinstall --config archinstall.json --dry-run`
  on the ISO before trusting it.
- The build needs root, roughly 20GB of scratch space, and network.
