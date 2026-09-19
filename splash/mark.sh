#!/usr/bin/env bash
# The starch mark: a mountain, since starch is Arch and Arch's is a mountain —
# but two open strokes rather than a filled triangle, so it is plainly its own
# mark and not Arch's badge worn by something that is not Arch upstream.
set -euo pipefail
S=1200
W=96
OUT=${1:-mark.png}

# Mauve to sapphire at 45 degrees, the gradient the window borders use.
magick -size ${S}x${S} gradient:'#cba6f7-#74c7ec' -rotate -45 \
       -gravity center -extent ${S}x${S} grad.png

# The strokes as a greyscale mask: white is kept, black is cut away.
magick -size ${S}x${S} xc:black -stroke white -fill none -strokewidth $W \
  -draw "stroke-linecap round stroke-linejoin round path 'M 210,880 L 600,300 L 990,880'" \
  -draw "stroke-linecap round stroke-linejoin round path 'M 405,880 L 600,590 L 795,880'" \
  -colorspace gray mask.png

# CopyOpacity puts the mask's intensity into the gradient's alpha. Note the
# absence of -alpha off, which would apply to both images and leave the mask
# itself as the result — greyscale, which is what happened the first time.
magick grad.png mask.png -compose CopyOpacity -composite \
  -trim +repage "PNG32:$OUT"

rm -f grad.png mask.png
