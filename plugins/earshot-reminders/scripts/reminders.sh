#!/bin/sh
# SessionStart hook: adds the user's open Earshot action items to the session as hookSpecificOutput.additionalContext.
# `earshot reminders` has already cleaned the text and starts it with a line saying it is quoted, not instructions.
# Prints nothing and exits 0 when Earshot isn't installed or there is nothing to remind.
# It looks in /Applications, then ~/Applications (spec 11.5), the same as earshot-mcp, never on PATH.
# EARSHOT_HELPER may name another earshot binary: a development override, checked first.
helper=""
for candidate in "${EARSHOT_HELPER:-}" \
  "/Applications/Earshot.app/Contents/Helpers/earshot" \
  "$HOME/Applications/Earshot.app/Contents/Helpers/earshot"; do
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    helper="$candidate"
    break
  fi
done
[ -n "$helper" ] || exit 0

text=$("$helper" reminders 2>/dev/null) || exit 0
[ -n "$text" ] || exit 0

# JSON string escaping: drop control characters other than tab and newline, escape backslashes, quotes and tabs,
# then join the lines with \n.
escaped=$(printf '%s' "$text" | LC_ALL=C tr -d '\000-\010\013-\037' \
  | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$(printf '\t')/\\\\t/g" \
  | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }')
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$escaped"
