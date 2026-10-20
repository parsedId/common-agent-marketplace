#!/usr/bin/env bash
# test-backend-copilot.sh - runs the copilot adapter against the REAL Copilot
# CLI on herdr: the adapter's screen needles against real screens, then one
# real `chief-spawn.sh --agent copilot --mode researcher` through teardown.
#
# NOT zero-cost: one trivial research turn (the spawned worker's brief).
# Opt in explicitly:
#
#   CHIEF_TEST_COPILOT=1 bash tests/chief/test-backend-copilot.sh
#
# Skips cleanly (exit 0) without the opt-in, herdr, copilot, jq, ss or a copilot
# login (~/.copilot/config.json, or $COPILOT_HOME/config.json).
#
# It never touches the caller's herdr: everything runs in a scrubbed
# environment with its own HOME/XDG dirs and its own herdr server and socket.
# It aborts, before any herdr client call or copilot run, unless that
# isolation is proven (see isolation_guard). Only the login file is copied
# into the temp HOME, and removed again on EXIT/INT/TERM/HUP.
#
# CHIEF_TEST_COPILOT_GUARD_ONLY=1 runs the isolation guard alone and prints it.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
CHIEF_BIN="$REPO_ROOT/plugins/chief/bin"
. "$TEST_DIR/lib/harness.sh"

echo "test-backend-copilot:"

if [ "${CHIEF_TEST_COPILOT:-0}" != "1" ]; then
  echo "  (skipped - opt in with CHIEF_TEST_COPILOT=1; spends real Copilot requests and needs herdr)"
  exit 0
fi
. "$TEST_DIR/lib/copilot-isolation.sh"


REPO="$ISO/repo"; PROBE="$ISO/probe-repo"
for r in "$REPO" "$PROBE"; do
  mkdir -p "$r"
  git -C "$r" init -q -b main
  git -C "$r" commit -q --allow-empty -m init
done

# The login, plus trust for the spawn repo only (copilot trusts by repo root);
# the probe repo stays untrusted so its trust dialog shows.
mkdir -p "$HOME/.copilot"
( umask 077
  grep -v '^[[:space:]]*//' "$LOGIN_SRC" | jq --arg r "$REPO" '. + {trustedFolders: [$r]}' > "$HOME/.copilot/config.json" ) \
  || { echo "  [FAIL] could not prepare the copilot login"; exit 1; }

export CHIEF_HOME="$ISO/chief" CHIEF_BACKEND=herdr
. "$CHIEF_BIN/lib/paths.sh"
. "$CHIEF_BIN/lib/meta.sh"
. "$CHIEF_BIN/lib/backends/backend.sh"
chief_agent_load copilot

screen() { herdr agent read "$1" --source recent-unwrapped --lines 40 2>/dev/null; }
shows_ready() { grep -Eq -- "$(agent_ready_text)"; }
shows_quota() { grep -qiE 'rate limit|quota|upgrade|usage limit|premium request'; }

# collect_until <agent> <regex> <timeout-s> <dir> - saves each distinct screen as
# <dir>/N.txt (N in SHOTS) until one matches <regex> (collapsed whitespace)
collect_until() {
  local agent=$1 re=$2 limit=$(( $3 * 10 )) dir=$4 last="" s i
  SHOTS=0
  mkdir -p "$dir"
  for i in $(seq 1 "$limit"); do
    s=$(screen "$agent")
    if [ "$s" != "$last" ]; then SHOTS=$((SHOTS + 1)); printf '%s\n' "$s" > "$dir/$SHOTS.txt"; last=$s; fi
    printf '%s' "$s" | tr -s '[:space:]' ' ' | grep -Eq -- "$re" && return 0
    sleep 0.1
  done
  return 1
}
ready_screens() {  # <dir> <last-n> -> how many of screens 1..<last-n> show the ready text
  local n=0 i
  for i in $(seq 1 "$2"); do shows_ready < "$1/$i.txt" && n=$((n + 1)); done
  echo "$n"
}

# --- needles against the real screens (no model turn) -----------------------

PANE=$(herdr worktree create --cwd "$PROBE" --branch probe --path "$ISO/probe-wt" --label probe \
         --trust-repository --no-focus | jq -r '.result.root_pane.pane_id // empty')
