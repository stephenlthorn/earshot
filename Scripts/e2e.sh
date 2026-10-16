#!/bin/zsh
# Scripts/e2e.sh: Earshot records a scripted two-voice meeting played through the speakers with `say`.
# Needs: `make app` done, Earshot allowed to record system audio (click Allow on first run), and Claude Code signed in.
# Nothing here can hang: every wait counts against one 5-minute deadline from launch, and each `say` gets 20 s.
# The meetings and the run's own library index and lessons go to a temporary folder; your index is never touched.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d /tmp/earshot-e2e.XXXXXX)
OUT="$WORK/meetings"
DATA="$WORK/data"
mkdir -p "$OUT" "$DATA"
DEADLINE=$(( SECONDS + 300 ))

# The Earshot this run launched, found by its arguments: `open` doesn't give a pid.
find_app() { pgrep -n -f -- "--e2e .* $OUT" 2>/dev/null || true; }

# Stops any `say` this script started and the Earshot it launched, if either is still running. The app's children
# (`claude -p`, the command target) go first: a SIGTERM skips applicationShouldTerminate, so the app would never
# stop them itself.
cleanup() {
  pkill -P $$ -x say 2>/dev/null || true
  local pid=$(find_app) tries=0
  if [[ -n "$pid" ]]; then
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null && (( tries < 50 )); do sleep 0.1; tries=$(( tries + 1 )); done
    if kill -0 "$pid" 2>/dev/null; then
      pkill -KILL -P "$pid" 2>/dev/null || true
      kill -KILL "$pid" 2>/dev/null || true
    fi
    echo "Clean-up: stopped the Earshot this run started (pid $pid)"
  fi
}
trap cleanup EXIT
# Ctrl-C, a closed terminal or a killed make: every way out goes through the clean-up.
trap 'exit 130' INT TERM HUP

# The clean-up (EXIT trap) stops the app and any `say`.
fail() {
  echo "FAIL: $1 ($OUT)"
  exit 1
}

open -n build/Build/Products/Release/Earshot.app --args --e2e notes_and_do 40 "$OUT" "$DATA"

# The meeting starts once Earshot says it is recording. If it gives up first (e2e-done), go straight to the check.
until [[ -f "$OUT/e2e-recording" || -f "$OUT/e2e-done" ]]; do
  (( SECONDS < DEADLINE )) || fail "Earshot didn't start recording within 5 minutes (is a permission prompt waiting?)"
  sleep 0.5
done

if [[ ! -f "$OUT/e2e-done" ]]; then
  while IFS=: read -r voice line; do
    (( SECONDS < DEADLINE )) || fail "the meeting didn't finish playing within 5 minutes"
    # SIGALRM ends `say` after 20 s: a stuck audio output must not hang the run.
    perl -e 'alarm shift; exec @ARGV' 20 say -v "$voice" "$line" \
      || fail "say didn't finish within 20 s, or failed (voice $voice): the audio output looks stuck"
    sleep 0.4
  done < <(grep -v '^#' Scripts/meeting-script.txt)
fi

until [[ -f "$OUT/e2e-done" ]]; do
  (( SECONDS < DEADLINE )) || fail "Earshot didn't finish within 5 minutes"
  sleep 1
done
# Earshot quits on its own after the result; give it a moment so the clean-up never cuts a normal quit short.
for _ in {1..100}; do
  [[ -n "$(find_app)" ]] || break
  sleep 0.1
done
python3 Scripts/e2e_check.py "$OUT"
