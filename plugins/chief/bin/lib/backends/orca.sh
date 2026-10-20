#!/usr/bin/env bash
# orca.sh - Orca backend adapter (`orca agent-context --json`, schema v1).
#
# Same flow as herdr.sh: each task gets its own linked worktree plus a
# terminal running the agent, given the brief's CONTENT as its first prompt
# (the brief lives outside the worktree), and cleaned up on any failure.
#
# Orca only resolves a worktree selector for a worktree IT created, so
# backend_spawn goes through `orca worktree create --repo path:<project>`,
# registering the project first (`orca repo add`) if `orca repo list` doesn't
# have it. The task is created as a child of the project's main worktree, so
# Orca nests it under the project like herdr's linked-worktree workspaces.
# That call can't pin a branch or path: Orca picks its own branch name, which
# is renamed to the exact requested one, and the path is used as-is.
#
# Spawn and relaunch share one launch path (_chief_orca_launch): `terminal
# create --command <chief_agent_command>`, wait for agent_ready_text on the
# rendered screen, then send the brief. backend_spawn pre-trusts the new
# worktree (agent_prepare) first.
#
# Endpoint: "orca:<terminal-handle>". backend_busy polls `orca terminal
# wait --for tui-idle` with a short timeout. Readiness and prompt delivery go
# by the rendered screen instead: `tui-idle` reports the bare shell as idle
# before the agent has started.
#
# backend_kill closes every terminal in the task's worktree (herdr closes the
# whole workspace). backend_teardown also tells Orca to forget the worktree,
# which plain `git worktree remove` would leave as a stale entry.

_chief_orca_handle() {  # <id> -> the task's terminal handle
  chief_meta_get "$1" endpoint | sed 's/^orca://'
}

_chief_orca_close_tab() {  # <handle> - best-effort
  orca terminal close --terminal "$1" --tab >/dev/null 2>&1 || true
}

# _chief_orca_ensure_repo <project-dir> - registers the project with Orca if
# it isn't already (herdr opens the project's workspace itself).
_chief_orca_ensure_repo() {
  local project_dir=$1
  orca repo list --json 2>/dev/null \
    | jq -e --arg p "$project_dir" '[.result.repos[]? | select(.path == $p)] | length > 0' >/dev/null 2>&1 \
    && return 0
  orca repo add --path "$project_dir" --json >/dev/null 2>&1 \
    || { echo "chief-backend-orca: could not register '$project_dir' with Orca ('orca repo add --path $project_dir' failed)" >&2; return 1; }
}

