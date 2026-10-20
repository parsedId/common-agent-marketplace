#!/usr/bin/env bash
# test-hooks.sh - session-start.sh and stop-watch-arm.sh's own bash logic:
# what JSON/exit code they produce for a given .chief/ state. Runs the hook
# scripts directly as plain bash - this is NOT invoking the claude CLI or
# spending any model tokens, and never touches herdr/Orca.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
HOOKS="$REPO_ROOT/plugins/chief/hooks"
BIN="$REPO_ROOT/plugins/chief/bin"
. "$TEST_DIR/lib/harness.sh"

command -v python3 >/dev/null 2>&1 || { echo "test-hooks: python3 required to validate JSON output, skipping"; exit 0; }

WORK=$(mktemp -d)
harness_trap 'rm -rf "$WORK"'
SS="$HOOKS/session-start.sh"
ARM="$HOOKS/stop-watch-arm.sh"

json_field() {  # <json> <python-expr-on-d> - tiny helper to pull one field
  python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" <<<"$2" 2>/dev/null
}

echo "test-hooks:"

mkdir -p "$WORK/fresh" && cd "$WORK/fresh" && git init -q
unset CHIEF_HOME
out=$("$SS")
assert_eq "$(echo "$out" | python3 -m json.tool >/dev/null 2>&1; echo $?)" "0" "session-start: fresh project output is valid JSON"
ctx=$(json_field "d['hookSpecificOutput']['additionalContext']" "$out")
assert_contains "$ctx" "You are Chief" "session-start: injects the using-chief identity"
assert_contains "$ctx" "NOT CONFIGURED YET" "session-start: flags an unconfigured project"
assert_contains "$ctx" "'setup' skill" "session-start: points at the setup skill"

arm_out=$("$ARM" 2>&1); arm_rc=$?
assert_eq "$arm_rc" "0" "stop-watch-arm: exits 0 (lets the turn end) with no .chief/state at all"

echo "---"
mkdir -p "$WORK/configured/project" && cd "$WORK/configured/project" && git init -q -b master
git commit --allow-empty -q -m init
export CHIEF_HOME="$WORK/configured/project/.chief"
export CHIEF_BACKEND=mock
"$BIN/chief-setup.sh" --backend orca >/dev/null
out2=$("$SS")
ctx2=$(json_field "d['hookSpecificOutput']['additionalContext']" "$out2")
assert_contains "$ctx2" "backend: orca" "session-start: reports the configured backend"
assert_contains "$ctx2" "agents: not configured, workers run claude" "session-start: hints when no agents are configured"
assert_not_contains "$ctx2" "NOT CONFIGURED YET" "session-start: no longer flags as unconfigured"
assert_contains "$ctx2" "(empty)" "session-start: reports an empty backlog plainly"

"$BIN/chief-backlog.sh" add t-1 "test task" >/dev/null
timeout 10 "$BIN/chief-spawn.sh" t-1 "$WORK/configured/project" --mode builder --branch feat/t-1 --intent "test" --spec "test" >/dev/null
echo "done: finished" >> "$CHIEF_HOME/tasks/t-1/status"
out3=$("$SS")
ctx3=$(json_field "d['hookSpecificOutput']['additionalContext']" "$out3")
assert_contains "$ctx3" "t-1: done: finished" "session-start: shows the in-flight task's latest status"
assert_contains "$ctx3" "[agent: claude]" "session-start: shows the in-flight task's agent"
assert_contains "$ctx3" "t-1: done: finished [mode: builder]" \
  "session-start: also shows the task's current mode, so a fresh session can tell a researcher from a builder task without reading meta by hand"

timeout 10 "$BIN/chief-spawn.sh" bs-1 "$WORK/configured/project" --mode brainstormer --branch feat/bs-1 --intent "idea" >/dev/null
ctx5=$(json_field "d['hookSpecificOutput']['additionalContext']" "$("$SS")")
assert_contains "$ctx5" "[mode: brainstormer] [agent: claude] [attach: tail -f '$CHIEF_HOME/tasks/bs-1/term.log']" \
  "session-start: repeats the attach hint for an in-flight brainstormer"
assert_not_contains "$ctx5" "[mode: builder] [agent: claude] [attach:" "session-start: no attach hint for a builder"

