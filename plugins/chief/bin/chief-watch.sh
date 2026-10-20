#!/usr/bin/env bash
# chief-watch.sh - the token saver. A plain bash loop, no model calls: sleeps,
# checks every in-flight task's state, and only exits (with a reason printed
# on stdout) when something needs the operator's attention. Chief's Stop hook
# runs this in the background at zero model cost and only "rewakes" you when
# it exits - see hooks/stop-watch-arm.sh.
#
# Usage: chief-watch.sh   (runs until something actionable happens, or forever)
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/paths.sh"
chief_ensure_dirs
. "$CHIEF_ROOT/bin/lib/meta.sh"
. "$CHIEF_ROOT/bin/lib/backends/backend.sh"

POLL="${CHIEF_POLL:-15}"
BEACON="$STATE/.last-watcher-beat"

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

while true; do
  touch "$BEACON"

  any_in_flight=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    any_in_flight=1
    line=$("$CHIEF_ROOT/bin/task/chief-crew-state.sh" "$id" 2>/dev/null) || continue
    baseline=$(chief_meta_get "$id" notify-baseline 2>/dev/null || true)
    case "$line" in
      "state: done"*|"state: failed"*|"state: blocked"*|"state: needs-decision"*|"state: stale"*)
        # Notify once per state change: the delivered line is the baseline,
        # which a resumed held/done task also starts with (chief-backlog.sh).
        norm=$(chief_notify_line "$line")
        [ "$norm" = "$baseline" ] && continue
        chief_meta_set "$id" notify-baseline "$norm"
        echo "$id: $line"
        exit 0
        ;;
      *)
        [ -n "$baseline" ] && chief_meta_set "$id" notify-baseline ""
        ;;
    esac
  done < <(in_flight_ids)

  if [ "$any_in_flight" -eq 0 ]; then
    echo "nothing in flight"
    exit 0
  fi

  sleep "$POLL"
done
