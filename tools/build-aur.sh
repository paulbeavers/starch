#!/usr/bin/env bash
# Build the packages starch needs from the AUR into a local pacman repo that
# build.sh installs from.
#
# mkarchiso installs from repositories, not from files, so an AUR package has
# to exist in a repo before the ISO can pull it in. This builds them once into
# localrepo/; build.sh adds that directory to the profile's pacman.conf.
#
# Everything else comes from the official repositories — including, perhaps
# surprisingly, broadcom-wl-dkms, which is in extra.
#
# Run it as yourself, not as root: makepkg refuses to run as root and calls
# sudo itself for the dependencies it needs.
#
#     ./tools/build-aur.sh              build anything missing or out of date
#     ./tools/build-aur.sh --force      rebuild everything
set -euo pipefail

# Package, and why it is here.
AUR_PACKAGES=(
    calamares             # the installer; Qt6 and kpmcore come from extra
    broadcom-bt-firmware  # BCM20702 bluetooth, in the same MacBooks
)

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$HERE/localrepo"
WORK="$HERE/.build-aur"
DB="starch-local"
AUR=https://aur.archlinux.org

C_B=$'\e[1;34m'; C_G=$'\e[1;32m'; C_R=$'\e[1;31m'; C_0=$'\e[0m'
step() { printf '\n%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '    %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
die()  { printf '\n%sERROR:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "run this as yourself; makepkg will not run as root."
command -v makepkg >/dev/null || die "base-devel is not installed:  sudo pacman -S base-devel"
command -v repo-add >/dev/null || die "repo-add is missing (it comes with pacman)."
command -v git >/dev/null || die "git is not installed."

FORCE=0
[[ ${1:-} == --force ]] && FORCE=1

mkdir -p "$WORK" "$REPO"

for pkg in "${AUR_PACKAGES[@]}"; do
    step "$pkg"

    # Already built and not being forced? Leave it. Rebuilding Calamares takes
    # twenty minutes and nothing about it has changed.
    if [[ $FORCE -eq 0 ]] && compgen -G "$REPO/$pkg-*.pkg.tar.*" >/dev/null; then
        ok "already in the repo: $(basename "$(compgen -G "$REPO/$pkg-*.pkg.tar.*" | head -1)")"
        continue
    fi

    if [[ -d $WORK/$pkg/.git ]]; then
        git -C "$WORK/$pkg" fetch --quiet origin
        git -C "$WORK/$pkg" reset --hard --quiet origin/master
    else
        git clone --quiet "$AUR/$pkg.git" "$WORK/$pkg" \
            || die "could not clone $pkg from the AUR"
    fi
    ok "$(git -C "$WORK/$pkg" log -1 --format='%h %s')"

    ( cd "$WORK/$pkg" && makepkg --syncdeps --cleanbuild --force --noconfirm ) \
        || die "$pkg failed to build. The output above says why; its PKGBUILD is in $WORK/$pkg."

    # Not the -debug packages: detached symbols nothing installs, and every
    # byte would ride along in the squashfs.
    for built in "$WORK/$pkg"/*.pkg.tar.*; do
        case "$built" in *-debug-*) continue ;; esac
        mv -f "$built" "$REPO"/
    done
    rm -f "$WORK/$pkg"/*-debug-*.pkg.tar.*
    ok "built"
done

step "Indexing $REPO"
rm -f "$REPO"/*-debug-*.pkg.tar.*
rm -f "$REPO/$DB.db"* "$REPO/$DB.files"*
repo-add --quiet "$REPO/$DB.db.tar.zst" "$REPO"/*.pkg.tar.*
ok "$(ls -1 "$REPO"/*.pkg.tar.* | wc -l) package(s)"
ls -lh "$REPO"/*.pkg.tar.* | awk '{print "      " $9 "  " $5}'

step "Done"
echo "    Now build the ISO as usual:  sudo ./build.sh"
