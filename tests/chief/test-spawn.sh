#!/usr/bin/env bash
# test-spawn.sh - chief-spawn.sh brief rendering, against the mock backend.
# Covers the case a plain `sed -e "s|{SPEC}|$SPEC|g"` substitution cannot
# survive: a --spec/--intent value with embedded newlines and sed-delimiter
# characters (|, &, \).
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
BIN="$REPO_ROOT/plugins/chief/bin"
. "$TEST_DIR/lib/harness.sh"

echo "test-spawn:"

WORK=$(mktemp -d)
harness_trap 'rm -rf "$WORK"'
mkdir -p "$WORK/project" && cd "$WORK/project" && git init -q -b master
git commit --allow-empty -q -m init
export CHIEF_HOME="$WORK/.chief"
export CHIEF_BACKEND=mock

SPEC=$'line one with a | pipe\nline two with an & ampersand\nline three with a \\ backslash'
INTENT=$'multi-line intent\nwith a | pipe too'

assert_success "spawn: survives a --spec/--intent with embedded newlines and sed-delimiter characters" -- \
  timeout 10 "$BIN/chief-spawn.sh" t-1 "$WORK/project" --mode builder --branch feat/t-1 --intent "$INTENT" --spec "$SPEC"

BRIEF="$CHIEF_HOME/tasks/t-1/brief.md"
assert_file_exists "$BRIEF" "spawn: brief was written"
assert_contains "$(cat "$BRIEF")" "$INTENT" "spawn: the multi-line intent is rendered verbatim"
assert_contains "$(cat "$BRIEF")" "$SPEC" "spawn: the multi-line spec is rendered verbatim"
assert_not_contains "$(cat "$BRIEF")" "{TASK}" "spawn: the {TASK} placeholder was filled"
assert_not_contains "$(cat "$BRIEF")" "{SPEC}" "spawn: the {SPEC} placeholder was filled"

LIFECYCLE="$CHIEF_HOME/tasks/t-1/lifecycle"
assert_file_exists "$LIFECYCLE" "spawn: lifecycle checklist was written"
assert_contains "$(cat "$LIFECYCLE")" "t-1" "spawn: the {TASK_ID} placeholder was filled with the task id"
assert_not_contains "$(cat "$LIFECYCLE")" "{TASK_ID}" "spawn: no unfilled {TASK_ID} placeholder remains"
assert_contains "$(cat "$LIFECYCLE")" "- [ ] filed" "spawn: the builder lifecycle checklist's first step is present"

CFG="$CLAUDE_CONFIG_DIR/.claude.json"
assert_eq "$(jq -r --arg p "$CHIEF_HOME/worktrees/t-1" '.projects[$p].hasTrustDialogAccepted' "$CFG")" "true" "spawn: the task's worktree is pre-trusted"
. "$BIN/lib/paths.sh"; . "$BIN/lib/meta.sh"
assert_eq "$(chief_meta_get t-1 agent)" "claude" "spawn: the default agent is recorded in meta"

rm -f "$CFG"
assert_success "spawn: CHIEF_NO_PRETRUST=1 still spawns" -- \
  env CHIEF_NO_PRETRUST=1 timeout 10 "$BIN/chief-spawn.sh" t-2 "$WORK/project" --mode builder --branch feat/t-2 --intent x
assert_file_missing "$CFG" "spawn: CHIEF_NO_PRETRUST=1 leaves the claude config untouched"

# the brief is agent-neutral: the turn-ended protocol is a path, not a Claude hook
BRIEF_T1=$(cat "$CHIEF_HOME/tasks/t-1/brief.md")
assert_contains "$BRIEF_T1" "touch $CHIEF_HOME/tasks/t-1/turn-ended" "brief: tells any agent to touch the turn-ended file"
assert_not_contains "$BRIEF_T1" "{TURN_FILE}" "brief: no unfilled turn placeholder"
assert_not_contains "$BRIEF_T1" "{REVIEW_CHECKLIST}" "brief: no review-checklist placeholder"
assert_not_contains "$BRIEF_T1" "Self-review" "brief: no builder self-review step"
assert_contains "$BRIEF_T1" "the project's checks pass, the work is committed, and the tree is clean" "brief: checks, commit and a clean tree before done"
assert_contains "$BRIEF_T1" "done: <short commit sha> <one-line summary>" "brief: the done line starts with the short commit sha"
assert_contains "$BRIEF_T1" "fix them with new commits (amend only for commit-message findings)" "brief: findings are fixed with new commits"
assert_contains "$BRIEF_T1" "report \`done\` again" "brief: done is reported again after fixes"

