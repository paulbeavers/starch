#!/usr/bin/env bash
# Regenerate the installer's branding images from the mark.
#
# The mark lives with the Plymouth theme, in splash/, because that is where it
# is drawn. The installer uses the same one rather than a second
# drawing of it: two copies of a logo drift, and the boot splash and the
# installer are the same product a minute apart.
#
#     ./tools/make-logos.sh
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SPLASH="$ROOT/splash"
HERE="$ROOT/calamares/branding/starch"

[[ -d $SPLASH ]] || {
    echo "no splash sources at $SPLASH" >&2
    exit 1
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# The mark over the wordmark, at a resolution it will scale *down* from on any
# panel. logo.sh trims it tight, so its artwork starts at the very first pixel.
tight="$tmp/logo-tight.png"
HEIGHT=1100 bash "$SPLASH/logo.sh" "$tight"

# productLogo: the tight mark with transparent margin added back.
#
# Trimmed tight, it sat flush against the top edge of the sidebar and read as
# a rendering fault. The margin has to be in the asset: Calamares scales the
# pixmap to the box it gives the label, and QSS padding on the sidebar widget
# does not move a pixmap inside its own label — that was tried and changed
# nothing. Vertical only, because the sidebar is fitted to its width, so
# padding the sides would merely shrink the mark while leaving the top flush.
lw=$(identify -format %w "$tight")
lh=$(identify -format %h "$tight")
pad=$(( lh * 12 / 100 ))
magick "$tight" -background none -gravity center \
    -extent "${lw}x$(( lh + pad * 2 ))" "PNG32:$HERE/logo.png"

# productWelcome: the same logo on a dark rounded card.
#
# The welcome page's panel is light — it comes from Qt's palette, not from
# branding — and the logo is a pale gradient over near-white text, so on it the
# wordmark all but disappeared. The card is the splash's own background colour,
# so the installer opens on the picture the boot just showed rather than on a
# washed-out version of it.
#
# Baked into the image rather than set in branding.desc because branding has no
# key for it: style: reaches the sidebar and the navigation, not the page.
card_w=1400; card_h=920; radius=30
magick -size "${card_w}x${card_h}" xc:none \
    -fill '#11111b' -draw "roundrectangle 0,0 $((card_w-1)),$((card_h-1)) $radius,$radius" \
    \( "$tight" -resize "x$(( card_h * 62 / 100 ))" \) \
    -gravity center -composite \
    "PNG32:$HERE/welcome.png"

# productIcon: the mark alone and square, because an icon slot is square and a
# wide image in one is mostly empty space.
bash "$SPLASH/mark.sh" "$tmp/mark.png"
magick "$tmp/mark.png" -trim +repage -resize 460x460 \
    -background none -gravity center -extent 512x512 PNG32:"$HERE/logo-small.png"

identify -format '  %f %wx%h\n' "$HERE/logo.png" "$HERE/welcome.png" "$HERE/logo-small.png"
