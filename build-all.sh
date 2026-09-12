#!/usr/bin/env bash
# Build everything, from a fresh clone to a bootable ISO.
#
#     git clone --recurse-submodules https://github.com/paulbeavers/starch.git
#     cd starch
#     ./build-all.sh
#
# There are two builds and the order between them matters. The AUR packages —
# Calamares above all — have to exist before mkarchiso can install them, and
# Calamares has to be the current one, because starch patches its recipe to
# build a module the AUR skips. An ISO built against a stale Calamares carries
# an installer that refuses to start, which is a slow way to find out.
#
# No options. The two scripts underneath have their own if you need them:
# ./tools/build-aur.sh --force rebuilds Calamares, ./build.sh --check and
# --assemble inspect without building.
#
# Run it as yourself. makepkg refuses to run as root, so this calls sudo for
# the ISO step alone and asks then.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

C_B=$'\e[1;34m'; C_G=$'\e[1;32m'; C_Y=$'\e[1;33m'; C_R=$'\e[1;31m'; C_0=$'\e[0m'
step() { printf '\n%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '    %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '    %s!%s %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '\n%sERROR:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

step "Checking prerequisites"

[[ $EUID -ne 0 ]] || die "run this as yourself, not with sudo — makepkg refuses to run as root. It asks for your password when it needs it."

missing=()
command -v git       >/dev/null || missing+=(git)
command -v makepkg   >/dev/null || missing+=(base-devel)
command -v mkarchiso >/dev/null || missing+=(archiso)
[[ ${#missing[@]} -eq 0 ]] || die "not installed: ${missing[*]}
    sudo pacman -S --needed ${missing[*]}"
ok "git, base-devel and archiso are present"

# A plain `git clone` leaves the submodule empty, and the desktop half lives
# there. Fix it rather than complain about it.
if [[ -f hyprland-setup/install.sh ]]; then
    ok "hyprland-setup submodule is present"
else
    git submodule update --init --recursive \
        || die "could not fetch the hyprland-setup submodule"
    ok "hyprland-setup checked out"
fi

avail=$(df -BG --output=avail . 2>/dev/null | tail -1 | tr -dc '0-9')
if [[ ${avail:-0} -lt 25 ]]; then
    warn "only ${avail}GB free here; the two builds together want about 25GB"
else
    ok "${avail}GB free"
fi

# ── the AUR packages ──────────────────────────────────────────────────────────
# Skips whatever is already in localrepo, so this is seconds on a re-run and
# about twenty minutes on a cold one.
step "AUR packages (Calamares, firmware)"
./tools/build-aur.sh

# ── the ISO ───────────────────────────────────────────────────────────────────
step "The ISO"
warn "this needs root; sudo will ask for your password"
sudo ./build.sh

step "Done"
newest="$(ls -t out/*.iso 2>/dev/null | head -1 || true)"
[[ -n $newest ]] || die "the build reported success but no ISO is in out/"
ok "$newest ($(du -h "$newest" | cut -f1))"
cat <<NOTE

    Try it without burning anything:  ./test-boot.sh
    Write it to a USB stick:          sudo dd if=$newest of=/dev/sdX bs=4M status=progress oflag=sync

    The name carries today's date. If you burn one, check the timestamp
    rather than the filename — two builds on the same day share a name,
    and burning yesterday's has cost an evening here before.
NOTE
