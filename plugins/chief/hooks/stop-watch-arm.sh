#!/usr/bin/env bash
# stop-watch-arm.sh - the token-saving trick. Registered as a Stop hook with
# asyncRewake: true, so Claude Code runs this in the background at zero
# model cost every time the primary session's turn ends, and only "rewakes"
# the session (via exit 2 + stderr) if it finds something worth interrupting
# you for. chief-watch.sh does the actual polling; this script only
# interprets its exit.
#
# Deliberately NOT handled here (kept out for v1 simplicity): concurrent-arm
# locking, generation claims, beacon staleness backstops. Firstmate's
# equivalent (bin/fm-claude-stop-autoarm.sh) solves those; this is the
# simpler version of the same idea, sized for one person's fleet.
set -euo pipefail

CHIEF_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../bin/lib/worktree.sh
. "$CHIEF_PLUGIN_ROOT/bin/lib/worktree.sh"

# shellcheck source=../bin/lib/paths.sh
. "$CHIEF_PLUGIN_ROOT/bin/lib/paths.sh"

# No CHIEF_HOME at all -> Chief isn't in use here; let the
# turn end normally rather than creating one just to watch nothing.
[ -d "$STATE" ] || exit 0

# A spawned builder's own session must never arm a watcher on itself - only
# the primary session supervises. Judge by the launch dir (CLAUDE_PROJECT_DIR),
# not the cwd, which drifts in the primary session. Race-free even for Orca's
# create-and-launch spawn; see bin/lib/worktree.sh.
LAUNCH_DIR="${CLAUDE_PROJECT_DIR:-.}"
if chief_is_linked_worktree "$LAUNCH_DIR"; then
  # Skip always. Warn once (exit 0: stderr does not wake the model) only for a
  # session that is not one of Chief's workers: its dir is not a task's
  # recorded worktree and no spawn is mid-flight (meta not written yet).
  launch_real=$(cd "$LAUNCH_DIR" && pwd -P)
  is_worker=
  for meta in "$TASKS"/*/meta "$ARCHIVE"/*/meta; do
    [ -f "$meta" ] || continue
    wt=$(sed -n 's/^worktree=//p' "$meta" | head -n1)
    wt=$(cd "$wt" 2>/dev/null && pwd -P) || continue
    case "$launch_real/" in "$wt/"*) is_worker=1 ;; esac
  done
  if [ -z "$is_worker" ] \
     && ! grep -qsE '^status=spawning$' "$TASKS"/*/meta \
     && grep -qsE '^status=working$' "$TASKS"/*/meta \
     && [ ! -e "$STATE/.arm-skip-noted" ]; then
    : > "$STATE/.arm-skip-noted"
    echo "chief watcher: not armed - this session was launched in a linked worktree ($launch_real) while tasks are in flight; start Chief from the main checkout" >&2
  fi
  exit 0
fi

WATCH="$CHIEF_ROOT/bin/chief-watch.sh"

REASON=$("$WATCH" 2>&1) || true

if [ "$REASON" = "nothing in flight" ]; then
  exit 0
fi

echo "chief watcher: $REASON" >&2
exit 2
