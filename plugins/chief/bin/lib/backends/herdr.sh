#!/usr/bin/env bash
# herdr.sh - herdr backend adapter, verified against a live
# herdr 0.9.1 install (see `herdr --skill` for herdr's own authoritative
# usage guide - re-check it after a herdr upgrade in case the CLI shape
# below has moved on).
#
# herdr organizes terminals as workspace -> tab -> pane, and separately
# tracks a "coding agent" occupying a pane (idle/working/blocked/done/
# unknown). `herdr worktree create` does both the git-worktree-add AND the
# terminal-open in one call, returning the new pane's id
# (workspace-qualified, e.g. "w2:p1") at `.result.root_pane.pane_id` - that
# pane id is exactly what agent commands accept as a target, so it's used
# unmodified as this adapter's endpoint ("herdr:<pane_id>").
#
# Each project has one primary workspace; herdr natively groups each task's
# linked-worktree workspace (labelled with the plain task id) under it.
#
# The brief lives under $CHIEF_HOME (inside the project's main checkout),
# never inside the per-task worktree, so telling the agent to go Read it would
# hit the agent's own "allow reads outside the working directory?"
# permission dialog on every single spawn too. Sidestepped entirely by
# sending the brief's own CONTENT as the prompt text instead of a path for
# the agent to go read.
#
# `herdr agent prompt --wait` submits text+Enter as one write, then (per
# herdr's own docs) waits up to 5s for observed working/blocked activity
# before reporting `agent_prompt_stalled` - that 5s race is herdr's own
# inherent behavior, not something this adapter controls. A stall can mean
# the text landed but the Enter didn't register (a bare Enter recovers it),
# the text never reached the input line (only resending recovers it), or the
# TUI hadn't rendered yet (the text is queued in the pty; wait). See
# _chief_herdr_recover.
#
# `agent start` returning, ready or not, says nothing about the TUI: readiness
# is read off the screen (_chief_herdr_start_agent). backend_spawn and
# backend_relaunch return 0 only once the first turn was observed started.
#
# CHIEF_HERDR_START_WAIT (s) bounds the wait for the agent's ready screen,
# CHIEF_HERDR_SUBMIT_TIMEOUT_MS how long the first prompt waits for its turn to
# START (reach `working`), CHIEF_HERDR_PROMPT_WAIT (s) the stall recovery. None
# waits for that turn to finish - a first turn on a large task can
# legitimately run long. backend_send's ordinary mid-task turns don't wait.
CHIEF_HERDR_START_WAIT="${CHIEF_HERDR_START_WAIT:-60}"
CHIEF_HERDR_SUBMIT_TIMEOUT_MS="${CHIEF_HERDR_SUBMIT_TIMEOUT_MS:-30000}"
CHIEF_HERDR_PROMPT_WAIT="${CHIEF_HERDR_PROMPT_WAIT:-20}"

