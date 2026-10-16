#!/bin/bash
# render.sh [dir] : export the .icon in <dir> (default: final/) with ictool, make the
# sized PNGs with sips, the renditions strip and the small-size sheet.
# ictool fills the whole output with the squircle, so each rendition is exported at
# 824 px (the macOS 26 icon body) and centred on a transparent 1024 canvas, which
# gives the standard 100 px Tahoe margin.
set -euo pipefail
W="$(cd "$(dirname "$0")" && pwd)"
D="${1:-$(dirname "$W")}"
ICT="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
mkdir -p "$D/work"
for R in Default Dark ClearLight TintedDark; do
  "$ICT" "$D/AppIcon.icon" --export-image --output-file "$D/work/rend-$R.png" \
    --platform macOS --rendition "$R" --width 824 --height 824 --scale 1
  python3 -c "
import sys
from PIL import Image
p = sys.argv[1]
body = Image.open(p).convert('RGBA')
canvas = Image.new('RGBA', (1024, 1024), (0, 0, 0, 0))
canvas.alpha_composite(body, (100, 100))
canvas.save(p)" "$D/work/rend-$R.png"
done
cp "$D/work/rend-Default.png" "$D/icon-1024.png"
for s in 512 256 128 64 32 16; do sips -z $s $s "$D/icon-1024.png" --out "$D/icon-$s.png" >/dev/null; done
python3 "$W/sheet.py" "$D"
