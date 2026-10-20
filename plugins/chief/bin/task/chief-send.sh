#!/usr/bin/env bash
# chief-send.sh - steer a task: write a durable inbox record, ring a
# best-effort doorbell in its terminal. The durable record IS the delivery;
# the doorbell is just a nudge to look sooner.
#
# Usage: chief-send.sh <id> "<text>"
#        chief-send.sh <id> --key Enter|Escape|C-c
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../lib/paths.sh"
. "$CHIEF_ROOT/bin/lib/meta.sh"
. "$CHIEF_ROOT/bin/lib/backends/backend.sh"

fail() { echo "chief-send: $*" >&2; exit 1; }

ID=${1:-}
[ -n "$ID" ] || fail "usage: chief-send.sh <id> \"<text>\" | --key <name>"
chief_meta_exists "$ID" || fail "no such task: $ID"
shift

if [ "${1:-}" = "--key" ]; then
  KEY=${2:-}
  [ -n "$KEY" ] || fail "--key requires a value (Enter, Escape, or C-c)"
  backend_send "$ID" "$KEY"
  echo "sent: $ID <- key $KEY"
  exit 0
fi

TEXT=${1:-}
[ -n "$(printf '%s' "$TEXT" | tr -d '[:space:]')" ] || fail "message text must not be empty"

INBOX=$(chief_task_path "$ID" inbox)
mkdir -p "$INBOX/handled"
NEXT=$(
  { ls "$INBOX" 2>/dev/null | grep -E '^[0-9]{3}\.msg$' || true
    ls "$INBOX/handled" 2>/dev/null | grep -E '^[0-9]{3}\.msg$' || true
  } | sed -E 's/\.msg$//' | sort -n | tail -1
)
NEXT=$(printf '%03d' "$(( 10#${NEXT:-0} + 1 ))")
MSG_FILE="$INBOX/$NEXT.msg"
printf '%s\n' "$TEXT" > "$MSG_FILE"

backend_send "$ID" "chief: instruction waiting in $INBOX/$NEXT.msg" || true
echo "sent: $ID <- $MSG_FILE"
