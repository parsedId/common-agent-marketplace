#!/usr/bin/env bash
# chief-control.sh - lifecycle control plane: interrupt | exit | relaunch.
# Never teardown/discard - that stays with chief-teardown.sh, which owns the
# landed-work check. This script never deletes a worktree.
#
# Usage: chief-control.sh <id> interrupt
#        chief-control.sh <id> exit
#        chief-control.sh <id> relaunch --note "<progress so far>"
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../lib/paths.sh"
. "$CHIEF_ROOT/bin/lib/meta.sh"
. "$CHIEF_ROOT/bin/lib/brief.sh"
. "$CHIEF_ROOT/bin/lib/backends/backend.sh"

fail() { echo "chief-control: $*" >&2; exit 1; }

ID=${1:-}; VERB=${2:-}
[ -n "$ID" ] && [ -n "$VERB" ] || fail "usage: chief-control.sh <id> interrupt|exit|relaunch [--note \"...\"]"
chief_meta_exists "$ID" || fail "no such task: $ID"
shift 2

case "$VERB" in
  interrupt)
    # The agent keeps running - this is a nudge, not a stop. Nothing here
    # needs to "pick back up" afterwards, because it never left.
    backend_send "$ID" Escape
    echo "interrupted: $ID (agent keeps running)"
    ;;

  exit)
    backend_kill "$ID"
    chief_meta_set "$ID" status exited
    echo "exited: $ID (worktree and commits preserved)"
    ;;

  relaunch)
    NOTE=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --note) NOTE=$2; shift 2 ;;
        *) fail "unknown argument: $1" ;;
      esac
    done
    [ -n "$NOTE" ] || fail "relaunch requires --note \"<progress so far>\" - the replacement gets the worktree but not the conversation"

    BRIEF=$(chief_task_path "$ID" brief.md)
    [ -f "$BRIEF" ] || fail "no brief found at $BRIEF"

    # Only the latest checkpoint carries forward: the new agent inherits the
    # worktree's git state but none of the old conversation, so this note is
    # all it gets told. Strip any earlier checkpoint first so a repeat
    # relaunch replaces it instead of stacking a changelog of past notes.
    chief_brief_strip_section "$BRIEF" "# Relaunch checkpoint"
    {
      echo ""
      echo "# Relaunch checkpoint ($(date -u +%Y-%m-%dT%H:%MZ))"
      echo "You are a replacement for a previous agent on this same task. Its worktree and commits are exactly as it left them. Its progress note:"
      echo "> $NOTE"
    } >> "$BRIEF"

    backend_kill "$ID"
    backend_relaunch "$ID" "$BRIEF" || {
      echo "chief-control: relaunch failed to start; the previous record is unchanged and the worktree is untouched" >&2
      exit 1
    }
    chief_meta_set "$ID" status working
    echo "relaunched: $ID (same worktree, brief carries the checkpoint note)"
    chief_record_attach "$ID"
    ;;

  *)
    fail "unknown verb '$VERB' - must be interrupt, exit, or relaunch"
    ;;
esac
