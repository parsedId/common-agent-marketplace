#!/usr/bin/env bash
# backend.sh - loads the configured backend adapter and nothing else.
# Every chief-*.sh script that needs a worker terminal sources this (after
# paths.sh AND meta.sh - the herdr/orca adapters call
# chief_meta_get to recover their own endpoint identifier); nothing above
# this file should know whether it's talking to herdr or Orca.
#
# Adapter contract - each backends/<name>.sh must define all of:
#   backend_spawn   <id> <project-dir> <brief-path> <branch>
#                     -> creates the worktree + terminal, launches the agent in
#                        it pointed at the brief, prints the worktree path on
#                        its own stdout line first, then the backend's own
#                        endpoint identifier on a second line. Returns 0 only
#                        once the agent's first turn is observed started;
#                        otherwise non-zero (chief-spawn.sh then rolls back).
#   backend_send    <id> <text-or-special-key>
#                     -> best-effort delivers text (or "Enter"/"Escape"/"C-c")
#                        to that task's terminal.
#   backend_busy    <id> -> exit 0 if the terminal looks actively working,
#                           exit 1 if idle/settled. Best-effort;
#                           chief-crew-state.sh treats tasks/<id>/turn-ended as the authoritative
#                           signal and this as a fallback only.
#   backend_kill    <id> -> tears down the terminal/session. Never touches
#                           the worktree or its git history.
#   backend_relaunch <id> <brief-path>
#                     -> launches a fresh agent in the EXISTING worktree
#                        (recorded in tasks/<id>/meta) pointed at the given
#                        brief, after backend_kill already stopped the old
#                        one. Does not create a new worktree or branch.
#                        Returns 0 only once the first turn is observed started.
#   backend_spawn_cleanup <id> <project-dir> <branch>
#                     -> best-effort rollback of whatever backend_spawn may
#                        have created before failing, or before
#                        chief-spawn.sh could parse its output - worktree,
#                        branch, terminal/pane. Called ONLY by chief-spawn.sh
#                        on those two failure paths, always wrapped in
#                        `|| true` so a cleanup failure never masks the
#                        original error. Must not depend on any meta record
#                        (at most a spawning stub) - only on the
#                        id/project-dir/branch already known to the caller
#                        before backend_spawn was ever invoked. A backend
#                        that hasn't implemented this yet simply leaves the
#                        call a no-op (command-not-found, swallowed by the
#                        caller's `|| true`) rather than erroring.
#   backend_attach_hint <id>   (optional)
#                     -> prints one line telling the operator how to reach the
#                        task's pane. chief-spawn.sh records it as attach= for a
#                        brainstormer. Fails or is absent when there is none.
#
#   backend_teardown <id> <project-dir> <worktree>
#                     -> Called by chief-teardown.sh after backend_kill and
#                        before it removes the worktree via git, so a backend
#                        that tracks worktrees itself (orca) can forget it.
#                        Must call `chief_agent_release <id> <worktree>`. Failures are ignored.
#
# Every function above that touches the agent starts with `chief_agent_use <id>`
# (agents/agent.sh), which loads the adapter recorded in the task's meta.
#
# Selection: $CHIEF_BACKEND env var, else $CONFIG/backend, else "herdr".

CHIEF_BACKEND="${CHIEF_BACKEND:-}"
if [ -z "$CHIEF_BACKEND" ] && [ -f "$CONFIG/backend" ]; then
  CHIEF_BACKEND=$(tr -d '[:space:]' < "$CONFIG/backend")
fi
CHIEF_BACKEND="${CHIEF_BACKEND:-herdr}"

case "$CHIEF_BACKEND" in
  herdr|orca) ;;
  mock)
    # Dev/test only - a fake terminal (one background process + a log file)
    # used to exercise chief-spawn/control/crew-state/watch without a real
    # herdr or Orca install. Never select this in a real project.
    ;;
  *)
    echo "chief-backend: unsupported backend '$CHIEF_BACKEND' (must be herdr or orca)" >&2
    exit 1
    ;;
esac

# shellcheck source=/dev/null
. "$CHIEF_ROOT/bin/lib/agents/agent.sh"
. "$CHIEF_ROOT/bin/lib/backends/$CHIEF_BACKEND.sh"

for _fn in backend_spawn backend_send backend_busy backend_kill backend_relaunch backend_teardown; do
  declare -F "$_fn" >/dev/null || { echo "chief-backend: '$CHIEF_BACKEND' does not define $_fn" >&2; exit 1; }
done
unset _fn

# chief_record_attach <id> - stores and prints a brainstormer's attach hint, if
# the backend has one.
chief_record_attach() {
  local hint
  [ "$(chief_meta_get "$1" mode 2>/dev/null)" = brainstormer ] && declare -F backend_attach_hint >/dev/null || return 0
  hint=$(backend_attach_hint "$1" 2>/dev/null) || return 0
  [ -n "$hint" ] || return 0
  chief_meta_set "$1" attach "$hint"
  echo "attach: $hint"
}