arm_out2=$("$ARM" 2>&1); arm_rc2=$?
assert_eq "$arm_rc2" "2" "stop-watch-arm: exits 2 (rewake) once a task hits a terminal state"
assert_contains "$arm_out2" "t-1" "stop-watch-arm: the rewake reason names the task"

echo "---"
cd "$CHIEF_HOME/worktrees/t-1" || exit 1
out4=$("$SS")
assert_eq "$out4" "{}" "session-start: stands down completely inside the builder's own worktree"
CLAUDE_PROJECT_DIR="$CHIEF_HOME/worktrees/t-1" "$ARM" >/dev/null 2>&1
assert_eq "$?" "0" "stop-watch-arm: a worker launched in its own worktree never arms"
"$ARM" >/dev/null 2>&1
assert_eq "$?" "0" "stop-watch-arm: no launch dir known falls back to the cwd, so a worker still stands down"

# The primary session launched in the main checkout whose cwd drifted into a
# task worktree must still arm.
sed -i '/^notify-baseline=/d' "$CHIEF_HOME/tasks/t-1/meta"  # re-report t-1 to the fresh watcher
arm_out6=$(CLAUDE_PROJECT_DIR="$WORK/configured/project" "$ARM" 2>&1); arm_rc6=$?
assert_eq "$arm_rc6" "2" "stop-watch-arm: primary session with cwd in a linked worktree still arms"
assert_contains "$arm_out6" "t-1" "stop-watch-arm: ...and reports the finished task"

echo "---"
# Skipped arms stay quiet for Chief's workers, even in a worktree outside
# $WORKTREES (Orca picks its own path), and warn once for anyone else.
echo "status=working" > "$CHIEF_HOME/tasks/t-1/meta.tmp"; cat "$CHIEF_HOME/tasks/t-1/meta" >> "$CHIEF_HOME/tasks/t-1/meta.tmp"
mv "$CHIEF_HOME/tasks/t-1/meta.tmp" "$CHIEF_HOME/tasks/t-1/meta"
git -C "$WORK/configured/project" worktree add -q -b ext "$WORK/ext"
git -C "$WORK/configured/project" worktree add -q -b other "$WORK/other"
mkdir -p "$CHIEF_HOME/tasks/e-1"
printf 'status=working\nworktree=%s\n' "$WORK/ext" > "$CHIEF_HOME/tasks/e-1/meta"
cd "$WORK/ext/" || exit 1
arm_out7=$(CLAUDE_PROJECT_DIR="$WORK/ext" "$ARM" 2>&1); arm_rc7=$?
assert_eq "$arm_rc7" "0" "stop-watch-arm: a worker in an external worktree skips (exit 0)"
assert_eq "$arm_out7" "" "stop-watch-arm: ...silently"
assert_eq "$([ -e "$CHIEF_HOME/state/.arm-skip-noted" ] && echo yes || echo no)" "no" "stop-watch-arm: ...without using up the notice"

# A spawn in flight has no worktree recorded yet: stay silent too.
printf 'status=spawning\nworktree=%s/pending\n' "$WORK" > "$CHIEF_HOME/tasks/e-1/meta"
arm_out7b=$(CLAUDE_PROJECT_DIR="$WORK/other" "$ARM" 2>&1)
assert_eq "$arm_out7b" "" "stop-watch-arm: an unrecorded linked worktree stays silent while a spawn is in flight"
rm "$CHIEF_HOME/tasks/e-1/meta"

# An unrelated linked worktree with tasks working: warn once, exit 0.
arm_out7c=$(CLAUDE_PROJECT_DIR="$WORK/other" "$ARM" 2>&1); arm_rc7c=$?
assert_eq "$arm_rc7c" "0" "stop-watch-arm: a skipped arm never wakes the model (exit 0)"
assert_contains "$arm_out7c" "not armed" "stop-watch-arm: an unrelated linked worktree with tasks in flight is told on stderr"
assert_eq "$([ -e "$CHIEF_HOME/state/.arm-skip-noted" ] && echo yes || echo no)" "yes" "stop-watch-arm: ...and the notice is recorded"
arm_out8=$(CLAUDE_PROJECT_DIR="$WORK/other" "$ARM" 2>&1)
assert_eq "$arm_out8" "" "stop-watch-arm: ...but only once"

harness_summary
