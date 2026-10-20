#!/usr/bin/env bash
# test-spawn-cleanup.sh - chief-spawn.sh's rollback-on-failure and spawn
# lock (issue #16, item 2), exercised against the mock backend using its
# CHIEF_MOCK_SPAWN_FAIL / CHIEF_MOCK_SPAWN_MALFORMED failure injectors -
# zero cost, no herdr/orca required. Covers:
#   - a missing or already-existing --branch: fails with nothing left
#     behind (an existing branch is never touched).
#   - backend_spawn failing outright: the worktree/branch it already
#     created get rolled back, no meta record is left behind.
#   - backend_spawn "succeeding" with malformed (one-line) output: same
#     rollback, same no-meta-record outcome.
#   - a stub status=spawning meta (a spawn interrupted mid-flight, issue
#     #36): crew-state reports it blocked, watch surfaces it, and
#     teardown --abandon cleans it up.
#   - the atomic spawn lock: a same-id spawn that finds the lock already
#     held fails fast without ever touching the backend, and the lock
#     itself is always released afterwards (trap on exit).
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
BIN="$REPO_ROOT/plugins/chief/bin"
. "$TEST_DIR/lib/harness.sh"

WORK=$(mktemp -d)
harness_trap 'rm -rf "$WORK"'
mkdir -p "$WORK/project" && cd "$WORK/project" && git init -q -b master
git commit --allow-empty -q -m init
export CHIEF_HOME="$WORK/.chief"
export CHIEF_BACKEND=mock

echo "test-spawn-cleanup:"

# --- a missing --branch fails before anything is created -------------------
assert_failure "spawn: fails without --branch" -- \
  "$BIN/chief-spawn.sh" t-nobranch "$WORK/project" --mode builder --intent "no branch"

assert_file_missing "$CHIEF_HOME/worktrees/t-nobranch" \
  "spawn (no --branch): no worktree created"
assert_file_missing "$CHIEF_HOME/tasks/t-nobranch/meta" \
  "spawn (no --branch): no meta record left behind"
assert_file_missing "$CHIEF_HOME/tasks/t-nobranch/status" \
  "spawn (no --branch): no task files left behind"
assert_file_missing "$CHIEF_HOME/tasks/t-nobranch/spawning" \
  "spawn (no --branch): no lock left behind"
assert_eq "$(git -C "$WORK/project" branch --list | wc -l | tr -d ' ')" "1" \
  "spawn (no --branch): no branch created"

# --- an existing --branch is refused, and survives untouched ----------------
git -C "$WORK/project" branch feat/t-exists
EXISTS_SHA=$(git -C "$WORK/project" rev-parse feat/t-exists)
assert_failure "spawn: fails when --branch already exists" -- \
  "$BIN/chief-spawn.sh" t-exists "$WORK/project" --mode builder --branch feat/t-exists --intent "taken"

assert_eq "$(git -C "$WORK/project" rev-parse feat/t-exists 2>/dev/null)" "$EXISTS_SHA" \
  "spawn (existing branch): the branch and its commit survive"
assert_file_missing "$CHIEF_HOME/worktrees/t-exists" \
  "spawn (existing branch): no worktree created"
assert_file_missing "$CHIEF_HOME/tasks/t-exists/meta" \
  "spawn (existing branch): no meta record left behind"
assert_file_missing "$CHIEF_HOME/tasks/t-exists/status" \
  "spawn (existing branch): no task files left behind"
assert_file_missing "$CHIEF_HOME/tasks/t-exists/spawning" \
  "spawn (existing branch): no lock left behind"

# --- backend_spawn fails outright -----------------------------------------
assert_failure \
  "spawn: fails when backend_spawn itself fails" -- \
  env CHIEF_MOCK_SPAWN_FAIL=1 "$BIN/chief-spawn.sh" t-fail "$WORK/project" \
    --mode builder --branch feat/t-fail --intent "should fail"

assert_file_missing "$CHIEF_HOME/worktrees/t-fail" \
  "spawn (backend_spawn failed): worktree was rolled back, not left orphaned"
assert_not_contains "$(git -C "$WORK/project" branch --list)" "feat/t-fail" \
  "spawn (backend_spawn failed): branch was rolled back, not left orphaned"
assert_file_missing "$CHIEF_HOME/tasks/t-fail/meta" \
  "spawn (backend_spawn failed): no meta record was left behind"
