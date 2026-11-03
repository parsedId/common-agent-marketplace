#!/usr/bin/env bash
# test-watch.sh - chief-watch.sh's in_flight_ids against the mock backend.
# Reproduces the notification-storm bug: once a task's crew state reaches a
# terminal state and the normal flow (chief-backlog.sh hold here) has acted on
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

"$BIN/chief-backlog.sh" add t-1 "Add hello.txt" >/dev/null

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
echo "done: added hello.txt" >> "$CHIEF_HOME/tasks/t-1/status"

OUT1=$(timeout 10 "$BIN/chief-watch.sh")
assert_contains "$OUT1" "t-1: state: done" "first Stop hook: watch surfaces the newly-done task"

OUT2=$(CHIEF_POLL=1 timeout 3 "$BIN/chief-watch.sh"; echo "rc=$?")
assert_eq "$OUT2" "rc=124" \
  "second Stop hook (state unchanged): watch stays silent, the done alert was already delivered"

# The normal flow acts on the task: Chief holds it for review.
"$BIN/chief-backlog.sh" hold t-1 "reported" >/dev/null

OUT3=$(timeout 10 "$BIN/chief-watch.sh")
assert_not_contains "$OUT3" "t-1: state: done" \
  "third Stop hook (after chief-backlog.sh hold acted on it): watch no longer re-notifies about the same already-surfaced done task"
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

echo "done: added world.txt" >> "$CHIEF_HOME/tasks/t-2/status"

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
echo "done: switched to the new approach" >> "$CHIEF_HOME/tasks/t-2/status"

OUT7=$(timeout 10 "$BIN/chief-watch.sh")
assert_contains "$OUT7" "t-2: state: done · switched to the new approach" \
  "once the state changes, watch surfaces the new terminal state"

OUT8=$(CHIEF_POLL=1 timeout 3 "$BIN/chief-watch.sh"; echo "rc=$?")
assert_eq "$OUT8" "rc=124" \
  "and stays silent on subsequent Stop hooks until the state changes again"

# --- brainstormer: an operator-wait never wakes Chief; done does ---
"$BIN/chief-backlog.sh" hold t-2 "reported" >/dev/null
assert_success "spawn: brainstormer" -- \
  timeout 10 "$BIN/chief-spawn.sh" bs-1 "$WORK/project" --mode brainstormer --branch feat/bs-1 --intent "shape an idea"
kill "$(cat "$CHIEF_HOME/tasks/bs-1/term.pid")"; sleep 1
echo "working: brainstorming with operator" >> "$CHIEF_HOME/tasks/bs-1/status"
turn_ago() { touch -d "@$(($(date +%s) - $1))" "$CHIEF_HOME/tasks/bs-1/turn-ended"; }
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
echo "done: spec ready" >> "$CHIEF_HOME/tasks/bs-1/status"
assert_contains "$(watch_bs)" "bs-1: state: done · spec ready" "brainstormer done: watch wakes Chief immediately"

# --- stale: the idle counter alone is not a state change ---
assert_success "spawn: builder for the stale scenario" -- \
  timeout 10 "$BIN/chief-spawn.sh" st-1 "$WORK/project" --mode builder --branch feat/st-1 --intent "idle"
kill "$(cat "$CHIEF_HOME/tasks/st-1/term.pid")"; sleep 1
echo "working: waiting on a job" >> "$CHIEF_HOME/tasks/st-1/status"
stale_ago() { touch -d "@$(($(date +%s) - $1))" "$CHIEF_HOME/tasks/st-1/turn-ended"; }
watch_st() { CHIEF_POLL=1 timeout 3 "$BIN/chief-watch.sh"; }

stale_ago 250
assert_contains "$(watch_st)" "st-1: state: stale" "stale builder: watch wakes Chief once"
stale_ago 400
out=$(watch_st); rc=$?
assert_eq "$rc:$out" "124:" "stale builder, larger idle counter: watch stays silent"
echo "working: back at it" >> "$CHIEF_HOME/tasks/st-1/status"
touch "$CHIEF_HOME/tasks/st-1/turn-ended"
out=$(watch_st); rc=$?
assert_eq "$rc:$out" "124:" "stale builder active again: watch stays silent"
stale_ago 250
assert_contains "$(watch_st)" "st-1: state: stale" "stale again after activity: watch wakes Chief again"

# --- agent flip: a changed [agent: ...] part is not a state change ---
assert_success "spawn: builder for the agent-flip scenario" -- \
  timeout 10 "$BIN/chief-spawn.sh" ag-1 "$WORK/project" --mode builder --branch feat/ag-1 --intent "flip"
