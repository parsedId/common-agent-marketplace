#!/usr/bin/env bash
# test-watch.sh - chief-watch.sh's in_flight_ids against the mock backend.
# Reproduces the notification-storm bug: once a task's crew state reaches a
# terminal state and the normal flow (chief-pr-open.sh here) has acted on
# it, chief-watch.sh must stop re-notifying about it on every subsequent
# Stop hook, because in_flight_ids only follows tasks whose meta status is
# still "working".
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
BIN="$REPO_ROOT/plugins/chief/bin"
. "$TEST_DIR/lib/harness.sh"

echo "test-watch:"

WORK=$(mktemp -d)
harness_trap 'rm -rf "$WORK"'

git init -q -b main "$WORK/remote.git" --bare
git clone -q "$WORK/remote.git" "$WORK/project"
( cd "$WORK/project" \
    && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
    && git push -q origin main )

export CHIEF_HOME="$WORK/.chief"
export CHIEF_BACKEND=mock
export CHIEF_PR_PROVIDER=mock
export CHIEF_PR_MOCK_LOG="$WORK/mock.log"
export CHIEF_PR_MOCK_URL="https://example.invalid/mock/pr/1"
: > "$CHIEF_PR_MOCK_LOG"

assert_success "spawn: creates the worktree and launches the mock backend" -- \
  timeout 10 "$BIN/chief-spawn.sh" t-1 "$WORK/project" --mode builder --branch feat/t-1 --intent "Add hello.txt"

# Simulate the builder finishing its work and reporting done, the same way
# test-lifecycle.sh does.
(
  cd "$CHIEF_HOME/worktrees/t-1" || exit 1
  echo hello > hello.txt
  git add hello.txt
  git -c user.email=t@t -c user.name=t commit -q -m "add hello.txt"
)
echo "done: added hello.txt" >> "$CHIEF_HOME/state/t-1.status"

OUT1=$(timeout 10 "$BIN/chief-watch.sh")
assert_contains "$OUT1" "t-1: state: done" "first Stop hook: watch surfaces the newly-done task"

OUT2=$(timeout 10 "$BIN/chief-watch.sh")
assert_not_contains "$OUT2" "t-1: state: done" \
  "second Stop hook (status still in-flight): the already-surfaced done line is not re-fired"

# The normal flow acts on the task: open a PR for it.
"$BIN/pr/chief-pr-open.sh" t-1 --confirm --title "My title" --body "My body" >/dev/null

OUT3=$(timeout 10 "$BIN/chief-watch.sh")
assert_not_contains "$OUT3" "t-1: state: done" \
  "third Stop hook (after chief-pr-open.sh acted on it): watch no longer re-notifies about the same already-surfaced done task"
assert_eq "$OUT3" "nothing in flight" "third Stop hook: nothing left in flight"

# --- resume-for-steering: don't re-nag the SAME terminal string (nag-fix) --
# Chief holds a task with a report, then resumes it (status in-flight) to
# steer it further. chief-watch.sh must not immediately re-surface the exact
# same "done"/"held" state it already reported and Chief already acted on -
# but it MUST surface it again once the state actually changes, same as any
# other task.
assert_success "spawn: second task for the resume scenario" -- \
  timeout 10 "$BIN/chief-spawn.sh" t-2 "$WORK/project" --mode builder --branch feat/t-2 --intent "Add world.txt"

"$BIN/chief-backlog.sh" add t-2 "Add world.txt" >/dev/null

echo "done: added world.txt" >> "$CHIEF_HOME/state/t-2.status"

OUT4=$(timeout 10 "$BIN/chief-watch.sh")
assert_contains "$OUT4" "t-2: state: done" "t-2 first Stop hook: watch surfaces the newly-done task"

"$BIN/chief-backlog.sh" hold t-2 "steering: try a different approach" >/dev/null

# Resume it for further steering - the exact same "done" report is still
# t-2's crew state at this instant, nothing new has happened yet.
"$BIN/chief-backlog.sh" status t-2 in-flight >/dev/null

OUT5=$(timeout 10 "$BIN/chief-watch.sh")
assert_not_contains "$OUT5" "t-2: state: done · added world.txt" \
  "resumed Stop hook: watch does not immediately re-surface the same done state Chief already acted on"

OUT6=$(timeout 10 "$BIN/chief-watch.sh")
assert_not_contains "$OUT6" "t-2: state: done · added world.txt" \
  "another resumed Stop hook with no state change: still held back, not re-nagged"

# The builder reports something new - the state has actually moved on, so
# the normal every-Stop-hook nag must resume for this new finding.
echo "done: switched to the new approach" >> "$CHIEF_HOME/state/t-2.status"

OUT7=$(timeout 10 "$BIN/chief-watch.sh")
assert_contains "$OUT7" "t-2: state: done · switched to the new approach" \
  "once the state changes, watch surfaces the new terminal state"

OUT8=$(timeout 10 "$BIN/chief-watch.sh")
assert_not_contains "$OUT8" "t-2: state: done · switched to the new approach" \
  "but surfaces that new state only once"

# Re-armed (back to work), then the identical line again: surfaces again.
echo "working: round 2" >> "$CHIEF_HOME/state/t-2.status"
touch "$CHIEF_HOME/state/t-2.turn-ended"
CHIEF_POLL=1 timeout 3 "$BIN/chief-watch.sh" >/dev/null
echo "done: switched to the new approach" >> "$CHIEF_HOME/state/t-2.status"
assert_contains "$(timeout 10 "$BIN/chief-watch.sh")" "t-2: state: done · switched to the new approach" \
  "after a working phase, an identical terminal line surfaces again"

# --- brainstormer: an operator-wait never wakes Chief; done does ---
"$BIN/chief-backlog.sh" hold t-2 "reported" >/dev/null
assert_success "spawn: brainstormer" -- \
  timeout 10 "$BIN/chief-spawn.sh" bs-1 "$WORK/project" --mode brainstormer --branch feat/bs-1 --intent "shape an idea"
kill "$(cat "$CHIEF_HOME/state/bs-1.term.pid")"; sleep 1
echo "working: brainstorming with operator" >> "$CHIEF_HOME/state/bs-1.status"
turn_ago() { touch -d "@$(($(date +%s) - $1))" "$CHIEF_HOME/state/bs-1.turn-ended"; }
watch_bs() { CHIEF_POLL=1 timeout 3 "$BIN/chief-watch.sh"; }
silent() {  # <name> - the watcher keeps waiting: no output, killed by timeout (124)
  local out rc; out=$(watch_bs); rc=$?
  assert_eq "$rc:$out" "124:" "$1"
}

silent "brainstormer with no turn-ended file: watch does not wake Chief"
turn_ago 3600
silent "brainstormer idle for 1h: watch does not wake Chief"
turn_ago 1000000
silent "brainstormer idle for days: watch still does not wake Chief"
echo "done: spec ready" >> "$CHIEF_HOME/state/bs-1.status"
assert_contains "$(watch_bs)" "bs-1: state: done · spec ready" "brainstormer done: watch wakes Chief immediately"

harness_summary