# --- agent selection: flags, config, validation --------------------------
spawn() {  # <id> [flags...]
  local id=$1; shift
  timeout 10 "$BIN/chief-spawn.sh" "$id" "$WORK/project" --mode builder --branch "feat/$id" --intent x "$@"
}
meta() { chief_meta_get "$1" "$2"; }
leftovers() { ls -A "$CHIEF_HOME/tasks/$1" 2>/dev/null | wc -l | tr -d ' '; }

assert_success "spawn: --agent claude:opus" -- spawn a-1 --agent claude:opus
assert_eq "$(meta a-1 agent):$(meta a-1 model)" "claude:opus" "spawn: --agent agent:model is recorded"
assert_contains "$(spawn a-00 --agent codex:gpt-5 --args "--search")" "launch: codex --dangerously-bypass-approvals-and-sandbox --model gpt-5 --search" "spawn: prints the final launch line"
assert_success "spawn: --agent codex:gpt-5" -- spawn a-0 --agent codex:gpt-5
assert_eq "$(meta a-0 agent):$(meta a-0 model)" "codex:gpt-5" "spawn: a codex task is recorded"
assert_success "spawn: --model alone" -- spawn a-2 --model sonnet
assert_eq "$(meta a-2 agent):$(meta a-2 model)" "claude:sonnet" "spawn: --model alone keeps the default agent"

mkdir -p "$CHIEF_HOME/config"
printf 'claude:opus\n' > "$CHIEF_HOME/config/agents"
assert_success "spawn: config pool" -- spawn a-3
assert_eq "$(meta a-3 model)" "opus" "spawn: the config's profile is used"
assert_success "spawn: --model over config" -- spawn a-4 --model haiku
assert_eq "$(meta a-4 model)" "haiku" "spawn: --model overrides just the model of the configured profile"
assert_success "spawn: --agent over config" -- spawn a-5 --agent claude
assert_eq "$(meta a-5 model)" "" "spawn: an explicit --agent wins over the config"

printf 'claude command="/bin/sh --dangerously-skip-permissions"\n' > "$CHIEF_HOME/config/agents"
assert_success "spawn: command override" -- spawn a-6
assert_eq "$(meta a-6 command)" "/bin/sh --dangerously-skip-permissions" "spawn: the profile's command is recorded in meta"
assert_success "spawn: explicit agent drops the override" -- spawn a-7 --agent claude
assert_eq "$(meta a-7 command || echo none)" "none" "spawn: --agent does not inherit a configured command"
rm "$CHIEF_HOME/config/agents"

assert_failure "spawn: the old mode ship is rejected" -- timeout 10 "$BIN/chief-spawn.sh" a-x "$WORK/project" --mode ship --branch feat/a-x --intent x
assert_failure "spawn: the old mode scout is rejected" -- timeout 10 "$BIN/chief-spawn.sh" a-x "$WORK/project" --mode scout --branch feat/a-x --intent x
assert_contains "$(spawn a-90 --agent claude:haiku)" "agent: claude:haiku" "spawn: prints the agent line"
assert_contains "$(spawn a-91 --agent claude --model opus)" "agent: claude:opus" "spawn: the agent line reflects --model"
printf 'claude:opus\n' > "$CHIEF_HOME/config/agents"
assert_contains "$(spawn a-92 --model haiku --dry-run)" "agent: claude:haiku (global fallback)" "spawn: with a pool, the agent line reflects --model and keeps the fallback marker"
assert_contains "$(spawn a-92 --model haiku)" "agent: claude:haiku (global fallback)" "spawn: the real spawn prints the same agent line"
assert_eq "$(meta a-92 model)" "haiku" "spawn: the printed model is the recorded one"

printf 'claude:opus\n[builder]\ncodex:gpt-5\n[researcher]\ncopilot\n' > "$CHIEF_HOME/config/agents"
assert_success "spawn: builder task with builder/researcher pools" -- spawn a-11
assert_eq "$(meta a-11 agent)" "codex" "spawn: a builder task uses the [builder] pool"
assert_success "spawn: researcher task with builder/researcher pools" -- timeout 10 "$BIN/chief-spawn.sh" a-12 "$WORK/project" --mode researcher --branch feat/a-12 --intent x
assert_eq "$(meta a-12 agent)" "copilot" "spawn: a researcher task uses the [researcher] pool"

