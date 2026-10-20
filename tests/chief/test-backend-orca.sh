#!/usr/bin/env bash
# test-backend-orca.sh - exercises orca.sh's adapter functions, then the real
# chief-spawn/send/control/crew-state/teardown scripts end to end, against a
# REAL live Orca instance and real (minimal) claude turns, on a throwaway scratch
# repo (like test-backend-herdr.sh) that backend_spawn registers with Orca
# itself; only that registration is removed again, never any other.
#
# NOT zero-cost: needs `orca` on PATH talking to a live Orca runtime, and
# spends a small number of real tokens on a few trivial claude turns. Opt in:
#
#   CHIEF_TEST_ORCA=1 bash tests/chief/test-backend-orca.sh
#
# Skips cleanly (no opt-in, no orca, no live runtime) so it's safe for
# run-tests.sh's default sweep.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
CHIEF_BIN="$REPO_ROOT/plugins/chief/bin"
. "$TEST_DIR/lib/harness.sh"

echo "test-backend-orca:"

if [ "${CHIEF_TEST_ORCA:-0}" != "1" ]; then
  echo "  (skipped - opt in with CHIEF_TEST_ORCA=1; spends real tokens and needs a live orca)"
  exit 0
fi

if ! command -v orca >/dev/null 2>&1; then
  echo "  (skipped - orca not on PATH)"
  exit 0
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "  (skipped - claude CLI not on PATH)"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "  (skipped - jq not on PATH, required by backends/orca.sh)"
  exit 0
fi

if ! orca status --json 2>/dev/null | jq -e '.ok == true' >/dev/null 2>&1; then
  echo "  (skipped - no reachable orca runtime; run 'orca open' or 'orca serve' first)"
  exit 0
fi

WORK=$(mktemp -d)
ID="chief-test-orca-$$"
ID2="$ID-b"
BRANCH="chief/$ID"
PROJECT="$WORK/chief-test-orca-proj-$$"
mkdir -p "$PROJECT" && git -C "$PROJECT" init -q -b main \
  && git -C "$PROJECT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# backend_spawn/backend_relaunch only wait for the first prompt to be accepted,