echo "done: shipped" >> "$CHIEF_HOME/tasks/ag-1/status"
watch_ag() { CHIEF_POLL=1 timeout 3 "$BIN/chief-watch.sh"; }
set_ag() {
  local m="$CHIEF_HOME/tasks/ag-1/meta"
  grep -vE '^(agent|model)=' "$m" > "$m.tmp"; mv "$m.tmp" "$m"
  printf 'agent=claude\nmodel=%s\n' "$1" >> "$m"
}
set_ag ""
assert_contains "$(watch_ag)" "ag-1: state: done" "agent flip: first delivery"
set_ag sonnet
out=$(watch_ag); rc=$?
assert_eq "$rc:$out" "124:" "agent flip: same line with another agent stays silent"
echo "done: shipped again" >> "$CHIEF_HOME/tasks/ag-1/status"
assert_contains "$(watch_ag)" "ag-1: state: done" "agent flip: a different state still delivers"

# --- reviewer tag: a trailing [reviewer: id] is not a state change ---
assert_success "spawn: builder for the reviewer-tag scenario" -- \
  timeout 10 "$BIN/chief-spawn.sh" rv-1 "$WORK/project" --mode builder --branch feat/rv-1 --intent "tag"
echo "done: shipped" >> "$CHIEF_HOME/tasks/rv-1/status"
watch_rv() { CHIEF_POLL=1 timeout 3 "$BIN/chief-watch.sh"; }
assert_contains "$(watch_rv)" "rv-1: state: done" "reviewer tag: first delivery"
printf 'reviewer=rv-1-review\n' >> "$CHIEF_HOME/tasks/rv-1/meta"
out=$(watch_rv); rc=$?
assert_eq "$rc:$out" "124:" "reviewer tag: same line with a reviewer suffix stays silent"

# --- old-format baseline (with the [agent: ...] tag) still matches ---
m="$CHIEF_HOME/tasks/rv-1/meta"
grep -v '^notify-baseline=' "$m" > "$m.tmp"; mv "$m.tmp" "$m"
printf 'notify-baseline=state: done · shipped [mode: builder] [agent: claude]\n' >> "$m"
out=$(watch_rv); rc=$?
assert_eq "$rc:$out" "124:" "old-format baseline: the stored [agent: ...] tag still matches"

# Activity that only touches turn-ended (no new status line) also starts a new
# stale episode; polling the same episode again stays silent.
touch "$CHIEF_HOME/tasks/st-1/turn-ended"
out=$(watch_st); rc=$?
assert_eq "$rc:$out" "124:" "touch-only activity: watch stays silent"
stale_ago 260
assert_contains "$(watch_st)" "st-1: state: stale" "stale again after touch-only activity: watch wakes Chief again"
out=$(watch_st); rc=$?
assert_eq "$rc:$out" "124:" "same stale episode polled again: delivered once"

# --- single instance + exactly-once delivery (atomic claims) ---
export CHIEF_POLL=1
ARM="$REPO_ROOT/plugins/chief/hooks/stop-watch-arm.sh"
OWNERF="$CHIEF_HOME/state/watch.owner"
owner_is_not() { [ -s "$OWNERF" ] && [ "$(cat "$OWNERF")" != "$1" ]; }
wait_until() { local n=0; until "$@"; do n=$((n + 1)); [ "$n" -ge 100 ] && return 1; sleep 0.1; done; }
line() { echo "t-2: state: done · $1 [mode: builder] [agent: claude]"; }

"$BIN/chief-backlog.sh" status t-2 in-flight >/dev/null
echo "done: race" >> "$CHIEF_HOME/tasks/t-2/status"
for i in 1 2 3; do ( timeout 6 "$BIN/chief-watch.sh" > "$WORK/race-$i.out" 2>&1 ) & done
wait
assert_eq "$(cat "$WORK"/race-*.out)" "$(line race)" "racing watchers: the change is delivered exactly once"

# An older watcher exits silently when a newer one arms, also through the hook.
echo "working: older exits" >> "$CHIEF_HOME/tasks/t-2/status"
rm -f "$OWNERF"
( timeout 10 "$BIN/chief-watch.sh" > "$WORK/old.out" 2>&1; echo "rc=$?" >> "$WORK/old.out" ) &
wait_until owner_is_not ""
old_owner=$(cat "$OWNERF")
( CLAUDE_PROJECT_DIR="$WORK/project" timeout 10 "$ARM" > "$WORK/new.out" 2>&1; echo "rc=$?" >> "$WORK/new.out" ) &
wait_until owner_is_not "$old_owner"
echo "done: older exits" >> "$CHIEF_HOME/tasks/t-2/status"
wait
assert_eq "$(cat "$WORK/old.out")" "rc=0" "older watcher exits silently (0, no output)"
assert_eq "$(cat "$WORK/new.out")" "chief watcher: $(line 'older exits')
rc=2" "the newer watcher, armed by the hook, delivers the change"

