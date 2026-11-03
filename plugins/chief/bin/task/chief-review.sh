#!/usr/bin/env bash
# chief-review.sh - start or re-arm a builder's reviewers on its latest commit.
# Round 1 files and spawns <builder>-rv (one <builder>-rv-<model> per reviewer
# in the run); later rounds archive each report, message each reviewer and
# re-arm it. Modes (--mode, else [reviewer] mode in the agents config):
#   parallel    every reviewer at once (default; strategy all fans out the pool)
#   sequential  one at a time in pool order, the next only on PASS; the first
#               non-PASS stops the run. Blocks until then: run it in the background.
#   first       pool entry 1 only
# --only <agent[:model],...> narrows the pool for parallel/sequential.
# mode ask is the dispatch skill's: it asks, then passes --mode and --only.
# Only sequential reads a verdict; no mode forwards findings.
#
# Usage: chief-review.sh <builder-id> [--mode parallel|sequential|first] [--only <agent[:model],...>]
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../lib/paths.sh"
. "$CHIEF_ROOT/bin/lib/meta.sh"
. "$CHIEF_ROOT/bin/lib/id.sh"
. "$CHIEF_ROOT/bin/lib/lock.sh"
. "$CHIEF_ROOT/bin/lib/agents/agent.sh"

fail() { echo "chief-review: $*" >&2; exit 1; }

BID=${1:-}; [ $# -eq 0 ] || shift
MODE="" ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE=${2:-}; shift 2 || fail "--mode needs a value" ;;
    --only) ONLY=${2:-}; shift 2 || fail "--only needs a value" ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[ -n "$BID" ] || fail "usage: chief-review.sh <builder-id> [--mode parallel|sequential|first] [--only <agent[:model],...>]"
chief_meta_exists "$BID" || fail "no such task: $BID"
[ "$(chief_meta_get "$BID" mode 2>/dev/null)" = builder ] || fail "$BID is not a builder"

# One coordinator per builder; the lock lasts the whole run (a sequential one blocks).
REVIEW_LOCK="$STATE/.review-$BID.lock"
chief_lock_acquire "$REVIEW_LOCK" 0 || fail "a review of $BID is already running"
trap 'chief_lock_release "$REVIEW_LOCK"' EXIT

LAST=$(tail -n 1 "$(chief_task_path "$BID" status)" 2>/dev/null || true)
[[ $LAST == done:* ]] || fail "$BID is not done (last status: ${LAST:-none})"
PROJECT=$(chief_meta_require "$BID" project)
WORKTREE=$(chief_meta_require "$BID" worktree)
BRANCH=$(chief_meta_require "$BID" branch)
[ -z "$(git -C "$WORKTREE" status --porcelain)" ] || fail "$BID's worktree is not clean"
BASE=$(git -C "$PROJECT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##') || true
[ -n "$BASE" ] || BASE=$(git -C "$PROJECT" symbolic-ref --quiet --short HEAD 2>/dev/null || echo main)
SHA=$(git -C "$WORKTREE" rev-parse HEAD)
[ -n "$MODE" ] || MODE=$(chief_agent_review_mode) || fail "cannot read the reviewer pool from the agents config"
case "$MODE" in
  parallel|sequential|first) ;;
  ask) fail "mode ask: ask the operator for the mode and pool entries, then pass --mode and --only" ;;
  *) fail "unknown mode '$MODE' (parallel, sequential, first)" ;;
