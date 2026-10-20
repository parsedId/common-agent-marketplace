#!/usr/bin/env bash
# paths.sh - shared path resolution, sourced by every chief-*.sh entrypoint
# and the hooks. Pure definitions; chief_ensure_dirs is the only thing that
# touches disk, and entrypoints that write under state/, config/ or worktrees/
# call it explicitly.
#
# Two roots, never confused:
#   CHIEF_ROOT  the plugin's own installed files (bin/, templates/, skills/) -
#               read-only, resolved from this script's own location so it
#               works whether Claude Code installed the plugin or a developer
#               is running it straight out of a checkout.
#   CHIEF_HOME  the operator's one shared runtime home. Defaults to
#               <outermost git root>/.chief of wherever the Chief session
#               runs (never inside a project - see home.sh), override with
#               the CHIEF_HOME env var. This is gitignored working state,
#               never plugin code. Its layout:
#
#   tasks/<id>/   one folder per task: meta status inbox/ lifecycle turn-ended
#                 brief.md report.md evidence/
#   archive/<id>/ a torn-down task's folder
#   state/        global machine state only: locks, agent cursors, trust-owned,
#                 watcher heartbeat
#   backlog.md    the backlog
#   config/       operator configuration
#   worktrees/    one disposable checkout per task
#
# Every bin/chief-*.sh entrypoint sources this before anything else, relative
# to its own directory - "lib/paths.sh" from bin/, "../lib/paths.sh" from
# bin/task/.

# This file always lives at <plugin-root>/bin/lib/paths.sh, so its own
# location - not the caller's - is what tells us where the plugin root is.
_chief_paths_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHIEF_ROOT="$(cd "$_chief_paths_lib_dir/../.." && pwd)"
. "$_chief_paths_lib_dir/home.sh"
unset _chief_paths_lib_dir

CHIEF_HOME="${CHIEF_HOME:-$(chief_default_home)}"

TASKS="$CHIEF_HOME/tasks"
ARCHIVE="$CHIEF_HOME/archive"
STATE="$CHIEF_HOME/state"
BACKLOG="$CHIEF_HOME/backlog.md"
CONFIG="$CHIEF_HOME/config"
WORKTREES="$CHIEF_HOME/worktrees"

chief_ensure_dirs() { mkdir -p "$STATE" "$CONFIG" "$WORKTREES"; }

# chief_task_dir <id> -> the task's folder: under $TASKS, or $ARCHIVE once torn down.
chief_task_dir() {
  if [ ! -d "$TASKS/$1" ] && [ -d "$ARCHIVE/$1" ]; then
    printf '%s/%s' "$ARCHIVE" "$1"
  else
    printf '%s/%s' "$TASKS" "$1"
  fi
}

# chief_task_path <id> <name> -> a file or folder inside the task's folder.
chief_task_path() {
  printf '%s/%s' "$(chief_task_dir "$1")" "$2"
}

# chief_task_archive <id> -> moves the task's folder into $ARCHIVE.
chief_task_archive() {
  [ -d "$TASKS/$1" ] || return 0
  mkdir -p "$ARCHIVE"
  mv "$TASKS/$1" "$ARCHIVE/$1"
}