# A displaced watcher that read an older state and runs its clear path must not
# cause a re-delivery.
echo "working: gated" >> "$CHIEF_HOME/tasks/t-2/status"
cp -r "$REPO_ROOT/plugins/chief" "$WORK/plugin-copy"
cat > "$WORK/plugin-copy/bin/task/chief-crew-state.sh" <<GATE
#!/usr/bin/env bash
touch "$WORK/gate-entered"
while [ ! -e "$WORK/gate-release" ]; do sleep 0.1; done
echo "state: working"
GATE
( timeout 10 "$WORK/plugin-copy/bin/chief-watch.sh" > "$WORK/gated.out" 2>&1; echo "rc=$?" >> "$WORK/gated.out" ) &
wait_until test -e "$WORK/gate-entered"
echo "done: gated" >> "$CHIEF_HOME/tasks/t-2/status"
assert_eq "$(timeout 10 "$BIN/chief-watch.sh")" "$(line gated)" "replacement watcher delivers while the old one is gated"
touch "$WORK/gate-release"
wait
assert_eq "$(cat "$WORK/gated.out")" "rc=0" "displaced watcher exits silently after its gate"
sed -i '/^notify-baseline=/d' "$CHIEF_HOME/tasks/t-2/meta"   # as if the clear path ran
assert_eq "$(timeout 3 "$BIN/chief-watch.sh"; echo "rc=$?")" "rc=124" \
  "baseline cleared by a stale watcher: a later watcher does not re-deliver"

# A watcher paused after its ownership check, just before building its claim,
# with a status line appended meanwhile, must not re-deliver what the
# replacement delivered.
echo "done: snap" >> "$CHIEF_HOME/tasks/t-2/status"
rm -f "$WORK/gate-entered" "$WORK/gate-release"
mkdir "$WORK/gatebin"
cat > "$WORK/gatebin/cksum" <<GATE
#!/usr/bin/env bash
touch "$WORK/gate-entered"
while [ ! -e "$WORK/gate-release" ]; do sleep 0.1; done
exec $(command -v cksum) "\$@"
GATE
chmod +x "$WORK/gatebin/cksum"
( PATH="$WORK/gatebin:$PATH" timeout 10 "$BIN/chief-watch.sh" > "$WORK/snap-a.out" 2>&1; echo "rc=$?" >> "$WORK/snap-a.out" ) &
wait_until test -e "$WORK/gate-entered"
assert_eq "$(timeout 10 "$BIN/chief-watch.sh")" "$(line snap)" "replacement delivers the event while the old watcher is paused"
echo "working: moved on" >> "$CHIEF_HOME/tasks/t-2/status"
touch "$WORK/gate-release"
wait
assert_eq "$(cat "$WORK/snap-a.out")" "rc=0" "paused watcher with a stale snapshot does not deliver a duplicate"

# A watcher that wins the claim and is displaced before printing still
# delivers: the claim alone makes delivery exactly-once.
echo "done: claimed" >> "$CHIEF_HOME/tasks/t-2/status"
rm -f "$WORK/gate-entered" "$WORK/gate-release"; mkdir -p "$WORK/mkbin"
cat > "$WORK/mkbin/mkdir" <<GATE
#!/usr/bin/env bash
$(command -v mkdir) "\$@"; rc=\$?
case "\${!#}" in */claims/t-2.*) touch "$WORK/gate-entered"; while [ ! -e "$WORK/gate-release" ]; do sleep 0.1; done ;; esac
exit \$rc
GATE
chmod +x "$WORK/mkbin/mkdir"
( PATH="$WORK/mkbin:$PATH" timeout 10 "$BIN/chief-watch.sh" > "$WORK/claim-a.out" 2>&1; echo "rc=$?" >> "$WORK/claim-a.out" ) &
wait_until test -e "$WORK/gate-entered"
touch "$CHIEF_HOME/tasks/t-2/turn-ended"   # a finishing turn; same done event
assert_eq "$(timeout 3 "$BIN/chief-watch.sh"; echo "rc=$?")" "rc=124" "replacement does not deliver an event already claimed"
touch "$WORK/gate-release"
wait
assert_eq "$(cat "$WORK/claim-a.out")" "$(line claimed)
rc=0" "the displaced claim winner delivers the event"
assert_eq "$(timeout 3 "$BIN/chief-watch.sh"; echo "rc=$?")" "rc=124" "a later watcher does not re-deliver it"

