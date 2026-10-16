#!/bin/zsh
# Scripts/screenshots.sh (`make screenshots`): the README screenshots and the live panel GIF, drawn offscreen from
# the app's real views with a made-up sample meeting. Nothing asks for a permission, and your settings, meetings,
# index and Keychain are never read.
# Needs: Xcode and xcodegen (for `make app`), Google Chrome (for the notes page) and ffmpeg (for the GIF).
# EARSHOT_BUILD_LOCK=<file> runs the build and the render under `lockf`, one heavy job at a time.
# While it renders (about 20 s), keys typed in other apps are dropped: each offscreen window is briefly key.
# The menu shot needs this Mac's microphone status for Earshot not to be "denied"; the renderer stops if it is.
set -euo pipefail
cd "$(dirname "$0")/.."

SCREENS=docs/images/screens
GIF=docs/images/live-panel.gif
APP=build/Build/Products/Release/Earshot.app
CHROME=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
GIF_LIMIT=$(( 2 * 1024 * 1024 ))
SHOTS=(menu live-panel confirm settings-claude settings-local settings-live settings-ai-apps onboarding)
# The app's settings domain. The renderer must never write it; its modification time is checked around the render.
PREFS="$HOME/Library/Preferences/com.stephenthorn.earshot.plist"
WORK=$(mktemp -d /tmp/earshot-screens.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
heavy() { if [[ -n "${EARSHOT_BUILD_LOCK:-}" ]]; then /usr/bin/lockf -k "$EARSHOT_BUILD_LOCK" "$@"; else "$@"; fi }
# `$within <seconds> <command>` ends a command that hangs (a stuck browser, say).
within=(perl -e 'alarm shift; exec @ARGV')

[[ -x "$CHROME" ]] || fail "Google Chrome not found at $CHROME (set CHROME=/path/to/chrome)"
command -v ffmpeg >/dev/null || fail "ffmpeg not found (brew install ffmpeg)"

prefs_stamp() { stat -f%m "$PREFS" 2>/dev/null || echo none; }

heavy make app
before=$(prefs_stamp)
heavy $within 300 "$APP/Contents/MacOS/Earshot" --render-screenshots "$WORK" >/dev/null
sleep 1  # cfprefsd writes in the background; give a stray write time to land before checking
[[ "$(prefs_stamp)" == "$before" ]] || fail "the renderer changed $PREFS (or another Earshot did meanwhile)"
[[ ! -e "$WORK/scratch" ]] || fail "the renderer left its scratch folder (the sample meetings) behind"

mkdir -p "$SCREENS"
for shot in $SHOTS; do
  for look in light dark; do
    [[ -s "$WORK/$shot-$look.png" ]] || fail "the renderer wrote no $shot-$look.png"
    cp "$WORK/$shot-$look.png" "$SCREENS/"
  done
done

# The notes page as Chrome draws it, from the header to the end of Flagged moments. Each copy has its color scheme
# pinned by the renderer. Where Flagged moments ends is measured, not assumed: the renderer's measuring copy runs
# one script that writes it onto <body> (data-crop-bottom, CSS px), and Chrome's --dump-dom prints it.
chrome=("$CHROME" --headless=new --disable-gpu --hide-scrollbars --no-first-run --no-default-browser-check
  --user-data-dir="$WORK/chrome")
[[ -s "$WORK/notes-page-measure.html" ]] || fail "the renderer wrote no notes-page-measure.html"
dom=$($within 120 $chrome --window-size=900,1600 --dump-dom "file://$WORK/notes-page-measure.html" 2>/dev/null) \
  || fail "Chrome couldn't load notes-page-measure.html"
crop=$(print -r -- "$dom" | sed -nE 's/.*data-crop-bottom="([0-9]+)".*/\1/p' | head -1)
[[ "$crop" == <1-> ]] || fail "the notes page has no Flagged moments section to crop to"
# Headless Chrome repaints the top of the page in its last rows, so the window is taller than the crop.
for look in light dark; do
  [[ -s "$WORK/notes-page-$look.html" ]] || fail "the renderer wrote no notes-page-$look.html"
  $within 120 $chrome --force-device-scale-factor=2 --window-size=900,$(( crop + 300 )) \
    --screenshot="$WORK/notes-page-$look.png" "file://$WORK/notes-page-$look.html" >/dev/null 2>&1 \
    || fail "Chrome couldn't draw notes-page-$look.html"
  [[ -s "$WORK/notes-page-$look.png" ]] || fail "Chrome wrote no notes-page-$look.png"
  height=$(sips -g pixelHeight "$WORK/notes-page-$look.png" | awk '/pixelHeight/ { print $2 }')
  (( height >= crop * 2 )) || fail "Chrome drew notes-page-$look.png $height px high, less than the $(( crop * 2 )) px crop"
  ffmpeg -y -loglevel error -i "$WORK/notes-page-$look.png" -vf "crop=iw:$(( crop * 2 )):0:0" \
    "$SCREENS/notes-page-$look.png"
done

# The GIF: 1.5 s a frame, looping, one palette for all frames. Drawn at 2x, kept at full size while it fits in 2 MB.
frames=("$WORK"/gif/frame-*.png(N))
(( ${#frames} == 12 )) || fail "expected 12 GIF frames, found ${#frames}"
for width in 792 640 520; do
  ffmpeg -y -loglevel error -framerate 2/3 -i "$WORK/gif/frame-%02d.png" \
    -vf "scale=$width:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=full[p];[b][p]paletteuse=dither=sierra2_4a" \
    -loop 0 "$WORK/live-panel.gif"
  (( $(stat -f%z "$WORK/live-panel.gif") < GIF_LIMIT )) && break
done
(( $(stat -f%z "$WORK/live-panel.gif") < GIF_LIMIT )) || fail "the GIF is over 2 MB even at $width px wide"
cp "$WORK/live-panel.gif" "$GIF"

for file in "$SCREENS"/*.png "$GIF"; do
  printf '%8s  %s\n' "$(( $(stat -f%z "$file") / 1024 )) KB" "$file"
done
