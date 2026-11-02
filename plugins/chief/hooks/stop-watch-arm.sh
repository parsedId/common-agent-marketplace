#!/usr/bin/env bash
# stop-watch-arm.sh - the token-saving trick. Registered as a Stop hook with
# asyncRewake: true, so Claude Code runs this in the background at zero
# model cost every time the primary session's turn ends, and only "rewakes"
# the session (via exit 2 + stderr) if it finds something worth interrupting
# you for. chief-watch.sh does the actual polling; this script only
# interprets its exit.
#
# Concurrent arms are resolved by chief-watch.sh itself (the newest watcher
# takes over; an older one exits silently, which this script must not rewake
# on). Beacon staleness backstops are deliberately not handled.
set -euo pipefail

CHIEF_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../bin/lib/worktree.sh
. "$CHIEF_PLUGIN_ROOT/bin/lib/worktree.sh"

# A spawned builder's own session must never arm a watcher on itself - only
# the primary (operator-facing) session supervises. This check is race-free
# even against Orca's create-and-launch-in-one-call spawn; see
# bin/lib/worktree.sh. Judge by the launch dir, not the cwd, which drifts in
# the primary session.
LAUNCH_DIR="${CLAUDE_PROJECT_DIR:-.}"
chief_is_linked_worktree "$LAUNCH_DIR" && exit 0

# shellcheck source=../bin/lib/home.sh
. "$CHIEF_PLUGIN_ROOT/bin/lib/home.sh"
export CHIEF_HOME="${CHIEF_HOME:-$(cd "$LAUNCH_DIR" && chief_default_home)}"

# shellcheck source=../bin/lib/paths.sh
. "$CHIEF_PLUGIN_ROOT/bin/lib/paths.sh"

# No CHIEF_HOME at all -> Chief isn't in use here; let the
# turn end normally rather than creating one just to watch nothing.
[ -d "$STATE" ] || exit 0

WATCH="$CHIEF_ROOT/bin/chief-watch.sh"

REASON=$("$WATCH" 2>&1) || true

if [ -z "$REASON" ] || [ "$REASON" = "nothing in flight" ]; then
  exit 0
fi

echo "chief watcher: $REASON" >&2
exit 2
