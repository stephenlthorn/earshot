#!/bin/bash
# marks.sh [dir]: render the flat marks to PNG with headless Chrome (transparent),
# then build menubar-preview.png (44x44, 2x of a 22 pt menu bar slot, 18 pt glyph).
set -euo pipefail
W="$(cd "$(dirname "$0")" && pwd)"
D="${1:-$(dirname "$W")}"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
for m in mark-on-dark mark-on-light mark-white mark-ink mark-template; do
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
    --window-size=512,512 --default-background-color=00000000 --allow-file-access-from-files \
    --screenshot="$D/work/$m.png" "file://$D/$m.svg" 2>/dev/null >/dev/null
done
python3 "$W/menubar.py" "$D"
