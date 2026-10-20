#!/usr/bin/env bash
# worktree.sh - the ONE guard that keeps Chief's identity/supervision
# hooks from misfiring inside a spawned builder's own Claude Code session.
#
# A linked git worktree's --git-dir differs from its --git-common-dir (which
# points back at the main checkout's .git); the main checkout's own git-dir
# IS its git-common-dir. This fact is true the instant `git worktree add`
# creates the worktree - before any agent launches in it - so it's race-free
# even for a backend like Orca that creates the worktree and launches the
# agent in one call. No marker file needed.
#
# chief_is_linked_worktree [dir] -> exit 0 if dir (default: cwd) is inside a
#                              linked worktree, exit 1 if it's the main
#                              checkout or not a git repo at all.
chief_is_linked_worktree() {
  local dir=${1:-.} git_dir common_dir
  git_dir=$(git -C "$dir" rev-parse --git-dir 2>/dev/null) || return 1
  common_dir=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  git_dir=$(cd "$dir" && cd "$git_dir" 2>/dev/null && pwd) || return 1
  common_dir=$(cd "$dir" && cd "$common_dir" 2>/dev/null && pwd) || return 1
  [ "$git_dir" != "$common_dir" ]
}
