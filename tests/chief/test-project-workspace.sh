#!/usr/bin/env bash
# test-project-workspace.sh - the spawn flow against the mock
# backend: origin sync before the task worktree exists, and all Chief state
# under CHIEF_HOME - never a .chief inside a project.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
BIN="$REPO_ROOT/plugins/chief/bin"
. "$TEST_DIR/lib/harness.sh"

echo "test-project-workspace:"

WORK=$(mktemp -d)
harness_trap 'rm -rf "$WORK"'
GIT=(git -c user.email=t@t -c user.name=t)

# A workspace repo with a project checkout nested inside (as projects/<repo>),
# whose origin is ahead of the local checkout.
mkdir -p "$WORK/ws/projects" && git -C "$WORK/ws" init -q -b main
git init -q --bare -b main "$WORK/origin.git"
git clone -q "$WORK/origin.git" "$WORK/ws/projects/app" 2>/dev/null
P="$WORK/ws/projects/app"
"${GIT[@]}" -C "$P" commit --allow-empty -q -m init && git -C "$P" push -q origin main
git clone -q "$WORK/origin.git" "$WORK/other"
echo new > "$WORK/other/from-origin.txt"
"${GIT[@]}" -C "$WORK/other" add . && "${GIT[@]}" -C "$WORK/other" commit -q -m "advance origin" && git -C "$WORK/other" push -q origin main

export CHIEF_BACKEND=mock
unset CHIEF_HOME
HOME_DIR="$WORK/ws/.chief"

# --- spawn from inside the project: state still lands at the workspace root
cd "$P"
assert_success "spawn: first task, run with cwd inside the project" -- \
  timeout 20 "$BIN/chief-spawn.sh" a-1 "$P" --mode builder --branch feat/a-1 --intent "one"
assert_file_exists "$HOME_DIR/tasks/a-1/meta" "spawn: CHIEF_HOME resolved to the workspace root, not the project"
assert_file_missing "$P/.chief" "spawn: no .chief created inside the project"
assert_file_exists "$WORK/ws/.chief/worktrees/a-1/from-origin.txt" "spawn: the worktree branches from the freshly synced origin"

# --- default CHIEF_HOME resolution from a project and from its worktree
assert_success "spawn: a task to resolve from" -- timeout 20 "$BIN/chief-spawn.sh" b-1 "$P" --mode builder --branch feat/b-1 --intent "three"
for dir in "$P" "$WORK/ws/.chief/worktrees/b-1"; do
  assert_success "backlog from ${dir#"$WORK"/}" -- bash -c "cd '$dir' && '$BIN/chief-backlog.sh' add x-$RANDOM t"
  assert_file_missing "$dir/.chief" "no .chief created in ${dir#"$WORK"/}"
done
"$BIN/chief-teardown.sh" b-1 --abandon >/dev/null 2>&1

harness_summary
