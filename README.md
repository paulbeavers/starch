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

## Layout

The desktop half — `install.sh` and the Hyprland configuration — lives in its
own repository and is pinned here as a submodule:

```
build.sh              assembles the archiso profile and runs mkarchiso
extract-packages.sh   derives the package list from the submodule's install.sh
calamares/            installer sequence, module config and branding
installer/            scripts the install runs, plus the text-menu fallback
tools/build-aur.sh    builds what the official repos do not carry
test-boot.sh          boots the result in QEMU
hyprland-setup/       submodule: the desktop install and config
localrepo/            built packages (gitignored; make it with build-aur.sh)
```

Splitting them keeps the desktop usable on its own — clone that repo and run
`install.sh` on an existing Arch system, no ISO involved — and pins exactly
which version of the config an ISO carries, since the submodule records a
commit rather than tracking a branch.

Clone with the submodule:

```bash
git clone --recurse-submodules git@github.com:paulbeavers/starch.git
# or, in an existing clone:
git submodule update --init
```

Update the desktop config an ISO will ship:

```bash
git -C hyprland-setup pull
git add hyprland-setup && git commit -m "Bump hyprland-setup"
```

## Build

```bash
sudo pacman -S archiso base-devel   # once
./tools/build-aur.sh                # once: builds Calamares, ~20 minutes
sudo ./build.sh                     # ~3GB, 20-40 minutes
```

`tools/build-aur.sh` is not optional and is easy to miss. Two packages are not
in the official repositories — Calamares itself, and the Broadcom bluetooth
firmware — and `mkarchiso` installs from repositories, not from files. So they
are built once into `localrepo/`, which `build.sh` adds to the profile's
pacman.conf. `localrepo/` is gitignored, because it holds built packages rather
than source: a fresh clone has to run this before the first build. `build.sh`
refuses to start without it and names what is missing.

It skips anything already built. Rebuilding Calamares takes twenty minutes and
nothing about it changes between ISOs; `--force` rebuilds anyway.

Everything else — including, perhaps surprisingly, `broadcom-wl-dkms` — comes
from the official repositories.

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

A live desktop that installs itself. tty1 starts Hyprland, and the session
starts Calamares. That is not decoration: it is what gives the medium a network
applet, a terminal and a file manager, so someone can join a wifi network and
check the machine works before committing a disk to it. An installer alone
cannot do any of that.

Quitting Calamares leaves the desktop running. Logging out, or a desktop that
will not start at all, falls through to a text menu with the older installer, a
shell and this boot's log.

## How the install works

Calamares copies the live filesystem onto the target — the same image you have
been using, so what gets installed is what you tested — and then turns that
copy into an ordinary system. The whole install is a file copy: it needs no
network, on any supported hardware.

That is why the ISO is ~3GB. It carries the finished desktop, every graphics
vendor's driver and the Broadcom wireless one, because it cannot know what it
will be installed onto. `install.sh` removes the drivers the hardware rules out
once it knows, so an AMD laptop does not keep 900MB of NVIDIA userspace.

Copying an image has one recurring hazard, which cost several rounds to learn:
**the live medium keeps things outside its own filesystem**, and each of them
has to be put back by hand.

| What | Where it really lives | Restored by |
|---|---|---|
| Kernel | deleted from `/boot`; a copy survives in `/usr/lib/modules` | `copy-kernel` |
| Microcode | deleted from `/boot`; raw files survive in `/usr/lib/firmware` | `add-microcode` |
| Pacman keyring | a tmpfs, filled at boot | `strip-live` |
| Live user, autologin, archiso hooks | present, and must not be | `strip-live` |

The first exec step checks a kernel can be found, before the partitioner runs.
An earlier version discovered that after repartitioning, which left a machine
with no OS and no way to finish.

## How the profile is put together

`build.sh` copies archiso's stock `releng` profile and layers on top, rather
than this repo carrying its own copy. `releng` holds the bootloader
configuration for syslinux, GRUB and systemd-boot, and those change between
archiso releases. A vendored copy drifts silently and fails at boot, which is
the worst possible place to find out.

| Layer | Source |
|---|---|
| Desktop packages | `extract-packages.sh`, derived from `install.sh` |
| Installer packages | explicit list in `build.sh` |
| Calamares | `localrepo/`, built by `tools/build-aur.sh` |
| Calamares config | `calamares/` — sequence, modules, branding |
| Post-install scripts | `installer/` — run in the target during the install |
| The desktop repo | the `hyprland-setup` submodule, by allowlist |
| Live user | `live`, uid 1500 so the installed user gets 1000 |
| Boot behaviour | tty1 starts the desktop; other VTs are plain shells |

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

- Requires **UEFI**. The partitioner writes GPT with an EFI system partition
  and installs systemd-boot; there is no BIOS path.
- `test-boot.sh` needs a display for the graphical mode. `--monitor` drops back
  to a plain framebuffer, because QEMU cannot screenshot a GL surface.
- The Broadcom driver is chosen from a list of eight PCI IDs. Anything else is
  left to the in-kernel drivers, which handle most modern Broadcom parts.