# _chief_orca_find_worktree <id> <project-dir> <branch> - prints
# "<path>\t<refs/heads/branch>" of the Orca worktree backend_spawn made for
# <id>: on the requested branch, or still on Orca's own branch if the rename
# never happened (found by its path, which ends in the sanitized <id>). The
# only id-derived handle that survives a failed spawn with no meta record.
_chief_orca_find_worktree() {
  local id=$1 project_dir=$2 branch=$3 name=${1//\//-}
  orca worktree list --repo "path:$project_dir" --json 2>/dev/null \
    | jq -r --arg b "refs/heads/$branch" --arg s "/$name" \
        '.result.worktrees[]? | select(.branch == $b or (.path | endswith($s))) | "\(.path)\t\(.branch)"' \
    | head -n1
}

_chief_orca_screen() {  # <handle> -> the terminal's rendered screen
  orca terminal read --terminal "$1" --screen --json 2>/dev/null \
    | jq -r '.result.terminal.tail // [] | join("\n")'
}

# _chief_orca_wait_screen <handle> <egrep-pattern> [timeout-s] - polls the
# rendered screen until it matches. Never guess the agent's readiness from
# `tui-idle`: it reports the bare shell as idle before the agent has started,
# and a prompt sent into that gap is silently dropped.
_chief_orca_wait_screen() {
  local handle=$1 pattern=$2 timeout=${3:-${CHIEF_ORCA_START_WAIT:-30}} waited=0
  while [ "$waited" -lt $((timeout * 2)) ]; do
    _chief_orca_screen "$handle" | grep -Eq "$pattern" && return 0
    sleep 0.5
    waited=$((waited + 1))
  done
  return 1
}

# _chief_orca_start_ready <handle> - the agent shows agent_ready_text; otherwise
# the worker would sit on a prompt nobody answers.
_chief_orca_start_ready() {
  local handle=$1
  # A transient hint ("paste again to expand") can cover the status line.
  _chief_orca_wait_screen "$handle" "$(agent_ready_text)" && return 0
  echo "chief-backend-orca: agent not ready in $handle (folder-trust dialog? Chief and Orca must share CLAUDE_CONFIG_DIR); screen:" >&2
  _chief_orca_screen "$handle" | grep -v '^[[:space:]]*$' | tail -5 | sed 's/^/  /' >&2
  return 1
}

# _chief_orca_prompt <handle> <text> - submit <text> to <handle> and check the
# screen: the text (or the agent's pasted-text placeholder) showing up means
# it landed. If it still sits in the live input line a bare Enter submits it,
# and the prompt counts as sent only once it has left that line; not landed
# within CHIEF_ORCA_PROMPT_WAIT seconds is resent once. Does NOT wait for the
# turn to finish - a first turn on a large task can legitimately run long.
_chief_orca_prompt() {
  local handle=$1 text=$2
  local needle screen waited=0 limit=$(( ${CHIEF_ORCA_PROMPT_WAIT:-20} * 2 ))
  needle=$(printf '%s' "$text" | tr -s '[:space:]' ' ' | cut -c1-24)
  orca terminal send --terminal "$handle" --text "$text" --enter --wait-submit 5 >/dev/null 2>&1 \
    || { echo "chief-backend-orca: 'orca terminal send' failed for $handle" >&2; return 1; }
  while [ "$waited" -lt "$limit" ]; do
    screen=$(_chief_orca_screen "$handle")
    if printf '%s' "$screen" | chief_agent_has_text "$needle"; then
      printf '%s\n' "$screen" | chief_agent_input_line | chief_agent_has_text "$needle" || return 0
      orca terminal send --terminal "$handle" --enter >/dev/null 2>&1
      _chief_orca_wait_submitted "$handle" "$needle" && return 0
      echo "chief-backend-orca: prompt for $handle still unsubmitted after Enter" >&2
      return 1
    fi
    sleep 0.5
    waited=$((waited + 1))
  done
  orca terminal send --terminal "$handle" --text "$text" --enter --wait-submit 5 >/dev/null 2>&1 \
    || { echo "chief-backend-orca: 'orca terminal send' failed for $handle" >&2; return 1; }
}

# _chief_orca_wait_submitted <handle> <needle> - polls until the prompt has left
# the live input line
_chief_orca_wait_submitted() {
  local handle=$1 needle=$2 waited=0
  while [ "$waited" -lt $(( ${CHIEF_ORCA_PROMPT_WAIT:-20} * 2 )) ]; do
    _chief_orca_screen "$handle" | chief_agent_input_line | chief_agent_has_text "$needle" || return 0
    sleep 0.5
    waited=$((waited + 1))
  done
  return 1
}

# _chief_orca_launch <worktree> <brief_path> -> creates a terminal in an
# existing worktree, starts the agent, submits the brief; prints the handle.
# Closes the new terminal if that fails.
_chief_orca_launch() {
  local worktree=$1 brief_path=$2
  local json handle
  # orca's connect banner goes to stderr, --json's body to stdout even on
  # failure - discard stderr, don't merge it in (breaks the jq parse below).
  json=$(orca terminal create --worktree "path:$worktree" --command "$(chief_agent_command)" --json 2>/dev/null) \
    || { echo "chief-backend-orca: 'orca terminal create' failed: $json" >&2; return 1; }
  handle=$(printf '%s' "$json" | jq -r '.result.handle // .result.terminal.handle // empty')
  [ -n "$handle" ] \
    || { echo "chief-backend-orca: could not read terminal handle from: $json" >&2; return 1; }

  { _chief_orca_start_ready "$handle" && _chief_orca_prompt "$handle" "$(cat "$brief_path")"; } \
    || { _chief_orca_close_tab "$handle"; return 1; }

  printf '%s\n' "$handle"
}

backend_spawn() {
  local id=$1 project_dir=$2 brief_path=$3 branch=$4
  local json worktree orca_branch handle
  chief_agent_use "$id" || return 1
  _chief_orca_ensure_repo "$project_dir" || return 1
  json=$(orca worktree create --repo "path:$project_dir" --name "$id" --parent-worktree "path:$project_dir" --json 2>/dev/null) \
    || { echo "chief-backend-orca: 'orca worktree create' failed: $json" >&2; return 1; }

  # From here a worktree exists: any failure rolls it back.
  worktree=$(printf '%s' "$json" | jq -r '.result.worktree.path // empty')
  orca_branch=$(printf '%s' "$json" | jq -r '.result.worktree.branch // empty' | sed 's#^refs/heads/##')
  [ -n "$worktree" ] && [ -n "$orca_branch" ] \
    || { echo "chief-backend-orca: could not read worktree path/branch from: $json" >&2
         backend_spawn_cleanup "$id" "$project_dir" "$branch"; return 1; }

  if [ "$orca_branch" != "$branch" ]; then
    git -C "$worktree" branch -m "$branch" \
      || { echo "chief-backend-orca: could not rename branch '$orca_branch' to '$branch' in $worktree" >&2
           backend_spawn_cleanup "$id" "$project_dir" "$branch"; return 1; }
  fi

  agent_prepare "$worktree"
  orca terminal close --worktree "path:$worktree" --all >/dev/null 2>&1 || true
  handle=$(_chief_orca_launch "$worktree" "$brief_path") \
    || { backend_spawn_cleanup "$id" "$project_dir" "$branch"; return 1; }

  printf '%s\n' "$worktree"
  printf 'orca:%s\n' "$handle"
}

# backend_spawn_cleanup <id> <project-dir> <branch> - best-effort rollback
# after backend_spawn itself failed, or chief-spawn.sh couldn't parse its
# output. See backend.sh's contract header for the calling convention.
backend_spawn_cleanup() {
  local id=$1 project_dir=$2 branch=$3
  local found worktree orca_branch
  found=$(_chief_orca_find_worktree "$id" "$project_dir" "$branch")
  [ -n "$found" ] || return 0
  worktree=${found%%$'\t'*}
  orca_branch=${found#*$'\t'}
  orca_branch=${orca_branch#refs/heads/}
  orca terminal close --worktree "path:$worktree" --all >/dev/null 2>&1 || true
  chief_agent_release "$id" "$worktree"
  orca worktree rm --worktree "path:$worktree" --force >/dev/null 2>&1 \
    || git -C "$project_dir" worktree remove --force "$worktree" >/dev/null 2>&1 \
    || rm -rf "$worktree"
  git -C "$project_dir" branch -D "$branch" >/dev/null 2>&1 || true
  git -C "$project_dir" branch -D "$orca_branch" >/dev/null 2>&1 || true
}

backend_send() {
  local id=$1 text=$2
  local handle
  handle=$(_chief_orca_handle "$id")
  case "$text" in
    Enter)  orca terminal send --terminal "$handle" --enter ;;
    Escape) orca terminal send --terminal "$handle" --text $'\x1b' ;;
    C-c)    orca terminal send --terminal "$handle" --interrupt ;;
    *)      orca terminal send --terminal "$handle" --text "$text" --enter ;;
  esac >/dev/null 2>&1
}

