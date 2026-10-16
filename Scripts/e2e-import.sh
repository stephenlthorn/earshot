#!/bin/zsh
# Scripts/e2e-import.sh: Earshot imports a two-voice meeting made with `say` and runs the whole pipeline with your own
# Claude Code (your subscription): transcript, notes, notes.html, the library index and a Do payload.
# Needs: `make app` done and Claude Code signed in. It records nothing and asks for no permission.
# With EARSHOT_E2E_LOCAL_URL and EARSHOT_E2E_LOCAL_MODEL both set, the notes come from that local model server instead
# (`--local <url> <model>`; Claude Code isn't needed), and the run gets 15 minutes instead of 5.
# The meetings, and the run's own library index and lessons, go to a temporary folder: your index in
# ~/Library/Application Support/Earshot/Index is never touched. On a Mac where Earshot never ran, the app saves its
# default Settings on launch; those are removed again at the end.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/Build/Products/Release/Earshot.app
WORK=$(mktemp -d "${${TMPDIR:-/tmp}%/}/earshot-e2e-import.XXXXXX")
OUT="$WORK/meetings"
DATA="$WORK/data"
INDEX="$DATA/Index"
AUDIO="$WORK/meeting.m4a"
APP_PID=""

[[ -d "$APP" ]] || { echo "FAIL: $APP not found; run make app first"; exit 1; }

PREFS_EXISTED=0; defaults read com.stephenthorn.earshot settings >/dev/null 2>&1 && PREFS_EXISTED=1

# The Earshot this run launched, found by its arguments: `open` doesn't give a pid.
find_app() { pgrep -n -f -- "--e2e-import .* $OUT" 2>/dev/null || true; }

# Stops that Earshot, if it is still running, and waits until it is gone, so it can't save Settings again after the
# clean-up. Its children (`claude -p`, the command target) go first: a SIGTERM skips
# applicationShouldTerminate, so the app would never stop them itself.
stop_app() {
  local pid=${APP_PID:-$(find_app)} tries=0
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null || return 0
  pkill -TERM -P "$pid" 2>/dev/null || true
  kill -TERM "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && (( tries < 50 )); do sleep 0.1; tries=$(( tries + 1 )); done
  if kill -0 "$pid" 2>/dev/null; then
    pkill -KILL -P "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
    sleep 0.5
  fi
  echo "Clean-up: stopped the Earshot this run started (pid $pid)"
}

cleanup() {
  stop_app
  if (( ! PREFS_EXISTED )) && defaults read com.stephenthorn.earshot settings >/dev/null 2>&1; then
    defaults delete com.stephenthorn.earshot settings && echo "Clean-up: removed the default Settings the app saved"
  fi
  echo "The meetings folder and the run's index are kept for a look: $WORK"
}
trap cleanup EXIT
# Ctrl-C, a closed terminal or a killed make: every way out goes through the clean-up.
trap 'exit 130' INT TERM HUP

# The clean-up (EXIT trap) stops the app.
fail() {
  echo "FAIL: $1"
  exit 1
}

# One WAVE file per line, joined with short pauses, then AAC. Each `say` gets 20 s.
n=0
while IFS=: read -r voice line; do
  n=$(( n + 1 ))
  perl -e 'alarm shift; exec @ARGV' 20 say -v "$voice" --file-format=WAVE --data-format=LEI16@22050 \
    -o "$WORK/part-$(printf %02d $n).wav" "$line" || fail "say didn't make line $n (voice $voice)"
done < <(grep -v '^#' Scripts/meeting-script.txt)
python3 -B - "$WORK/meeting.wav" "$WORK"/part-*.wav <<'PY'
import sys, wave
out, parts = sys.argv[1], sys.argv[2:]
with wave.open(parts[0]) as first:
    params = first.getparams()
pause = b"\0" * (params.sampwidth * params.nchannels * int(params.framerate * 0.5))
with wave.open(out, "wb") as joined:
    joined.setparams(params)
    for part in parts:
        with wave.open(part) as w:
            joined.writeframes(w.readframes(w.getnframes()) + pause)
PY
afconvert -f m4af -d aac "$WORK/meeting.wav" "$AUDIO"
echo "Made $AUDIO ($n lines, two voices)"

# Your own Claude Code, or a local model server when both variables are set.
LAUNCH=(--e2e-import "$AUDIO" "$OUT" "$DATA")
MINUTES=5
WRITER="your Claude Code"
if [[ -n "${EARSHOT_E2E_LOCAL_URL:-}" && -n "${EARSHOT_E2E_LOCAL_MODEL:-}" ]]; then
  LAUNCH+=(--local "$EARSHOT_E2E_LOCAL_URL" "$EARSHOT_E2E_LOCAL_MODEL")
  MINUTES=15
  WRITER="the local model $EARSHOT_E2E_LOCAL_MODEL at $EARSHOT_E2E_LOCAL_URL"
fi

mkdir -p "$OUT" "$DATA"
open -n "$APP" --args "${LAUNCH[@]}"
DEADLINE=$(( SECONDS + MINUTES * 60 ))
echo "Earshot is importing it and writing notes with $WRITER (up to $MINUTES minutes)..."

# The pid, so a crash shows at once instead of after the deadline. A very fast run may be over before it is seen.
for _ in {1..100}; do
  APP_PID=$(find_app)
  [[ -n "$APP_PID" || -f "$OUT/e2e-done" ]] && break
  sleep 0.1
done
[[ -n "$APP_PID" || -f "$OUT/e2e-done" ]] || fail "Earshot didn't start, or quit at once without a result"

until [[ -f "$OUT/e2e-done" ]]; do
  (( SECONDS < DEADLINE )) || fail "Earshot didn't finish within $MINUTES minutes"
  if [[ -n "$APP_PID" ]] && ! kill -0 "$APP_PID" 2>/dev/null; then
    [[ -f "$OUT/e2e-done" ]] || fail "Earshot quit without a result (it may have crashed; see Console)"
  fi
  sleep 1
done
# Earshot quits on its own after the result; give it a moment so the clean-up never cuts a normal quit short.
for _ in {1..100}; do
  [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null || break
  sleep 0.1
done
python3 -B Scripts/e2e_import_check.py "$OUT" "$INDEX"
