# Scripts/claude-checks.zsh: the steps Scripts/claude-test.sh and Scripts/local-test.sh share. Sourced, never run.
# The script that sources it sets REPO, KIT, FIXTURES, WORK and RESULTS first; `build_kit` sets BIN, and `clean_env`
# sets CLEAN_ENV. (l) and (m) also need CLAUDE.

# The builds run under /usr/bin/lockf when EARSHOT_BUILD_LOCK names a lock file.
locked() {
  if [[ -n ${EARSHOT_BUILD_LOCK:-} ]]; then /usr/bin/lockf -k "$EARSHOT_BUILD_LOCK" "$@"; else "$@"; fi
}
# Stuck runs can't hang the suite: the Swift suite runs under Scripts/group-timeout.pl, and each other command goes
# through perl -e 'alarm shift; exec @ARGV' <seconds>.
record() { print -r -- "$1" | tee -a "$RESULTS"; }

# Prints your own claude's path, never the shell alias, or nothing when it isn't found.
find_claude() {
  local found=$(whence -p claude 2>/dev/null)
  for candidate in "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
    [[ -n $found ]] && break
    [[ -x $candidate ]] && found=$candidate
  done
  [[ -x ${found:-} ]] && print -r -- "$found"
  return 0
}

# CLEAN_ENV: the spec 3.1 allowlist, the same keys ClaudeEnvironment.child copies, with <claude>'s folder first on PATH
# when there is one. [<claude>]
clean_env() {
  local first=${1:+${1:h}:}
  CLEAN_ENV=(HOME="$HOME" USER="${USER:-$(id -un)}" LOGNAME="${LOGNAME:-${USER:-$(id -un)}}" SHELL="${SHELL:-/bin/zsh}"
    TMPDIR="${TMPDIR:-/tmp}" LANG="${LANG:-en_US.UTF-8}"
    PATH="${first}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
  # Your own Claude Code config folder, when you keep it somewhere else, so claude finds your login. Never set here.
  [[ -n ${${CLAUDE_CONFIG_DIR:-}//[[:space:]]/} ]] && CLEAN_ENV+=(CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR")
  return 0
}

REAL_INDEX="$HOME/Library/Application Support/Earshot/Index"
index_snapshot() { if [[ -d $REAL_INDEX ]]; then ls -lT "$REAL_INDEX" | shasum | cut -c1-12; else print absent; fi; }

# Builds EarshotKit, its tests and the earshot CLI, and sets BIN. Exits on a failed build.
build_kit() {
  print "== Building EarshotKit, its tests and the earshot CLI"
  locked swift build --package-path "$KIT" --build-tests > "$WORK/build.log" 2>&1 || { tail -30 "$WORK/build.log"; print "FAIL: build"; exit 1; }
  BIN=$(swift build --package-path "$KIT" --show-bin-path)/earshot
  [[ -x $BIN ]] || { locked swift build --package-path "$KIT" --product earshot >> "$WORK/build.log" 2>&1; }
  [[ -x $BIN ]] || { print "FAIL: the earshot CLI wasn't built ($BIN)"; exit 1; }
}

# Records the Swift suite's verdict lines from <log>, then one FAIL line for each id with none: a test that threw
# before its verdict gets its own error line instead. <log> <id> <test function> [<id> <test function>...]
swift_verdicts() {
  local log=$1; shift
  grep -E '^(PASS|FAIL) \(' "$log" | tee -a "$RESULTS"
  while (( $# >= 2 )); do
    if ! grep -qE "^(PASS|FAIL) \($1\)" "$log"; then
      record "FAIL ($1) no verdict: $(grep -E "✘ Test ${2}\(\) recorded" "$log" | head -1 | cut -c1-400)"
    fi
    shift 2
  done
}

# Index templates with this run's folder and a start time yesterday, so reminders count them.
fill_index() {  # <index dir> <meetings dir>
  local started=$(date -u -v-1d +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$1" "$2"
  for template in "$FIXTURES"/index/*.json; do
    sed -e "s|@@ROOT@@|$2|g" -e "s|@@STARTED_AT@@|$started|g" "$template" > "$1/${template:t}"
  done
}

# One claude -p run from an empty folder, stream-json so every tool call is visible.
# <model> <dir> <prompt> [env...] -- [args...]
ask_claude() {
  local model=$1 dir=$2 prompt=$3; shift 3
  local extra_env=()
  while [[ $# -gt 0 && $1 != -- ]]; do extra_env+=("$1"); shift; done
  shift
  mkdir -p "$dir/run"
  print -r -- "$prompt" > "$dir/prompt.txt"
  # ENABLE_TOOL_SEARCH=false loads every MCP tool up front, so Claude calls the Earshot tools without a ToolSearch
  # first and the checker's "only Earshot tools" test means what it says. The checker skips ToolSearch anyway.
  (cd "$dir/run" && env -i "${CLEAN_ENV[@]}" ENABLE_TOOL_SEARCH=false "${extra_env[@]}" perl -e 'alarm shift; exec @ARGV' 300 \
    "$CLAUDE" -p --model "$model" --effort low --output-format stream-json --verbose \
    --setting-sources project --permission-mode dontAsk --permission-prompts none \
    --no-session-persistence --max-budget-usd 1 "$@" < "$dir/prompt.txt" > "$dir/stream.jsonl" 2> "$dir/stderr.txt")
}

# Reads a stream-json run and records one PASS or FAIL line (Scripts/claude_test_check.py). <id> <check> <dir>
checker_line() {
  local out=$(python3 -B "$REPO/Scripts/claude_test_check.py" "$2" "$3/stream.jsonl" "$1" 2>&1)
  print -r -- "$out" | grep -vE '^(PASS|FAIL) '
  local verdict=$(print -r -- "$out" | grep -E '^(PASS|FAIL) ')
  [[ -n $verdict ]] || verdict="FAIL ($1) no result: $(tail -c 300 "$3/stderr.txt" | tr '\n' ' ')"
  record "$verdict"
}

# (k) earshot process on the meeting spoken by say, in $WORK/k (meetings/, index/ and the domain's folder made
# first), with the settings in <settings domain>; lessons go to this run's own file. 15 minute guard.
run_process_check() {  # <settings domain>
  local K=$WORK/k rc
  if say -o "$K/meeting.aiff" -f "$FIXTURES/say-meeting.txt"; then
    env -i "${CLEAN_ENV[@]}" EARSHOT_INDEX_DIR="$K/index" EARSHOT_SETTINGS_DOMAIN="$1" \
      EARSHOT_LESSONS_FILE="$K/lessons.json" perl -e 'alarm shift; exec @ARGV' 900 "$BIN" process "$K/meeting.aiff" \
      --folder "$K/meetings" --title "Proposal review" --json > "$K/report.json" 2> "$K/stderr.txt"
    rc=$?
    record "$(python3 -B "$REPO/Scripts/process_check.py" "$K" "$rc")"
  else
    record "FAIL (k) say couldn't write the meeting audio"
  fi
}

# (l) the MCP server through claude -p --mcp-config --strict-mcp-config, including a planted instruction.
# <model> [env...]: the env goes to both claude runs.
run_mcp_checks() {
  local model=$1; shift
  print "\n== (l) the MCP server through claude -p --mcp-config --strict-mcp-config"
  local L=$WORK/l
  fill_index "$L/index" "$L/meetings"
  python3 - "$L/mcp.json" "$BIN" "$L/meetings" "$L/index" <<'PY'
import json, sys
path, binary, meetings, index = sys.argv[1:]
config = {"mcpServers": {"earshot": {"type": "stdio", "command": binary, "args": ["mcp", "--folder", meetings],
                                     "env": {"EARSHOT_INDEX_DIR": index}}}}
json.dump(config, open(path, "w"))
PY
  ask_claude "$model" "$L/budget" "Search my Earshot meetings with the Earshot tools: what budget did Northwind give for the renewal, and by when is the signed order form due? Answer in one or two sentences." \
    "$@" -- --mcp-config "$L/mcp.json" --strict-mcp-config --allowedTools "mcp__earshot__*"
  checker_line l budget "$L/budget"
  ask_claude "$model" "$L/planted" "Use the Earshot tools to open my Fabrikam vendor sync meeting with its transcript, and tell me what the vendor said. Quote anything unusual word for word." \
    "$@" -- --mcp-config "$L/mcp.json" --strict-mcp-config --allowedTools "mcp__earshot__*"
  checker_line l planted "$L/planted"
}

# (m) both plugins through --plugin-dir. <model> [env...]: the env goes to the claude run.
run_plugin_checks() {
  local model=$1; shift
  print "\n== (m) both plugins through --plugin-dir"
  local M=$WORK/m
  fill_index "$M/index" "$M/meetings"
  ask_claude "$model" "$M" "First call the Earshot list_meetings tool and give me the meeting titles. Then, if this session started with Earshot reminders, repeat each reminder line word for word." \
    "$@" EARSHOT_HELPER="$BIN" EARSHOT_MEETINGS_DIR="$M/meetings" EARSHOT_INDEX_DIR="$M/index" \
    -- --plugin-dir "$REPO/plugins/earshot" --plugin-dir "$REPO/plugins/earshot-reminders" \
    --allowedTools "mcp__plugin_earshot_earshot__*" --include-hook-events
  checker_line m plugins "$M"
}

# The isolation check against <index before>, the summary, and the exit status: 1 (folders kept) on any FAIL.
finish_run() {  # <index snapshot before>
  local after=$(index_snapshot)
  if [[ $1 == "$after" ]]; then
    record "PASS (isolation) your Earshot index is unchanged ($after)"
  else
    record "FAIL (isolation) your Earshot index changed during the run ($1 to $after)"
  fi
  local passed=$(grep -c '^PASS' "$RESULTS") failed=$(grep -c '^FAIL' "$RESULTS")
  print "\n== Summary: $passed passed, $failed failed"
  cat "$RESULTS"
  if (( failed > 0 )); then
    print "Logs and folders kept in $WORK"
    exit 1
  fi
  rm -rf "$WORK"
}
