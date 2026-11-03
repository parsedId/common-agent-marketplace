#!/usr/bin/env bash
# test-review-modes.sh - chief-review.sh run modes (parallel, sequential, first,
# --only), the sequential early stop and the watcher's round gate with fewer
# than all reviewers running, against the mock backend.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
BIN="$REPO_ROOT/plugins/chief/bin"
. "$TEST_DIR/lib/harness.sh"

echo "test-review-modes:"

WORK=$(mktemp -d)
harness_trap 'rm -rf "$WORK"'
mkdir -p "$WORK/project" && cd "$WORK/project" && git init -q -b main
git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
export CHIEF_HOME="$WORK/.chief"
export CHIEF_BACKEND=mock
export CHIEF_REVIEW_POLL=1
. "$BIN/lib/paths.sh"
. "$BIN/lib/meta.sh"
RV="$BIN/task/chief-review.sh"
CFG="$CHIEF_HOME/config/agents"
mkdir -p "$CHIEF_HOME/config"

newb() {  # <id>: a done builder with one commit
  "$BIN/chief-backlog.sh" add "$1" "T $1" >/dev/null
  timeout 10 "$BIN/chief-spawn.sh" "$1" "$WORK/project" --mode builder --branch "feat/$1" --intent "T" >/dev/null
  ( cd "$CHIEF_HOME/worktrees/$1" && echo "$1" > "$1.txt" && git add "$1.txt" \
    && git -c user.email=t@t -c user.name=t commit -q -m "add $1" )
  echo "done: $(git -C "$CHIEF_HOME/worktrees/$1" rev-parse --short HEAD) ok" >> "$TASKS/$1/status"
  "$BIN/chief-backlog.sh" hold "$1" reported >/dev/null
}
finish() {  # <reviewer> PASS|FAIL
  printf 'Verdict: %s\n' "$2" > "$TASKS/$1/report.md"
  echo "done: round 1 $2 @x" >> "$TASKS/$1/status"
}
wait_for() {  # <file-or-meta test as a command...>: poll up to 15s
  local i; for i in $(seq 1 30); do "$@" && return 0; sleep 0.5; done; return 1
}
has_meta() { [ -f "$TASKS/$1/meta" ]; }
watch_out() { CHIEF_POLL=1 timeout 4 "$BIN/chief-watch.sh"; }
hold_all() {
  local t; for t in "$TASKS"/*/; do t=$(basename "$t"); [ "$(chief_meta_get "$t" status 2>/dev/null)" = working ] && "$BIN/chief-backlog.sh" hold "$t" idle >/dev/null; done
}

# --- config and plan ---
. "$BIN/lib/id.sh"
. "$BIN/lib/agents/agent.sh"
printf '[reviewer]\nmode = sequential\nclaude:sonnet\ncodex\n' > "$CFG"
assert_eq "$(chief_agent_review_mode)" "sequential" "config: mode is read from [reviewer]"
assert_eq "$(chief_agent_review_plan sequential | tr '\n' ',')" "1 sonnet,2 codex," "plan: sequential lists the whole pool"
assert_eq "$(chief_agent_review_plan first)" "1 sonnet" "plan: first is entry 1"
assert_eq "$(chief_agent_review_plan parallel codex)" "2 codex" "plan: --only picks by bare agent"
assert_eq "$(chief_agent_review_plan sequential claude:sonnet,codex | tr '\n' ',')" "1 sonnet,2 codex," "plan: --only picks by agent:model"
assert_failure "plan: --only outside the pool is refused" -- chief_agent_review_plan parallel gemini
assert_failure "plan: --only with first is refused" -- chief_agent_review_plan first codex
printf '[reviewer]\nmode = bogus\nclaude\n' > "$CFG"
assert_failure "config: an unknown mode is refused" -- chief_agent_review_mode
printf 'mode = parallel\nclaude\n' > "$CFG"
assert_failure "config: mode outside [reviewer] is refused" -- chief_agent_review_mode
printf '[reviewer]\nclaude:sonnet\ncodex\n' > "$CFG"
assert_eq "$(chief_agent_review_mode)" "parallel" "config: mode defaults to parallel"
assert_eq "$(chief_agent_review_plan parallel)" "0 " "plan: parallel without strategy all is the strategy's single pick"
rm -f "$CFG"
assert_eq "$(chief_agent_review_plan sequential)" "0 " "plan: no pool is a single default reviewer"

# --- ask is the skill's job ---
printf '[reviewer]\nmode = ask\nclaude:sonnet\ncodex\n' > "$CFG"
newb m-1
out=$("$RV" m-1 2>&1); rc=$?
assert_eq "$rc" "1" "ask: the script refuses to guess"
assert_contains "$out" "mode ask: ask the operator" "ask: says what to do"
assert_file_missing "$TASKS/m-1-rv-sonnet/meta" "ask: nothing spawned"
out=$(timeout 30 "$RV" m-1 --mode parallel --only codex 2>&1)
assert_contains "$out" "review: m-1-rv-codex round 1 of m-1" "ask: --mode and --only run the chosen subset"
assert_file_missing "$TASKS/m-1-rv-sonnet/meta" "ask: the unchosen entry is not spawned"
assert_eq "$(chief_meta_get m-1 reviewer)" "m-1-rv-codex" "ask: only the chosen reviewer is linked"

# --- first ---
newb m-2
out=$(timeout 30 "$RV" m-2 --mode first 2>&1)
assert_contains "$out" "review: m-2-rv-sonnet round 1 of m-2" "first: runs entry 1"
assert_file_missing "$TASKS/m-2-rv-codex/meta" "first: no other entry"
assert_eq "$(chief_meta_get m-2-rv-sonnet agent)" "claude" "first: entry 1's agent"
assert_failure "first: --only is refused" -- "$RV" m-2 --mode first --only codex

# --- parallel from the flag, over a sequential config ---
printf '[reviewer]\nmode = sequential\nstrategy = all\nclaude:sonnet\ncodex\n' > "$CFG"
assert_eq "$(chief_agent_review_plan parallel | tr '\n' ',')" "1 sonnet,2 codex," "plan: parallel with strategy all lists the whole pool"
newb m-3
out=$(timeout 30 "$RV" m-3 --mode parallel 2>&1)
assert_contains "$out" "review: m-3-rv-sonnet, m-3-rv-codex round 1 of m-3" "parallel: --mode overrides the config and starts the pool"
assert_eq "$(chief_meta_get m-3 review_ids)" "m-3-rv-sonnet m-3-rv-codex" "parallel: review_ids is the round"
assert_failure "bad flag: unknown mode" -- "$RV" m-3 --mode nope

# --- sequential: the next starts only on PASS; one wake per run ---
hold_all
newb m-4
"$RV" m-4 > "$WORK/m-4.out" 2>&1 &
RVPID=$!
wait_for has_meta m-4-rv-sonnet
assert_file_missing "$TASKS/m-4-rv-codex/meta" "sequential: only the first entry starts"
assert_eq "$(chief_meta_get m-4 review_pending)" "1" "sequential: the run is pending"
sleep 2
assert_file_missing "$TASKS/m-4-rv-codex/meta" "sequential: the second waits for the first"
finish m-4-rv-sonnet PASS
wait_for has_meta m-4-rv-codex
assert_file_exists "$TASKS/m-4-rv-codex/meta" "sequential: a PASS starts the next entry"
silent=$(watch_out); rc=$?
assert_eq "$rc:$silent" "124:" "sequential: the first reviewer's PASS does not wake Chief"
finish m-4-rv-codex PASS
wait $RVPID; rc=$?
assert_eq "$rc" "0" "sequential: the run completes"
assert_contains "$(cat "$WORK/m-4.out")" "review: m-4-rv-sonnet, m-4-rv-codex round 1 of m-4" "sequential: reports both"
assert_not_contains "$(cat "$WORK/m-4.out")" "stopped" "sequential: not stopped early"
assert_eq "$(chief_meta_get m-4 review_pending)" "" "sequential: pending is lifted"
assert_eq "$(chief_meta_get m-4 review_round)" "1" "sequential: review_round set"
out=$(watch_out)
assert_contains "$out" "all 2 reviewers of m-4 done, combined report: $TASKS/m-4/review-round-1.md" "sequential: one wake with the combined report"

# --- sequential: the first FAIL stops the run and returns its findings ---
hold_all
newb m-5
"$RV" m-5 > "$WORK/m-5.out" 2>&1 &
RVPID=$!
wait_for has_meta m-5-rv-sonnet
finish m-5-rv-sonnet FAIL
wait $RVPID; rc=$?
assert_eq "$rc" "0" "early stop: exits 0"
assert_contains "$(cat "$WORK/m-5.out")" "review: m-5-rv-sonnet round 1 of m-5" "early stop: only the failing reviewer ran"
assert_contains "$(cat "$WORK/m-5.out")" "stopped at m-5-rv-sonnet: done: round 1 FAIL" "early stop: names the FAIL"
assert_file_missing "$TASKS/m-5-rv-codex/meta" "early stop: the next entry never starts"
assert_eq "$(chief_meta_get m-5 reviewer)" "m-5-rv-sonnet" "early stop: only the reviewer that ran is linked"
out=$(watch_out)
assert_contains "$out" "m-5-rv-sonnet: state: done" "early stop: the FAIL wakes Chief"
assert_not_contains "$out" "all " "early stop: a lone reviewer needs no combined report"

# --- sequential round 2: PASS then FAIL stops before the third; a second round re-arms ---
hold_all
printf '[reviewer]\nmode = sequential\nclaude:sonnet\ncodex\ncopilot\n' > "$CFG"
newb m-6
"$RV" m-6 > "$WORK/m-6.out" 2>&1 &
RVPID=$!
wait_for has_meta m-6-rv-sonnet; finish m-6-rv-sonnet PASS
wait_for has_meta m-6-rv-codex; finish m-6-rv-codex FAIL
wait $RVPID
assert_file_missing "$TASKS/m-6-rv-copilot/meta" "stop after PASS,FAIL: the third never starts"
assert_eq "$(chief_meta_get m-6 review_ids)" "m-6-rv-sonnet m-6-rv-codex" "stop after PASS,FAIL: the round is the two that ran"
out=$(watch_out)
assert_contains "$out" "all 2 reviewers of m-6 done" "stop after PASS,FAIL: both are in the round report"
( cd "$CHIEF_HOME/worktrees/m-6" && echo x > x.txt && git add x.txt && git -c user.email=t@t -c user.name=t commit -q -m x )
echo "done: $(git -C "$CHIEF_HOME/worktrees/m-6" rev-parse --short HEAD) fixed" >> "$TASKS/m-6/status"
hold_all
"$RV" m-6 > "$WORK/m-6b.out" 2>&1 &
RVPID=$!
wait_for grep -q "round 2 requested" "$TASKS/m-6-rv-sonnet/status"
assert_file_missing "$TASKS/m-6-rv-codex/inbox/001.msg" "round 2: the second is not re-armed before the first finishes"
echo "done: round 2 FAIL @x" >> "$TASKS/m-6-rv-sonnet/status"
wait $RVPID
assert_file_exists "$TASKS/m-6-rv-sonnet/report.round-1.md" "round 2: the first reviewer's report is archived"
assert_file_missing "$TASKS/m-6-rv-codex/inbox/001.msg" "round 2: an early stop leaves later reviewers alone"
assert_eq "$(chief_meta_get m-6 review_ids)" "m-6-rv-sonnet" "round 2: the round is the one that ran"
assert_eq "$(chief_meta_get m-6 review_round)" "2" "round 2: review_round advances"

# --- --only on a later round skips linked reviewers outside the subset ---
( cd "$CHIEF_HOME/worktrees/m-6" && echo y > y.txt && git add y.txt && git -c user.email=t@t -c user.name=t commit -q -m y )
echo "done: $(git -C "$CHIEF_HOME/worktrees/m-6" rev-parse --short HEAD) again" >> "$TASKS/m-6/status"
out=$(timeout 30 "$RV" m-6 --mode parallel --only codex 2>&1)
assert_contains "$out" "review: m-6-rv-codex round 3 of m-6" "only: round 3 re-arms just the chosen reviewer"
assert_file_exists "$TASKS/m-6-rv-codex/inbox/001.msg" "only: it got the round message"

# --- a failed spawn mid-sequence links nothing ---
hold_all
newb m-7
CHIEF_MOCK_SPAWN_FAIL_ID=m-7-rv-codex "$RV" m-7 > "$WORK/m-7.out" 2>&1 &
RVPID=$!
wait_for has_meta m-7-rv-sonnet; finish m-7-rv-sonnet PASS
wait $RVPID; rc=$?
assert_eq "$rc" "1" "spawn failure: exits 1"
assert_eq "$(chief_meta_get m-7 reviewer)" "" "spawn failure: nothing is linked"
assert_eq "$(chief_meta_get m-7 review_pending)" "" "spawn failure: pending is lifted"
assert_eq "$(chief_meta_get m-7-rv-sonnet status)" "torn-down" "spawn failure: the started reviewer is discarded"

harness_summary
