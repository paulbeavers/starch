#!/usr/bin/env bash
# The mark over the wordmark.
#
#     ./logo.sh                       -> logo.png, 440px tall
#     HEIGHT=1100 ./logo.sh out.png    -> a bigger one, somewhere else
#
# The default is sized for a 1080p panel and no larger, because Plymouth draws
# the watermark at its native size — it does not fit it to the screen — so an
# image sized "large enough for anything" simply fills the display. It doubles
# images on a hidpi output, which is why designing for 1080p is right rather
# than a compromise.
#
# Anything that is *not* Plymouth wants it bigger, and scales it down itself:
# hence HEIGHT. Calamares' branding uses this.
set -euo pipefail

HEIGHT="${HEIGHT:-440}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Resolved before the cd below, or a relative path lands in the temp directory
# and is thrown away with it.
OUT="${1:-$HERE/logo.png}"
[[ $OUT == /* ]] || OUT="$PWD/$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

bash "$HERE/mark.sh" mark.png

# Mono, because the whole desktop is mono, letterspaced so it reads as a mark
# rather than as a word someone typed.
magick -background none -fill '#cdd6f4' \
  -font 'JetBrains-Mono-ExtraBold' -pointsize 190 -kerning 26 \
  label:'starch' -trim +repage PNG32:word.png

magick -background none -fill '#6c7086' \
  -font 'JetBrains-Mono-Medium' -pointsize 46 -kerning 16 \
  label:'ARCH LINUX' -trim +repage PNG32:tag.png

# Gaps between the three come from a transparent border on each, so -append
# does not have to be told about spacing.
magick mark.png -resize x420 -bordercolor none -border 30x36 PNG32:a.png
magick word.png -resize x140 -bordercolor none -border 30x22 PNG32:b.png
magick tag.png                -bordercolor none -border 30x14 PNG32:c.png

magick a.png b.png c.png -background none -gravity center -append +repage \
  -trim +repage -resize "x$HEIGHT" "PNG32:$WORK/out.png"

install -m 644 "$WORK/out.png" "$OUT"
identify -format '  %f %wx%h\n' "$OUT"
