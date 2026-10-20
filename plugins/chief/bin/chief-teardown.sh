#!/usr/bin/env bash
# chief-teardown.sh - kills the terminal, removes the worktree, marks the
# backlog item done. A BUILDER task refuses unless its branch has landed on the
# default branch, unless --abandon force-discards it. Any other role discards
# unconditionally - its deliverable is the report at $DATA/<id>/report.md,
# outside the worktree, untouched either way.
#
# Teardown deletes only the LOCAL branch and worktree; the remote branch is
# kept, --abandon included. --delete-remote is the only way to run
# 'git push origin --delete <branch>'; it fails loudly if the push fails and
# is never passed on to reviewers.
#
# A builder whose PR was squash- or rebase-merged has a branch that's never a
# local ancestor of the default branch (both methods create new commits
# with no ancestry back to it) - so when the ancestry check fails, this
# also asks the provider directly whether the recorded PR is merged before
# refusing.
#
# Tearing down a builder also discards its linked reviewers, once the builder's
# own teardown has succeeded; a refused builder leaves the reviewer alone.
#
# Usage: chief-teardown.sh <id> [--abandon] [--delete-remote]
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/paths.sh"
. "$CHIEF_ROOT/bin/lib/meta.sh"
. "$CHIEF_ROOT/bin/lib/backends/backend.sh"
. "$CHIEF_ROOT/bin/lib/pr-providers/pr-provider.sh"
. "$CHIEF_ROOT/bin/lib/git-sync.sh"

fail() { echo "chief-teardown: $*" >&2; exit 1; }

ID=${1:-}
[ -n "$ID" ] || fail "usage: chief-teardown.sh <id> [--abandon] [--delete-remote]"
chief_meta_exists "$ID" || fail "no such task: $ID"
shift

ABANDON=0
DELETE_REMOTE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --abandon) ABANDON=1 ;;
    --delete-remote) DELETE_REMOTE=1 ;;
    *) fail "unknown argument: $1" ;;
  esac
  shift
done

PROJECT=$(chief_meta_require "$ID" project)
BRANCH=$(chief_meta_require "$ID" branch)
WORKTREE=$(chief_meta_require "$ID" worktree)
MODE=$(chief_meta_get "$ID" mode 2>/dev/null || true)

_chief_discard() {  # <reason-for-the-echo-line>
  local rc=0
  git -C "$PROJECT" ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1 || rc=$?
  if [ "$DELETE_REMOTE" -eq 1 ]; then
    case "$rc" in
      0) git -C "$PROJECT" push origin --delete "$BRANCH" >&2 \
           || fail "could not delete remote branch $BRANCH; nothing was torn down"
         echo "remote branch deleted: $BRANCH" ;;
      2) echo "remote branch not deleted: $BRANCH not found on origin" ;;
      *) fail "could not reach origin to delete remote branch $BRANCH; nothing was torn down" ;;
    esac
  elif [ "$rc" -eq 0 ]; then
    echo "remote branch kept: $BRANCH"
  fi
  backend_kill "$ID"
  backend_teardown "$ID" "$PROJECT" "$WORKTREE" || true
  git -C "$PROJECT" worktree remove --force "$WORKTREE" 2>/dev/null || rm -rf "$WORKTREE"
  git -C "$PROJECT" branch -D "$BRANCH" >/dev/null 2>&1 || true
  "$CHIEF_ROOT/bin/chief-backlog.sh" done "$ID" 2>/dev/null || true
  chief_meta_set "$ID" status torn-down
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
  *) [ "$ABANDON" -eq 1 ] || fail "task $ID has unknown mode '${MODE:-none}' - tear it down with --abandon" ;;
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
  PR_URL=$(chief_meta_get "$ID" pr_url 2>/dev/null || true)
  PR_PROVIDER=$(chief_meta_get "$ID" pr_provider 2>/dev/null || true)
  if [ -n "$PR_URL" ] && [ -n "$PR_PROVIDER" ] \
    && chief_pr_load_provider "$PR_PROVIDER" 2>/dev/null && pr_merged "$PR_URL"; then
    _chief_discard "landed via merged PR $PR_URL ($PR_PROVIDER) - not a local ancestor (squash/rebase merge), confirmed with the provider instead"
    chief_sync_default_branch "$PROJECT"
    exit 0
  fi
  fail "REFUSED: $BRANCH is not reachable from $DEFAULT - the work has not landed. Merge it by hand, or open a PR with chief-pr-open.sh and merge it with chief-pr-merge.sh, then retry. If it was merged via chief-pr-merge.sh, that lands on the remote's default branch - fetch/update $DEFAULT locally (e.g. git -C $PROJECT fetch origin $DEFAULT && git -C $PROJECT merge --ff-only origin/$DEFAULT) and retry. To discard it instead of landing it, use --abandon."
fi

_chief_discard "landed on $DEFAULT, worktree removed"
chief_sync_default_branch "$PROJECT"
