#!/bin/bash
# Build self-contained HTML (icon embedded as data URI) and render PNGs with headless Chrome.
set -euo pipefail
ART="$(cd "$(dirname "$0")/.." && pwd)"
FINAL="$ART/../icon"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
python3 - "$ART" "$FINAL" <<'PY'
import base64, sys, pathlib
art, final = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
uri = "data:image/png;base64," + base64.b64encode((final/"icon-512.png").read_bytes()).decode()
for name in ("banner", "social-preview"):
    tpl = art/"src"/f"{name}.tpl.html"
    if tpl.exists():
        (art/f"{name}.html").write_text(tpl.read_text().replace("{{ICON}}", uri))
PY
shot() { # url out w h scale
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor="$4" \
    --window-size="$3" --screenshot="$2" "$1" 2>/dev/null >/dev/null
}
shot "file://$ART/banner.html?theme=light" "$ART/banner-light.png" 1280,550 2
shot "file://$ART/banner.html?theme=dark"  "$ART/banner-dark.png"  1280,550 2
[ -f "$ART/social-preview.html" ] && shot "file://$ART/social-preview.html" "$ART/social-preview.png" 1280,640 1
for f in "$ART"/*.png; do sips -g pixelWidth -g pixelHeight "$f" | tail -2 | tr '\n' ' '; ls -l "$f" | awk '{print $5, $9}'; done
