#!/usr/bin/env bash
# test-backlog.sh - chief-backlog.sh: the whole markdown-file backlog.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
CHIEF_BIN="$REPO_ROOT/plugins/chief/bin"
BL="$CHIEF_BIN/chief-backlog.sh"
. "$TEST_DIR/lib/harness.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" && git init -q
export CHIEF_HOME="$WORK/.chief"
. "$CHIEF_BIN/lib/paths.sh"
. "$CHIEF_BIN/lib/meta.sh"
BACKLOG="$CHIEF_HOME/backlog.md"

echo "test-backlog:"

assert_success "add files a new queued record" -- "$BL" add t-1 "Add rate limiting"
assert_success "add a second record" -- "$BL" add t-2 "Fix flaky test"
assert_contains "$("$BL" list)" "## t-1 [queued] Add rate limiting" "list shows the new record"
assert_eq "$("$BL" next)" "t-1" "next returns the first queued id"

assert_success "status moves a record to in-flight" -- "$BL" status t-1 in-flight
assert_contains "$("$BL" show t-1)" "[in-flight]" "show reflects the new status"
assert_eq "$("$BL" next)" "t-2" "next skips the now in-flight record"

assert_success "hold sets status and note together" -- "$BL" hold t-1 "blocked on captain - which limiter lib?"
assert_contains "$("$BL" show t-1)" "[held]" "hold sets status to held"
assert_contains "$("$BL" show t-1)" "note: blocked on captain" "hold records the reason"
assert_eq "$(chief_meta_get t-1 status 2>/dev/null || true)" "" "hold is a no-op on task meta when t-1 has no meta record yet"

assert_success "note overwrites the existing note, not appends" -- "$BL" note t-1 "operator said: token-bucket"
assert_contains "$(cat "$BACKLOG")" "note: operator said: token-bucket" "the new note text is present"
assert_not_contains "$(cat "$BACKLOG")" "blocked on captain" "the old note text is gone, not duplicated"
assert_eq "$(grep -c '^note:' "$BACKLOG")" "1" "exactly one note line exists for t-1"

assert_success "done marks a record done" -- "$BL" done t-2
assert_contains "$("$BL" list done)" "t-2" "list done filters correctly"
assert_eq "$("$BL" next)" "" "next returns nothing once no record is queued"

# --- a record whose task DOES have a chief-meta record -------------------
# (i.e. it was actually spawned) - hold/done must advance its meta status
# away from "working" so chief-watch.sh's in_flight_ids stops including it.
assert_success "add a third record" -- "$BL" add t-3 "Third task"
chief_meta_set t-3 status working
assert_success "hold on a spawned task also advances its meta status" -- "$BL" hold t-3 "needs a decision"
assert_eq "$(chief_meta_get t-3 status)" "held" "hold advances a spawned task's meta status away from working"

assert_success "add a fourth record" -- "$BL" add t-4 "Fourth task"
chief_meta_set t-4 status working
assert_success "done on a spawned task also advances its meta status" -- "$BL" done t-4

# --- un-holding via status in-flight must restore watcher tracking (#31) --
assert_success "add a fifth record" -- "$BL" add t-5 "Fifth task"
chief_meta_set t-5 status working
assert_success "hold t-5" -- "$BL" hold t-5 "needs a decision"
assert_eq "$(chief_meta_get t-5 status)" "held" "t-5 meta status is held after hold"
assert_success "status in-flight un-holds t-5" -- "$BL" status t-5 in-flight
assert_contains "$("$BL" show t-5)" "[in-flight]" "backlog show reflects in-flight"
assert_eq "$(chief_meta_get t-5 status)" "working" \
  "the documented un-hold step (status in-flight) restores meta status to working, so chief-watch.sh's in_flight_ids picks it back up"

assert_success "file a task with an agent" -- "$BL" add t-6 "Sixth task"
chief_meta_set t-6 agent codex; chief_meta_set t-6 model gpt-5
assert_not_contains "$("$BL" show t-6)" "[agent:" "show: a queued record carries no agent"
"$BL" status t-6 in-flight >/dev/null
assert_contains "$("$BL" show t-6)" "## t-6 [in-flight] Sixth task [agent: codex:gpt-5]" "show: an in-flight record appends its agent after the title"
assert_contains "$("$BL" list in-flight)" "## t-6 [in-flight] Sixth task [agent: codex:gpt-5]" "list: an in-flight record appends its agent"
assert_contains "$("$BL" list)" "## t-5 [in-flight] Fifth task" "list: other records keep their prefix format"
assert_eq "$("$BL" next)" "" "next: unaffected"

assert_success "status in-flight is a no-op on task meta when the task has no meta record yet" -- "$BL" status t-2 in-flight
assert_eq "$(chief_meta_get t-2 status 2>/dev/null || true)" "" "no meta record was created for t-2 by the in-flight transition"
assert_eq "$(chief_meta_get t-4 status)" "done" "done advances a spawned task's meta status away from working"

assert_failure "add refuses a duplicate id" -- "$BL" add t-1 "dup"
assert_failure "status refuses an unknown id" -- "$BL" status nope queued
assert_failure "status refuses an invalid status value" -- "$BL" status t-1 bogus
assert_failure "note refuses an unknown id" -- "$BL" note nope "x"
# NOTE: show does not validate the id - an unknown id just prints nothing
# (exit 0). Documenting actual behavior here, not asserting it's ideal.
assert_eq "$("$BL" show nope)" "" "show on an unknown id prints nothing rather than erroring"

harness_summary