# _chief_herdr_name <id> -> the herdr agent name. herdr accepts only
# ^[a-z][a-z0-9_-]{0,31}$: a valid id is used as is, any other becomes a
# sanitized prefix plus an 8-hex hash of the id (deterministic, unique per id).
_chief_herdr_name() {
  local id=$1 hash base
  if [[ $id =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
    printf '%s' "$id"
    return
  fi
  hash=$(printf '%s' "$id" | cksum | awk '{ printf "%08x", $1 }')
  base=$(printf '%s' "$id" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_\n-' '-' | sed 's/^[^a-z]*//' | cut -c1-23)
  printf '%s-%s' "${base:-t}" "$hash"
}

_chief_herdr_workspace_id() {  # <pane-id> -> workspace id ("w2:p1" -> "w2")
  printf '%s' "$1" | cut -d: -f1
}

# _chief_herdr_close_task_workspace <id> - best-effort: closes the workspace
# whose worktree is the task's, whatever label it carries - the only
# id-derived handle guaranteed to survive a failure with no parsed pane id.
_chief_herdr_close_task_workspace() {
  local worktree="$WORKTREES/$1"
  herdr workspace list 2>/dev/null \
    | jq -r --arg a "$worktree" --arg b "$(realpath -m "$worktree")" \
        '.result.workspaces[]? | select(.worktree.checkout_path as $p | $p != null and ($p == $a or $p == $b)) | .workspace_id' \
    | while read -r w; do herdr workspace close "$w" >/dev/null 2>&1; done || true
}

_chief_herdr_screen() {  # <id> [source] -> the agent's screen
  herdr agent read "$(_chief_herdr_name "$1")" --source "${2:-recent-unwrapped}" --lines 40 2>/dev/null
}

# _chief_herdr_trust_dialog_ours <screen> <worktree> - the screen shows the
# agent's folder-trust dialog for <worktree> (its path wraps across lines)
_chief_herdr_trust_dialog_ours() {
  local screen=$1 worktree=$2 flat d
  printf '%s' "$screen" | tr -s '[:space:]' ' ' | grep -Eq -- "$(agent_trust_text)" || return 1
  flat=$(printf '%s' "$screen" | tr -d '[:space:]')
  for d in "$worktree" "$(realpath -m "$worktree")"; do
    [[ $flat == *"$(printf '%s' "$d" | tr -d '[:space:]')"* ]] && return 0
  done
  return 1
}

# _chief_herdr_start_agent <id> <pane-id> <worktree> - start the agent in
# <pane-id> under live name <id>, with the agent's own args, never inherited
# from the operator's session. `agent start` is no evidence of readiness (it
# returns "idle" before the TUI renders): poll the screen for agent_ready_text.
# A folder-trust dialog for <worktree> (pre-trust is the fast path, but a
# concurrent claude can drop its entry) is accepted once with agent_trust_keys.
_chief_herdr_start_agent() {
  local id=$1 pane_id=$2 worktree=$3 cmd args="" out screen keys reason waited=0 pressed=0
  local limit=$(( CHIEF_HERDR_START_WAIT * 2 ))
  cmd=$(chief_agent_command)
  [[ $cmd != *' '* ]] || args=${cmd#* }  # herdr runs the agent's own executable: pass the words after the first
  # agent_pane_busy: the pane's shell isn't up yet (slow host); nothing started, so retry
  until out=$(herdr agent start "$(_chief_herdr_name "$id")" --kind "$(agent_name)" --pane "$pane_id" --timeout 30000 \
                -- $args 2>&1) || [[ $out == *agent_not_ready* ]]; do
    [[ $out == *agent_pane_busy* ]] && [ "$waited" -lt "$limit" ] || {
      echo "chief-backend-herdr: 'herdr agent start' failed for $id: $out" >&2
      return 1
    }
    sleep 0.5
    waited=$((waited + 1))
  done
  waited=0
  while :; do
    screen=$(_chief_herdr_screen "$id")
    printf '%s' "$screen" | grep -Eq -- "$(agent_ready_text)" && return 0
    keys=$(agent_trust_keys)
    if [ "$pressed" = 0 ] && [ -n "$keys" ] && _chief_herdr_trust_dialog_ours "$screen" "$worktree"; then
      herdr agent send-keys "$(_chief_herdr_name "$id")" $keys >/dev/null 2>&1
      pressed=1
    fi
    [ "$waited" -lt "$limit" ] || break
    sleep 0.5
    waited=$((waited + 1))
  done
  reason="no ready screen after ${CHIEF_HERDR_START_WAIT}s"
  printf '%s' "$screen" | tr -s '[:space:]' ' ' | grep -Eq -- "$(agent_trust_text)" \
    && reason="stopped at the folder-trust dialog"
  echo "chief-backend-herdr: agent $id not ready ($reason); screen:" >&2
  printf '%s\n' "$screen" | grep -v '^[[:space:]]*$' | tail -5 | sed 's/^/  /' >&2
  return 1
}

# _chief_herdr_turn_started <reply> - herdr's reply shows the turn running or
# finished; `blocked` (a dialog nobody answers) is not a started turn
_chief_herdr_turn_started() {
  printf '%s' "$1" | jq -e '.result.agent.agent_status | . == "working" or . == "done"' >/dev/null 2>&1
}

# _chief_herdr_submit <id> <text> - submit <text> (herdr's reply in
# $SUBMIT_REPLY): 0 the turn started, 1 herdr failed, 2 it replied without one
_chief_herdr_submit() {
  SUBMIT_REPLY=$(herdr agent prompt "$(_chief_herdr_name "$1")" "$2" --wait --until working --until done \
                   --timeout "$CHIEF_HERDR_SUBMIT_TIMEOUT_MS" 2>&1) || return 1
  _chief_herdr_turn_started "$SUBMIT_REPLY" || return 2
}

# _chief_herdr_recover <id> <text> <before> - after agent_prompt_stalled, decide
# from the screen what became of <text>, polling up to CHIEF_HERDR_PROMPT_WAIT s.
# <before> is the screen read just before the send:
#   text or the paste placeholder shown -> it landed: a bare Enter if it still
#     sits in the live input line; never a resend over it
#   agent ready, screen changed         -> it landed (an agent that echoes the
#     brief inline shows no needle): wait for the turn, never resend, success
#     whatever the wait says
#   agent ready, screen as before       -> it never arrived: resend once
#   anything else (shell only, dialog)  -> not rendered yet, any text is queued
#     in the pty: keep waiting, never resend
# 0 only once the turn is observed started.
_chief_herdr_recover() {
  local id=$1 text=$2 before=$3 needle screen waited=0 limit=$(( CHIEF_HERDR_PROMPT_WAIT * 2 ))
  needle=$(printf '%s' "$text" | tr -s '[:space:]' ' ' | cut -c1-24)
  while :; do
    screen=$(_chief_herdr_screen "$id" detection)
    if printf '%s' "$screen" | chief_agent_has_text "$needle"; then
      if printf '%s\n' "$screen" | chief_agent_input_line | chief_agent_has_text "$needle"; then
        herdr agent send-keys "$(_chief_herdr_name "$id")" enter >/dev/null 2>&1
      fi
      herdr agent wait "$(_chief_herdr_name "$id")" --until working --until done --timeout 15000 >/dev/null 2>&1
      return
    fi
    if printf '%s' "$screen" | grep -Eq -- "$(agent_ready_text)"; then
      if [ "$screen" = "$before" ]; then
        _chief_herdr_submit "$id" "$text"
      else
        herdr agent wait "$(_chief_herdr_name "$id")" --until working --until done --timeout 15000 >/dev/null 2>&1
        return 0
      fi
      return
    fi
    [ "$waited" -lt "$limit" ] || return 1
    sleep 0.5
    waited=$((waited + 1))
  done
}

# _chief_herdr_prompt <id> <text> - submit <text> and wait only for the turn to
# START, not to finish; one recovery attempt after a stall, no further retry.
_chief_herdr_prompt() {
  local id=$1 text=$2 rc=0 before
  before=$(_chief_herdr_screen "$id" detection)
  _chief_herdr_submit "$id" "$text" || rc=$?
  [ "$rc" != 0 ] || return 0
  if [ "$rc" = 1 ]; then
    [[ $SUBMIT_REPLY == *agent_prompt_stalled* ]] || {
      echo "chief-backend-herdr: 'herdr agent prompt' failed for $id: $SUBMIT_REPLY" >&2
      return 1
    }
    _chief_herdr_recover "$id" "$text" "$before" && return 0
  fi
  # A permission/approval prompt nobody is present to answer is not a wedged
  # terminal - `agent get`'s state is `blocked` only for the former.
  if herdr agent get "$(_chief_herdr_name "$id")" 2>/dev/null | jq -e '.result.agent.agent_status == "blocked"' >/dev/null; then
    echo "chief-backend-herdr: prompt for $id stalled at an unanswered permission/approval prompt - no one is present to answer it" >&2
  else
    echo "chief-backend-herdr: no turn started for $id after the prompt" >&2
  fi
  return 1
}

backend_spawn() {
  local id=$1 project_dir=$2 brief_path=$3 branch=$4
  local worktree="$WORKTREES/$id"
  local json pane_id
  chief_agent_use "$id" || return 1
  agent_prepare "$worktree"
  json=$(herdr worktree create --cwd "$project_dir" --branch "$branch" --path "$worktree" \
           --label "$id" --trust-repository --no-focus 2>&1) \
    || { echo "chief-backend-herdr: 'herdr worktree create' failed: $json" >&2; return 1; }
  pane_id=$(printf '%s' "$json" | jq -r '.result.root_pane.pane_id // empty')
  [ -n "$pane_id" ] || { echo "chief-backend-herdr: could not read pane id from: $json" >&2; return 1; }

  _chief_herdr_start_agent "$id" "$pane_id" "$worktree" || return 1

  _chief_herdr_prompt "$id" "$(cat "$brief_path")" || return 1

  printf '%s\n' "$worktree"
  printf 'herdr:%s\n' "$pane_id"
}

# backend_spawn_cleanup <id> <project-dir> <branch> - best-effort rollback
# after backend_spawn itself failed, or chief-spawn.sh couldn't parse its
# output. See backend.sh's contract header for the calling convention.
backend_spawn_cleanup() {
  local id=$1 project_dir=$2 branch=$3
  local worktree="$WORKTREES/$id"
  _chief_herdr_close_task_workspace "$id"
  chief_agent_release "$id" "$worktree"
  git -C "$project_dir" worktree remove --force "$worktree" >/dev/null 2>&1 || rm -rf "$worktree"
  git -C "$project_dir" branch -D "$branch" >/dev/null 2>&1 || true
}

backend_send() {
  local id=$1 text=$2
  case "$text" in
    Enter)  herdr agent send-keys "$(_chief_herdr_name "$id")" enter ;;
    Escape) herdr agent send-keys "$(_chief_herdr_name "$id")" esc ;;
    C-c)    herdr agent send-keys "$(_chief_herdr_name "$id")" ctrl+c ;;
    *)      herdr agent prompt "$(_chief_herdr_name "$id")" "$text" ;;
  esac >/dev/null
}

