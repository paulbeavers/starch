#!/usr/bin/env bash
# The password dialog's pieces.
#
# two-step loads the lock image when it shows the splash, not when it first
# needs a password — so a theme without these does not merely lack a dialog, it
# fails to start at all and Plymouth falls back to the text splash. That is
# exactly what happened the first time: the theme loaded, `loading lock image`
# was the last thing it logged, and the boot showed a generic grey screen.
#
# Drawn rather than set from a font, so there is no dependency on a particular
# icon set being installed and no guessing at codepoints.
set -euo pipefail

TEXT='#cdd6f4'
DIM='#6c7086'
SURF='#313244'
LINE='#45475a'

# Padlock: a shackle arc over a rounded body.
magick -size 40x48 xc:none \
    -stroke "$TEXT" -strokewidth 4 -fill none \
    -draw "path 'M 11,22 L 11,14 A 9,9 0 0 1 29,14 L 29,22'" \
    -stroke none -fill "$TEXT" \
    -draw 'roundrectangle 5,22 35,44 5,5' \
    PNG32:theme/lock.png

# Keyboard: a body with three rows of keys and a space bar.
magick -size 44x32 xc:none \
    -stroke "$DIM" -strokewidth 2 -fill none \
    -draw 'roundrectangle 2,4 42,28 4,4' \
    -stroke none -fill "$DIM" \
    -draw 'rectangle 7,9 11,12   rectangle 14,9 18,12   rectangle 21,9 25,12 rectangle 28,9 32,12' \
    -draw 'rectangle 9,15 13,18  rectangle 16,15 20,18  rectangle 23,15 27,18' \
    -draw 'rectangle 13,21 31,24' \
    PNG32:theme/keyboard.png

# Caps Lock: a chevron over a bar.
magick -size 28x32 xc:none \
    -stroke "$TEXT" -strokewidth 4 -fill none \
    -draw "stroke-linecap round stroke-linejoin round path 'M 5,16 L 14,6 L 23,16'" \
    -stroke none -fill "$TEXT" \
    -draw 'roundrectangle 7,22 21,27 2,2' \
    PNG32:theme/capslock.png

# The field the password is typed into: a rounded well with one hairline border.
magick -size 320x40 xc:none \
    -fill "$SURF" -stroke "$LINE" -strokewidth 2 \
    -draw 'roundrectangle 1,1 318,38 10,10' \
    PNG32:theme/entry.png

# One of these per character typed.
magick -size 14x14 xc:none -fill "$TEXT" -stroke none \
    -draw 'circle 7,7 7,2' PNG32:theme/bullet.png

identify -format '  %f %wx%h\n' theme/{lock,keyboard,capslock,entry,bullet}.png
