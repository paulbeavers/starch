#!/usr/bin/env bash
# What the panel will actually show, so it can be judged before a boot.
set -euo pipefail
W=${1:-1920}; H=${2:-1080}; OUT=${3:-mock.png}

# The background: crust, lifted very slightly in the middle so the panel does
# not read as switched off.
magick -size ${W}x${H} radial-gradient:'#1c1c2b-#0d0d15' bg.png

# Logo at a fixed fraction of the height, so it lands the same on any panel.
logo_h=$(( H * 34 / 100 ))
magick logo.png -resize x${logo_h} PNG32:logo-s.png

# Spinner below it, from the theme where the frames actually live.
magick theme/throbber-0006.png -resize x$(( H * 5 / 100 )) PNG32:spin-s.png

magick bg.png \
  \( logo-s.png \) -gravity center -geometry +0-$(( H * 4 / 100 )) -composite \
  \( spin-s.png \) -gravity center -geometry +0+$(( H * 38 / 100 )) -composite \
  "$OUT"
rm -f bg.png logo-s.png spin-s.png
