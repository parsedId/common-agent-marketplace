#!/usr/bin/env bash
# mock.sh - DEV/TEST ONLY fake terminal backend.
#
# Real backends launch the agent in a real terminal. This one launches a
# harmless placeholder background process instead, so the rest of Chief's
# scripts (spawn/control/crew-state/watch/teardown) can be exercised end to
# end without herdr, Orca, or spending real model tokens. A test then plays
# the builder's role by hand-writing tasks/<id>/status and
# tasks/<id>/turn-ended, exactly as a real brief instructs a real agent to.
#
# "Terminal" here is one log file (tasks/<id>/term.log) plus one long-lived
# placeholder process whose pid is recorded in tasks/<id>/term.pid.
#
# $CHIEF_MOCK_PID_LOG, if set, is a file every placeholder pid is appended to,
# so a test harness can reap exactly the workers it started.
#
# CHIEF_MOCK_SPAWN_FAIL=1 and CHIEF_MOCK_SPAWN_MALFORMED=1 are test-only
# failure injectors (unset in normal use) so chief-spawn.sh's own failure
# handling - the backend_spawn_cleanup calls, the spawn lock - can be
# exercised without herdr/orca: FAIL simulates backend_spawn itself
# failing after the worktree/branch/terminal already exist; MALFORMED
# simulates it succeeding but returning only one output line.

backend_spawn() {
  local id=$1 project_dir=$2 brief_path=$3 branch=$4
  local worktree="$WORKTREES/$id"
  chief_agent_use "$id" || return 1
  agent_prepare "$worktree"
  git -C "$project_dir" worktree add -q -b "$branch" "$worktree" >/dev/null
  local log="$(chief_task_path "$id" term.log)"
  : > "$log"
  {
    echo "[mock] launched for $id"
    echo "[mock] brief: $brief_path"
    echo "[mock] worktree: $worktree"
  } >> "$log"
  # A placeholder long-lived process standing in for a real terminal session.
  # Must not inherit this function's stdout/stderr: backend_spawn's caller
  # reads its output via $(...), and a background child holding that pipe's
  # write end open would block the command substitution until the child
  # exits - i.e. until sleep's 100000 seconds are up.
  ( exec -a "chief-mock-$id" sleep 100000 ) >/dev/null 2>&1 &
  disown
  echo $! > "$(chief_task_path "$id" term.pid)"
  [ -z "${CHIEF_MOCK_PID_LOG:-}" ] || echo $! >> "$CHIEF_MOCK_PID_LOG"
  if [ "${CHIEF_MOCK_SPAWN_FAIL:-0}" = "1" ]; then
    echo "[mock] simulated backend_spawn failure for $id" >&2
    return 1
  fi
  printf '%s\n' "$worktree"
  if [ "${CHIEF_MOCK_SPAWN_MALFORMED:-0}" != "1" ]; then
    printf 'mock:%s\n' "$id"
  fi
}

# backend_spawn_cleanup <id> <project-dir> <branch> - best-effort rollback
# after backend_spawn itself failed, or chief-spawn.sh couldn't parse its
# output, before any meta record exists.
backend_spawn_cleanup() {
  local id=$1 project_dir=$2 branch=$3
  local worktree="$WORKTREES/$id"
  local pid
  chief_agent_release "$id" "$worktree"
  pid=$(cat "$(chief_task_path "$id" term.pid)" 2>/dev/null) || true
  [ -n "${pid:-}" ] && kill "$pid" 2>/dev/null
  rm -f "$(chief_task_path "$id" term.pid)" "$(chief_task_path "$id" term.log)"
  git -C "$project_dir" worktree remove --force "$worktree" >/dev/null 2>&1 || rm -rf "$worktree"
  git -C "$project_dir" branch -D "$branch" >/dev/null 2>&1 || true
}

backend_send() {
  local id=$1 text=$2
  echo "[mock] send: $text" >> "$(chief_task_path "$id" term.log)"
}

backend_busy() {
  local id=$1
  local pid
  pid=$(cat "$(chief_task_path "$id" term.pid)" 2>/dev/null) || return 1
  kill -0 "$pid" 2>/dev/null
}

backend_attach_hint() {
  printf "tail -f '%s'\n" "$(chief_task_path "$1" term.log)"
}

backend_relaunch() {
  local id=$1 brief_path=$2
  chief_agent_use "$id" || return 1
  agent_prepare "$(chief_meta_get "$id" worktree)"
  echo "[mock] relaunch for $id" >> "$(chief_task_path "$id" term.log)"
  echo "[mock] brief: $brief_path" >> "$(chief_task_path "$id" term.log)"
  ( exec -a "chief-mock-$id" sleep 100000 ) >/dev/null 2>&1 &
  disown
  echo $! > "$(chief_task_path "$id" term.pid)"
  [ -z "${CHIEF_MOCK_PID_LOG:-}" ] || echo $! >> "$CHIEF_MOCK_PID_LOG"
}

backend_teardown() {
  chief_agent_release "$1" "$3"
}

backend_kill() {
  local id=$1
  local pid
  pid=$(cat "$(chief_task_path "$id" term.pid)" 2>/dev/null) || return 0
  kill "$pid" 2>/dev/null || true
  rm -f "$(chief_task_path "$id" term.pid)" "$(chief_task_path "$id" term.log)"
}
