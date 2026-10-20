#!/usr/bin/env bash
# test-agent-adapters.sh - agents/codex.sh and agents/copilot.sh: contract values, model flag, CLI check, and herdr's start args.
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

echo "test-agent-adapters:"

for a in codex copilot; do
  chief_meta_set "n-$a" agent "$a"; chief_meta_set "m-$a" agent "$a"; chief_meta_set "m-$a" model big
done

chief_agent_use n-codex
assert_eq "$(agent_name)" "codex" "codex: herdr kind"
assert_eq "$(chief_agent_command)" "codex --dangerously-bypass-approvals-and-sandbox" "codex: no-approval flag, no model flag without a model"
chief_agent_use m-codex
assert_eq "$(chief_agent_command)" "codex --dangerously-bypass-approvals-and-sandbox --model big" "codex: model flag with a model"

chief_agent_use n-copilot
assert_eq "$(agent_name)" "copilot" "copilot: herdr kind"
assert_eq "$(chief_agent_command)" "copilot --allow-all" "copilot: allow-all flag, no model flag without a model"
chief_agent_use m-copilot
assert_eq "$(chief_agent_command)" "copilot --allow-all --model big" "copilot: model flag with a model"

for a in codex copilot; do
  chief_agent_use "n-$a"
  assert_success "$a: trust prepare/release are no-ops" -- bash -c ". '$LIB/agents/$a.sh'; agent_prepare /x && agent_release /x"
  assert_eq "$(agent_ready_text | wc -l | tr -d ' ')" "1" "$a: ready text"
  assert_eq "$(agent_trust_text | wc -l | tr -d ' ')" "1" "$a: trust dialog text"
  assert_eq "$(agent_trust_keys)" "" "$a: trust dialog is never auto-accepted"
  assert_eq "$(PATH=/nonexistent agent_require 2>&1)" "chief-agent: the '$a' CLI is not installed" "$a: agent_require names the missing CLI"
  assert_success "$a: agent_require passes when the CLI exists" -- agent_require
done

chief_agent_use n-copilot
assert_success "copilot: ready text matches the 1.0.97 footer" -- bash -c "echo 'Interactive · Allow All' | grep -Eq '$(agent_ready_text)'"
assert_success "copilot: ready text still matches the old texts" -- bash -c "echo 'for commands' | grep -Eq '$(agent_ready_text)' && echo 'for shortcuts' | grep -Eq '$(agent_ready_text)'"
assert_success "copilot: paste text matches the 1.0.95 placeholder" -- bash -c "echo '❯ [Paste #1 - 20 lines]' | grep -Eq '$(agent_paste_text)'"

# herdr starts the task's own kind with its args (and a command override's args).
mkdir "$WORK/bin"
printf '#!/bin/sh\necho "$*" >> "%s"\n' "$WORK/herdr.log" > "$WORK/bin/herdr"; chmod +x "$WORK/bin/herdr"
PATH="$WORK/bin:$PATH"
. "$LIB/backends/herdr.sh"
CHIEF_HERDR_START_WAIT=0  # the stub shows no screen: don't wait for one
chief_agent_use m-codex; _chief_herdr_start_agent t1 pane-1 "$WORK/wt" 2>/dev/null
assert_contains "$(cat "$WORK/herdr.log")" "agent start t1 --kind codex --pane pane-1 --timeout 30000 -- --dangerously-bypass-approvals-and-sandbox --model big" "herdr: starts the task's agent kind with its args"
chief_meta_set y1 agent copilot; chief_meta_set y1 model m; chief_meta_set y1 args "--banner"
chief_agent_use y1
assert_eq "$(chief_agent_command)" "copilot --allow-all --model m --banner" "copilot: model flag, then extra args"
chief_meta_set y2 agent codex; chief_meta_set y2 args "--search"
chief_agent_use y2
assert_eq "$(chief_agent_command)" "codex --dangerously-bypass-approvals-and-sandbox --search" "codex: extra args without a model"
chief_meta_set x1 agent codex; chief_meta_set x1 model gpt-5; chief_meta_set x1 args "--search"
chief_agent_use x1; _chief_herdr_start_agent t3 pane-3 "$WORK/wt" 2>/dev/null
assert_contains "$(cat "$WORK/herdr.log")" "agent start t3 --kind codex --pane pane-3 --timeout 30000 -- --dangerously-bypass-approvals-and-sandbox --model gpt-5 --search" "herdr: model and args both reach the agent's own executable"
assert_eq "$(chief_agent_command)" "codex --dangerously-bypass-approvals-and-sandbox --model gpt-5 --search" "orca: the launch command carries model and args too"
chief_meta_set o1 agent copilot; chief_meta_set o1 command "copilot --allow-all --model other"
chief_agent_use o1; _chief_herdr_start_agent t2 pane-2 "$WORK/wt" 2>/dev/null
assert_contains "$(cat "$WORK/herdr.log")" "agent start t2 --kind copilot --pane pane-2 --timeout 30000 -- --allow-all --model other" "herdr: a command override supplies the args"
chief_meta_set o2 agent copilot; chief_meta_set o2 command "copilot"
chief_agent_use o2; _chief_herdr_start_agent t4 pane-4 "$WORK/wt" 2>/dev/null
assert_contains "$(grep 'agent start t4' "$WORK/herdr.log")" "agent start t4 --kind copilot --pane pane-4 --timeout 30000 --" "herdr: a bare command passes no arguments"

harness_summary
