#!/usr/bin/env bash
# test-control.sh - chief-control.sh: interrupt | exit | relaunch.
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
CTL="$BIN/task/chief-control.sh"
META_LIB="$BIN/lib/meta.sh"

echo "test-control:"

assert_failure "refuses an unknown task id" -- "$CTL" nope interrupt

timeout 10 "$BIN/chief-spawn.sh" t-1 "$WORK/project" --mode builder --branch feat/t-1 --intent "test" --spec "test" --agent claude:opus --args "--verbose" >/dev/null

assert_failure "refuses an unknown verb" -- "$CTL" t-1 bogus

old_pid=$(cat "$CHIEF_HOME/tasks/t-1/term.pid")
assert_success "interrupt succeeds" -- "$CTL" t-1 interrupt
assert_contains "$(cat "$CHIEF_HOME/tasks/t-1/term.log")" "send: Escape" "interrupt delivers Escape to the backend"
kill -0 "$old_pid" 2>/dev/null
assert_eq "$?" "0" "interrupt does NOT stop the agent - it keeps running"

assert_success "exit succeeds" -- "$CTL" t-1 exit
kill -0 "$old_pid" 2>/dev/null
assert_eq "$?" "1" "exit stops the agent process"
assert_file_exists "$CHIEF_HOME/worktrees/t-1" "exit preserves the worktree"
TASK_STATUS=$(. "$BIN/lib/paths.sh"; . "$META_LIB"; chief_meta_get t-1 status)
assert_eq "$TASK_STATUS" "exited" "exit records status=exited"

assert_failure "relaunch without --note is refused" -- "$CTL" t-1 relaunch

mkdir -p "$CHIEF_HOME/config"; echo "codex:gpt-5" > "$CHIEF_HOME/config/agents"
rm -f "$CLAUDE_CONFIG_DIR/.claude.json"
assert_success "relaunch with --note succeeds" -- "$CTL" t-1 relaunch --note "was mid-way adding hello.txt"
assert_contains "$(cat "$CHIEF_HOME/tasks/t-1/meta")" "agent=claude" "relaunch keeps the recorded agent instead of re-selecting from the changed config"
assert_contains "$(cat "$CHIEF_HOME/tasks/t-1/meta")" "model=opus" "relaunch keeps the recorded model"
assert_contains "$(cat "$CHIEF_HOME/tasks/t-1/meta")" "args=--verbose" "relaunch keeps the recorded args"
assert_contains "$(tail -6 "$WORK/.chief/tasks/t-1/brief.md")" "was mid-way adding hello.txt" "the checkpoint note is appended to the brief"
assert_contains "$(tail -6 "$WORK/.chief/tasks/t-1/brief.md")" "Relaunch checkpoint" "the checkpoint section is clearly marked"
new_pid=$(cat "$CHIEF_HOME/tasks/t-1/term.pid")
kill -0 "$new_pid" 2>/dev/null
assert_eq "$?" "0" "relaunch starts a new backend process in the same worktree"
assert_eq "$(jq -r --arg p "$CHIEF_HOME/worktrees/t-1" '.projects[$p].hasTrustDialogAccepted' "$CLAUDE_CONFIG_DIR/.claude.json")" "true" "relaunch re-trusts the worktree"
TASK_STATUS2=$(. "$BIN/lib/paths.sh"; . "$META_LIB"; chief_meta_get t-1 status)
assert_eq "$TASK_STATUS2" "working" "relaunch records status=working again"

# a relaunched brainstormer gets its attach hint recomputed
timeout 10 "$BIN/chief-spawn.sh" bs-1 "$WORK/project" --mode brainstormer --branch feat/bs-1 --intent "idea" >/dev/null
sed -i '/^attach=/d' "$CHIEF_HOME/tasks/bs-1/meta"
out=$("$CTL" bs-1 relaunch --note "mid-way")
assert_contains "$out" "attach: tail -f" "relaunch of a brainstormer prints the attach hint again"
assert_contains "$(cat "$CHIEF_HOME/tasks/bs-1/meta")" "attach=tail -f" "relaunch of a brainstormer re-records attach="
"$CTL" t-1 relaunch --note "again" >/dev/null
assert_not_contains "$(cat "$CHIEF_HOME/tasks/t-1/meta")" "attach=" "relaunch of a builder records no attach="

harness_summary
