#!/usr/bin/env bash
# Build everything, from a fresh clone to a bootable ISO.
#
#     git clone --recurse-submodules https://github.com/paulbeavers/starch.git
#     cd starch
#     ./build-all.sh
#
# There are two builds and they are easy to get out of order. The AUR packages
# — Calamares above all — have to exist before mkarchiso can install them, and
# Calamares has to be the *current* one, because starch patches its recipe to
# build a module the AUR skips. Running the ISO build against a stale Calamares
# produces media whose installer refuses to start, which is a slow way to find
# out. This runs them in the right order and stops at the first failure.
#
#     ./build-all.sh              build what is missing, then the ISO
#     ./build-all.sh --force-aur  rebuild the AUR packages first
#     ./build-all.sh --no-iso     stop after the AUR packages
#     ./build-all.sh --check      say what would happen, build nothing
#
# Run it as yourself. makepkg refuses to run as root, so this cannot be sudo'd
# as a whole; it calls sudo for the ISO step alone and will ask then.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

C_B=$'\e[1;34m'; C_G=$'\e[1;32m'; C_Y=$'\e[1;33m'; C_R=$'\e[1;31m'; C_0=$'\e[0m'
step() { printf '\n%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '    %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '    %s!%s %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '\n%sERROR:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

FORCE_AUR=0
DO_ISO=1
CHECK=0
for arg in "$@"; do
    case "$arg" in
        --force-aur) FORCE_AUR=1 ;;
        --no-iso)    DO_ISO=0 ;;
        --check)     CHECK=1 ;;
        -h|--help)   sed -n '2,20p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *)           die "unknown option: $arg" ;;
    esac
done

# ── what has to be true first ─────────────────────────────────────────────────
step "Checking prerequisites"

[[ $EUID -ne 0 ]] || die "run this as yourself, not with sudo — makepkg refuses to run as root. It will ask for your password when it needs it."

missing=()
command -v git      >/dev/null || missing+=(git)
command -v makepkg  >/dev/null || missing+=(base-devel)
command -v mkarchiso >/dev/null || missing+=(archiso)
[[ ${#missing[@]} -eq 0 ]] || die "not installed: ${missing[*]}
    sudo pacman -S --needed ${missing[*]}"
ok "git, base-devel and archiso are present"

# A plain `git clone` leaves the submodule empty, and the desktop half lives
# there. Fix it rather than complain about it.
if [[ ! -f hyprland-setup/install.sh ]]; then
    if [[ $CHECK -eq 1 ]]; then
        warn "the hyprland-setup submodule is empty; would run git submodule update --init"
    else
        step "Fetching the desktop submodule"
        git submodule update --init --recursive \
            || die "could not fetch the hyprland-setup submodule"
        ok "hyprland-setup checked out"
    fi
else
    ok "hyprland-setup submodule is present"
fi

avail=$(df -BG --output=avail . 2>/dev/null | tail -1 | tr -dc '0-9')
if [[ ${avail:-0} -lt 25 ]]; then
    warn "only ${avail}GB free here; the two builds together want about 25GB"
else
    ok "${avail}GB free"
fi

# ── the AUR packages ──────────────────────────────────────────────────────────
# build-aur.sh skips whatever is already in localrepo unless forced, so this is
# cheap on a re-run and about twenty minutes on a cold one.
step "AUR packages (Calamares, firmware)"
if [[ $CHECK -eq 1 ]]; then
    if compgen -G "localrepo/calamares-*.pkg.tar.*" >/dev/null; then
        warn "would keep the Calamares already in localrepo (--force-aur rebuilds it)"
    else
        warn "would build Calamares — about twenty minutes"
    fi
else
    if [[ $FORCE_AUR -eq 1 ]]; then
        ./tools/build-aur.sh --force
    else
        ./tools/build-aur.sh
    fi
fi

# ── the ISO ───────────────────────────────────────────────────────────────────
if [[ $DO_ISO -eq 0 ]]; then
    step "Stopping before the ISO (--no-iso)"
    ok "build it when you are ready with:  sudo ./build.sh"
    exit 0
fi

if [[ $CHECK -eq 1 ]]; then
    step "The ISO"
    ./build.sh --check || true
    exit 0
fi

step "The ISO"
printf '    %s!%s this needs root; sudo will ask for your password\n' "$C_Y" "$C_0"
sudo ./build.sh

step "Done"
newest="$(ls -t out/*.iso 2>/dev/null | head -1 || true)"
if [[ -n $newest ]]; then
    ok "$newest ($(du -h "$newest" | cut -f1))"
    echo
    echo "    Try it without burning anything:  ./test-boot.sh"
    echo "    Write it to a USB stick:          sudo dd if=$newest of=/dev/sdX bs=4M status=progress oflag=sync"
    echo
    echo "    The name carries today's date. If you burn one, check the"
    echo "    timestamp rather than the filename — two builds on the same day"
    echo "    share a name, and burning yesterday's has cost an evening before."
else
    warn "the build reported success but no ISO is in out/"
fi
