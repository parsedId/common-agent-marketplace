#!/usr/bin/env bash
# session-start.sh - force-injects the using-chief identity skill as
# additionalContext, plus a backlog/in-flight digest when one exists. Stands
# down entirely inside a spawned builder's own worktree/session - see
# bin/lib/worktree.sh for why that check is race-free.
set -euo pipefail

CHIEF_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../bin/lib/worktree.sh
. "$CHIEF_PLUGIN_ROOT/bin/lib/worktree.sh"

if chief_is_linked_worktree; then
  echo '{}'
  exit 0
fi

# shellcheck source=../bin/lib/paths.sh
. "$CHIEF_PLUGIN_ROOT/bin/lib/paths.sh"

SKILL_FILE="$CHIEF_ROOT/skills/using-chief/SKILL.md"
[ -f "$SKILL_FILE" ] || { echo '{}'; exit 0; }

# shellcheck source=../bin/lib/meta.sh
. "$CHIEF_ROOT/bin/lib/meta.sh"
BACKEND_CONFIG="$CONFIG/backend"

digest="## Configuration"$'\n'
if [ -f "$BACKEND_CONFIG" ]; then
  digest+="backend: $(cat "$BACKEND_CONFIG") (from .chief/config/backend)"$'\n'
  if [ -f "$CONFIG/agents" ]; then
    digest+="agents: from .chief/config/agents"$'\n'
  else
    digest+="agents: not configured, workers run claude (.chief/config/agents sets the agent and model)"$'\n'
  fi
else
  digest+="NOT CONFIGURED YET at CHIEF_HOME ($CHIEF_HOME) - load the 'setup' skill once here before dispatching anything. This is a one-time step for this CHIEF_HOME, not something to repeat inside each project you dispatch into."$'\n'
fi

digest+=$'\n'"## Backlog and in-flight tasks"$'\n'

if [ -f "$BACKLOG" ] && [ -s "$BACKLOG" ]; then
  digest+=$'\n'"### Backlog"$'\n'"$(grep '^## ' "$BACKLOG" || true)"$'\n'
else
  digest+=$'\n'"### Backlog"$'\n'"(empty)"$'\n'
fi
digest+=$'\n'"### In-flight"$'\n'
any=0
for f in "$TASKS"/*/meta; do
  [ -e "$f" ] || continue
  id=$(basename "$(dirname "$f")")
  status=$(grep '^status=' "$f" | cut -d= -f2- || echo unknown)
  [ "$status" = "working" ] || continue
  any=1
  line=$(tail -n 1 "$(chief_task_path "$id" status)" 2>/dev/null || echo "no status yet")
  mode=$(grep '^mode=' "$f" | cut -d= -f2- || echo unknown)
  tags=""
  if [ "$mode" = brainstormer ]; then
    attach=$(chief_meta_get "$id" attach 2>/dev/null || true)
    [ -z "$attach" ] || tags=" [attach: $attach]"
  fi
  for link in for reviewer; do
    linked=$(chief_meta_get "$id" "$link" 2>/dev/null || true)
    [ -z "$linked" ] || tags+=" [$link: $linked]"
  done
  digest+="- $id: $line [mode: $mode] [agent: $(chief_meta_agent "$id")]$tags"$'\n'
done
[ "$any" -eq 0 ] && digest+="(none)"$'\n'

escape_for_json() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

combined="$(cat "$SKILL_FILE")"$'\n\n'"$digest"
escaped=$(escape_for_json "<EXTREMELY_IMPORTANT>
You MUST follow the 'using-chief' identity and job description below. It applies to this Chief session's CHIEF_HOME (typically your top-level workspace root) - a single shared home, not something to set up separately inside each project you dispatch into:

$combined
</EXTREMELY_IMPORTANT>")
printf '{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "%s"}}\n' "$escaped"
