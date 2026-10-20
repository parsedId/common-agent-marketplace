#!/usr/bin/env bash
# test-teardown.sh - chief-teardown.sh's non-happy-path branches: a researcher's
# unconditional discard (a researcher's deliverable is its report at
# tasks/<id>/report.md, outside the worktree - the worktree itself was
# always scratch, so there is nothing to prove "landed" before discarding
# it), and a builder's explicit --abandon override. The ordinary
# builder-refuses-then-succeeds-after-merge path is already covered end to end
# by test-lifecycle.sh; this file only covers what that one doesn't.
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

echo "test-teardown:"

# --- a researcher, never landed, with a throwaway commit ---------------------
assert_success "backlog: file the researcher" -- "$BIN/chief-backlog.sh" add s-1 "Investigate caching options"
assert_success "spawn: researcher task" -- \
  timeout 10 "$BIN/chief-spawn.sh" s-1 "$WORK/project" --mode researcher --branch feat/s-1 --intent "Investigate caching options"
assert_contains "$(cat "$CHIEF_HOME/tasks/s-1/lifecycle")" "handed off to a successor" \
  "spawn: a researcher task gets the researcher lifecycle checklist, not the builder one"
echo "findings: use an LRU cache" > "$CHIEF_HOME/tasks/s-1/report.md"

# Simulate the researcher doing exactly what its brief invites: a throwaway
# commit in its own scratch worktree, never meant to land.
(
  cd "$CHIEF_HOME/worktrees/s-1" || exit 1
  echo scratch > scratch.txt
  git add scratch.txt
  git -c user.email=t@t -c user.name=t commit -q -m "scratch"
)
echo "done: wrote report.md" >> "$CHIEF_HOME/tasks/s-1/status"

assert_success "teardown: a researcher tears down unconditionally, even with an unlanded commit" -- \
  "$BIN/chief-teardown.sh" s-1
assert_file_missing "$CHIEF_HOME/worktrees/s-1" "teardown: researcher worktree removed"
assert_file_missing "$CHIEF_HOME/tasks/s-1" "teardown: the task folder leaves tasks/"
assert_file_exists "$CHIEF_HOME/archive/s-1/report.md" "teardown: the researcher's report survives in the archive"
assert_eq "$(cat "$CHIEF_HOME/archive/s-1/report.md")" "findings: use an LRU cache" "teardown: the report content is untouched"
assert_contains "$(cat "$CHIEF_HOME/archive/s-1/meta")" "status=torn-down" "teardown: the archived meta says torn-down"
assert_contains "$("$BIN/chief-backlog.sh" show s-1)" "[done]" "teardown: backlog item marked done"

# --- a builder, never landed, explicitly abandoned --------------------------
assert_success "backlog: file the builder" -- "$BIN/chief-backlog.sh" add b-1 "Add hello.txt"
assert_success "spawn: builder task" -- \
  timeout 10 "$BIN/chief-spawn.sh" b-1 "$WORK/project" --mode builder --branch feat/b-1 --intent "Add hello.txt" --spec "content: hello"
(
  cd "$CHIEF_HOME/worktrees/b-1" || exit 1
  echo hello > hello.txt
  git add hello.txt
  git -c user.email=t@t -c user.name=t commit -q -m "add hello.txt"
)
echo "done: added hello.txt" >> "$CHIEF_HOME/tasks/b-1/status"

assert_failure "teardown: still refuses a builder with no --abandon, even after done" -- "$BIN/chief-teardown.sh" b-1
assert_file_exists "$CHIEF_HOME/worktrees/b-1" "teardown refusal: builder worktree is untouched"

assert_success "teardown: --abandon force-discards an unlanded builder" -- "$BIN/chief-teardown.sh" b-1 --abandon
assert_file_missing "$CHIEF_HOME/worktrees/b-1" "teardown --abandon: worktree removed"
assert_not_contains "$(git -C "$WORK/project" worktree list)" "worktrees/b-1" "teardown --abandon: git no longer tracks the worktree"
assert_contains "$("$BIN/chief-backlog.sh" show b-1)" "[done]" "teardown --abandon: backlog item marked done"

# --- an already-landed builder still doesn't need --abandon -----------------
assert_success "backlog: file a second builder" -- "$BIN/chief-backlog.sh" add b-2 "Add world.txt"
assert_success "spawn: second builder task" -- \
  timeout 10 "$BIN/chief-spawn.sh" b-2 "$WORK/project" --mode builder --branch feat/b-2 --intent "Add world.txt" --spec "content: world"
(
  cd "$CHIEF_HOME/worktrees/b-2" || exit 1
  echo world > world.txt
  git add world.txt
  git -c user.email=t@t -c user.name=t commit -q -m "add world.txt"
)
git -C "$WORK/project" merge --ff-only feat/b-2 >/dev/null
assert_success "teardown: a landed builder tears down without --abandon, as before" -- "$BIN/chief-teardown.sh" b-2

