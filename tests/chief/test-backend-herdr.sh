#!/usr/bin/env bash
# test-backend-herdr.sh - exercises herdr.sh's five adapter
# functions against a REAL herdr install and a real (minimal) claude turn.
#
# Unlike every other file in this directory, this one is NOT zero-cost: it
# needs `herdr` on PATH, a headless herdr server, and spends a small number
# of real tokens on one trivial claude prompt ("reply with exactly: ok").
# Opt in explicitly:
#
#   CHIEF_TEST_HERDR=1 bash tests/chief/test-backend-herdr.sh
#
# Skips cleanly (exit 0) if herdr isn't installed or the opt-in isn't set,
# so it's safe for run-tests.sh's default sweep and outside the devcontainer.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
CHIEF_BIN="$REPO_ROOT/plugins/chief/bin"
. "$TEST_DIR/lib/harness.sh"

echo "test-backend-herdr:"

if [ "${CHIEF_TEST_HERDR:-0}" != "1" ]; then
  echo "  (skipped - opt in with CHIEF_TEST_HERDR=1; spends real tokens and needs herdr)"
  exit 0
fi

if ! command -v herdr >/dev/null 2>&1; then
  echo "  (skipped - herdr not on PATH)"
  exit 0
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "  (skipped - claude CLI not on PATH)"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "  (skipped - jq not on PATH, required by backends/herdr.sh)"
  exit 0
fi

# herdr's server is a per-machine singleton (one socket under
# ~/.config/herdr/) - reuse one that's already running, only start (and
# later stop) our own if none is.
STARTED_SERVER=0
if ! herdr status --json 2>/dev/null | grep -q '"running":true'; then
  nohup herdr server >/tmp/chief-test-herdr-server.log 2>&1 < /dev/null &
  disown
  STARTED_SERVER=1
  for _ in $(seq 1 20); do
    herdr status --json 2>/dev/null | grep -q '"running":true' && break
    sleep 0.5
  done
fi
herdr status --json 2>/dev/null | grep -q '"running":true' \
  || { echo "  [FAIL] could not start a herdr server"; harness_summary; exit 1; }

WORK=$(mktemp -d)
ID=t-herdr-1