esac
PLAN=$(chief_agent_review_plan "$MODE" "$ONLY") || fail "cannot plan the reviewers (see above)"
[ "$(git -C "$WORKTREE" rev-list --count "$BASE..$SHA")" -gt 0 ] || fail "$BID has no commit ahead of $BASE"
DONE_SHA=${LAST#done: }; DONE_SHA=${DONE_SHA%% *}
{ [ "${#DONE_SHA}" -ge 7 ] && [[ $SHA == "$DONE_SHA"* ]]; } \
  || fail "$BID's done line does not start with HEAD's SHA ${SHA:0:7} (it committed after reporting done, or the line has no SHA)"

LINKED=$(chief_meta_get "$BID" reviewer 2>/dev/null || true)
ROUND=1 DEAD=""
if [ -n "$LINKED" ]; then
  # A torn-down reviewer is skipped and unlinked; fail only when none is left.
  LIVE=""
  for RID in $LINKED; do
    if [ "$(chief_meta_get "$RID" status 2>/dev/null)" = torn-down ]; then
      DEAD+=" $(chief_meta_get "$RID" pick 2>/dev/null || true) "; continue
    fi
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

PRIOR=$LINKED   # restored if a spawn fails
PRIOR_SHA=$(chief_meta_get "$BID" review_sha 2>/dev/null || true)
ALL=$LINKED IDS="" STARTED="" STOP=""
SEQ=0; [ "$MODE" = sequential ] && SEQ=1

link() {  # publish the reviewers so far (the watcher's gate reads review_ids)
  chief_meta_set "$BID" reviewer "$ALL"
  chief_meta_set "$BID" review_ids "$IDS"
}

find_rv() {  # <pick> - the linked reviewer for that pool entry
  local r
  for r in $LINKED; do
    [ "$(chief_meta_get "$r" pick 2>/dev/null || true)" = "$1" ] && { echo "$r"; return 0; }
  done
  return 0
}

spawn_rv() {  # <pick> <slug>
  local RID title
  title=$("$CHIEF_ROOT/bin/chief-backlog.sh" show "$BID" | sed -n '1s/^## [^ ]* \[[a-z-]*\] //; 1s/ \[agent: [^]]*\]$//p')
  RID=$(chief_id_compose "$BID" "rv${2:+-$2}")
  if [ -z "$("$CHIEF_ROOT/bin/chief-backlog.sh" show "$RID")" ]; then
    "$CHIEF_ROOT/bin/chief-backlog.sh" add "$RID" "review of $BID: $title" >/dev/null
  fi
  if ! CHIEF_AGENT_PICK=$([ "$1" = 0 ] || echo "$1") "$CHIEF_ROOT/bin/chief-spawn.sh" "$RID" "$PROJECT" --mode reviewer --branch "chore/$RID" \
    --intent "Review $BID" --spec "$text"; then
    for started in $STARTED; do "$CHIEF_ROOT/bin/chief-teardown.sh" "$started" --abandon >/dev/null 2>&1 || true; done
    chief_meta_set "$BID" reviewer "$PRIOR"; chief_meta_set "$BID" review_ids ""
    fail "spawning reviewer $RID failed${STARTED:+; discarded ${STARTED// /, }}; nothing new is linked, retry the review"
  fi
  chief_meta_set "$RID" for "$BID"
  chief_meta_set "$RID" pick "$1"
  chief_meta_set "$RID" armed_round "$ROUND@$SHA"
  STARTED+="${STARTED:+ }$RID"
  ALL+="${ALL:+ }$RID"
  NEWRID=$RID
}

rearm_rv() {  # <reviewer-id>
  local RID=$1 REPORT ARCHIVE_TO priors prev
  REPORT=$(chief_task_path "$RID" report.md)
  # The report belongs to the round this reviewer last reviewed (it may have sat out rounds).
  prev=$(chief_meta_get "$RID" armed_round 2>/dev/null || true); prev=${prev%%@*}
  [[ $prev =~ ^[0-9]+$ ]] && [ "$prev" -lt "$ROUND" ] || prev=$((ROUND - 1))
  ARCHIVE_TO="${REPORT%.md}.round-$prev.md"
  # armed_round=<round>@<sha> marks a finished re-arm; archiving alone does not, so a retry redoes the
  # unfinished steps. A new commit restarts the round for every reviewer, so all review the same SHA.
  if [ "$(chief_meta_get "$RID" armed_round 2>/dev/null)" = "$ROUND@$SHA" ]; then
    echo "chief-review: $RID already re-armed for round $ROUND, skipped" >&2; return 0
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
}

# Blocks until the reviewer's last status line is terminal (or it is torn down).
await_rv() {
  local last
  while :; do
    last=$(tail -n 1 "$(chief_task_path "$1" status)" 2>/dev/null || true)
    case "$last" in done:*|failed:*|blocked:*|needs-decision:*) break ;; esac
    [ "$(chief_meta_get "$1" status 2>/dev/null)" != torn-down ] || { last="torn down"; break; }
    sleep "${CHIEF_REVIEW_POLL:-5}"
  done
  VERDICT=$last
}

if [ "$PLAN" = "0 " ] && [ -n "$LINKED" ]; then   # no pool to pick from: re-arm whoever is linked
  PLAN=""; for RID in $LINKED; do PLAN+="$(chief_meta_get "$RID" pick 2>/dev/null || echo 0) "$'\n'; done
fi

if [ "$SEQ" = 1 ]; then
  # Claim the SHA up front so the same-SHA guard sees the run; the gate keeps the watcher quiet
  # until it ends. An unfinished run gives the SHA back and leaves review_round alone, so a
  # retry resumes the same round (armed reviewers are skipped).
  trap '[ -n "${RUN_DONE:-}" ] || chief_meta_set "$BID" review_sha "$PRIOR_SHA"
    chief_meta_set "$BID" review_pending ""; chief_lock_release "$REVIEW_LOCK"' EXIT
  chief_meta_set "$BID" review_pending 1
  chief_meta_set "$BID" review_sha "$SHA"
fi

while read -r pick slug; do
  [[ " $DEAD " != *" $pick "* ]] || continue
  RID=$(find_rv "$pick")
  if [ -n "$RID" ]; then rearm_rv "$RID"; else spawn_rv "$pick" "$slug"; RID=$NEWRID; fi
  IDS+="${IDS:+ }$RID"
  [ "$SEQ" = 1 ] || continue
  link
  await_rv "$RID"
  [[ $VERDICT == done:*" PASS"* ]] || { STOP="$RID: ${VERDICT:-no status}"; break; }
done <<< "$PLAN"

[ -n "$IDS" ] || fail "no live reviewer matches the selection"
link
chief_meta_set "$BID" review_round "$ROUND"
chief_meta_set "$BID" review_sha "$SHA"
RUN_DONE=1

echo "review: ${IDS// /, } round $ROUND of $BID @${SHA:0:7}${STOP:+ (sequential, stopped at $STOP)}"