assert_eq "$(jq -r --arg p "$CHIEF_HOME/worktrees/t-fail" '.projects[$p].hasTrustDialogAccepted // "unset"' "$CLAUDE_CONFIG_DIR/.claude.json")" "unset" \
  "spawn (backend_spawn failed): the pre-trust was released"
assert_eq "$(grep -c t-fail "$CHIEF_HOME/state/trust-owned" 2>/dev/null)" "0" \
  "spawn (backend_spawn failed): no trust-owned entry left"

# --- backend_spawn "succeeds" but returns malformed output ----------------
assert_failure \
  "spawn: fails when backend_spawn returns malformed output" -- \
  env CHIEF_MOCK_SPAWN_MALFORMED=1 "$BIN/chief-spawn.sh" t-malformed "$WORK/project" \
    --mode builder --branch feat/t-malformed --intent "malformed output"

assert_file_missing "$CHIEF_HOME/worktrees/t-malformed" \
  "spawn (malformed output): worktree was rolled back, not left orphaned"
assert_not_contains "$(git -C "$WORK/project" branch --list)" "feat/t-malformed" \
  "spawn (malformed output): branch was rolled back, not left orphaned"
assert_file_missing "$CHIEF_HOME/tasks/t-malformed/meta" \
  "spawn (malformed output): no meta record was left behind"

# --- an interrupted spawn leaves a status=spawning stub -------------------
mkdir -p "$CHIEF_HOME/tasks/t-stub"
printf 'project=%s\nmode=builder\nbranch=chief/t-stub\nworktree=%s\nstatus=spawning\n' \
  "$WORK/project" "$CHIEF_HOME/worktrees/t-stub" > "$CHIEF_HOME/tasks/t-stub/meta"

assert_contains "$("$BIN/task/chief-crew-state.sh" t-stub)" "state: blocked" \
  "crew-state: a spawning stub is reported blocked"
assert_contains "$(timeout 10 "$BIN/chief-watch.sh")" "t-stub: state: blocked" \
  "watch: surfaces the spawning stub"
: > "$CHIEF_HOME/tasks/t-stub/spawning"
assert_contains "$("$BIN/task/chief-crew-state.sh" t-stub)" "state: working" \
  "crew-state: a spawning stub with the spawn lock held is a live spawn, not blocked"
rm -f "$CHIEF_HOME/tasks/t-stub/spawning"
assert_success "teardown: --abandon cleans up the spawning stub" -- \
  "$BIN/chief-teardown.sh" t-stub --abandon
assert_contains "$(cat "$CHIEF_HOME/archive/t-stub/meta")" "status=torn-down" \
  "teardown: the stub is marked torn-down"

# --- the atomic spawn lock --------------------------------------------------
mkdir -p "$CHIEF_HOME/state"
mkdir -p "$CHIEF_HOME/tasks/t-locked"
: > "$CHIEF_HOME/tasks/t-locked/spawning"

assert_failure "spawn: refuses a same-id spawn while the lock is held" -- \
  "$BIN/chief-spawn.sh" t-locked "$WORK/project" --mode builder --branch feat/t-locked --intent "should be locked out"

assert_file_missing "$CHIEF_HOME/worktrees/t-locked" \
  "spawn (locked): never even reached backend_spawn - no worktree created"
assert_file_missing "$CHIEF_HOME/tasks/t-locked/meta" \
  "spawn (locked): no meta record was left behind"

rm -f "$CHIEF_HOME/tasks/t-locked/spawning"
assert_success "spawn: succeeds once the lock is released" -- \
  "$BIN/chief-spawn.sh" t-locked "$WORK/project" --mode builder --branch feat/t-locked --intent "should now succeed"

# --- the lock is released after both a failed and a successful spawn ------
assert_file_missing "$CHIEF_HOME/tasks/t-fail/spawning" \
  "spawn: lock released via trap after a failed spawn"
assert_file_missing "$CHIEF_HOME/tasks/t-locked/spawning" \
  "spawn: lock released via trap after a successful spawn"

# --- --dry-run and usage errors create nothing, not even the empty dirs ---
FRESH="$WORK/fresh/.chief"
assert_success "spawn: --dry-run on a fresh home" -- \
  env CHIEF_HOME="$FRESH" "$BIN/chief-spawn.sh" t-dry "$WORK/project" --mode builder --branch feat/t-dry --intent x --dry-run
assert_failure "spawn: a usage error on a fresh home" -- env CHIEF_HOME="$FRESH" "$BIN/chief-spawn.sh"
assert_file_missing "$FRESH" "spawn: a dry run or usage error creates no .chief"

harness_summary
