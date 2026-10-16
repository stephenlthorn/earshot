#!/bin/zsh
# Scripts/local-test.sh: the local model checks, run by `make local-test`. Real calls to your own local
# OpenAI-compatible server (Ollama, LM Studio, llama.cpp, vLLM) at EARSHOT_LOCAL_URL (for example
# http://localhost:11434/v1) with the model EARSHOT_LOCAL_MODEL. Each check prints PASS or FAIL with evidence:
#   (a), (c) to (i)  the gated Swift suite LocalLiveTests (EARSHOT_LOCAL_TESTS=1): one structured call, then the same
#                    notes, live, brief, ask and fix checks as make claude-test
#   (k)              earshot process on a meeting spoken by `say`, with Earshot set to the local model
#   (l), (m)         only when EARSHOT_LOCAL_ANTHROPIC_URL names the server's Anthropic Messages API (llama.cpp serves
#                    one at the same /v1 address) and Claude Code is installed: the MCP server and both plugins, with
#                    Claude Code running on the local model instead of your Claude plan
# Only temporary folders are used: a meetings folder and an index of its own for each check, never your meetings,
# your index, your lessons or your Earshot settings ((k) reads a settings domain of its own that holds only the local
# provider, address and model). Children get an allowlist environment, and Claude runs skip your user settings.
# Set EARSHOT_BUILD_LOCK to a lock file to run the builds under /usr/bin/lockf.
set -uo pipefail
REPO=${0:A:h:h}
KIT=$REPO/Packages/EarshotKit
FIXTURES=$KIT/Tests/Fixtures/claude
LOCAL_URL=${EARSHOT_LOCAL_URL:-}
LOCAL_MODEL=${EARSHOT_LOCAL_MODEL:-}
if [[ -z ${LOCAL_URL//[[:space:]]/} || -z ${LOCAL_MODEL//[[:space:]]/} ]]; then
  print "FAIL (preflight) set EARSHOT_LOCAL_URL (for example http://localhost:11434/v1) and EARSHOT_LOCAL_MODEL (the model's name on that server)"
  exit 1
fi

# 1. The server lists the model, or one FAIL line with what it lists.
# A helper that crashed (a traceback, nothing printed) stops the run too, with its own FAIL line.
PREFLIGHT=$(python3 -B "$REPO/Scripts/local_test_setup.py" models "$LOCAL_URL" "$LOCAL_MODEL")
PREFLIGHT_STATUS=$?
[[ -n $PREFLIGHT ]] && print -r -- "$PREFLIGHT"
if (( PREFLIGHT_STATUS != 0 )); then
  [[ $PREFLIGHT == FAIL* ]] || print "FAIL (preflight) the model list check crashed (exit $PREFLIGHT_STATUS)"
  exit 1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/earshot-local-test.XXXXXX")
RESULTS=$WORK/results.txt
: > "$RESULTS"
source "$REPO/Scripts/claude-checks.zsh"

# Claude Code is optional here: it is needed only for (l) and (m).
CLAUDE=$(find_claude)
clean_env "$CLAUDE"
INDEX_BEFORE=$(index_snapshot)

print "== Local model: $LOCAL_MODEL at $LOCAL_URL"
print "== Work folder: $WORK"
# 2. The build, under the lock when EARSHOT_BUILD_LOCK is set.
build_kit

# ---------------------------------------------------------------------------------------------------------------
# 3. In a process group of its own, so the 90-minute guard stops the test runners too.
print "\n== (a), (c) to (i): LocalLiveTests"
perl "$REPO/Scripts/group-timeout.pl" 5400 env EARSHOT_LOCAL_TESTS=1 EARSHOT_LOCAL_URL="$LOCAL_URL" \
  EARSHOT_LOCAL_MODEL="$LOCAL_MODEL" swift test --package-path "$KIT" --skip-build --filter LocalLiveTests \
  > "$WORK/swift.log" 2>&1
swift_verdicts "$WORK/swift.log" a localStructuredCallReturnsJSON \
  c notesFindAshleysProposalByFriday d notesNeverGuessWhichExternalAttendeeSpoke \
  e notesLinkARewordedStartedItemThroughLiveRef f liveExtractionAcrossStagesUpdatesByRef g briefFromFixtureHistory \
  h askAnswersWithATime i fixAppliesTheInstruction

# ---------------------------------------------------------------------------------------------------------------
# 4. earshot process with a settings domain that holds only the local provider, address and model.
print "\n== (k) earshot process on a meeting spoken by say, with Earshot set to $LOCAL_MODEL"
K=$WORK/k
mkdir -p "$K/meetings" "$K/index" "$K/settings"
if python3 -B "$REPO/Scripts/local_test_setup.py" settings "$K/settings/defaults.plist" "$LOCAL_URL" "$LOCAL_MODEL"; then
  run_process_check "$K/settings/defaults"
else
  record "FAIL (k) the settings domain for the local model couldn't be written"
fi

# ---------------------------------------------------------------------------------------------------------------
# 5. The MCP server and both plugins, with Claude Code talking to the local server instead of Anthropic.
if [[ -z ${EARSHOT_LOCAL_ANTHROPIC_URL:-} ]]; then
  record "SKIP (l) (m): set EARSHOT_LOCAL_ANTHROPIC_URL to run the MCP and plugin checks with Claude Code on the local model"
elif [[ ! -x ${CLAUDE:-} ]]; then
  record "SKIP (l) (m): Claude Code wasn't found, so the MCP and plugin checks with Claude Code on the local model can't run"
else
  LOCAL_CLAUDE_ENV=(ANTHROPIC_BASE_URL="$EARSHOT_LOCAL_ANTHROPIC_URL" ANTHROPIC_AUTH_TOKEN=local
    ANTHROPIC_DEFAULT_HAIKU_MODEL="$LOCAL_MODEL" ANTHROPIC_DEFAULT_SONNET_MODEL="$LOCAL_MODEL"
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1)
  print "== Claude Code: $($CLAUDE --version 2>/dev/null) at $CLAUDE, on $EARSHOT_LOCAL_ANTHROPIC_URL"
  run_mcp_checks "$LOCAL_MODEL" "${LOCAL_CLAUDE_ENV[@]}"
  run_plugin_checks "$LOCAL_MODEL" "${LOCAL_CLAUDE_ENV[@]}"
fi

# ---------------------------------------------------------------------------------------------------------------
# 6. Your index untouched, the summary and the exit status.
finish_run "$INDEX_BEFORE"
