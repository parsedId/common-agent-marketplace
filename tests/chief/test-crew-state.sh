#!/usr/bin/env bash
# test-crew-state.sh - chief-crew-state.sh's state classification, exercised
# directly against hand-written task files rather than a real spawn
# (faster, and isolates the classification logic from the spawn machinery,
# which test-lifecycle.sh already covers together).
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
BIN="$REPO_ROOT/plugins/chief/bin"
. "$TEST_DIR/lib/harness.sh"

WORK=$(mktemp -d)
harness_trap 'rm -rf "$WORK"'
mkdir -p "$WORK/project" && cd "$WORK/project" && git init -q -b master
export CHIEF_HOME="$WORK/.chief"
export CHIEF_BACKEND=mock
CS="$BIN/task/chief-crew-state.sh"

echo "test-crew-state:"

assert_failure "refuses an unknown task id" -- "$CS" nope

# Minimal meta + a live mock terminal process, no status written yet.
mkdir -p "$CHIEF_HOME"/tasks/{t-1,t-2,bs-1,t-3}
printf 'project=%s\nmode=builder\nbranch=chief/t-1\nworktree=%s\nendpoint=mock:t-1\nstatus=working\n' \
  "$WORK/project" "$WORK/.chief/worktrees/t-1" > "$CHIEF_HOME/tasks/t-1/meta"

( exec -a chief-mock-t-1 sleep 100000 ) >/dev/null 2>&1 &
disown
echo $! > "$CHIEF_HOME/tasks/t-1/term.pid"

assert_contains "$("$CS" t-1)" "state: working" "a live backend process with no status yet reads as working"
assert_contains "$("$CS" t-1)" "[mode: builder]" "the state line reports the task's mode, so Chief can tell a researcher from a builder without re-reading meta by hand"

printf 'agent=codex\nmodel=gpt-5\n' >> "$CHIEF_HOME/tasks/t-1/meta"
assert_contains "$("$CS" t-1)" "[mode: builder] [agent: codex:gpt-5]" "the state line appends agent:model after the mode"
assert_contains "$("$CS" t-1)" "state: working" "the state prefix is unchanged"

kill "$(cat "$CHIEF_HOME/tasks/t-1/term.pid")"
sleep 1
assert_contains "$("$CS" t-1)" "state: stale" "a dead process with no turn-ended marker reads as stale"

touch "$CHIEF_HOME/tasks/t-1/turn-ended"
assert_contains "$("$CS" t-1)" "state: working" "a fresh turn-ended marker reads as working even with the process dead"

touch -d "@$(($(date +%s) - 500))" "$CHIEF_HOME/tasks/t-1/turn-ended"
assert_contains "$("$CS" t-1)" "state: stale" "an old turn-ended marker (past the threshold) reads as stale"

echo "blocked: need operator input on limiter lib" >> "$CHIEF_HOME/tasks/t-1/status"
assert_contains "$("$CS" t-1)" "state: blocked · need operator input" "a blocked status line is authoritative regardless of liveness"

echo "needs-decision: pick a library" >> "$CHIEF_HOME/tasks/t-1/status"
assert_contains "$("$CS" t-1)" "state: needs-decision" "needs-decision status line is authoritative"

echo "failed: could not install deps" >> "$CHIEF_HOME/tasks/t-1/status"
assert_contains "$("$CS" t-1)" "state: failed" "failed status line is authoritative"

echo "done: added hello.txt" >> "$CHIEF_HOME/tasks/t-1/status"
assert_contains "$("$CS" t-1)" "state: done · added hello.txt" "done status line is authoritative and carries its detail"
assert_contains "$("$CS" t-1)" "[mode: builder]" "mode still reports correctly once the task is done"

printf 'project=%s\nmode=researcher\nbranch=chief/t-2\nworktree=%s\nendpoint=mock:t-2\nstatus=working\n' \
  "$WORK/project" "$WORK/.chief/worktrees/t-2" > "$CHIEF_HOME/tasks/t-2/meta"
echo "done: wrote report.md" >> "$CHIEF_HOME/tasks/t-2/status"
assert_contains "$("$CS" t-2)" "[mode: researcher]" "a researcher task reports its own mode, distinct from a builder task"

# --- brainstormer: waiting on the operator in its pane is never stale ------
printf 'project=%s\nmode=brainstormer\nbranch=feat/bs-1\nworktree=%s\nendpoint=mock:bs-1\nstatus=working\nattach=tail -f x.log\n' \
  "$WORK/project" "$WORK/.chief/worktrees/bs-1" > "$CHIEF_HOME/tasks/bs-1/meta"
echo "working: brainstorming with operator" >> "$CHIEF_HOME/tasks/bs-1/status"

out=$("$CS" bs-1)
assert_contains "$out" "state: working · awaiting operator in pane" "a brainstormer with no turn-ended file yet reads as awaiting the operator"
assert_contains "$out" "[mode: brainstormer]" "the awaiting line keeps the mode tag"
assert_contains "$out" "[attach: tail -f x.log]" "the awaiting line repeats the attach hint"
for age in 500 14500 1000000; do
  touch -d "@$(($(date +%s) - age))" "$CHIEF_HOME/tasks/bs-1/turn-ended"
  assert_contains "$("$CS" bs-1)" "awaiting operator in pane" "an idle brainstormer is awaiting, not stale, after ${age}s"
done
printf 'project=%s\nmode=researcher\nbranch=chief/t-3\nworktree=x\nendpoint=mock:t-3\nstatus=working\n' "$WORK/project" > "$CHIEF_HOME/tasks/t-3/meta"
touch -d "@$(($(date +%s) - 500))" "$CHIEF_HOME/tasks/t-3/turn-ended"
assert_contains "$("$CS" t-3)" "state: stale" "a researcher idle that long is still stale"

echo "blocked: cannot read the repo" >> "$CHIEF_HOME/tasks/bs-1/status"
assert_contains "$("$CS" bs-1)" "state: blocked" "a brainstormer's blocked surfaces immediately"
echo "done: spec ready" >> "$CHIEF_HOME/tasks/bs-1/status"
out=$("$CS" bs-1)
assert_contains "$out" "state: done · spec ready" "a brainstormer's done surfaces immediately"
assert_not_contains "$out" "attach:" "a terminal brainstormer line carries no attach hint"
echo "failed: gave up" >> "$CHIEF_HOME/tasks/bs-1/status"
assert_contains "$("$CS" bs-1)" "state: failed" "a brainstormer's failed surfaces immediately"

harness_summary
