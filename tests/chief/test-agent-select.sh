#!/usr/bin/env bash
# test-agent-select.sh - agents/agent.sh: the .chief/config/agents file and its strategies.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$TEST_DIR/../.." && pwd)/plugins/chief/bin/lib"
. "$TEST_DIR/lib/harness.sh"

WORK=$(mktemp -d)
harness_trap 'rm -rf "$WORK"'
export CHIEF_HOME="$WORK/.chief"
. "$LIB/paths.sh"
. "$LIB/agents/agent.sh"
CFG="$CONFIG/agents"

echo "test-agent-select:"

# pick <mode> -> "agent:model|command" of the selection (current shell, so cursors persist)
pick() { chief_agent_select "$1" && echo "$SEL_AGENT:$SEL_MODEL|$SEL_COMMAND"; }
cfg() { cat > "$CFG"; }

assert_eq "$(pick builder)" "claude:|" "no config: claude, default model"
cfg <<< "# only comments"
assert_eq "$(pick builder)" "claude:|" "a config with no pool: claude"

cfg <<'EOF2'
# the pool

claude:opus
codex:gpt-5   # trailing comment
EOF2
assert_eq "$(pick builder)" "claude:opus|" "first: the first entry (strategy omitted)"
assert_eq "$(pick builder)" "claude:opus|" "first: always the same"

cfg <<'EOF2'
strategy = round-robin   # rotate
claude:opus
codex:gpt-5
copilot
EOF2
assert_eq "$(pick builder; pick builder; pick builder; pick builder)" "claude:opus|
codex:gpt-5|
copilot:|
claude:opus|" "round-robin: rotates and wraps"
assert_eq "$(cat "$STATE/agent-cursor-builder")" "4" "round-robin: the cursor is persisted"
assert_eq "$(pick researcher)" "claude:opus|" "round-robin: each mode has its own cursor"
printf 'junk' > "$STATE/agent-cursor-builder"
assert_eq "$(pick builder)" "claude:opus|" "round-robin: a corrupt cursor restarts at the first entry"

rm -f "$STATE"/agent-cursor-*
for i in 1 2 3 4 5 6; do (chief_agent_select builder; echo "$SEL_AGENT:$SEL_MODEL") & done > "$WORK/par.out"; wait
assert_eq "$(sort "$WORK/par.out" | uniq -c | awk '{print $1}' | tr '\n' ' ')" "2 2 2 " "round-robin: parallel spawns never pick the same entry twice in a row"

cfg <<'EOF2'
strategy = weighted
claude:opus   weight=3
codex:gpt-5   weight=2
copilot       weight=1
EOF2
w() { CHIEF_AGENT_RANDOM=$1 pick builder; }
assert_eq "$(w 0; w 2; w 3; w 4; w 5; w 6)" "claude:opus|
claude:opus|
codex:gpt-5|
codex:gpt-5|
copilot:|
claude:opus|" "weighted: the injected random walks the weight ranges"
cfg <<'EOF2'
strategy = weighted
claude weight=0
codex
EOF2
assert_eq "$(w 0; w 7)" "codex:|
codex:|" "weighted: weight=0 is never picked"
cfg <<'EOF2'
strategy = weighted
claude weight=0
EOF2
assert_contains "$(pick builder 2>&1)" "every weight in the pool is 0" "weighted: all zero errors"

cfg <<'EOF2'
strategy = random
claude weight=100
codex
EOF2
assert_eq "$(w 0; w 1; w 2)" "claude:|
codex:|
claude:|" "random: equal weights, ignoring weight="

cfg <<'EOF2'
strategy = first
claude:opus
[researcher]
strategy = round-robin
claude:haiku
codex:gpt-5-mini
[builder]
codex:gpt-5
EOF2
rm -f "$STATE"/agent-cursor-*
assert_eq "$(pick researcher; pick researcher)" "claude:haiku|
codex:gpt-5-mini|" "sections: a researcher pool with its own strategy"
assert_eq "$(pick builder)" "codex:gpt-5|" "sections: a builder pool inherits the global strategy"
cfg <<'EOF2'
strategy = round-robin
claude:opus
[researcher]
codex
EOF2
rm -f "$STATE"/agent-cursor-*
assert_eq "$(pick builder; pick builder)" "claude:opus|
claude:opus|" "sections: a mode without a section uses the global pool (one entry here)"
assert_eq "$(pick researcher)" "codex:|" "sections: the researcher pool wins over the global one"