# --- a squash-merged builder: never a local ancestor, but landed -------
GC=(git -c user.email=t@t -c user.name=t)
assert_success "backlog: file a third builder" -- "$BIN/chief-backlog.sh" add b-3 "Add moon.txt"
assert_success "spawn: third builder task" -- \
  timeout 10 "$BIN/chief-spawn.sh" b-3 "$WORK/project" --mode builder --branch feat/b-3 --intent "Add moon.txt" --spec "content: moon"
(
  cd "$CHIEF_HOME/worktrees/b-3" || exit 1
  echo moon > moon.txt
  git add moon.txt
  "${GC[@]}" commit -q -m "add moon.txt"
)

assert_failure "teardown: refuses a builder whose content is not on the default branch" -- "$BIN/chief-teardown.sh" b-3
assert_file_exists "$CHIEF_HOME/worktrees/b-3" "teardown refusal (not landed): worktree is untouched"

git -C "$WORK/project" merge --squash feat/b-3 >/dev/null
"${GC[@]}" -C "$WORK/project" commit -q -m "squash feat/b-3"
assert_success "teardown: a squash-merged builder lands via the git-only check" -- "$BIN/chief-teardown.sh" b-3
assert_file_missing "$CHIEF_HOME/worktrees/b-3" "teardown (squash-merged): worktree removed"
assert_contains "$("$BIN/chief-backlog.sh" show b-3)" "[done]" "teardown (squash-merged): backlog item marked done"

# --- squash-merged, then the default branch changed the same file: unprovable
assert_success "backlog: file a diverged builder" -- "$BIN/chief-backlog.sh" add b-5 "Add star.txt"
assert_success "spawn: diverged builder task" -- \
  timeout 10 "$BIN/chief-spawn.sh" b-5 "$WORK/project" --mode builder --branch feat/b-5 --intent "Add star.txt" --spec "content: star"
(
  cd "$CHIEF_HOME/worktrees/b-5" || exit 1
  echo star > star.txt
  git add star.txt
  "${GC[@]}" commit -q -m "add star.txt"
)
git -C "$WORK/project" merge --squash feat/b-5 >/dev/null
"${GC[@]}" -C "$WORK/project" commit -q -m "squash feat/b-5"
echo "bright star" > "$WORK/project/star.txt"
"${GC[@]}" -C "$WORK/project" commit -q -am "rework star.txt"

assert_failure "teardown: refuses a squash-merged builder whose landing git cannot prove" -- "$BIN/chief-teardown.sh" b-5
assert_file_exists "$CHIEF_HOME/worktrees/b-5" "teardown refusal (unprovable): worktree is untouched"
assert_success "teardown: --abandon discards it once the operator has verified the merge" -- "$BIN/chief-teardown.sh" b-5 --abandon

# --- the remote branch is kept unless --delete-remote is passed ---------
BARE="$WORK/origin.git"
git init -q --bare "$BARE"
git -C "$WORK/project" remote add origin "$BARE"
git -C "$WORK/project" push -q origin master

spawn_pushed() {  # <id> <branch>
  assert_success "backlog: file $1" -- "$BIN/chief-backlog.sh" add "$1" "Add $1.txt"
  assert_success "spawn: $1" -- \
    timeout 10 "$BIN/chief-spawn.sh" "$1" "$WORK/project" --mode builder --branch "$2" --intent "Add $1.txt" --spec "content: $1"
  (
    cd "$CHIEF_HOME/worktrees/$1" || exit 1
    echo "$1" > "$1.txt"
    git add "$1.txt"
    git -c user.email=t@t -c user.name=t commit -q -m "add $1.txt"
    git push -q origin "$2"
  )
  assert_contains "$(git -C "$BARE" branch --list "$2")" "$2" "setup: $2 pushed to origin"
}

spawn_pushed b-4 feat/b-4
git -C "$WORK/project" merge --ff-only feat/b-4 >/dev/null
assert_success "teardown: a landed builder tears down" -- "$BIN/chief-teardown.sh" b-4
assert_contains "$(git -C "$BARE" branch --list feat/b-4)" "feat/b-4" "teardown: remote branch kept by default"

spawn_pushed p-5 feat/p-5
assert_success "teardown: --abandon tears down" -- "$BIN/chief-teardown.sh" p-5 --abandon
assert_contains "$(git -C "$BARE" branch --list feat/p-5)" "feat/p-5" "teardown --abandon: remote branch kept"

spawn_pushed p-6 feat/p-6
assert_success "teardown: --abandon --delete-remote tears down" -- "$BIN/chief-teardown.sh" p-6 --abandon --delete-remote
assert_eq "$(git -C "$BARE" branch --list feat/p-6)" "" "teardown --delete-remote: remote branch deleted"

