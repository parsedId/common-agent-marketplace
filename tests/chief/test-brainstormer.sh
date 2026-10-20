#!/usr/bin/env bash
# test-brainstormer.sh - the brainstormer brief and lifecycle content, and the
# attach hint chief-spawn.sh records for it, against the mock backend.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
BIN="$REPO_ROOT/plugins/chief/bin"
. "$TEST_DIR/lib/harness.sh"

echo "test-brainstormer:"

WORK=$(mktemp -d)
harness_trap 'rm -rf "$WORK"'
mkdir -p "$WORK/project" && cd "$WORK/project" && git init -q -b master
git commit --allow-empty -q -m init
export CHIEF_HOME="$WORK/.chief"
export CHIEF_BACKEND=mock
. "$BIN/lib/paths.sh"
. "$BIN/lib/meta.sh"

spawn() {  # <id> <role> [flags...]
  local id=$1 role=$2; shift 2
  timeout 10 "$BIN/chief-spawn.sh" "$id" "$WORK/project" --mode "$role" --branch "feat/$id" --intent "shape the idea" "$@"
}

out=$(spawn bs-1 brainstormer)
BRIEF=$(cat "$TASKS/bs-1/brief.md")

# the brief: self-contained, agent-neutral, explicit about confirmation and scope
assert_contains "$BRIEF" "shape the idea" "brief: the operator's intent is rendered"
assert_contains "$BRIEF" "you talk to the operator directly" "brief: says the operator is addressed directly"
assert_contains "$BRIEF" "in this pane" "brief: questions happen in the pane"
assert_contains "$BRIEF" "Never ask through \`needs-decision\`" "brief: no needs-decision for questions"
assert_contains "$BRIEF" "Never report \`done\` before the operator has explicitly confirmed the spec" "brief: done requires the operator's explicit confirmation"
assert_contains "$BRIEF" "TDD, implementation plans, writing project code, committing, pushing, opening a PR" "brief: lists what is out of scope"
assert_contains "$BRIEF" "$TASKS/bs-1/report.md" "brief: the spec goes to the standard report path"
assert_contains "$BRIEF" "touch $TASKS/bs-1/turn-ended" "brief: the turn-ended protocol is present"
assert_contains "$BRIEF" "working: brainstorming with operator" "brief: names the first status line"
assert_contains "$BRIEF" "done: spec ready" "brief: names the final status line"
assert_contains "$BRIEF" "report \`working: revising spec\` first" "brief: a revision after done starts with a working line"
assert_contains "$BRIEF" "Edit no project files" "brief: forbids project edits"
for section in Goal "In scope" "Out of scope" "Behavior and acceptance criteria" Decisions "Open questions"; do
  assert_contains "$BRIEF" "**$section**" "brief: the spec skeleton has $section"
done
assert_contains "$BRIEF" "rationale, the options rejected, and what existing code it reuses" "brief: decisions carry rationale, rejected options and reuse"
assert_contains "$BRIEF" "never saw this conversation" "brief: the spec must stand alone for another agent"
assert_not_contains "$BRIEF" "superpowers" "brief: no dependency on superpowers"
assert_not_contains "$BRIEF" "writing-plans" "brief: no downstream plan-writing hand-off"
assert_not_contains "$BRIEF" "/brainstorming" "brief: does not load a brainstorming skill"
assert_not_contains "$(sed 's/CLAUDE\.md//g' <<< "$BRIEF" | tr A-Z a-z)" "claude" "brief: agent-neutral wording"
for ph in TASK SPEC BRANCH REPORT_FILE STATUS_FILE TURN_FILE INBOX_DIR; do
  assert_not_contains "$BRIEF" "{$ph}" "brief: no unfilled {$ph}"
done
[ "$(wc -l < "$REPO_ROOT/plugins/chief/templates/brief-brainstormer.md")" -le 55 ]
assert_eq "$?" "0" "brief: stays about 50 lines"

# lifecycle
LIFECYCLE=$(cat "$TASKS/bs-1/lifecycle")
assert_contains "$LIFECYCLE" "(brainstormer)" "lifecycle: is the brainstormer checklist"
assert_contains "$LIFECYCLE" "attach:" "lifecycle: tells Chief to hand the operator the attach line"
assert_contains "$LIFECYCLE" "chief-spawn.sh --from" "lifecycle: ends in a handoff or acceptance"
assert_not_contains "$LIFECYCLE" "{TASK_ID}" "lifecycle: no unfilled placeholder"

# attach hint: printed and recorded for a brainstormer only
assert_contains "$out" "attach: tail -f '$TASKS/bs-1/term.log'" "spawn: prints the attach hint for a brainstormer"
assert_eq "$(chief_meta_get bs-1 attach)" "tail -f '$TASKS/bs-1/term.log'" "spawn: records attach= in meta"
assert_not_contains "$(spawn b-1 builder)" "attach:" "spawn: no attach line for a builder"
assert_eq "$(chief_meta_get b-1 attach 2>/dev/null)" "" "spawn: no attach= for a builder"
assert_not_contains "$(spawn bs-d brainstormer --dry-run)" "attach:" "dry-run: prints no attach line"
assert_file_missing "$TASKS/bs-d/meta" "dry-run: creates nothing"

# a brainstormer started as a handoff successor gets the hint too (the pairs are in test-handoff.sh)
spawn r-1 researcher >/dev/null
echo "done: found it" >> "$TASKS/r-1/status"
echo "# findings" > "$TASKS/r-1/report.md"
assert_success "handoff: researcher -> brainstormer" -- spawn bs-3 brainstormer --from r-1
assert_contains "$(chief_meta_get bs-3 attach)" "tail -f" "handoff: a brainstormer successor records an attach hint"

harness_summary
