#!/usr/bin/env bash
# A ring of dots that fades round the circle. Dots rather than a rotating arc
# because Plymouth plays frames at a fixed rate and a rotating arc makes any
# stutter obvious, while a fading ring does not.
set -euo pipefail
# Small on purpose. It sits below the logo, and on a 1280x800 panel a large
# ring reached the wordmark; the splash should read as a logo with a quiet
# indicator under it, not as a logo with a wheel on top of it.
N=${1:-36}          # frames
S=96                # canvas
R=30                # ring radius
DOT=5
C=$((S/2))

for ((f=0; f<N; f++)); do
  args=()
  for ((i=0; i<12; i++)); do
    # Brightness falls away behind the leading dot.
    lead=$(( (f * 12 / N) ))
    d=$(( (i - lead + 12) % 12 ))
    a=$(awk -v d="$d" 'BEGIN{ v = 1 - d*0.085; if (v < 0.12) v = 0.12; printf "%.3f", v }')
    ang=$(awk -v i="$i" 'BEGIN{ printf "%.6f", (i*30 - 90) * 3.14159265/180 }')
    x=$(awk -v c="$C" -v r="$R" -v a="$ang" 'BEGIN{ printf "%.1f", c + r*cos(a) }')
    y=$(awk -v c="$C" -v r="$R" -v a="$ang" 'BEGIN{ printf "%.1f", c + r*sin(a) }')
    args+=( -fill "rgba(203,166,247,$a)" -draw "circle $x,$y $x,$(awk -v y="$y" -v d="$DOT" 'BEGIN{printf "%.1f", y-d}')" )
  done
  magick -size ${S}x${S} xc:none "${args[@]}" "PNG32:$(printf 'throbber-%04d.png' "$f")"
done
echo "  $N spinner frames"