spawn_pushed p-7 feat/p-7
git -C "$WORK/project" remote set-url origin "$WORK/nowhere.git"
assert_failure "teardown: --delete-remote fails loudly when it cannot reach the remote" -- \
  "$BIN/chief-teardown.sh" p-7 --abandon --delete-remote
assert_file_exists "$CHIEF_HOME/worktrees/p-7" "teardown --delete-remote failure: worktree untouched"
assert_contains "$("$BIN/chief-backlog.sh" show p-7)" "[in-flight]" "teardown --delete-remote failure: backlog item untouched"
git -C "$WORK/project" remote set-url origin "$BARE"
assert_success "teardown: --abandon clears it afterwards" -- "$BIN/chief-teardown.sh" p-7 --abandon

# origin reachable but rejecting the delete: fails loudly, nothing torn down
spawn_pushed p-10 feat/p-10
printf '#!/bin/sh\nwhile read old new ref; do [ "$new" = 0000000000000000000000000000000000000000 ] && exit 1; done\nexit 0\n' > "$BARE/hooks/pre-receive"
chmod +x "$BARE/hooks/pre-receive"
assert_failure "teardown: --delete-remote fails loudly when the push is rejected" -- \
  "$BIN/chief-teardown.sh" p-10 --abandon --delete-remote
assert_file_exists "$CHIEF_HOME/worktrees/p-10" "teardown --delete-remote rejected: worktree untouched"
assert_contains "$(git -C "$WORK/project" branch --list feat/p-10)" "feat/p-10" "teardown --delete-remote rejected: local branch untouched"
rm "$BARE/hooks/pre-receive"
assert_success "teardown: --abandon clears it afterwards (rejected push)" -- "$BIN/chief-teardown.sh" p-10 --abandon

# researcher/reviewer discard path keeps the remote branch too
assert_success "spawn: pushed researcher" -- \
  timeout 10 "$BIN/chief-spawn.sh" p-8 "$WORK/project" --mode researcher --branch feat/p-8 --intent x
git -C "$CHIEF_HOME/worktrees/p-8" push -q origin feat/p-8
assert_success "teardown: researcher tears down" -- "$BIN/chief-teardown.sh" p-8
assert_contains "$(git -C "$BARE" branch --list feat/p-8)" "feat/p-8" "teardown (researcher): remote branch kept"

# --delete-remote on a builder is not passed on to its reviewer
spawn_pushed p-9 feat/p-9
assert_success "spawn: linked reviewer" -- \
  timeout 10 "$BIN/chief-spawn.sh" p-9-review "$WORK/project" --mode reviewer --branch chore/review-p-9 --intent x
git -C "$CHIEF_HOME/worktrees/p-9-review" push -q origin chore/review-p-9
( . "$BIN/lib/paths.sh"; . "$BIN/lib/meta.sh"; chief_meta_set p-9 reviewer p-9-review )
assert_success "teardown: builder with --delete-remote tears down" -- "$BIN/chief-teardown.sh" p-9 --abandon --delete-remote
assert_eq "$(git -C "$BARE" branch --list feat/p-9)" "" "teardown: builder's remote branch deleted"
assert_file_missing "$CHIEF_HOME/worktrees/p-9-review" "teardown: the reviewer was discarded too"
assert_contains "$(git -C "$BARE" branch --list chore/review-p-9)" "chore/review-p-9" "teardown: --delete-remote not passed on to the reviewer"

# --- a brainstormer discards like a researcher ---
assert_success "spawn: brainstormer task" -- \
  timeout 10 "$BIN/chief-spawn.sh" bs-1 "$WORK/project" --mode brainstormer --branch feat/bs-1 --intent x
assert_success "teardown: a brainstormer discards unconditionally" -- "$BIN/chief-teardown.sh" bs-1
assert_contains "$("$BIN/chief-teardown.sh" bs-1)" "torn down: bs-1" "teardown: re-running on an archived task completes"
assert_file_exists "$CHIEF_HOME/archive/bs-1/meta" "teardown: the re-run leaves the archive in place"

# --- teardown releases the task's pre-trusted worktree -------------------
export CHIEF_HOME="$WORK/.chief-trust"
CFG="$CLAUDE_CONFIG_DIR/.claude.json"
trusted() { jq -r --arg p "$CHIEF_HOME/worktrees/p-1" '.projects[$p].hasTrustDialogAccepted // "unset"' "$CFG"; }
. "$BIN/lib/paths.sh"
. "$BIN/lib/agents/claude.sh"
timeout 10 "$BIN/chief-spawn.sh" p-1 "$WORK/project" --mode researcher --branch feat/p-1 --intent x >/dev/null
STATE="$CHIEF_HOME/state" agent_prepare "$CHIEF_HOME/worktrees/p-1"
assert_eq "$(trusted)" "true" "setup: worktree trusted"
"$BIN/chief-teardown.sh" p-1 >/dev/null
assert_eq "$(trusted)" "unset" "teardown: worktree untrusted"

harness_summary
