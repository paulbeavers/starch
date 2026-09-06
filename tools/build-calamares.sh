#!/usr/bin/env bash
# Build Calamares from the AUR into a local pacman repo that build.sh can
# install from.
#
# mkarchiso installs packages from repositories, not from files, so an AUR
# package has to exist in a repo before the ISO can pull it in. This builds it
# once and puts it in localrepo/; build.sh adds that directory to the profile's
# pacman.conf.
#
# Only calamares itself comes from the AUR — every one of its dependencies
# (kpmcore, kcoreaddons, qt6-*, yaml-cpp, libpwquality) is in extra.
#
# Run it as yourself, not as root: makepkg refuses to run as root and calls
# sudo itself for the dependencies it needs.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$HERE/localrepo"
WORK="$HERE/.build-calamares"
DB="starch-local"
AUR=https://aur.archlinux.org/calamares.git

C_B=$'\e[1;34m'; C_G=$'\e[1;32m'; C_R=$'\e[1;31m'; C_0=$'\e[0m'
step() { printf '\n%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '    %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
die()  { printf '\n%sERROR:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "run this as yourself; makepkg will not run as root."
command -v makepkg >/dev/null || die "base-devel is not installed:  sudo pacman -S base-devel"
command -v repo-add >/dev/null || die "repo-add is missing (it comes with pacman)."
command -v git >/dev/null || die "git is not installed."

step "Fetching the PKGBUILD"
mkdir -p "$WORK"
if [[ -d $WORK/calamares/.git ]]; then
    git -C "$WORK/calamares" fetch --quiet origin
    git -C "$WORK/calamares" reset --hard --quiet origin/master
else
    git clone --quiet "$AUR" "$WORK/calamares"
fi
ok "$(git -C "$WORK/calamares" log -1 --format='%h %s')"

step "Building (this is a large C++ project — expect 10-30 minutes)"
echo "    makepkg will ask for sudo to install build dependencies."
( cd "$WORK/calamares" && makepkg --syncdeps --cleanbuild --force --noconfirm ) \
    || die "the build failed. The output above says why; the PKGBUILD is in $WORK/calamares."

step "Adding it to $REPO"
mkdir -p "$REPO"
# Not the -debug package: it is 60MB of detached symbols that nothing on the
# ISO needs, and every byte of it would ride along in the squashfs.
for pkg in "$WORK"/calamares/*.pkg.tar.*; do
    case "$pkg" in *-debug-*) continue ;; esac
    mv -f "$pkg" "$REPO"/
done
rm -f "$REPO"/*-debug-*.pkg.tar.*
rm -f "$REPO/$DB.db.tar.zst" "$REPO/$DB.files.tar.zst" "$REPO/$DB.db" "$REPO/$DB.files"
repo-add --quiet "$REPO/$DB.db.tar.zst" "$REPO"/*.pkg.tar.*
ok "$(ls -1 "$REPO"/*.pkg.tar.* | wc -l) package(s) in the repo"
ls -lh "$REPO"/*.pkg.tar.* | sed 's/^/      /'

step "Done"
echo "    Now build the ISO as usual:  sudo ./build.sh"