# not the turn to finish - poll backend_busy before asserting on the reply.
wait_for_idle() {  # <id> [timeout-s]
  local id=$1 timeout=${2:-60} waited=0
  while [ "$waited" -lt "$timeout" ]; do
    backend_busy "$id" || return 0
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}
wait_capture() {  # <id> <text> [timeout-s] - the task's screen shows <text> (a transient hint can cover it briefly)
  local id=$1 text=$2 timeout=${3:-20} waited=0
  while [ "$waited" -lt "$timeout" ]; do
    capture "$id" | grep -qF -- "$text" && return 0
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}
_orca_has_worktree() {  # <path> -> exit 0 if Orca still lists it
  orca worktree list --repo "path:$PROJECT" --json 2>/dev/null \
    | jq -e --arg p "$1" '[.result.worktrees[]? | select(.path == $p)] | length > 0' >/dev/null
}
_repo_id() {  # -> the scratch project's Orca repo id, empty if unregistered
  orca repo list --json 2>/dev/null \
    | jq -r --arg p "$PROJECT" '.result.repos[]? | select(.path == $p) | .id'
}
_main_wt() {  # -> the project's main worktree row
  orca worktree list --repo "path:$PROJECT" --json 2>/dev/null \
    | jq -c '.result.worktrees[]? | select(.isMainWorktree == true)'
}
_child_count() {  # -> number of worktrees nested under the project's main worktree
  _main_wt | jq -r '.childWorktreeIds | length'
}
_parent_is_main() {  # <worktree-path> -> exit 0 if its parent is the project's main worktree
  local main_id
  main_id=$(_main_wt | jq -r '.id')
  orca worktree list --repo "path:$PROJECT" --json 2>/dev/null \
    | jq -e --arg p "$1" --arg m "$main_id" '[.result.worktrees[]? | select(.path == $p and .parentWorktreeId == $m)] | length == 1' >/dev/null
}
_repo_snapshot() {  # -> every registered repo as "<id> <path>", sorted
  orca repo list --json 2>/dev/null | jq -r '.result.repos[]? | "\(.id) \(.path)"' | sort
}
ORCA_WORKSPACES="${ORCA_WORKSPACES:-$HOME/orca/workspaces}"
ORCA_DATA=$(ls "$HOME"/.config/orca/profiles/*/orca-data.json 2>/dev/null | head -n1)
SCRATCH_WS="$ORCA_WORKSPACES/$(basename "$PROJECT")"

# Everything Orca knows, as one comparable text: repos, every repo's worktrees,
# terminals, projects, project setups and the workspaces dir tree.
orca_snapshot() {
  echo "## repos"; _repo_snapshot
  echo "## worktrees"
  orca repo list --json 2>/dev/null | jq -r '.result.repos[]?.path' | sort | while read -r repo; do
    orca worktree list --repo "path:$repo" --json 2>/dev/null \
      | jq -r --arg r "$repo" '.result.worktrees[]? | "\($r) \(.path) \(.branch)"'
  done | sort
  echo "## terminals"
  orca terminal list --json 2>/dev/null | jq -r '.result.terminals[]? | "\(.handle) \(.worktreePath)"' | sort
  echo "## projects"
  orca project list --json 2>/dev/null | jq -r '.result.projects[]? | "\(.id) \(.displayName)"' | sort
  echo "## project setups"
  orca project setups --json 2>/dev/null | jq -r '.result.setups[]? | "\(.id) \(.path)"' | sort
  echo "## workspaces dir"
  ( cd "$ORCA_WORKSPACES" 2>/dev/null && find . | sort )
}
_data_refs() {  # -> how many lines of orca-data.json mention this run's scratch repo/worktrees
  [ -n "$ORCA_DATA" ] || { echo 0; return; }
  grep -cF -e "$(basename "$PROJECT")" -e "$ID" "$ORCA_DATA"
}

SWEPT_WORKTREES=()
SNAP_BEFORE=$(orca_snapshot)
[ -z "$(_repo_id)" ] && SCRATCH_OURS=1

# Orca's claude hook leaves /tmp/orca-claude-statusline-last-<leafId> per pane
# and never removes it; remember the leaf ids of this run's own terminals
# (taken from `terminal show`) so exactly those files can be removed.
record_leaves() {  # <worktree-path>
  local handle
  orca terminal list --worktree "path:$1" --json 2>/dev/null | jq -r '.result.terminals[]?.handle' \
    | while read -r handle; do
        orca terminal show --terminal "$handle" --json 2>/dev/null | jq -r '.result.terminal.leafId // empty'
      done >> "$WORK/leaves"
}

# Orca-side cleanup, idempotent. Touches only the scratch repo this run
# registered (exact path under $WORK, absent from the registry before spawn):
# every non-main worktree in it was made by this run, and the repo is removed
# through the supported CLI only.
cleanup_orca() {
  local wt repo_id
  [ "${ORCA_CLEANED:-0}" = 1 ] && return 0
  ORCA_CLEANED=1
  [ "${SCRATCH_OURS:-0}" = 1 ] || return 0
  case "$PROJECT" in "$WORK"/*) ;; *) return 0 ;; esac
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    SWEPT_WORKTREES+=("$wt")
    record_leaves "$wt"
    orca terminal close --worktree "path:$wt" --all >/dev/null 2>&1 || true
    orca worktree rm --worktree "path:$wt" --force >/dev/null 2>&1 || true
  done < <(orca worktree list --repo "path:$PROJECT" --json 2>/dev/null \
             | jq -r '.result.worktrees[]? | select(.isMainWorktree != true) | .path')
  repo_id=$(_repo_id)
  [ -n "$repo_id" ] && { orca project setup-delete --setup "$repo_id" >/dev/null 2>&1 || true; }
  rmdir "$SCRATCH_WS/.orca-worktree-trash" "$SCRATCH_WS" 2>/dev/null || true
}
# Claude keeps a transcript dir (and per-session env dirs) per cwd; remove the
# ones for this run's own worktree paths and sessions only, plus the statusline
# files recorded above.
cleanup_claude() {
  local wt dir f leaf
  for wt in "${WORKTREE:-}" "${WORKTREE2:-}" "${E2E_WT:-}" "${SWEPT_WORKTREES[@]}"; do
    case "$wt" in "$SCRATCH_WS"/*) ;; *) continue ;; esac
    dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf '%s' "$wt" | sed 's/[^A-Za-z0-9]/-/g')"
    for f in "$dir"/*.jsonl; do
      [ -e "$f" ] && rm -rf "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/$(basename "$f" .jsonl)"
    done
    rm -rf "$dir"
  done
  [ -f "$WORK/leaves" ] && while read -r leaf; do
    [ -n "$leaf" ] && rm -f "/tmp/orca-claude-statusline-last-$leaf"
  done < "$WORK/leaves"
  return 0
}
cleanup() {
  if declare -F chief_agent_release >/dev/null; then
    chief_agent_release "$ID" "${WORKTREE:-}" 2>/dev/null
    chief_agent_release "$ID2" "${WORKTREE2:-}" 2>/dev/null
  fi
  cleanup_orca
  cleanup_claude
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

export CHIEF_HOME="$WORK/.chief"
. "$CHIEF_BIN/lib/paths.sh"
chief_ensure_dirs
. "$CHIEF_BIN/lib/meta.sh"
. "$CHIEF_BIN/lib/agents/agent.sh"
. "$CHIEF_BIN/lib/backends/orca.sh"
capture() { _chief_orca_screen "$(_chief_orca_handle "$1")"; }

BRIEF="$WORK/brief.md"
printf 'Reply with exactly the single word: ok\n' > "$BRIEF"

chief_meta_set "$ID" agent claude
SPAWN_OUTPUT=$(backend_spawn "$ID" "$PROJECT" "$BRIEF" "$BRANCH" 2>"$WORK/spawn.err")
SPAWN_RC=$?
assert_eq "$SPAWN_RC" "0" "backend_spawn succeeds"
[ "$SPAWN_RC" = "0" ] || cat "$WORK/spawn.err"

WORKTREE=$(printf '%s\n' "$SPAWN_OUTPUT" | sed -n 1p)
ENDPOINT=$(printf '%s\n' "$SPAWN_OUTPUT" | sed -n 2p)

[ -n "$WORKTREE" ]
assert_eq "$?" "0" "backend_spawn printed a non-empty worktree path"
assert_contains "$ENDPOINT" "orca:" "backend_spawn prints an orca: endpoint second"
record_leaves "$WORKTREE"
assert_file_exists "$WORKTREE/.git" "backend_spawn actually created the git worktree (via orca)"
assert_eq "$(orca terminal list --worktree "path:$WORKTREE" --json 2>/dev/null | jq -r '[.result.terminals[]?] | length')" "1" \
  "backend_spawn leaves the worktree with just the agent's terminal (no fallback shell)"

[ -n "$(_repo_id)" ]
assert_eq "$?" "0" "backend_spawn registered the unregistered scratch project with Orca"
assert_eq "$(_child_count)" "1" "the task is nested under the project's main worktree"
_parent_is_main "$WORKTREE"
assert_eq "$?" "0" "the task worktree's parent is the project's main worktree"

chief_meta_set "$ID" endpoint "$ENDPOINT"
chief_meta_set "$ID" worktree "$WORKTREE"
chief_meta_set "$ID" project "$PROJECT"

CURRENT_BRANCH=$(git -C "$WORKTREE" rev-parse --abbrev-ref HEAD 2>/dev/null)
assert_eq "$CURRENT_BRANCH" "$BRANCH" "the worktree is on the exact chief/<id> branch, renamed from Orca's own"

wait_for_idle "$ID"
CAPTURE=$(capture "$ID")
assert_contains "$CAPTURE" "ok" "the pane shows the claude reply"
wait_capture "$ID" "bypass permissions"
assert_eq "$?" "0" "backend_spawn starts the worker with bypass permissions on"

backend_busy "$ID"
assert_eq "$?" "1" "backend_busy reports idle (not busy) once the reply is done"

assert_success "backend_send delivers a special key without erroring" -- backend_send "$ID" Escape

backend_kill "$ID"
assert_eq "$?" "0" "backend_kill exits cleanly"
assert_file_exists "$WORKTREE/.git" "backend_kill does not touch the worktree"
assert_eq "$(orca terminal list --worktree "path:$WORKTREE" --json 2>/dev/null | jq -r '[.result.terminals[]?] | length')" "0" \
  "backend_kill closes every terminal in the task's worktree"

BRIEF2="$WORK/brief2.md"
printf 'Reply with exactly the single word: ok\n' > "$BRIEF2"
backend_relaunch "$ID" "$BRIEF2" 2>"$WORK/relaunch.err"
RELAUNCH_RC=$?
assert_eq "$RELAUNCH_RC" "0" "backend_relaunch succeeds in the same worktree"
[ "$RELAUNCH_RC" = "0" ] || cat "$WORK/relaunch.err"

record_leaves "$WORKTREE"
NEW_ENDPOINT=$(chief_meta_get "$ID" endpoint)
assert_contains "$NEW_ENDPOINT" "orca:" "backend_relaunch records a fresh orca endpoint"
[ "$NEW_ENDPOINT" != "$ENDPOINT" ]
assert_eq "$?" "0" "backend_relaunch's endpoint differs from the original terminal"

wait_for_idle "$ID"
RELAUNCH_CAPTURE=$(capture "$ID")
assert_contains "$RELAUNCH_CAPTURE" "ok" "the pane shows the relaunched claude's reply"

backend_kill "$ID"

# A second task is a second child of the same main worktree and registers the
# project only once; rolling it back leaves the first alone.
printf 'Reply with exactly the single word: ok\n' > "$WORK/brief3.md"
REPO_ID=$(_repo_id)
chief_meta_set "$ID2" agent claude
SPAWN2=$(backend_spawn "$ID2" "$PROJECT" "$WORK/brief3.md" "chief/$ID2" 2>/dev/null)
WORKTREE2=$(printf '%s\n' "$SPAWN2" | sed -n 1p)
record_leaves "$WORKTREE2"
assert_file_exists "$WORKTREE2/.git" "a second spawn created its worktree"
assert_eq "$(_child_count)" "2" "two tasks are two children of the main worktree"
assert_eq "$(_repo_id)" "$REPO_ID" "the project stays registered once"
backend_spawn_cleanup "$ID2" "$PROJECT" "chief/$ID2"
_orca_has_worktree "$WORKTREE2"
assert_eq "$?" "1" "backend_spawn_cleanup removes the worktree from 'orca worktree list'"
assert_file_missing "$WORKTREE2" "backend_spawn_cleanup removes the worktree from disk"
git -C "$PROJECT" show-ref --verify --quiet "refs/heads/chief/$ID2"
assert_eq "$?" "1" "backend_spawn_cleanup deletes the task's branch"
assert_eq "$(_child_count)" "1" "rolling back the second task leaves the first nested"
_parent_is_main "$WORKTREE"
assert_eq "$?" "0" "the first task is still nested under the main worktree"

backend_teardown "$ID" "$PROJECT" "$WORKTREE"
_orca_has_worktree "$WORKTREE"
assert_eq "$?" "1" "backend_teardown leaves no stale worktree entry in 'orca worktree list'"
assert_eq "$(_child_count)" "0" "no task remains nested under the main worktree"

# --- end to end: the real lifecycle scripts on this backend ---------------
# A researcher, so teardown needs no landed branch. A real claude turn, driven only
# through chief-spawn / chief-send / chief-control / chief-crew-state /
# chief-teardown.
export CHIEF_BACKEND=orca
E2E="chief-test-e2e-$$"
E2E_BRANCH="feat/$E2E"
E2E_STATUS="$TASKS/$E2E/status"
wait_for_status() {  # <prefix> [timeout-s] - the task's last status line starts with <prefix>
  local waited=0 timeout=${2:-180}
  while [ "$waited" -lt "$timeout" ]; do
    tail -n1 "$E2E_STATUS" 2>/dev/null | grep -q "^$1" && return 0
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

timeout 240 "$CHIEF_BIN/chief-spawn.sh" "$E2E" "$PROJECT" --mode researcher --branch "$E2E_BRANCH" \
  --intent "Reply with exactly the single word: ok. Also write that word into the report file, then finish with a done status line." \
  >"$WORK/e2e-spawn.out" 2>&1
E2E_RC=$?
assert_eq "$E2E_RC" "0" "chief-spawn.sh succeeds on the orca backend"
[ "$E2E_RC" = "0" ] || cat "$WORK/e2e-spawn.out"
E2E_WT=$(chief_meta_get "$E2E" worktree)
E2E_EP=$(chief_meta_get "$E2E" endpoint)
record_leaves "$E2E_WT"
assert_eq "$(chief_meta_get "$E2E" status)" "working" "chief-spawn.sh marks the task working"
assert_contains "$E2E_EP" "orca:" "chief-spawn.sh records an orca endpoint"
assert_eq "$(git -C "$E2E_WT" rev-parse --abbrev-ref HEAD)" "$E2E_BRANCH" "the task worktree is on the requested branch"
_parent_is_main "$E2E_WT"
assert_eq "$?" "0" "the task is nested under the project's main worktree"
assert_eq "$(_child_count)" "1" "the main worktree has exactly the one task under it"

wait_for_status "done" 180
assert_eq "$?" "0" "the builder reports done through its status file"
wait_for_idle "$E2E"
assert_contains "$(capture "$E2E")" "ok" "the pane shows the builder's real reply"
wait_capture "$E2E" "bypass permissions"
assert_eq "$?" "0" "the builder runs in bypass-permissions mode"
assert_contains "$("$CHIEF_BIN/task/chief-crew-state.sh" "$E2E" 2>&1)" "state: done" "chief-crew-state.sh reports done"

"$CHIEF_BIN/task/chief-send.sh" "$E2E" "no action needed, just reply ok" >"$WORK/e2e-send.out" 2>&1
assert_eq "$?" "0" "chief-send.sh succeeds"
assert_file_exists "$TASKS/$E2E/inbox/001.msg" "chief-send.sh writes the durable inbox message"

"$CHIEF_BIN/task/chief-control.sh" "$E2E" interrupt >/dev/null 2>&1
assert_eq "$?" "0" "chief-control.sh interrupt succeeds"
assert_eq "$(chief_meta_get "$E2E" endpoint)" "$E2E_EP" "interrupt keeps the same terminal"

timeout 240 "$CHIEF_BIN/task/chief-control.sh" "$E2E" relaunch --note "e2e relaunch" >"$WORK/e2e-relaunch.out" 2>&1
RELAUNCH_RC=$?
assert_eq "$RELAUNCH_RC" "0" "chief-control.sh relaunch succeeds"
[ "$RELAUNCH_RC" = "0" ] || cat "$WORK/e2e-relaunch.out"
record_leaves "$E2E_WT"
[ "$(chief_meta_get "$E2E" endpoint)" != "$E2E_EP" ]
assert_eq "$?" "0" "relaunch records a fresh terminal"
assert_eq "$(_child_count)" "1" "relaunch keeps the one task nested under the main worktree"
wait_for_idle "$E2E"
wait_capture "$E2E" "bypass permissions"
assert_eq "$?" "0" "the relaunched builder runs in bypass-permissions mode"

"$CHIEF_BIN/chief-teardown.sh" "$E2E" >"$WORK/e2e-teardown.out" 2>&1
assert_eq "$?" "0" "chief-teardown.sh succeeds"
assert_eq "$(chief_meta_get "$E2E" status)" "torn-down" "teardown marks the task torn down"
assert_file_missing "$E2E_WT" "teardown removes the worktree"
_orca_has_worktree "$E2E_WT"
assert_eq "$?" "1" "teardown leaves no worktree entry in 'orca worktree list'"
assert_eq "$(_child_count)" "0" "no task remains nested under the main worktree"
git -C "$PROJECT" show-ref --verify --quiet "refs/heads/$E2E_BRANCH"
assert_eq "$?" "1" "teardown deletes the task's branch"

cleanup_orca
cleanup_claude
SNAP_AFTER=$(orca_snapshot)
assert_eq "$SNAP_AFTER" "$SNAP_BEFORE" "Orca's repos, worktrees, terminals, projects, setups and workspaces dir are identical before and after the run"
[ "$SNAP_AFTER" = "$SNAP_BEFORE" ] || diff <(echo "$SNAP_BEFORE") <(echo "$SNAP_AFTER")
for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(_data_refs)" = 0 ] && break; sleep 1; done
assert_eq "$(_data_refs)" "0" "orca-data.json holds no entry for the scratch repo or this run's worktrees"
STATUSLINE_LEFT=0
while read -r leaf; do
  [ -n "$leaf" ] && [ -e "/tmp/orca-claude-statusline-last-$leaf" ] && STATUSLINE_LEFT=$((STATUSLINE_LEFT + 1))
done < "$WORK/leaves"
assert_eq "$STATUSLINE_LEFT" "0" "no /tmp/orca-claude-statusline-last-* file from this run's panes is left behind"

harness_summary
