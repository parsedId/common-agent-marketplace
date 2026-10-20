#!/usr/bin/env bash
# chief-agents.sh - the agent each role would get now, from .chief/config/agents.
# Read-only: round-robin cursors do not advance; a weighted or random pool is
# listed, not picked. "(global fallback)" marks a role with no pool of its own.
#
# Usage: chief-agents.sh
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/paths.sh"
chief_ensure_dirs
. "$CHIEF_ROOT/bin/lib/agents/agent.sh"

for role in $CHIEF_ROLES; do
  chief_agent_select "$role" peek || exit 1
  printf '%-13s %s\n' "$role:" "$(chief_agent_describe)"
done