cfg <<'EOF2'
claude:opus args="--verbose --add-dir /x" weight=2 command="wrap"
codex args="--search"
EOF2
assert_eq "$(chief_agent_select builder; echo "$SEL_AGENT|$SEL_ARGS|$SEL_COMMAND")" "claude|--verbose --add-dir /x|wrap" "args: parsed next to weight and command, in any order"
cfg <<'EOF2'
strategy = round-robin
claude:opus
codex:gpt-5 args="--search"
EOF2
rm -f "$STATE"/agent-cursor-*
assert_eq "$(chief_agent_select builder; chief_agent_select builder; echo "$SEL_AGENT|$SEL_ARGS")" "codex|--search" "args: an entry without args does not leak into the next pick"
cfg <<'EOF2'
claude:opus command="/opt/bin/claude --dangerously-skip-permissions --foo" weight=2
EOF2
assert_eq "$(pick builder)" "claude:opus|/opt/bin/claude --dangerously-skip-permissions --foo" "command: kept verbatim, in either option order"

# builder and researcher pools: builder-only, researcher-only, both, neither
cfg <<'EOF2'
claude:opus
[builder]
codex:gpt-5
EOF2
assert_eq "$(pick builder; pick researcher)" "codex:gpt-5|
claude:opus|" "builder-only: builder uses [builder], researcher falls back to the global pool"
cfg <<'EOF2'
claude:opus
[researcher]
copilot
EOF2
assert_eq "$(pick builder; pick researcher)" "claude:opus|
copilot:|" "researcher-only: researcher uses [researcher], builder falls back to the global pool"
cfg <<'EOF2'
[builder]
codex:gpt-5
[researcher]
copilot
EOF2
assert_eq "$(pick builder; pick researcher)" "codex:gpt-5|
copilot:|" "both: each mode uses its own pool, no global pool needed"
cfg <<'EOF2'
claude:opus
EOF2
assert_eq "$(pick builder; pick researcher)" "claude:opus|
claude:opus|" "neither: both modes use the global pool"

# peek: no cursor advance, no pick for weighted/random, pool source
cfg <<'EOF2'
strategy = round-robin
claude:opus
codex:gpt-5
EOF2
rm -f "$STATE"/agent-cursor-*
chief_agent_select builder peek; assert_eq "$SEL_AGENT $POOL_SRC" "claude global" "peek: shows the next pick; a role without a section reports the global pool"
chief_agent_select builder peek; assert_eq "$SEL_AGENT" "claude" "peek: does not advance the cursor"
assert_file_missing "$STATE/agent-cursor-builder" "peek: writes no cursor file"
chief_agent_select builder; chief_agent_select builder peek; assert_eq "$SEL_AGENT" "codex" "peek: follows a real pick"
cfg <<'EOF2'
strategy = weighted
claude:opus weight=3
codex
[reviewer]
copilot
EOF2
chief_agent_select builder peek; assert_eq "$(chief_agent_describe)" "weighted pool: claude:opus (3), codex (1) (global fallback)" "peek: a weighted pool is listed with its weights, not picked"
chief_agent_select reviewer peek; assert_eq "$(chief_agent_describe)" "weighted pool: copilot (1)" "describe: a role's own pool has no marker (strategy inherited)"
cfg <<'EOF2'
[reviewer]
strategy = all
copilot
claude:sonnet
claude:sonnet args="--verbose"
EOF2
assert_eq "$(chief_agent_fanout reviewer | paste -sd' ' -)" "copilot claude-sonnet claude-sonnet" "all: one slug per entry"
assert_eq "$(CHIEF_AGENT_PICK=2 pick reviewer)" "claude:sonnet|" "all: CHIEF_AGENT_PICK picks that entry"
chief_agent_select reviewer; assert_eq "$SEL_AGENT" "copilot" "all: the first entry without a pick"
CHIEF_AGENT_PICK=3 chief_agent_select reviewer; assert_eq "$SEL_ARGS" "--verbose" "all: a pick carries the entry's args"
assert_contains "$(CHIEF_AGENT_PICK=9 chief_agent_select reviewer 2>&1)" "no pool entry 9" "all: a pick past the pool errors"
chief_agent_select reviewer peek; assert_eq "$(chief_agent_describe)" "all pool: copilot, claude:sonnet, claude:sonnet" "peek: an all pool is listed"
assert_eq "$(chief_agent_fanout builder)" "" "all: other roles run a single worker"
cfg <<'EOF2'
[builder]
strategy = all
claude
EOF2
assert_contains "$(chief_agent_select builder 2>&1)" "only for the reviewer role" "all: refused outside the reviewer role"
cfg <<< "# no pool"
chief_agent_select builder peek; assert_eq "$(chief_agent_describe)" "claude (no pool configured)" "describe: no pool marks the claude default"