printf 'claude:opus args="--verbose"\n' > "$CHIEF_HOME/config/agents"
assert_success "spawn: config args" -- spawn a-8
assert_eq "$(meta a-8 args)" "--verbose" "spawn: the profile's args are recorded in meta"
assert_success "spawn: --args over config" -- spawn a-9 --args "--add-dir /x"
assert_eq "$(meta a-9 args)" "--add-dir /x" "spawn: --args replaces the configured args"
assert_success "spawn: --agent drops configured args" -- spawn a-10 --agent claude
assert_eq "$(meta a-10 args || echo none)" "none" "spawn: --agent does not inherit configured args"
rm "$CHIEF_HOME/config/agents"

fails() {  # <id> <expected message> [flags...] - the spawn fails and leaves nothing behind
  local id=$1 msg=$2; shift 2
  local out; out=$(spawn "$id" "$@" 2>&1); local rc=$?
  assert_eq "$rc" "1" "spawn $id: fails"
  assert_contains "$out" "$msg" "spawn $id: says why"
  assert_eq "$(leftovers "$id")" "0" "spawn $id: no task files left behind"
  assert_file_missing "$CHIEF_HOME/worktrees/$id" "spawn $id: no worktree left behind"
  assert_eq "$(git -C "$WORK/project" branch --list "feat/$id" | wc -l | tr -d ' ')" "0" "spawn $id: no branch left behind"
}
fails b-1 "unknown agent 'nope' (available: claude" --agent nope
fails b-2 "bad profile" --agent 'claude:$(x)'
fails b-3 "bad profile" --model 'a b'
printf 'strategy = sometimes\n' > "$CHIEF_HOME/config/agents"
fails b-4 "unknown strategy"
printf 'claude command="my-claude"\n' > "$CHIEF_HOME/config/agents"
fails b-6 "cannot be combined with a model or args" --args "--x"
fails b-7 "cannot be combined with a model or args" --model opus
printf 'claude:opus command="my-claude"\n' > "$CHIEF_HOME/config/agents"
fails b-8 "cannot be combined with a model or args"
rm "$CHIEF_HOME/config/agents"
fails b-9 "may only use letters" --args "--add-dir '/a b'"
fails b-10 "args" --args '$(x)'
# herdr runs the agent's own executable: a command must start with it
printf 'claude command="/opt/wrap.sh --x"\n' > "$CHIEF_HOME/config/agents"
out=$(CHIEF_BACKEND=herdr spawn b-11 2>&1); rc=$?
assert_eq "$rc" "1" "spawn: a command with another executable fails on herdr"
assert_contains "$out" "herdr starts the agent's own executable (claude)" "spawn: and says to use args= or orca"
assert_eq "$(leftovers b-11)" "0" "spawn b-11: no task files left behind"
printf 'claude command="%s --x"\n' "$HARNESS_BIN/claude" > "$CHIEF_HOME/config/agents"
mkdir "$WORK/fakeherdr"; printf '#!/bin/sh\nexit 1\n' > "$WORK/fakeherdr/herdr"; chmod +x "$WORK/fakeherdr/herdr"
out=$(PATH="$WORK/fakeherdr:$PATH" CHIEF_BACKEND=herdr spawn b-12 2>&1)
assert_not_contains "$out" "starts the agent's own executable" "spawn: the same executable by path passes the herdr check"
assert_contains "$out" "herdr" "spawn: and goes on to the backend"
printf 'claude command="/bin/sh --x"\n' > "$CHIEF_HOME/config/agents"
assert_success "spawn: any executable is fine on the mock backend" -- spawn b-13
rm "$CHIEF_HOME/config/agents"
rm "$CHIEF_HOME/config/agents"
out=$(PATH=/usr/bin:/bin timeout 10 "$BIN/chief-spawn.sh" b-5 "$WORK/project" --mode builder --branch feat/b-5 --intent x 2>&1); rc=$?
assert_eq "$rc" "1" "spawn: a missing agent CLI fails"
assert_contains "$out" "the 'claude' CLI is not installed" "spawn: and says which CLI"
assert_eq "$(leftovers b-5)" "0" "spawn: and leaves no task files behind"

harness_summary