# backend_spawn/backend_relaunch only wait for the first turn to START, not
# finish (see herdr.sh's own header) - poll backend_busy before asserting
# on the reply so a trivial task's own completion time isn't a race.
wait_for_idle() {  # <id> [timeout-s]
  local id=$1 timeout=${2:-30} waited=0
  while [ "$waited" -lt "$timeout" ]; do
    backend_busy "$id" || return 0
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}
_ws_count_for_root() {  # <repo-root> -> number of herdr workspaces open for it
  herdr workspace list 2>/dev/null \
    | jq -r --arg root "$1" '[.result.workspaces[]? | select(.worktree.repo_root == $root)] | length'
}
_linked_ws_count() {  # <repo-root> -> number of linked-worktree workspaces open for it
  herdr workspace list 2>/dev/null \
    | jq -r --arg root "$1" '[.result.workspaces[]? | select(.worktree.repo_root == $root and .worktree.is_linked_worktree == true)] | length'
}
_primary_ws() {  # <repo-root> -> its non-linked (primary) workspace id
  herdr workspace list 2>/dev/null \
    | jq -r --arg root "$1" '.result.workspaces[]? | select(.worktree.repo_root == $root and .worktree.is_linked_worktree == false) | .workspace_id'
}
_ws_label() {  # <workspace-id> -> its label
  herdr workspace list 2>/dev/null \
    | jq -r --arg id "$1" '.result.workspaces[]? | select(.workspace_id == $id) | .label'
}
_ws_exists() {  # <workspace-id> -> the id again if still open, else empty
  herdr workspace list 2>/dev/null \
    | jq -r --arg id "$1" '.result.workspaces[]? | select(.workspace_id == $id) | .workspace_id'
}
cleanup() {
  if declare -F chief_agent_release >/dev/null; then
    chief_agent_release "$ID" "$WORK/.chief/worktrees/$ID" 2>/dev/null
    chief_agent_release "${ID2:-}" "$WORK/.chief/worktrees/${ID2:-}" 2>/dev/null
  fi
  # Safety net independent of how far the test got: close every workspace
  # this run could have produced, even if backend_spawn/relaunch failed
  # partway through and left one open without ever reporting it. Covers
  # both our own task-labeled linked-worktree workspaces AND the
  # separate auto-created "primary" workspace `herdr worktree create` opens
  # for the scratch project checkout itself (repo_root match).
  herdr workspace list 2>/dev/null \
    | jq -r --arg label "$ID" --arg work "$WORK" \
        '.result.workspaces[]? | select((.label | startswith($label)) or (.worktree.repo_root // "" | startswith($work))) | .workspace_id' 2>/dev/null \
    | while read -r ws; do herdr workspace close "$ws" --group >/dev/null 2>&1 || true; done
  [ "$STARTED_SERVER" = 1 ] && herdr server stop >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/project" && cd "$WORK/project"
git init -q -b main
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

export CHIEF_HOME="$WORK/.chief"
. "$CHIEF_BIN/lib/paths.sh"
chief_ensure_dirs
. "$CHIEF_BIN/lib/meta.sh"
. "$CHIEF_BIN/lib/agents/agent.sh"
. "$CHIEF_BIN/lib/backends/herdr.sh"
capture() { herdr agent read "$1" --source recent-unwrapped --lines 200 2>/dev/null; }

BRIEF="$WORK/brief.md"
printf 'Reply with exactly the single word: ok\n' > "$BRIEF"

chief_meta_set "$ID" mode builder
chief_meta_set "$ID" project "$WORK/project"
chief_meta_set "$ID" agent claude
SPAWN_OUTPUT=$(backend_spawn "$ID" "$WORK/project" "$BRIEF" "chief/$ID" 2>"$WORK/spawn.err")
SPAWN_RC=$?
assert_eq "$SPAWN_RC" "0" "backend_spawn succeeds (pre-trusts the worktree, then delivers the brief)"
[ "$SPAWN_RC" = "0" ] || cat "$WORK/spawn.err"

WORKTREE=$(printf '%s\n' "$SPAWN_OUTPUT" | sed -n 1p)
ENDPOINT=$(printf '%s\n' "$SPAWN_OUTPUT" | sed -n 2p)

assert_eq "$WORKTREE" "$WORK/.chief/worktrees/$ID" "backend_spawn prints the worktree path first"
assert_contains "$ENDPOINT" "herdr:" "backend_spawn prints a herdr: endpoint second"
assert_file_exists "$WORKTREE/.git" "backend_spawn actually created the git worktree"

# herdr opens the project's primary workspace itself; the task is its own
# linked-worktree workspace grouped under it.
PRIMARY=$(_primary_ws "$WORK/project")
[ -n "$PRIMARY" ]
assert_eq "$?" "0" "the project's primary workspace is open"
WS1=$(_chief_herdr_workspace_id "${ENDPOINT#herdr:}")
assert_eq "$(_ws_label "$WS1")" "$ID" "the task is its own workspace labeled with its plain id"
assert_eq "$(chief_meta_get "$ID" label 2>/dev/null || echo none)" "none" "backend_spawn records no label in meta"
assert_eq "$(_ws_count_for_root "$WORK/project")" "2" "the primary plus one task workspace exist for the project"
assert_eq "$(_linked_ws_count "$WORK/project")" "1" "the task workspace is a linked worktree"

assert_eq "$(jq -r --arg p "$WORKTREE" '.projects[$p].hasTrustDialogAccepted' "${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json")" "true" "backend_spawn pre-trusts the worktree in .claude.json"
chief_meta_set "$ID" endpoint "$ENDPOINT"
chief_meta_set "$ID" worktree "$WORKTREE"
chief_meta_set "$ID" project "$WORK/project"

# A second task is a second linked workspace under the same primary.
ID2="$ID-2"
BRIEF4="$WORK/brief4.md"
printf 'Reply with exactly the single word: ok\n' > "$BRIEF4"
chief_meta_set "$ID2" mode builder
chief_meta_set "$ID2" project "$WORK/project"
chief_meta_set "$ID2" agent claude
SPAWN_OUTPUT2=$(backend_spawn "$ID2" "$WORK/project" "$BRIEF4" "chief/$ID2" 2>"$WORK/spawn2.err")
SPAWN_RC2=$?
assert_eq "$SPAWN_RC2" "0" "backend_spawn succeeds for a second task against the same project"
[ "$SPAWN_RC2" = "0" ] || cat "$WORK/spawn2.err"
ENDPOINT2=$(printf '%s\n' "$SPAWN_OUTPUT2" | sed -n 2p)
WORKTREE2=$(printf '%s\n' "$SPAWN_OUTPUT2" | sed -n 1p)
assert_eq "$(_linked_ws_count "$WORK/project")" "2" "two tasks are two linked-worktree workspaces"
assert_eq "$(_primary_ws "$WORK/project")" "$PRIMARY" "still the same single primary workspace"

chief_meta_set "$ID2" endpoint "$ENDPOINT2"
chief_meta_set "$ID2" worktree "$WORKTREE2"
chief_meta_set "$ID2" project "$WORK/project"
backend_kill "$ID2"
assert_eq "$(_linked_ws_count "$WORK/project")" "1" "backend_kill closes the second task's whole workspace and leaves the first"
assert_eq "$(_primary_ws "$WORK/project")" "$PRIMARY" "the primary workspace survives backend_kill of a task"
git -C "$WORK/project" worktree remove --force "$WORKTREE2" >/dev/null 2>&1 || true
git -C "$WORK/project" branch -D "chief/$ID2" >/dev/null 2>&1 || true

wait_for_idle "$ID"
CAPTURE=$(capture "$ID")
assert_contains "$CAPTURE" "ok" "the pane shows the claude reply"
assert_contains "$CAPTURE" "bypass permissions" "backend_spawn starts the worker with bypass permissions on"

backend_busy "$ID"
assert_eq "$?" "1" "backend_busy reports idle (not busy) once the reply is done"

# The live-input-line check _chief_herdr_recover relies on, against REAL herdr
# rendering: Claude Code fills a never-yet-prompted box with a dim placeholder
# hint until the first real turn, which a bare-emptiness check would misread
# as pending text - confirm the needle-match check doesn't, and does catch our
# own text genuinely in flight.
chief_agent_use "$ID"
_chief_herdr_prompt_box_has_text() {  # <id> <text>
  herdr agent read "$1" --source detection --lines 40 2>/dev/null | chief_agent_input_line \
    | chief_agent_has_text "$(printf '%s' "$2" | tr -s '[:space:]' ' ' | cut -c1-24)"
}
assert_failure "the input-line check misses text that was never sent" -- \
  _chief_herdr_prompt_box_has_text "$ID" "never sent to this pane xyz123"

BRIEF3="$WORK/brief3.md"
printf 'Reply with exactly the single word: done\n' > "$BRIEF3"
( herdr agent prompt "$ID" "$(cat "$BRIEF3")" --wait --until working --until blocked --timeout 30000 \
    >"$WORK/prompt3.json" 2>&1 ) &
PROMPT_PID=$!
CAUGHT=0
for _ in $(seq 1 60); do
  _chief_herdr_prompt_box_has_text "$ID" "$(cat "$BRIEF3")" && { CAUGHT=1; break; }
  sleep 0.05
done
wait "$PROMPT_PID"
assert_eq "$CAUGHT" "1" "the input-line check catches our own text while genuinely in flight"

wait_for_idle "$ID"
CAPTURE2=$(capture "$ID")
assert_contains "$CAPTURE2" "done" "the raced-in prompt still completed normally"

assert_success "backend_send delivers a special key without erroring" -- backend_send "$ID" Escape

backend_kill "$ID"
assert_eq "$?" "0" "backend_kill exits cleanly"
assert_file_exists "$WORKTREE/.git" "backend_kill does not touch the worktree"
assert_eq "$(_linked_ws_count "$WORK/project")" "0" "backend_kill closes the task's workspace"
assert_eq "$(_primary_ws "$WORK/project")" "$PRIMARY" "backend_kill leaves the primary workspace open"

BRIEF2="$WORK/brief2.md"
printf 'Reply with exactly the single word: ok\n' > "$BRIEF2"
backend_relaunch "$ID" "$BRIEF2" 2>"$WORK/relaunch.err"
RELAUNCH_RC=$?
assert_eq "$RELAUNCH_RC" "0" "backend_relaunch succeeds in the same worktree"
[ "$RELAUNCH_RC" = "0" ] || cat "$WORK/relaunch.err"

NEW_ENDPOINT=$(chief_meta_get "$ID" endpoint)
assert_contains "$NEW_ENDPOINT" "herdr:" "backend_relaunch records a fresh herdr endpoint"
[ "$NEW_ENDPOINT" != "$ENDPOINT" ]
assert_eq "$?" "0" "backend_relaunch's endpoint differs from the original pane"
assert_eq "$(_linked_ws_count "$WORK/project")" "1" "backend_relaunch opens the task as a linked workspace again"
assert_eq "$(_ws_label "$(_chief_herdr_workspace_id "${NEW_ENDPOINT#herdr:}")")" "$ID" "backend_relaunch keeps the plain id label"

wait_for_idle "$ID"
RELAUNCH_CAPTURE=$(capture "$ID")
assert_contains "$RELAUNCH_CAPTURE" "ok" "the pane shows the relaunched claude's reply"

backend_kill "$ID"
assert_eq "$(_linked_ws_count "$WORK/project")" "0" "no task workspace remains after all tasks are killed"

# _chief_herdr_close_task_workspace finds the task workspace by its worktree
# path, whatever its label, and leaves look-alikes and the primary alone.
CLEANUP_ID=t-herdr-cleanup
_open_task_ws() {  # <id> <label>
  herdr worktree create --cwd "$WORK/project" --branch "chief/$1" \
    --path "$WORK/.chief/worktrees/$1" --label "$2" \
    --trust-repository --no-focus >/dev/null 2>&1
}
_drop_task_ws() {  # <id>
  git -C "$WORK/project" worktree remove --force "$WORK/.chief/worktrees/$1" >/dev/null 2>&1 || true
  git -C "$WORK/project" branch -D "chief/$1" >/dev/null 2>&1 || true
}
_linked_ws_labels() {  # <repo-root> -> labels of its linked-worktree workspaces
  herdr workspace list 2>/dev/null \
    | jq -r --arg root "$1" '.result.workspaces[]? | select(.worktree.repo_root == $root and .worktree.is_linked_worktree == true) | .label'
}
for LABEL_FORM in "$CLEANUP_ID" "$CLEANUP_ID · builder · project"; do
  _open_task_ws "$CLEANUP_ID" "$LABEL_FORM"
  _open_task_ws "$CLEANUP_ID-review" "$CLEANUP_ID-review"
  assert_eq "$(_linked_ws_count "$WORK/project")" "2" "cleanup setup: workspaces labeled '$LABEL_FORM' and '$CLEANUP_ID-review' are open"
  _chief_herdr_close_task_workspace "$CLEANUP_ID"
  assert_eq "$(_linked_ws_labels "$WORK/project")" "$CLEANUP_ID-review" "cleanup closes the workspace labeled '$LABEL_FORM' and leaves the <id>-review look-alike open"
  assert_eq "$(_primary_ws "$WORK/project")" "$PRIMARY" "cleanup leaves the primary workspace alone"
  _chief_herdr_close_task_workspace "$CLEANUP_ID-review"
  assert_eq "$(_linked_ws_count "$WORK/project")" "0" "cleanup closes the review workspace by its own path"
  _drop_task_ws "$CLEANUP_ID"
  _drop_task_ws "$CLEANUP_ID-review"
done

harness_summary
