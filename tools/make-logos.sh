#!/usr/bin/env bash
# Regenerate the installer's branding images from the mark.
#
# The mark lives with the Plymouth theme, in the desktop repo, because that is
# where it is drawn. The installer uses the same one rather than a second
# drawing of it: two copies of a logo drift, and the boot splash and the
# installer are the same product a minute apart.
#
#     ./tools/make-logos.sh
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SPLASH="$ROOT/hyprland-setup/splash"
HERE="$ROOT/calamares/branding/starch"

[[ -d $SPLASH ]] || {
    echo "no splash sources at $SPLASH — run: git submodule update --init" >&2
    exit 1
}

# productLogo and productWelcome: the mark over the wordmark, trimmed tight so
# whatever box Calamares puts it in is filled rather than padded, and at a
# resolution it will scale *down* from on any panel.
HEIGHT=1100 bash "$SPLASH/logo.sh" "$HERE/logo.png"

# productIcon: the mark alone and square, because an icon slot is square and a
# wide image in one is mostly empty space.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
bash "$SPLASH/mark.sh" "$tmp/mark.png"
magick "$tmp/mark.png" -trim +repage -resize 460x460 \
    -background none -gravity center -extent 512x512 PNG32:"$HERE/logo-small.png"

identify -format '  %f %wx%h\n' "$HERE/logo.png" "$HERE/logo-small.png"
