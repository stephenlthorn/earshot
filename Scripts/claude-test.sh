#!/bin/zsh
# Scripts/claude-test.sh: the Claude subscription checks (spec 18), run by `make claude-test`.
# Every check makes real calls through your own signed-in Claude Code and prints PASS or FAIL with evidence:
#   (a) to (j)  the gated Swift suite ClaudeLiveTests (EARSHOT_CLAUDE_TESTS=1)
#   (k)         earshot process on a meeting spoken by `say`
#   (l)         the MCP server through claude -p --mcp-config, including a planted instruction
#   (m)         both plugins through --plugin-dir
# Only temporary folders are used: a meetings folder and an index of its own for each check, never your meetings,
# your index, your lessons or your Earshot settings ((k) reads an empty settings domain, so it runs with Earshot's
# defaults: Claude Code, the default notes model and style, no extra instructions). Claude runs get an allowlist
# environment and skip your user settings (--setting-sources project in an empty folder), so your hooks, plugins and
# permission rules don't apply.
# Set EARSHOT_BUILD_LOCK to a lock file to run the builds under /usr/bin/lockf.
set -uo pipefail
REPO=${0:A:h:h}
KIT=$REPO/Packages/EarshotKit
FIXTURES=$KIT/Tests/Fixtures/claude
WORK=$(mktemp -d "${TMPDIR:-/tmp}/earshot-claude-test.XXXXXX")
RESULTS=$WORK/results.txt
: > "$RESULTS"

source "$REPO/Scripts/claude-checks.zsh"

CLAUDE=$(find_claude)
[[ -x ${CLAUDE:-} ]] || { print "FAIL: Claude Code not found"; exit 1; }
clean_env "$CLAUDE"

# Signed in with a Claude plan, checked the way Earshot does (free, no model call). Without it every check fails the
# same way, so stop with one clear line.
AUTH=$(env -i "${CLEAN_ENV[@]}" "$CLAUDE" auth status 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("authMethod") or "none")
except Exception: print("unknown")')
if [[ $AUTH != claude.ai ]]; then
  print "FAIL (preflight) Claude Code is not signed in with a Claude plan (authMethod: $AUTH): run claude in Terminal and log in, then run make claude-test again."
  rm -rf "$WORK"
  exit 1
fi

INDEX_BEFORE=$(index_snapshot)

print "== Claude Code: $($CLAUDE --version 2>/dev/null) at $CLAUDE"
print "== Work folder: $WORK"
build_kit

# ---------------------------------------------------------------------------------------------------------------
print "\n== (a) to (j): ClaudeLiveTests"
# In a process group of its own, so the 40-minute guard stops the test runners and any claude -p they started too.
perl "$REPO/Scripts/group-timeout.pl" 2400 env EARSHOT_CLAUDE_TESTS=1 swift test --package-path "$KIT" --skip-build \
  --filter ClaudeLiveTests > "$WORK/swift.log" 2>&1
swift_verdicts "$WORK/swift.log" a exactStructuredCallReturnsStructuredOutput b bogusKeyInTheParentEnvironmentNeverReachesClaude \
  c notesFindAshleysProposalByFriday d notesNeverGuessWhichExternalAttendeeSpoke \
  e notesLinkARewordedStartedItemThroughLiveRef f liveExtractionAcrossStagesUpdatesByRef g briefFromFixtureHistory \
  h askAnswersWithATime i fixAppliesTheInstruction j restrictedDoTargetWritesInsideAndIsDeniedOutside

# ---------------------------------------------------------------------------------------------------------------
print "\n== (k) earshot process on a meeting spoken by say"
K=$WORK/k
mkdir -p "$K/meetings" "$K/index" "$K/settings"
# A settings domain nothing ever wrote gives Earshot's defaults.
run_process_check "$K/settings/defaults"

# ---------------------------------------------------------------------------------------------------------------
run_mcp_checks sonnet

# ---------------------------------------------------------------------------------------------------------------
run_plugin_checks sonnet

# ---------------------------------------------------------------------------------------------------------------
finish_run "$INDEX_BEFORE"
