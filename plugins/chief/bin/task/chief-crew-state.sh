#!/usr/bin/env bash
# chief-crew-state.sh - deterministic read of a task's CURRENT state.
#
# tasks/<id>/status is an append-only EVENT log (a builder appends only on a
# phase change), so its last line can go stale the moment the builder keeps
# working without another reportable event. The brief tells every builder,
# whatever its agent, to touch tasks/<id>/turn-ended each time ITS turn ends;
# that one fact is enough to tell "quietly still working" apart from
# "actually stalled" without pane-diffing or any backend-specific heuristic.
#
# Usage: chief-crew-state.sh <id>
# Prints one line: "state: <working|done|blocked|needs-decision|failed|stale> · <detail> [mode: <builder|researcher|reviewer|brainstormer>] [agent: <agent[:model]>]"
#
# mode and agent are appended, not prefixed, so it doesn't break prefix matches on
# state/detail elsewhere. A non-terminal brainstormer also carries [attach: ...];
# a reviewer carries [for: <builder>], a reviewed builder [reviewer: <id>].
#
# A brainstormer waits on the operator in its own pane, so while idle it always
# reads "working · awaiting operator in pane", never stale.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../lib/paths.sh"
. "$CHIEF_ROOT/bin/lib/meta.sh"
. "$CHIEF_ROOT/bin/lib/backends/backend.sh"

STALE_AFTER_SECS=120

fail() { echo "chief-crew-state: $*" >&2; exit 1; }

ID=${1:-}
[ -n "$ID" ] || fail "usage: chief-crew-state.sh <id>"
chief_meta_exists "$ID" || fail "no such task: $ID"

STATUS_FILE=$(chief_task_path "$ID" status)
TURN_FILE=$(chief_task_path "$ID" turn-ended)
MODE=$(chief_meta_get "$ID" mode 2>/dev/null || true)
MODE_SUFFIX=" [mode: ${MODE:-unknown}] [agent: $(chief_meta_agent "$ID")]"
for link in for reviewer; do
  LINKED=$(chief_meta_get "$ID" "$link" 2>/dev/null || true)
  [ -z "$LINKED" ] || MODE_SUFFIX+=" [$link: $LINKED]"
done

# "spawning" without chief-spawn.sh's lock means the spawn was interrupted.
if [ "$(chief_meta_get "$ID" status 2>/dev/null || true)" = "spawning" ]; then
  if [ -e "$(chief_task_path "$ID" spawning)" ]; then
    echo "state: working · spawning$MODE_SUFFIX"
    exit 0
  fi
  echo "state: blocked · spawn interrupted - inspect the pane, then chief-teardown.sh $ID --abandon$MODE_SUFFIX"
  exit 0
fi

LAST=""
[ -f "$STATUS_FILE" ] && LAST=$(tail -n 1 "$STATUS_FILE" 2>/dev/null || true)

case "$LAST" in
  done:*)            echo "state: done · ${LAST#done: }$MODE_SUFFIX"; exit 0 ;;
  failed:*)          echo "state: failed · ${LAST#failed: }$MODE_SUFFIX"; exit 0 ;;
  blocked:*)         echo "state: blocked · ${LAST#blocked: }$MODE_SUFFIX"; exit 0 ;;
  needs-decision:*)  echo "state: needs-decision · ${LAST#needs-decision: }$MODE_SUFFIX"; exit 0 ;;
esac

ATTACH=$(chief_meta_get "$ID" attach 2>/dev/null || true)
[ "$MODE" != brainstormer ] || [ -z "$ATTACH" ] || MODE_SUFFIX+=" [attach: $ATTACH]"

# Anything else (a "working:" line, or no status yet) is only provisional -
# reconcile it against liveness before reporting.
if backend_busy "$ID" 2>/dev/null; then
  echo "state: working · ${LAST:-no status yet, backend reports busy}$MODE_SUFFIX"
  exit 0
fi

if [ "$MODE" = brainstormer ]; then
  echo "state: working · awaiting operator in pane$MODE_SUFFIX"
  exit 0
fi

now=$(date +%s)
turn_age=999999
if [ -f "$TURN_FILE" ]; then
  turn_mtime=$(stat -c %Y "$TURN_FILE" 2>/dev/null || stat -f %m "$TURN_FILE" 2>/dev/null || echo 0)
  turn_age=$(( now - turn_mtime ))
fi

if [ "$turn_age" -le "$STALE_AFTER_SECS" ]; then
  echo "state: working · ${LAST:-no status yet}, turn ended ${turn_age}s ago$MODE_SUFFIX"
else
  echo "state: stale · ${LAST:-no status ever}, no turn activity for ${turn_age}s$MODE_SUFFIX"
fi