# weights are decimal and bounded
cfg <<'EOF2'
strategy = weighted
claude weight=08
codex weight=09
EOF2
assert_eq "$(w 0; w 8; w 9; w 16; w 17)" "claude:|
codex:|
codex:|
codex:|
claude:|" "weight: 08 and 09 are decimal, not octal"
cfg <<'EOF2'
strategy = weighted
claude weight=1000
codex
EOF2
assert_eq "$(w 999; w 1000)" "claude:|
codex:|" "weight: 1000 is accepted"

# CRLF config
printf 'strategy = round-robin\r\nclaude:opus\r\n[researcher]\r\ncodex args="--search"\r\n' > "$CFG"
rm -f "$STATE"/agent-cursor-*
assert_eq "$(pick builder; pick researcher)" "claude:opus|
codex:|" "CRLF: line endings are ignored"

bad() { cfg; chief_agent_select "${1:-builder}" 2>&1; }
assert_contains "$(bad <<< 'strategy = sometimes')" "unknown strategy 'sometimes'" "error: unknown strategy"
assert_contains "$(bad <<< '[ship]')" "unknown section [ship]" "error: [ship] is not a section"
assert_contains "$(bad <<< '[scout]')" "unknown section [scout]" "error: [scout] is not a section"
assert_eq "$(bad <<< '[reviewer]')" "" "sections: reviewer is valid"
assert_eq "$(bad <<< '[brainstormer]')" "" "sections: brainstormer is valid"
assert_contains "$(bad <<< '[prod]')" "unknown section [prod]" "error: unknown section"
assert_contains "$(bad <<< 'Claude')" "bad profile 'Claude'" "error: bad agent name"
assert_contains "$(bad <<< 'claude:opus weight=x')" "unexpected ' weight=x'" "error: malformed weight"
assert_contains "$(bad <<< 'claude args="--x')" "unexpected" "error: unterminated args"
assert_contains "$(bad <<< 'claude weight=99999999999')" "weight 99999999999 must be 0 to 1000" "error: a huge weight"
assert_contains "$(bad <<< 'claude weight=1001')" "must be 0 to 1000" "error: a weight over the cap"
assert_contains "$(bad <<< "claude args=\"--x 'y'\"")" "may only use letters" "error: single quotes in args"
assert_contains "$(bad <<< 'claude command="a; rm b"')" "command 'a; rm b' may only use" "error: shell characters in command"
assert_contains "$(bad <<< 'claude args="$(x)"')" "may only use" "error: command substitution in args"
assert_contains "$(bad <<< 'claude:opus color=red')" "unexpected ' color=red'" "error: unknown option"
assert_contains "$(bad <<< 'claude:op us')" "unexpected ' us'" "error: a space inside the profile"
assert_contains "$(bad <<< 'claude command="unterminated')" "unexpected" "error: unterminated command"
assert_contains "$(bad <<< 'claude:$(rm)')" "bad profile" "error: shell metacharacters in the model"
assert_contains "$(bad <<< $'claude\ncodex x')" "agents:2:" "error: names the file line"

harness_summary
