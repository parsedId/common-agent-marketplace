#!/usr/bin/env bash
# test-lifecycle.sh - the full happy path end to end against the mock
# backend: file a backlog item, spawn, simulate the builder's own work,
# confirm teardown refuses before a merge exists, merge, then confirm
# teardown succeeds and cleans up. This is the scenario that matters most -
# it's the one a real dispatch actually goes through.
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

echo "test-lifecycle:"

assert_success "backlog: file the task" -- "$BIN/chief-backlog.sh" add t-1 "Add hello.txt"
assert_contains "$("$BIN/chief-backlog.sh" list)" "[queued]" "backlog: starts queued"

assert_success "spawn: creates the worktree and launches the mock backend" -- \
  timeout 10 "$BIN/chief-spawn.sh" t-1 "$WORK/project" --mode builder --branch feat/t-1 --intent "Add hello.txt" --spec "content: hello"

assert_contains "$("$BIN/chief-backlog.sh" show t-1)" "[in-flight]" "spawn: marks the backlog item in-flight"
assert_file_exists "$CHIEF_HOME/worktrees/t-1" "spawn: worktree exists"
assert_file_exists "$CHIEF_HOME/tasks/t-1/brief.md" "spawn: brief exists"
assert_contains "$(cat "$CHIEF_HOME/tasks/t-1/brief.md")" "Add hello.txt" "spawn: intent is rendered into the brief"
assert_contains "$(cat "$CHIEF_HOME/tasks/t-1/brief.md")" "report \`working" "spawn: the builder brief tells it to re-announce working after resuming from a terminal status"

# Simulate the builder actually doing its job - a real commit in its worktree.
(
  cd "$CHIEF_HOME/worktrees/t-1" || exit 1
  echo hello > hello.txt
  git add hello.txt
  git -c user.email=t@t -c user.name=t commit -q -m "add hello.txt"
)
echo "done: added hello.txt" >> "$CHIEF_HOME/tasks/t-1/status"

assert_contains "$("$BIN/task/chief-crew-state.sh" t-1)" "state: done" "crew-state: reports done once the builder reports it"

assert_failure "teardown: refuses before the branch has landed anywhere" -- "$BIN/chief-teardown.sh" t-1
assert_file_exists "$CHIEF_HOME/worktrees/t-1" "teardown refusal: worktree is untouched"

assert_success "merge: fast-forward the task branch into the default branch" -- \
  git -C "$WORK/project" merge --ff-only feat/t-1
assert_file_exists "$WORK/project/hello.txt" "merge: the file is now in the main checkout"
assert_eq "$(cat "$WORK/project/hello.txt")" "hello" "merge: the file content is correct"

assert_success "teardown: succeeds once the branch has landed" -- "$BIN/chief-teardown.sh" t-1
assert_file_missing "$CHIEF_HOME/worktrees/t-1" "teardown: worktree removed"
assert_not_contains "$(git -C "$WORK/project" worktree list)" "worktrees/t-1" "teardown: git no longer tracks the worktree"
assert_contains "$("$BIN/chief-backlog.sh" show t-1)" "[done]" "teardown: backlog item marked done"

harness_summary
