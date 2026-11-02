#!/usr/bin/env bash
# chief-watch.sh - the token saver. A plain bash loop, no model calls: sleeps,
# checks every in-flight task's state, and only exits (with a reason printed
# on stdout) when something needs the operator's attention. Chief's Stop hook
# runs this in the background at zero model cost and only "rewakes" you when
# it exits - see hooks/stop-watch-arm.sh.
#
# One watcher per CHIEF_HOME (best effort): the newest owns state/watch.owner,
# an older one exits silently. Exactly-once delivery comes from an atomic
# claim (mkdir) per task/state: state/claims/<id>.<status-lines>[.<turn-ended-mtime, stale only>].<line-hash>.
# A watcher that dies between claiming and printing loses that one alert.
#
# Usage: chief-watch.sh   (runs until something actionable happens, or forever)
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/paths.sh"
chief_ensure_dirs
. "$CHIEF_ROOT/bin/lib/meta.sh"
. "$CHIEF_ROOT/bin/lib/backends/backend.sh"

POLL="${CHIEF_POLL:-15}"
BEACON="$STATE/.last-watcher-beat"
OWNER="$STATE/watch.owner"
CLAIMS="$STATE/claims"

is_owner() { [ "$(cat "$OWNER" 2>/dev/null || true)" = "$$" ]; }

# A task's state snapshot: status line count and turn-ended mtime. Only a stale
# alert is keyed on the mtime (it fires without a new status line); the other
# alerts come from status lines.
task_lines() { { cat "$(chief_task_path "$1" status)" 2>/dev/null || true; } | wc -l | tr -d ' '; }
task_mtime() {
  local t; t=$(chief_task_path "$1" turn-ended)
  stat -c %Y "$t" 2>/dev/null || stat -f %m "$t" 2>/dev/null || echo 0
}

# Drop claims whose task is gone (ids contain no dots), or that are over a day
# old and not for the task's current state. Claim names are
# <id>.<lines>.<hash> or, for stale, <id>.<lines>.<mtime>.<hash>.
gc_claims() {
  local c id lines f3 f4 current
  for c in "$CLAIMS"/*; do
    [ -d "$c" ] || continue
    IFS=. read -r id lines f3 f4 <<< "$(basename "$c")"
    current=0
    if [ "$lines" = "$(task_lines "$id")" ] && { [ -z "$f4" ] || [ "$f3" = "$(task_mtime "$id")" ]; }; then current=1; fi
    if [ ! -d "$TASKS/$id" ] || { [ "$current" = 0 ] && [ -n "$(find "$c" -maxdepth 0 -mtime +0 2>/dev/null)" ]; }; then
      rmdir "$c" 2>/dev/null || true
    fi
  done
}

mkdir -p "$CLAIMS"
echo $$ > "$OWNER.$$" && mv -f "$OWNER.$$" "$OWNER"
gc_claims

in_flight_ids() {
  local f id
  for f in "$TASKS"/*/meta; do
    [ -e "$f" ] || continue
    id=$(basename "$(dirname "$f")")
    case "$(chief_meta_get "$id" status)" in
      working|spawning) printf '%s\n' "$id" ;;
    esac
  done
}

# round_gate <reviewer-id> - for a reviewer with siblings, returns 1 (stay quiet)
# until every live reviewer of its builder is done. The last one writes the
# round's combined report, acknowledges every reviewer's done line (so none
# is announced again) and sets ROUND_NOTE to point at the report. A sibling
# that failed, blocked or went stale announces itself; it holds the round back.
ROUND_NOTE=""
round_gate() {
  local bid rid live="" n out line ids
  bid=$(chief_meta_get "$1" for 2>/dev/null) || return 0
  for rid in $(chief_meta_get "$bid" reviewer 2>/dev/null); do
    [ "$(chief_meta_get "$rid" status 2>/dev/null)" != torn-down ] || continue
    live+="${live:+ }$rid"
  done
  [[ $live == *" "* ]] || return 0
  for rid in $live; do
    [[ $("$CHIEF_ROOT/bin/task/chief-crew-state.sh" "$rid" 2>/dev/null) == "state: done"* ]] || return 1
  done
  n=$(chief_meta_get "$bid" review_round 2>/dev/null || echo 1)
  out=$(chief_task_path "$bid" "review-round-$n.md")
  {
    echo "# Review round $n of $bid"
    for rid in $live; do
      printf '\n## %s\n\n' "$rid"
      cat "$(chief_task_path "$rid" report.md)" 2>/dev/null || echo "(no report)"
    done
  } > "$out"
  for rid in $live; do
    line=$("$CHIEF_ROOT/bin/task/chief-crew-state.sh" "$rid" 2>/dev/null) || continue
    chief_meta_set "$rid" notify-baseline "$(chief_notify_line "$line")"
  done
  read -ra ids <<< "$live"
  ROUND_NOTE=" · all ${#ids[@]} reviewers of $bid done, combined report: $out"
}

while true; do
  is_owner || exit 0
  touch "$BEACON"

  any_in_flight=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    any_in_flight=1
    # One coherent snapshot: the state read before the crew-state line keys
    # the claim; if it moved meanwhile, discard and re-poll.
    lines=$(task_lines "$id"); mtime=$(task_mtime "$id")
    line=$("$CHIEF_ROOT/bin/task/chief-crew-state.sh" "$id" 2>/dev/null) || continue
    [ "$lines.$mtime" = "$(task_lines "$id").$(task_mtime "$id")" ] || continue
    baseline=$(chief_meta_get "$id" notify-baseline 2>/dev/null || true)
    case "$line" in
      "state: done"*|"state: failed"*|"state: blocked"*|"state: needs-decision"*|"state: stale"*)
        # Notify once per state change: the delivered line is the baseline,
        # which a resumed held/done task also starts with (chief-backlog.sh).
        norm=$(chief_notify_line "$line")
        [ "$norm" = "$(chief_notify_line "$baseline")" ] && continue
        is_owner || exit 0
        gen=$lines; case "$line" in "state: stale"*) gen=$lines.$mtime ;; esac
        claim="$CLAIMS/$id.$gen.$(printf '%s' "$norm" | cksum | cut -d' ' -f1)"
        mkdir "$claim" 2>/dev/null || continue
        chief_meta_set "$id" notify-baseline "$norm"
        # One wake per round: a finished reviewer waits for its siblings.
        if [[ $line == "state: done"* ]]; then
          round_gate "$id" || { chief_meta_set "$id" notify-baseline ""; continue; }
        fi
        echo "$id: $line$ROUND_NOTE"
        exit 0
        ;;
      *)
        if [ -n "$baseline" ]; then is_owner || exit 0; chief_meta_set "$id" notify-baseline ""; fi
        ;;
    esac
  done < <(in_flight_ids)

  if [ "$any_in_flight" -eq 0 ]; then
    echo "nothing in flight"
    exit 0
  fi

  sleep "$POLL"
done
