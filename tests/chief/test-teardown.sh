#!/usr/bin/env bash
# test-teardown.sh - chief-teardown.sh's non-happy-path branches: a researcher's
# unconditional discard (a researcher's deliverable is its report at
# $DATA/<id>/report.md, outside the worktree - the worktree itself was
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
assert_contains "$(cat "$CHIEF_HOME/state/s-1.lifecycle")" "handed off to a successor" \
  "spawn: a researcher task gets the researcher lifecycle checklist, not the builder one"
echo "findings: use an LRU cache" > "$CHIEF_HOME/data/s-1/report.md"

# Simulate the researcher doing exactly what its brief invites: a throwaway
# commit in its own scratch worktree, never meant to land.
(
  cd "$CHIEF_HOME/worktrees/s-1" || exit 1
  echo scratch > scratch.txt
  git add scratch.txt
  git -c user.email=t@t -c user.name=t commit -q -m "scratch"
)
echo "done: wrote report.md" >> "$CHIEF_HOME/state/s-1.status"

assert_success "teardown: a researcher tears down unconditionally, even with an unlanded commit" -- \
  "$BIN/chief-teardown.sh" s-1
assert_file_missing "$CHIEF_HOME/worktrees/s-1" "teardown: researcher worktree removed"
assert_file_exists "$CHIEF_HOME/data/s-1/report.md" "teardown: the researcher's report survives - it lives outside the worktree"
assert_eq "$(cat "$CHIEF_HOME/data/s-1/report.md")" "findings: use an LRU cache" "teardown: the report content is untouched"
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
echo "done: added hello.txt" >> "$CHIEF_HOME/state/b-1.status"

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

# --- a squash/rebase-merged PR: the branch is never a local ancestor of --
# --- the default branch, but the provider confirms it's merged ---------
. "$BIN/lib/paths.sh"
. "$BIN/lib/meta.sh"

assert_success "backlog: file a third builder" -- "$BIN/chief-backlog.sh" add b-3 "Add moon.txt"
assert_success "spawn: third builder task" -- \
  timeout 10 "$BIN/chief-spawn.sh" b-3 "$WORK/project" --mode builder --branch feat/b-3 --intent "Add moon.txt" --spec "content: moon"
(
  cd "$CHIEF_HOME/worktrees/b-3" || exit 1
  echo moon > moon.txt
  git add moon.txt
  git -c user.email=t@t -c user.name=t commit -q -m "add moon.txt"
)
chief_meta_set b-3 pr_url "https://example.invalid/mock/pr/99"
chief_meta_set b-3 pr_provider mock

assert_failure "teardown: still refuses when the recorded PR isn't reported merged" -- "$BIN/chief-teardown.sh" b-3
assert_file_exists "$CHIEF_HOME/worktrees/b-3" "teardown refusal (PR not merged): worktree is untouched"

export CHIEF_PR_MOCK_MERGED=1
assert_success "teardown: a PR the provider reports merged lands even though the branch isn't a local ancestor" -- \
  "$BIN/chief-teardown.sh" b-3
unset CHIEF_PR_MOCK_MERGED
assert_file_missing "$CHIEF_HOME/worktrees/b-3" "teardown (PR merged): worktree removed"
assert_contains "$("$BIN/chief-backlog.sh" show b-3)" "[done]" "teardown (PR merged): backlog item marked done"

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

spawn_pushed b-5 feat/b-5
assert_success "teardown: --abandon tears down" -- "$BIN/chief-teardown.sh" b-5 --abandon
assert_contains "$(git -C "$BARE" branch --list feat/b-5)" "feat/b-5" "teardown --abandon: remote branch kept"

spawn_pushed b-6 feat/b-6
assert_success "teardown: --abandon --delete-remote tears down" -- "$BIN/chief-teardown.sh" b-6 --abandon --delete-remote
assert_eq "$(git -C "$BARE" branch --list feat/b-6)" "" "teardown --delete-remote: remote branch deleted"

spawn_pushed b-7 feat/b-7
git -C "$WORK/project" remote set-url origin "$WORK/nowhere.git"
assert_failure "teardown: --delete-remote fails loudly when it cannot reach the remote" -- \
  "$BIN/chief-teardown.sh" b-7 --abandon --delete-remote
git -C "$WORK/project" remote set-url origin "$BARE"
assert_success "teardown: --abandon clears it afterwards" -- "$BIN/chief-teardown.sh" b-7 --abandon

# --- a brainstormer discards like a researcher; an unknown mode refuses ---
assert_success "spawn: brainstormer task" -- \
  timeout 10 "$BIN/chief-spawn.sh" bs-1 "$WORK/project" --mode brainstormer --branch feat/bs-1 --intent x
assert_success "teardown: a brainstormer discards unconditionally" -- "$BIN/chief-teardown.sh" bs-1
assert_success "spawn: a task to give a legacy mode" -- \
  timeout 10 "$BIN/chief-spawn.sh" lg-1 "$WORK/project" --mode builder --branch feat/lg-1 --intent x
sed -i 's/^mode=.*/mode=ship/' "$CHIEF_HOME/state/lg-1.meta"
assert_failure "teardown: a legacy mode=ship task is refused, not silently discarded" -- "$BIN/chief-teardown.sh" lg-1
assert_file_exists "$CHIEF_HOME/worktrees/lg-1" "teardown refusal: legacy worktree is untouched"
assert_success "teardown: --abandon still clears a legacy task" -- "$BIN/chief-teardown.sh" lg-1 --abandon

# --- teardown releases the task's pre-trusted worktree -------------------
export CHIEF_HOME="$WORK/.chief-trust"
CFG="$CLAUDE_CONFIG_DIR/.claude.json"
trusted() { jq -r --arg p "$CHIEF_HOME/worktrees/p-1" '.projects[$p].hasTrustDialogAccepted // "unset"' "$CFG"; }
. "$BIN/lib/agents/claude.sh"
timeout 10 "$BIN/chief-spawn.sh" p-1 "$WORK/project" --mode researcher --branch feat/p-1 --intent x >/dev/null
STATE="$CHIEF_HOME/state" agent_prepare "$CHIEF_HOME/worktrees/p-1"
assert_eq "$(trusted)" "true" "setup: worktree trusted"
"$BIN/chief-teardown.sh" p-1 >/dev/null
assert_eq "$(trusted)" "unset" "teardown: worktree untrusted"

harness_summary