# Debris from earlier watchers does not break a later arm.
mkdir -p "$CHIEF_HOME/state/claims/gone-task.1.1.1"
: > "$OWNERF.99999"
echo "done: after debris" >> "$CHIEF_HOME/tasks/t-2/status"
assert_eq "$(timeout 10 "$BIN/chief-watch.sh")" "$(line 'after debris')" "owner-tmp/claim debris does not break a later arm"
assert_file_missing "$CHIEF_HOME/state/claims/gone-task.1.1.1" "claim GC drops a claim whose task is gone"
cl="$CHIEF_HOME/state/claims"
cur=$(cd "$cl" && ls -t | grep "^t-2\\." | head -1)
cur_st=$(cd "$cl" && ls -t | grep "^st-1\\." | head -1)
mkdir "$cl/t-2.1.111" "$cl/st-1.1.5.111"
touch -d '3 days ago' "$cl/$cur" "$cl/$cur_st" "$cl/t-2.1.111" "$cl/st-1.1.5.111"
timeout 3 "$BIN/chief-watch.sh" >/dev/null; true
assert_file_exists "$cl/$cur" "claim GC never removes the current done key, however old"
assert_file_exists "$cl/$cur_st" "claim GC never removes the current stale key, however old"
assert_file_missing "$cl/t-2.1.111" "claim GC removes an old-generation done claim"
assert_file_missing "$cl/st-1.1.5.111" "claim GC removes an old-generation stale claim"
# --- review rounds: a deferred reviewer keeps no claim; one announcement per round ---
setm() { sed -i "/^$2=/d" "$CHIEF_HOME/tasks/$1/meta"; printf '%s=%s\n' "$2" "$3" >> "$CHIEF_HOME/tasks/$1/meta"; }
mk_round() {   # <builder> <reviewer>...: a builder with finished-or-not reviewers
  local b=$1; shift
  for t in "$b" "$@"; do
    assert_success "spawn: $t" -- timeout 10 "$BIN/chief-spawn.sh" "$t" "$WORK/project" --mode builder --branch "feat/$t" --intent "round"
  done
  for t in "$@"; do setm "$t" for "$b"; done
  setm "$b" reviewer "$*"; setm "$b" review_round 1
}
mk_round rb-b rb-r1 rb-r2
echo "done: r1" >> "$CHIEF_HOME/tasks/rb-r1/status"
out=$(timeout 3 "$BIN/chief-watch.sh"); rc=$?
assert_eq "$rc:$out" "124:" "deferred reviewer: sibling still working, silent"
setm rb-r2 status torn-down
assert_contains "$(timeout 3 "$BIN/chief-watch.sh")" "rb-r1: state: done" \
  "deferred reviewer: announced once the sibling is torn down"

mk_round rc-b rc-r1 rc-r2
echo "done: r1" >> "$CHIEF_HOME/tasks/rc-r1/status"
echo "done: r2" >> "$CHIEF_HOME/tasks/rc-r2/status"
rm -f "$WORK/gate-entered" "$WORK/gate-release"; mkdir -p "$WORK/rbin"
cat > "$WORK/rbin/mkdir" <<GATE
#!/usr/bin/env bash
$(command -v mkdir) "\$@"; rc=\$?
case "\${!#}" in */claims/rc-r1.*) touch "$WORK/gate-entered"; while [ ! -e "$WORK/gate-release" ]; do sleep 0.1; done ;; esac
exit \$rc
GATE
chmod +x "$WORK/rbin/mkdir"
( PATH="$WORK/rbin:$PATH" timeout 10 "$BIN/chief-watch.sh" > "$WORK/rnd-a.out" 2>&1; echo "rc=$?" >> "$WORK/rnd-a.out" ) &
wait_until test -e "$WORK/gate-entered"
assert_contains "$(timeout 5 "$BIN/chief-watch.sh")" "all 2 reviewers of rc-b done" "overlapping watchers: the replacement announces the round"
touch "$WORK/gate-release"
wait
assert_eq "$(cat "$WORK/rnd-a.out")" "rc=0" "overlapping watchers: the paused one stays silent"

harness_summary