# The pane id in the endpoint names the workspace; its label is the task id.
backend_attach_hint() {
  local pane_id
  pane_id=$(chief_meta_get "$1" endpoint 2>/dev/null) || return 1
  pane_id=${pane_id#herdr:}
  [ -n "$pane_id" ] || return 1
  printf 'herdr workspace focus %s (workspace "%s")\n' "$(_chief_herdr_workspace_id "$pane_id")" "$1"
}

backend_busy() {
  local id=$1
  herdr agent get "$(_chief_herdr_name "$id")" 2>/dev/null | jq -e '.result.agent.agent_status == "working"' >/dev/null
}

backend_kill() {
  local id=$1
  local endpoint pane_id
  endpoint=$(chief_meta_get "$id" endpoint 2>/dev/null) || return 0
  pane_id=${endpoint#herdr:}
  [ -n "$pane_id" ] || return 0
  herdr workspace close "$(_chief_herdr_workspace_id "$pane_id")" >/dev/null 2>&1 || true
}

# _chief_herdr_project_in_use <id> <project-dir> - another live task of the
# project exists (any task but <id> whose meta is not torn-down)
_chief_herdr_project_in_use() {
  local m other want
  want=$(realpath -m "$2")
  for m in "$TASKS"/*/meta; do
    [ -f "$m" ] || continue
    other=$(basename "$(dirname "$m")")
    [ "$other" != "$1" ] || continue
    [ "$(realpath -m "$(chief_meta_get "$other" project 2>/dev/null)")" = "$want" ] || continue
    [ "$(chief_meta_get "$other" status 2>/dev/null)" != torn-down ] && return 0
  done
  return 1
}

# _chief_herdr_close_project_workspace <project-dir> - closes the workspace
# whose checkout is exactly <project-dir>, never the Chief home's own.
_chief_herdr_close_project_workspace() {
  local project=$1 real home
  real=$(realpath -m "$project"); home=$(realpath -m "$CHIEF_HOME")
  [ "$real" != "$home" ] && [ "$real" != "$(dirname "$home")" ] || return 0
  herdr workspace list 2>/dev/null \
    | jq -r --arg a "$project" --arg b "$real" \
        '.result.workspaces[]? | select(.worktree.checkout_path as $p | $p != null and ($p == $a or $p == $b)) | .workspace_id' \
    | while read -r w; do
        herdr workspace close "$w" >/dev/null 2>&1 \
          || echo "chief-backend-herdr: could not close project workspace $w ($project)" >&2
      done || true
}

# backend_teardown <id> <project-dir> <worktree> - releases the agent's trust
# and closes the project's primary workspace once no other live task uses it.
backend_teardown() {
  chief_agent_release "$1" "$3"
  _chief_herdr_project_in_use "$1" "$2" || _chief_herdr_close_project_workspace "$2"
}

backend_relaunch() {
  local id=$1 brief_path=$2
  local project worktree json pane_id
  # Closes the new workspace on any failure below, without repeating the call
  # at every site (a RETURN trap, skipped once `ok` is set). Matters here:
  # chief-control.sh already killed the OLD pane before calling relaunch, and
  # nothing else cleans up after this.
  local ok=0
  trap '[ "$ok" = 1 ] || _chief_herdr_close_task_workspace "$id"' RETURN

  project=$(chief_meta_get "$id" project)
  worktree=$(chief_meta_get "$id" worktree)
  chief_agent_use "$id" || return 1
  agent_prepare "$worktree"

  # --cwd is required here: without it, `herdr worktree open` resolves the
  # repo against ambient server state instead of this specific project -
  # confirmed live to pick up a stale, unrelated repo when omitted.
  json=$(herdr worktree open --cwd "$project" --path "$worktree" --label "$id" --trust-repository --no-focus 2>&1) \
    || { echo "chief-backend-herdr: 'herdr worktree open' failed: $json" >&2; return 1; }
  pane_id=$(printf '%s' "$json" | jq -r '.result.root_pane.pane_id // empty')
  [ -n "$pane_id" ] || { echo "chief-backend-herdr: could not read pane id from: $json" >&2; return 1; }

  _chief_herdr_start_agent "$id" "$pane_id" "$worktree" || return 1

  _chief_herdr_prompt "$id" "$(cat "$brief_path")" || return 1

  ok=1
  chief_meta_set "$id" endpoint "herdr:$pane_id"
}
