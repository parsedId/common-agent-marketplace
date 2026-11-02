#!/usr/bin/env bash
# chief-review.sh - start or re-arm a builder's reviewers on its latest commit.
# Round 1 files and spawns <builder>-rv (one <builder>-rv-<model> per [reviewer]
# entry under strategy all); later rounds archive each report, message each
# reviewer and re-arm it. It never reads a verdict or forwards findings.
#
# Usage: chief-review.sh <builder-id>
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../lib/paths.sh"
. "$CHIEF_ROOT/bin/lib/meta.sh"
. "$CHIEF_ROOT/bin/lib/id.sh"
. "$CHIEF_ROOT/bin/lib/agents/agent.sh"

fail() { echo "chief-review: $*" >&2; exit 1; }

BID=${1:-}
[ -n "$BID" ] || fail "usage: chief-review.sh <builder-id>"
chief_meta_exists "$BID" || fail "no such task: $BID"
[ "$(chief_meta_get "$BID" mode 2>/dev/null)" = builder ] || fail "$BID is not a builder"

LAST=$(tail -n 1 "$(chief_task_path "$BID" status)" 2>/dev/null || true)
[[ $LAST == done:* ]] || fail "$BID is not done (last status: ${LAST:-none})"
PROJECT=$(chief_meta_require "$BID" project)
WORKTREE=$(chief_meta_require "$BID" worktree)
BRANCH=$(chief_meta_require "$BID" branch)
[ -z "$(git -C "$WORKTREE" status --porcelain)" ] || fail "$BID's worktree is not clean"
BASE=$(git -C "$PROJECT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##') || true
[ -n "$BASE" ] || BASE=$(git -C "$PROJECT" symbolic-ref --quiet --short HEAD 2>/dev/null || echo main)
SHA=$(git -C "$WORKTREE" rev-parse HEAD)
[ "$(git -C "$WORKTREE" rev-list --count "$BASE..$SHA")" -gt 0 ] || fail "$BID has no commit ahead of $BASE"
DONE_SHA=${LAST#done: }; DONE_SHA=${DONE_SHA%% *}
{ [ "${#DONE_SHA}" -ge 7 ] && [[ $SHA == "$DONE_SHA"* ]]; } \
  || fail "$BID's done line does not start with HEAD's SHA ${SHA:0:7} (it committed after reporting done, or the line has no SHA)"

LINKED=$(chief_meta_get "$BID" reviewer 2>/dev/null || true)
ROUND=1
if [ -n "$LINKED" ]; then
  # A torn-down reviewer is skipped and unlinked; fail only when none is left.
  LIVE=""
  for RID in $LINKED; do
    [ "$(chief_meta_get "$RID" status 2>/dev/null)" != torn-down ] || continue
    if [ "$SHA" = "$(chief_meta_get "$BID" review_sha 2>/dev/null)" ] \
      && [[ $("$CHIEF_ROOT/bin/task/chief-crew-state.sh" "$RID") == "state: working"* ]]; then
      fail "$RID is already reviewing ${SHA:0:7}"
    fi
    LIVE+="${LIVE:+ }$RID"
  done
  if [ -z "$LIVE" ]; then
    [[ $LINKED == *" "* ]] && fail "reviewers $LINKED were torn down"
    fail "reviewer $LINKED was torn down"
  fi
  [ "$LIVE" = "$LINKED" ] || { LINKED=$LIVE; chief_meta_set "$BID" reviewer "$LINKED"; }
  ROUND=$(( $(chief_meta_get "$BID" review_round 2>/dev/null || echo 0) + 1 ))
fi

text="Review round $ROUND. Branch: $BRANCH. Pinned SHA: $SHA. Base: $BASE.
Builder brief (intent): $(chief_task_path "$BID" brief.md)
Builder done line: ${LAST#done: }"

if [ "$ROUND" -eq 1 ]; then
  # One reviewer per [reviewer] entry under strategy all (ids <builder>-rv-<model>), else one.
  # reviewer= is written only once every spawn succeeded; a failure discards the ones already started.
  IDS=""; PICK=0
  title=$("$CHIEF_ROOT/bin/chief-backlog.sh" show "$BID" | sed -n '1s/^## [^ ]* \[[a-z-]*\] //; 1s/ \[agent: [^]]*\]$//p')
  SLUGS=$(chief_agent_fanout reviewer) || fail "cannot read the reviewer pool from the agents config"
  while IFS= read -r slug; do
    PICK=$((PICK + 1))
    RID=$(chief_id_compose "$BID" "rv${slug:+-$slug}")
    if [ -z "$("$CHIEF_ROOT/bin/chief-backlog.sh" show "$RID")" ]; then
      "$CHIEF_ROOT/bin/chief-backlog.sh" add "$RID" "review of $BID: $title" >/dev/null
    fi
    if ! CHIEF_AGENT_PICK=$PICK "$CHIEF_ROOT/bin/chief-spawn.sh" "$RID" "$PROJECT" --mode reviewer --branch "chore/$RID" \
      --intent "Review $BID" --spec "$text"; then
      for started in $IDS; do "$CHIEF_ROOT/bin/chief-teardown.sh" "$started" --abandon >/dev/null 2>&1 || true; done
      fail "spawning reviewer $RID failed${IDS:+; discarded ${IDS// /, }}; nothing is linked, retry the review"
    fi
    chief_meta_set "$RID" for "$BID"
    IDS+="${IDS:+ }$RID"
  done <<< "$SLUGS"
  chief_meta_set "$BID" review_round "$ROUND"
  chief_meta_set "$BID" review_sha "$SHA"
  chief_meta_set "$BID" reviewer "$IDS"
else
  for RID in $LINKED; do
    REPORT=$(chief_task_path "$RID" report.md)
    ARCHIVE_TO="${REPORT%.md}.round-$((ROUND - 1)).md"
    # armed_round=<round>@<sha> marks a finished re-arm; archiving alone does not, so a retry redoes the
    # unfinished steps. A new commit restarts the round for every reviewer, so all review the same SHA.
    if [ "$(chief_meta_get "$RID" armed_round 2>/dev/null)" = "$ROUND@$SHA" ]; then
      echo "chief-review: $RID already re-armed for round $ROUND, skipped" >&2; continue
    fi
    # An archived report is never overwritten.
    [ ! -f "$REPORT" ] || [ -e "$ARCHIVE_TO" ] || mv "$REPORT" "$ARCHIVE_TO"
    priors=$(ls "${REPORT%.md}".round-*.md 2>/dev/null || true)
    "$CHIEF_ROOT/bin/task/chief-send.sh" "$RID" "$text
Earlier reports (to verify, not to repeat):
$priors"
    "$CHIEF_ROOT/bin/chief-backlog.sh" status "$RID" in-flight >/dev/null
    echo "working: round $ROUND requested" >> "$(chief_task_path "$RID" status)"
    touch "$(chief_task_path "$RID" turn-ended)"
    chief_meta_set "$RID" armed_round "$ROUND@$SHA"
  done
  IDS=$LINKED
  chief_meta_set "$BID" review_round "$ROUND"
  chief_meta_set "$BID" review_sha "$SHA"
fi

echo "review: ${IDS// /, } round $ROUND of $BID @${SHA:0:7}"
