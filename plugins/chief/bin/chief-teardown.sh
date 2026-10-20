#!/usr/bin/env bash
# chief-teardown.sh - kills the terminal, removes the worktree, marks the
# backlog item done and archives the task's folder. A BUILDER task refuses
# unless its branch has landed on the default branch, unless --abandon
# force-discards it. Any other role discards unconditionally - its deliverable
# is the report at tasks/<id>/report.md, outside the worktree, untouched either
# way.
#
# Teardown never touches the remote branch, on any path.
#
# A squash- or rebase-merged branch is never a local ancestor of the default
# branch, so when the ancestry check fails, a git-only check (needs git >= 2.38)
# asks whether merging it into the fetched default branch would change nothing.
#
# Tearing down a builder also discards its linked reviewers, once the builder's
# own teardown has succeeded; a refused builder leaves the reviewer alone.
#
# Usage: chief-teardown.sh <id> [--abandon]
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/paths.sh"
. "$CHIEF_ROOT/bin/lib/meta.sh"
. "$CHIEF_ROOT/bin/lib/backends/backend.sh"
. "$CHIEF_ROOT/bin/lib/git-sync.sh"

fail() { echo "chief-teardown: $*" >&2; exit 1; }

ID=${1:-}
[ -n "$ID" ] || fail "usage: chief-teardown.sh <id> [--abandon]"
chief_meta_exists "$ID" || fail "no such task: $ID"
shift

ABANDON=0
case "${1:-}" in
  --abandon) ABANDON=1; shift ;;
  "") ;;
  *) fail "unknown argument: $1" ;;
esac

PROJECT=$(chief_meta_require "$ID" project)
BRANCH=$(chief_meta_require "$ID" branch)
WORKTREE=$(chief_meta_require "$ID" worktree)
MODE=$(chief_meta_get "$ID" mode 2>/dev/null || true)

_chief_discard() {  # <reason-for-the-echo-line>
  backend_kill "$ID"
  backend_teardown "$ID" "$PROJECT" "$WORKTREE" || true
  git -C "$PROJECT" worktree remove --force "$WORKTREE" 2>/dev/null || rm -rf "$WORKTREE"
  git -C "$PROJECT" branch -D "$BRANCH" >/dev/null 2>&1 || true
  "$CHIEF_ROOT/bin/chief-backlog.sh" done "$ID" 2>/dev/null || true
  chief_meta_set "$ID" status torn-down
  chief_task_archive "$ID"
  echo "torn down: $ID ($1)"
  local rid
  for rid in $(chief_meta_get "$ID" reviewer 2>/dev/null || true); do
    if chief_meta_exists "$rid" && [ "$(chief_meta_get "$rid" status)" != torn-down ]; then
      "$CHIEF_ROOT/bin/chief-teardown.sh" "$rid" || echo "chief-teardown: could not tear down reviewer $rid" >&2
    fi
  done
}

case "$MODE" in
  builder) ;;
  researcher|reviewer|brainstormer)
    _chief_discard "$MODE, discarded - its deliverable is the report, not this worktree"
    exit 0 ;;
esac

if [ "$ABANDON" -eq 1 ]; then
  _chief_discard "abandoned - work had not landed, discarded on the operator's explicit instruction"
  exit 0
fi

git -C "$PROJECT" show-ref --verify --quiet "refs/heads/$BRANCH" \
  || fail "branch $BRANCH no longer exists in $PROJECT - refusing without proof it landed"

DEFAULT=$(git -C "$PROJECT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##') || true
[ -n "$DEFAULT" ] || DEFAULT=$(git -C "$PROJECT" symbolic-ref --quiet --short HEAD 2>/dev/null || echo main)

if ! git -C "$PROJECT" merge-base --is-ancestor "$BRANCH" "$DEFAULT" 2>/dev/null; then
  git -C "$PROJECT" fetch -q origin 2>/dev/null || true
  TARGET=$DEFAULT
  git -C "$PROJECT" rev-parse --verify -q "origin/$DEFAULT^{tree}" >/dev/null && TARGET=origin/$DEFAULT
  MERGED_TREE=$(git -C "$PROJECT" merge-tree --write-tree "$TARGET" "$BRANCH" 2>/dev/null | head -1) || true
  if [ -n "$MERGED_TREE" ] && [ "$MERGED_TREE" = "$(git -C "$PROJECT" rev-parse "$TARGET^{tree}")" ]; then
    _chief_discard "landed on $TARGET - not a local ancestor (squash/rebase merge), its content is already there"
    chief_sync_default_branch "$PROJECT"
    exit 0
  fi
  fail "REFUSED: $BRANCH is not reachable from $DEFAULT and merging it would still change $TARGET - the work has not landed (or git cannot prove it did). Merge its PR or merge it by hand, then retry. If it landed but cannot be proven (e.g. $DEFAULT changed the same files since), check the PR is merged and use --abandon. To discard it instead of landing it, use --abandon."
fi

_chief_discard "landed on $DEFAULT, worktree removed"
chief_sync_default_branch "$PROJECT"