[ -n "$PANE" ] || { echo "  [FAIL] could not open the probe pane"; exit 1; }
cmd=$(agent_command)
herdr agent start probe --kind "$(agent_name)" --pane "$PANE" --timeout 30000 -- ${cmd#* } >/dev/null 2>&1 || true

collect_until probe "$(agent_trust_text)" 30 "$ISO/shots-trust"
assert_eq "$?" "0" "the real folder-trust dialog matches agent_trust_text"
assert_eq "$(ready_screens "$ISO/shots-trust" "$SHOTS")" "0" "ready text matches none of the $SHOTS banner/trust screens before ready"

herdr agent send-keys probe enter >/dev/null 2>&1
collect_until probe "$(agent_ready_text)" 30 "$ISO/shots-ready"
assert_eq "$?" "0" "the real idle footer matches agent_ready_text"
assert_contains "$(cat "$ISO/shots-ready/$SHOTS.txt")" "Allow All" "the idle footer shows 'Allow All'"
assert_eq "$(ready_screens "$ISO/shots-ready" $((SHOTS - 1)))" "0" "ready text matches none of the $((SHOTS - 1)) screens before the idle footer"
assert_contains "$(chief_agent_input_line < "$ISO/shots-ready/$SHOTS.txt")" "❯" "the empty input line starts with agent_input_marker"

# A bracketed paste of 20 lines of /help: copilot shows its paste placeholder; if
# it did not take the paste, /help is a local command, not a model turn.
LONG=$(for _ in $(seq 1 20); do echo "/help"; done)
herdr pane send-text "$PANE" "$(printf '\033[200~%s\033[201~' "$LONG")" >/dev/null 2>&1
sleep 2
PASTED=$(screen probe)
assert_success "agent_paste_text matches the real paste placeholder" -- bash -c "printf '%s' \"\$1\" | tr -s '[:space:]' ' ' | grep -Eq -- \"\$2\"" _ "$PASTED" "$(agent_paste_text)"
assert_contains "$(printf '%s\n' "$PASTED" | chief_agent_input_line)" "[Paste #" "the placeholder sits on the input line found by agent_input_marker"
herdr workspace close "${PANE%%:*}" >/dev/null 2>&1 || true

# --- a real researcher spawn: ready, brief, finished with a status and a report

ID=t-copilot-1
INTENT="Test run. Write the single word ok into the report file and report done. Do nothing else."
SPAWN_OUT=$(bash "$CHIEF_BIN/chief-spawn.sh" "$ID" "$REPO" --agent copilot --mode researcher \
              --branch "research/$ID" --intent "$INTENT" 2>"$ISO/spawn.err")
SPAWN_RC=$?
assert_eq "$SPAWN_RC" "0" "chief-spawn.sh --agent copilot reaches ready and gets its brief"
if [ "$SPAWN_RC" != 0 ]; then
  sed 's/^/    /' "$ISO/spawn.err"
else
  assert_contains "$SPAWN_OUT" "spawned: $ID" "chief-spawn.sh reports the spawn"
  assert_eq "$(chief_meta_get "$ID" agent)" "copilot" "the task runs the copilot adapter"

  STATUS=$(chief_task_path "$ID" status) REPORT=$(chief_task_path "$ID" report.md) FINISHED=0
  for i in $(seq 1 120); do
    case $(tail -n1 "$STATUS" 2>/dev/null) in done:*|failed:*|blocked:*|needs-decision:*) FINISHED=1; break ;; esac
    if [ $((i % 5)) = 0 ] && screen "$ID" | shows_quota; then
      echo "  [FAIL] copilot shows a rate/quota message - stopped without retrying"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      break
    fi
    sleep 2
  done
  assert_eq "$FINISHED" "1" "the worker finishes with a status line"
  assert_contains "$(tail -n1 "$STATUS" 2>/dev/null)" "done:" "the last status line is done:"
  [ -s "$REPORT" ]
  assert_eq "$?" "0" "the worker wrote its report"
fi

bash "$CHIEF_BIN/chief-teardown.sh" "$ID" >/dev/null 2>&1
assert_eq "$?" "0" "chief-teardown.sh discards the copilot task"
assert_file_missing "$WORKTREES/$ID" "teardown removes the worktree"
assert_eq "$(herdr workspace list | jq -r --arg id "$ID" '[.result.workspaces[]? | select(.label | startswith($id))] | length')" "0" "teardown closes the task's workspace"

harness_summary
