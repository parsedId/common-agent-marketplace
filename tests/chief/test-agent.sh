#!/usr/bin/env bash
# test-agent.sh - agents/agent.sh loader: per-task adapter from meta, command override, unknown agent.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$TEST_DIR/../.." && pwd)/plugins/chief/bin/lib"
. "$TEST_DIR/lib/harness.sh"

WORK=$(mktemp -d)
harness_trap 'rm -rf "$WORK"'
export CHIEF_HOME="$WORK/.chief"
. "$LIB/paths.sh"
chief_ensure_dirs
. "$LIB/meta.sh"
. "$LIB/agents/agent.sh"

echo "test-agent:"

chief_agent_use none >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "$rc" "1" "use: a task with no recorded agent is refused"

chief_meta_set t1 agent claude
chief_meta_set t1 model opus
chief_agent_use t1
assert_eq "$(chief_agent_command)" "claude --dangerously-skip-permissions --model opus" "use: the model reaches the adapter"

chief_meta_set t2 agent claude
chief_meta_set t2 model ""
chief_agent_use t2
assert_eq "$(chief_agent_command)" "claude --dangerously-skip-permissions" "use: no model, no model flag"

chief_meta_set t3 agent claude
chief_meta_set t3 command "/opt/wrap/claude --foo --bar=1"
chief_agent_use t3
assert_eq "$(chief_agent_command)" "/opt/wrap/claude --foo --bar=1" "command override: replaces the launch command"
chief_meta_set t4 agent claude
chief_meta_set t4 command "wrapper"
chief_agent_use t4
chief_agent_use t1
assert_eq "$(chief_agent_command)" "claude --dangerously-skip-permissions --model opus" "use: the next task does not inherit the override"

chief_meta_set t5 agent claude
chief_meta_set t5 model opus
chief_meta_set t5 args "--verbose --add-dir /x"
chief_agent_use t5
assert_eq "$(chief_agent_command)" "claude --dangerously-skip-permissions --model opus --verbose --add-dir /x" "args: appended after the unattended and model flags"
chief_agent_use t1
assert_eq "$(chief_agent_command)" "claude --dangerously-skip-permissions --model opus" "args: the next task does not inherit them"

chief_meta_set bad agent nope
assert_contains "$(chief_agent_use bad 2>&1)" "unknown agent 'nope' (available: claude" "load: unknown agent lists the adapters"
chief_meta_set bad agent ../claude
assert_contains "$(chief_agent_use bad 2>&1)" "unknown agent '../claude'" "load: a name with a slash is refused"
chief_meta_set bad agent agent
assert_contains "$(chief_agent_use bad 2>&1)" "unknown agent 'agent'" "load: the loader file is not an adapter"
assert_eq "$(chief_agent_list | paste -sd' ' -)" "claude codex copilot" "list: only adapters"

harness_summary
