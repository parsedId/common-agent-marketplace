#!/usr/bin/env bash
# test-agent-claude.sh - agents/claude.sh: contract values and pre-trust in .claude.json.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LIB="$REPO_ROOT/plugins/chief/bin/lib"
. "$TEST_DIR/lib/harness.sh"

WORK=$(mktemp -d)
harness_trap 'rm -rf "$WORK"'
export CHIEF_HOME="$WORK/.chief"
. "$LIB/paths.sh"
chief_ensure_dirs
. "$LIB/meta.sh"
. "$LIB/agents/agent.sh"
chief_agent_load claude
CFG="$CLAUDE_CONFIG_DIR/.claude.json"
flag() { jq -r --arg p "$1" '.projects[$p].hasTrustDialogAccepted // "unset"' "$CFG"; }

echo "test-agent-claude:"

assert_eq "$(agent_name)" "claude" "agent: name"
assert_eq "$(agent_command)" "claude --dangerously-skip-permissions" "agent: command"
assert_eq "$(agent_ready_text)" "bypass permissions" "agent: ready text"
assert_eq "$(agent_trust_text)" "trust this folder" "agent: trust dialog text"
assert_eq "$(agent_trust_keys)" "down enter" "agent: keys that accept the trust dialog"
CHIEF_AGENT_MODEL=sonnet
assert_eq "$(agent_command)" "claude --dangerously-skip-permissions --model sonnet" "agent: model flag when a model is set"
CHIEF_AGENT_MODEL=

agent_prepare /a
assert_eq "$(flag /a)" "true" "trust: creates the config when missing and sets the flag"

echo '{"theme":"dark","projects":{"/b":{"allowedTools":["x"]}}}' > "$CFG"
agent_prepare /b; agent_prepare /b2
assert_eq "$(jq -r .theme "$CFG")" "dark" "trust: preserves unrelated top-level keys"
assert_eq "$(jq -c '.projects["/b"].allowedTools' "$CFG")" '["x"]' "trust: preserves the project's other keys"
assert_eq "$(flag /b2)" "true" "trust: handles several dirs"
agent_prepare /b
assert_eq "$(grep -cxF /b "$STATE/trust-owned")" "1" "trust: idempotent, recorded once"

agent_release /b
assert_eq "$(flag /b)" "unset" "untrust: removes the flag it set"
assert_eq "$(jq -c '.projects["/b"].allowedTools' "$CFG")" '["x"]' "untrust: keeps the project's other keys"

echo '{"projects":{"/u":{"hasTrustDialogAccepted":true}}}' > "$CFG"
agent_prepare /u; agent_release /u
assert_eq "$(flag /u)" "true" "untrust: leaves a dir the user already trusted"

echo '{not json' > "$CFG"
assert_contains "$(agent_prepare /d 2>&1)" "could not pre-trust /d" "trust: corrupt JSON warns"
assert_eq "$(cat "$CFG")" "{not json" "trust: corrupt JSON is left untouched"

rm -f "$CFG"
assert_contains "$(CHIEF_NO_PRETRUST=1 agent_prepare /e 2>&1)" "not pre-trusted" "trust: opt-out warns"
assert_file_missing "$CFG" "trust: CHIEF_NO_PRETRUST=1 is a no-op"

agent_prepare /r
agent_release /r
assert_eq "$(flag /r)" "unset" "release: untrusts the worktree"
assert_eq "$(grep -cxF /r "$STATE/trust-owned")" "0" "release: drops it from the marker"

# a symlinked .claude.json stays a symlink; a symlinked dir is trusted under both spellings
mkdir -p "$WORK/real/d"; ln -s "$WORK/real/d" "$WORK/link"
echo '{}' > "$WORK/real.json"; ln -sf "$WORK/real.json" "$CFG"
agent_prepare "$WORK/link"
assert_eq "$(test -L "$CFG" && echo link)" "link" "trust: a symlinked config stays a symlink"
assert_eq "$(jq -r --arg a "$WORK/link" --arg b "$WORK/real/d" '[.projects[$a].hasTrustDialogAccepted, .projects[$b].hasTrustDialogAccepted] | join(",")' "$WORK/real.json")" "true,true" "trust: both spellings of a symlinked dir"
agent_release "$WORK/link"
assert_eq "$(jq -c '.projects' "$WORK/real.json")" "{}" "release: both spellings removed"

harness_summary
