#!/usr/bin/env bash
# test-worktree-guard.sh - chief_is_linked_worktree, the check that keeps
# Chief's identity/supervision hooks from misfiring inside a spawned
# builder's own worktree. Race-free (git-dir vs git-common-dir), so it's
# testable with plain git - no backend needed at all.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
CHIEF_BIN="$REPO_ROOT/plugins/chief/bin"
. "$TEST_DIR/lib/harness.sh"
. "$CHIEF_BIN/lib/worktree.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "test-worktree-guard:"

mkdir -p "$WORK/main" && cd "$WORK/main"
git init -q -b main
git commit --allow-empty -q -m init
git worktree add -q -b feature "$WORK/linked"

( cd "$WORK/main" && chief_is_linked_worktree )
assert_eq "$?" "1" "the main checkout is NOT reported as a linked worktree"

( cd "$WORK/linked" && chief_is_linked_worktree )
assert_eq "$?" "0" "a linked worktree IS reported as one"

( cd "$WORK" && chief_is_linked_worktree )
assert_eq "$?" "1" "a plain non-git directory is not reported as a linked worktree"

( cd "$WORK/main" && chief_is_linked_worktree "$WORK/linked" )
assert_eq "$?" "0" "an explicit dir argument is judged instead of the cwd"

( cd "$WORK/linked" && chief_is_linked_worktree "$WORK/main" )
assert_eq "$?" "1" "an explicit main-checkout dir is not linked even when the cwd is"

harness_summary