backend_busy() {
  local id=$1
  local handle
  handle=$(_chief_orca_handle "$id")
  # Short idle-wait doubles as a non-blocking poll: succeeds (idle) or
  # times out (busy).
  orca terminal wait --terminal "$handle" --for tui-idle --timeout-ms 200 >/dev/null 2>&1 \
    && return 1
  return 0
}

# Unverified live: names the worktree and terminal to open in Orca.
backend_attach_hint() {
  local handle
  handle=$(_chief_orca_handle "$1" 2>/dev/null) || return 1
  [ -n "$handle" ] || return 1
  printf 'in Orca, open worktree %s (terminal %s)\n' "$1" "$handle"
}

backend_kill() {
  local id=$1
  local endpoint worktree
  endpoint=$(chief_meta_get "$id" endpoint 2>/dev/null) || return 0
  [ -n "${endpoint#orca:}" ] || return 0
  worktree=$(chief_meta_get "$id" worktree 2>/dev/null) || worktree=""
  if [ -n "$worktree" ]; then
    orca terminal close --worktree "path:$worktree" --all >/dev/null 2>&1 || true
  else
    _chief_orca_close_tab "${endpoint#orca:}"
  fi
}

# backend_teardown <id> <project-dir> <worktree> - called by chief-teardown.sh
# after backend_kill and before it removes the worktree via git.
backend_teardown() {
  orca worktree rm --worktree "path:$3" --force >/dev/null 2>&1 || true
  chief_agent_release "$1" "$3"
}

backend_relaunch() {
  local id=$1 brief_path=$2
  local worktree handle
  worktree=$(chief_meta_get "$id" worktree)
  chief_agent_use "$id" || return 1
  agent_prepare "$worktree"
  handle=$(_chief_orca_launch "$worktree" "$brief_path") || return 1
  chief_meta_set "$id" endpoint "orca:$handle"
}
