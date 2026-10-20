#!/usr/bin/env bash
# test-backend-orca-mock.sh - zero-cost unit test of orca.sh's
# argument-building and JSON-parsing, against a FAKE `orca` CLI stub (see
# below). No real Orca instance, no claude turn, no tokens.
#
# Not a substitute for test-backend-orca.sh (the opt-in real-Orca
# integration test): this only proves the adapter calls `orca` the way it
# claims to, against canned responses shaped like the real CLI's output.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
CHIEF_BIN="$REPO_ROOT/plugins/chief/bin"
. "$TEST_DIR/lib/harness.sh"

echo "test-backend-orca-mock:"

if ! command -v jq >/dev/null 2>&1; then
  echo "  (skipped - jq not on PATH, required by backends/orca.sh)"
  exit 0
fi

WORK=$(mktemp -d)
export CLAUDE_CONFIG_DIR="$WORK/claude"; mkdir -p "$CLAUDE_CONFIG_DIR"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

mkdir -p "$WORK/project" "$WORK/bin"
( cd "$WORK/project" && git init -q -b main \
    && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )

# --- fake `orca` -------------------------------------------------------
# Logs every call to $ORCA_MOCK_LOG and returns canned --json responses.
# `terminal wait --for tui-idle` exits 0 (idle) unless $ORCA_MOCK_BUSY=1.
# `worktree create` does a real `git worktree add` (sanitizing '/' out of
# --name into the branch, like the real Orca does) so backend_spawn's
# branch rename has something real to act on; fails instead with
# $ORCA_MOCK_WT_FAIL=1, for the "project isn't Orca-known" path.
# `worktree list`/`rm` mirror that against the real git worktrees under
# $ORCA_MOCK_WORKTREES. `terminal send` fails with $ORCA_MOCK_SEND_FAIL=1;
# `repo list`/`add` keep a registry in $ORCA_MOCK_REPOS ($ORCA_MOCK_REPO_ADD_FAIL=1
# makes `add` fail). The rendered screen (`terminal read --screen`) shows
# $ORCA_MOCK_SCREEN_TEXT, the prompt sent via `terminal send --text` as
# submitted history - unless $ORCA_MOCK_PROMPT_LANDS=0 (dropped until resent) or
# $ORCA_MOCK_PROMPT_PENDING=1 (sits in the input line until a bare Enter) - and the
# "bypass permissions on" status line unless $ORCA_MOCK_NO_BYPASS=1. $ORCA_MOCK_ENTER_LOST=1
# makes a bare Enter register nothing.
cat > "$WORK/bin/orca" <<'FAKE_ORCA'
#!/usr/bin/env bash
echo "$*" >> "$ORCA_MOCK_LOG"
# Real orca prints a connect banner to stderr on every call - mirror that
# so a regression to 2>&1 (merging it into a --json capture, breaking jq)
# fails loud instead of silently passing.
echo "[relay-connect] Handshake OK at version=mock" >&2
case "$1 $2" in
  "repo list")
    touch "$ORCA_MOCK_REPOS"
    jq -Rsc '{ok:true,result:{repos:(split("\n")|map(select(length>0)|{id:.,path:.}))}}' "$ORCA_MOCK_REPOS"
    ;;
  "repo add")
    if [ "${ORCA_MOCK_REPO_ADD_FAIL:-0}" = "1" ]; then
      echo '{"ok":false,"error":{"code":"runtime_error"}}'
      exit 1
    fi
    echo "${4}" >> "$ORCA_MOCK_REPOS"
    echo '{"ok":true}'
    ;;
  "worktree create")
    if [ "${ORCA_MOCK_WT_FAIL:-0}" = "1" ]; then
      echo '{"ok":false,"error":{"code":"runtime_error","message":"Not a valid git repository"}}'
      exit 1
    fi
    repo_path="${4#path:}"
    sanitized=${6//\//-}
    new_path="$ORCA_MOCK_WORKTREES/$sanitized"
    git -C "$repo_path" worktree add -q -b "$sanitized" "$new_path" >&2 || exit 1
    rm -f "$ORCA_MOCK_LOG.enter" "$ORCA_MOCK_LOG.resent"
    printf '{"ok":true,"result":{"worktree":{"path":"%s","branch":"refs/heads/%s"}}}\n' "$new_path" "$sanitized"
    ;;
  "terminal create")
    rm -f "$ORCA_MOCK_LOG.enter" "$ORCA_MOCK_LOG.resent" "$ORCA_MOCK_LOG.sent1"
    echo '{"ok":true,"result":{"terminal":{"handle":"term_mock-1"}}}'
    ;;
  "terminal wait")
    if [ "${ORCA_MOCK_BUSY:-0}" = "1" ]; then
      echo '{"ok":false,"error":{"code":"timeout"}}'
      exit 1
    fi
    echo '{"ok":true}'
    ;;
  "terminal read")
    case "$*" in
      *--screen*)
        prompt=$(cat "$ORCA_MOCK_LOG.prompt" 2>/dev/null)
        lines=("${ORCA_MOCK_SCREEN_TEXT:-}")
        if [ "${ORCA_MOCK_PROMPT_LANDS:-1}" = "1" ] || [ -e "$ORCA_MOCK_LOG.resent" ]; then
          if [ "${ORCA_MOCK_PROMPT_PENDING:-0}" = "1" ] && [ ! -e "$ORCA_MOCK_LOG.enter" ]; then
            lines+=("❯ $prompt")
          else
            lines+=("❯ $prompt" "● ok" "❯")
          fi
        else
          lines+=("❯")
        fi
        [ "${ORCA_MOCK_NO_BYPASS:-0}" = "1" ] || lines+=("bypass permissions on")
        printf '%s\n' "${lines[@]}" | jq -Rsc '{ok:true,result:{terminal:{tail:split("\n")[:-1]}}}'
        ;;
      *) echo '{"ok":true,"result":{"terminal":{"tail":["line one","line two"]}}}' ;;
    esac
    ;;
  "terminal send")
    case "$*" in *--text*) ;; *--enter*) [ "${ORCA_MOCK_ENTER_LOST:-0}" = "1" ] || : > "$ORCA_MOCK_LOG.enter" ;; esac
    case "$*" in *--text*)
      if [ "${ORCA_MOCK_PROMPT_LANDS:-1}" = "0" ] && [ ! -e "$ORCA_MOCK_LOG.sent1" ]; then : > "$ORCA_MOCK_LOG.sent1"; else : > "$ORCA_MOCK_LOG.resent"; fi
      printf '%s' "${*#*--text }" | sed 's/ --enter.*//' > "$ORCA_MOCK_LOG.prompt" ;; esac
    if [ "${ORCA_MOCK_SEND_FAIL:-0}" = "1" ]; then
      echo '{"ok":false,"error":{"code":"runtime_error"}}'
      exit 1
    fi
    echo '{"ok":true}'
    ;;
  "worktree list")
    repo_path="${4#path:}"
    git -C "$repo_path" worktree list --porcelain | awk -v root="$ORCA_MOCK_WORKTREES/" '
      /^worktree / { path = substr($0, 10) }
      /^branch /   { if (index(path, root) == 1) printf "{\"path\":\"%s\",\"branch\":\"%s\"}\n", path, substr($0, 8) }' \
      | jq -sc '{ok:true,result:{worktrees:.}}'
    ;;
  "worktree rm")
    wt="${4#path:}"
    common=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir) || exit 1
    git -C "$common/.." worktree remove --force "$wt" || exit 1
    echo '{"ok":true}'
    ;;
  "terminal close")
    echo '{"ok":true}'
    ;;
  *)
    echo "fake-orca: unhandled invocation: $*" >&2
    exit 1
    ;;
esac
FAKE_ORCA
chmod +x "$WORK/bin/orca"
export PATH="$WORK/bin:$PATH"
export ORCA_MOCK_LOG="$WORK/orca.log"
export ORCA_MOCK_WORKTREES="$WORK/orca-worktrees"
export ORCA_MOCK_REPOS="$WORK/orca-repos"
mkdir -p "$ORCA_MOCK_WORKTREES"
: > "$ORCA_MOCK_LOG"

export CHIEF_ORCA_PROMPT_WAIT=1 CHIEF_ORCA_START_WAIT=1
export CHIEF_HOME="$WORK/.chief"
. "$CHIEF_BIN/lib/paths.sh"
chief_ensure_dirs
. "$CHIEF_BIN/lib/meta.sh"
. "$CHIEF_BIN/lib/agents/agent.sh"
. "$CHIEF_BIN/lib/backends/orca.sh"
capture() { _chief_orca_screen "$(_chief_orca_handle "$1")"; }

ID=t-orca-1
BRANCH="chief/$ID"
BRIEF="$WORK/brief.md"
printf 'Reply with exactly the single word: ok\n' > "$BRIEF"

chief_meta_set "$ID" agent claude
SPAWN_OUTPUT=$(backend_spawn "$ID" "$WORK/project" "$BRIEF" "$BRANCH" 2>"$WORK/spawn.err")
SPAWN_RC=$?
assert_eq "$SPAWN_RC" "0" "backend_spawn succeeds"
[ "$SPAWN_RC" = "0" ] || cat "$WORK/spawn.err"

WORKTREE=$(printf '%s\n' "$SPAWN_OUTPUT" | sed -n 1p)
ENDPOINT=$(printf '%s\n' "$SPAWN_OUTPUT" | sed -n 2p)

assert_eq "$WORKTREE" "$ORCA_MOCK_WORKTREES/$ID" "backend_spawn prints the worktree path Orca assigned"
assert_eq "$ENDPOINT" "orca:term_mock-1" "backend_spawn prints an orca:<handle> endpoint second"
assert_file_exists "$WORKTREE/.git" "orca worktree create actually created a real git worktree"

CURRENT_BRANCH=$(git -C "$WORKTREE" rev-parse --abbrev-ref HEAD)
assert_eq "$CURRENT_BRANCH" "$BRANCH" "backend_spawn renamed Orca's sanitized branch to the requested chief/<id> branch"

assert_contains "$(cat "$ORCA_MOCK_LOG")" "repo add --path $WORK/project --json" \
  "backend_spawn registers a project Orca doesn't know yet"
assert_contains "$(cat "$ORCA_MOCK_LOG")" "worktree create --repo path:$WORK/project --name $ID --parent-worktree path:$WORK/project --json" \
  "backend_spawn creates the worktree nested under the project's main worktree, with no builtin agent or prompt"
assert_contains "$(cat "$ORCA_MOCK_LOG")" "terminal create --worktree path:$WORKTREE --command claude --dangerously-skip-permissions --json" \
  "backend_spawn starts the agent via terminal create with agent_command"
assert_contains "$(cat "$ORCA_MOCK_LOG")" "terminal send --terminal term_mock-1 --text Reply with exactly the single word: ok" \
  "backend_spawn sends the brief's own content (not a path) once the agent is ready"

: > "$ORCA_MOCK_LOG"
chief_meta_set "t-orca-fail" agent claude
ORCA_MOCK_WT_FAIL=1 backend_spawn "t-orca-fail" "$WORK/project" "$BRIEF" "chief/t-orca-fail" 2>"$WORK/spawn-fail.err"
assert_eq "$?" "1" "backend_spawn fails when 'orca worktree create' fails"
assert_contains "$(cat "$WORK/spawn-fail.err")" "orca worktree create" \
  "backend_spawn's failure message names the failing orca command"

# An already-registered project is not registered again; a failed registration
# fails the spawn clearly, before any worktree exists.
: > "$ORCA_MOCK_LOG"
chief_meta_set "t-orca-reg" agent claude
backend_spawn "t-orca-reg" "$WORK/project" "$BRIEF" "chief/t-orca-reg" >/dev/null 2>&1
assert_not_contains "$(cat "$ORCA_MOCK_LOG")" "repo add" "backend_spawn skips 'orca repo add' for an already-registered project"
backend_spawn_cleanup "t-orca-reg" "$WORK/project" "chief/t-orca-reg"

: > "$ORCA_MOCK_LOG"
mkdir -p "$WORK/project2" && ( cd "$WORK/project2" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
chief_meta_set "t-orca-noreg" agent claude
ORCA_MOCK_REPO_ADD_FAIL=1 backend_spawn "t-orca-noreg" "$WORK/project2" "$BRIEF" "chief/t-orca-noreg" 2>"$WORK/spawn-noreg.err"
assert_eq "$?" "1" "backend_spawn fails when registering the project fails"
assert_contains "$(cat "$WORK/spawn-noreg.err")" "could not register '$WORK/project2' with Orca" \
  "backend_spawn's failure message names the project and the failed 'orca repo add'"
assert_not_contains "$(cat "$ORCA_MOCK_LOG")" "worktree create" "backend_spawn creates no worktree when registration fails"

chief_meta_set "$ID" endpoint "$ENDPOINT"
chief_meta_set "$ID" worktree "$WORKTREE"
chief_meta_set "$ID" project "$WORK/project"

CAPTURE=$(capture "$ID")
assert_contains "$CAPTURE" "bypass permissions on" "capture returns the rendered screen's lines"
assert_contains "$(cat "$ORCA_MOCK_LOG")" "terminal read --terminal term_mock-1 --screen --json" "capture reads the rendered screen, not the raw stream"

: > "$ORCA_MOCK_LOG"
ORCA_MOCK_BUSY=0 backend_busy "$ID"
assert_eq "$?" "1" "backend_busy reports idle (exit 1) when 'terminal wait --for tui-idle' succeeds"

: > "$ORCA_MOCK_LOG"
ORCA_MOCK_BUSY=1 backend_busy "$ID"
assert_eq "$?" "0" "backend_busy reports busy (exit 0) when 'terminal wait --for tui-idle' times out"

: > "$ORCA_MOCK_LOG"
backend_send "$ID" Enter
assert_contains "$(cat "$ORCA_MOCK_LOG")" "terminal send --terminal term_mock-1 --enter" \
  "backend_send maps 'Enter' to --enter with no text"

: > "$ORCA_MOCK_LOG"
backend_send "$ID" Escape
assert_contains "$(cat "$ORCA_MOCK_LOG")" "terminal send --terminal term_mock-1 --text" \
  "backend_send maps 'Escape' to a raw --text payload"

: > "$ORCA_MOCK_LOG"
backend_send "$ID" C-c
assert_contains "$(cat "$ORCA_MOCK_LOG")" "terminal send --terminal term_mock-1 --interrupt" \
  "backend_send maps 'C-c' to --interrupt"

: > "$ORCA_MOCK_LOG"
backend_send "$ID" "hello there"
assert_contains "$(cat "$ORCA_MOCK_LOG")" "terminal send --terminal term_mock-1 --text hello there --enter" \
  "backend_send maps plain text to --text ... --enter"

: > "$ORCA_MOCK_LOG"
backend_kill "$ID"
assert_eq "$?" "0" "backend_kill exits cleanly"
assert_contains "$(cat "$ORCA_MOCK_LOG")" "terminal close --worktree path:$WORKTREE --all" \
  "backend_kill closes every terminal in the task's worktree"
assert_file_exists "$WORKTREE/.git" "backend_kill does not touch the worktree"

: > "$ORCA_MOCK_LOG"
chief_meta_set "t-orca-nowt" endpoint "orca:term_mock-9"
backend_kill "t-orca-nowt"
assert_contains "$(cat "$ORCA_MOCK_LOG")" "terminal close --terminal term_mock-9 --tab" \
  "backend_kill falls back to closing the terminal's tab with no recorded worktree"

: > "$ORCA_MOCK_LOG"
backend_kill "t-orca-none"
assert_eq "$(cat "$ORCA_MOCK_LOG")" "" "backend_kill is a no-op for a task with no endpoint"

: > "$ORCA_MOCK_LOG"
BRIEF2="$WORK/brief2.md"
printf 'Reply with exactly the single word: ok\n' > "$BRIEF2"
backend_relaunch "$ID" "$BRIEF2"
RELAUNCH_RC=$?
assert_eq "$RELAUNCH_RC" "0" "backend_relaunch succeeds"
assert_eq "$(jq -r --arg p "$WORKTREE" '.projects[$p].hasTrustDialogAccepted' "$CLAUDE_CONFIG_DIR/.claude.json")" "true" "backend_relaunch re-trusts the worktree"

NEW_ENDPOINT=$(chief_meta_get "$ID" endpoint)
assert_eq "$NEW_ENDPOINT" "orca:term_mock-1" "backend_relaunch records a fresh orca:<handle> endpoint"
assert_contains "$(cat "$ORCA_MOCK_LOG")" "terminal create --worktree path:$WORKTREE --command claude --dangerously-skip-permissions --json" \
  "backend_relaunch creates a fresh terminal in the SAME (existing) worktree path"
assert_not_contains "$(cat "$ORCA_MOCK_LOG")" "worktree create" \
  "backend_relaunch never calls 'orca worktree create' (no new checkout)"

# --- parity with herdr: failure cleanup, rollback, teardown, full flow -----

# A leftover Orca worktree (no meta record) for backend_spawn_cleanup to roll
# back, found by branch. An unrelated worktree is left alone.
orca worktree create --repo "path:$WORK/project" --name t-orca-c --parent-worktree "path:$WORK/project" --json >/dev/null 2>&1
git -C "$ORCA_MOCK_WORKTREES/t-orca-c" branch -m chief/t-orca-c
chief_meta_set "t-orca-keep" agent claude
backend_spawn "t-orca-keep" "$WORK/project" "$BRIEF" "chief/t-orca-keep" >/dev/null 2>&1
assert_file_exists "$ORCA_MOCK_WORKTREES/t-orca-c/.git" "a leftover worktree exists to roll back"
: > "$ORCA_MOCK_LOG"
backend_spawn_cleanup "t-orca-c" "$WORK/project" "chief/t-orca-c"
assert_eq "$?" "0" "backend_spawn_cleanup exits cleanly"
assert_contains "$(cat "$ORCA_MOCK_LOG")" "worktree rm --worktree path:$ORCA_MOCK_WORKTREES/t-orca-c --force" \
  "backend_spawn_cleanup has Orca remove the failed task's worktree"
assert_file_missing "$ORCA_MOCK_WORKTREES/t-orca-c" "backend_spawn_cleanup leaves no worktree on disk"
assert_eq "$(git -C "$WORK/project" branch --list 'chief/t-orca-c' | wc -l | tr -d ' ')" "0" \
  "backend_spawn_cleanup deletes the task's branch"
assert_file_exists "$ORCA_MOCK_WORKTREES/t-orca-keep/.git" "backend_spawn_cleanup leaves an unrelated worktree alone"

# A spawn that failed before the branch rename leaves Orca's own sanitized branch.
git -C "$WORK/project" worktree add -q -b t-orca-r "$ORCA_MOCK_WORKTREES/t-orca-r"
backend_spawn_cleanup "t-orca-r" "$WORK/project" "chief/t-orca-r"
assert_file_missing "$ORCA_MOCK_WORKTREES/t-orca-r" "backend_spawn_cleanup also finds a worktree still on Orca's own branch"
assert_eq "$(git -C "$WORK/project" branch --list 't-orca-r' | wc -l | tr -d ' ')" "0" \
  "backend_spawn_cleanup deletes Orca's own branch too"

: > "$ORCA_MOCK_LOG"
backend_spawn_cleanup "t-orca-never" "$WORK/project" "chief/t-orca-never"
assert_eq "$?" "0" "backend_spawn_cleanup is a no-op when nothing was created"
assert_not_contains "$(cat "$ORCA_MOCK_LOG")" "worktree rm" "backend_spawn_cleanup removes nothing when no worktree matches"

# A prompt that never landed is resent once; one sitting unsubmitted in the
# input line gets a bare Enter and no resend (spawn and relaunch share this).
rm -f "$ORCA_MOCK_LOG".{enter,resent,sent1}; : > "$ORCA_MOCK_LOG"
ORCA_MOCK_PROMPT_LANDS=0 _chief_orca_prompt term_mock-1 "$(cat "$BRIEF")"
assert_eq "$(grep -c -- '--text Reply with exactly' "$ORCA_MOCK_LOG")" "2" "a prompt that never landed is resent, once"
rm -f "$ORCA_MOCK_LOG".{enter,resent,sent1}; : > "$ORCA_MOCK_LOG"
ORCA_MOCK_PROMPT_PENDING=1 _chief_orca_prompt term_mock-1 "$(cat "$BRIEF")"
assert_eq "$(grep -c -- '--text Reply with exactly' "$ORCA_MOCK_LOG")" "1" "a prompt sitting in the input line is not resent"
assert_contains "$(cat "$ORCA_MOCK_LOG")" "terminal send --terminal term_mock-1 --enter" "a prompt sitting in the input line gets a bare Enter"
rm -f "$ORCA_MOCK_LOG".{enter,resent,sent1}; : > "$ORCA_MOCK_LOG"
ORCA_MOCK_PROMPT_PENDING=1 ORCA_MOCK_ENTER_LOST=1 CHIEF_ORCA_PROMPT_WAIT=1 _chief_orca_prompt term_mock-1 "$(cat "$BRIEF")" 2>/dev/null
assert_eq "$?" "1" "a recovery Enter that leaves the prompt in the input line is a failed prompt"
rm -f "$ORCA_MOCK_LOG".{enter,resent,sent1}

# The first prompt waits for the agent's TUI on the rendered screen, not tui-idle.
: > "$ORCA_MOCK_LOG"
chief_meta_set "t-orca-ready" agent claude
backend_spawn "t-orca-ready" "$WORK/project" "$BRIEF" "chief/t-orca-ready" >/dev/null 2>&1
assert_contains "$(cat "$ORCA_MOCK_LOG")" "terminal read --terminal term_mock-1 --screen --json" "backend_spawn waits for the agent's TUI on the rendered screen"
assert_not_contains "$(cat "$ORCA_MOCK_LOG")" "tui-idle" "backend_spawn does not trust tui-idle for readiness"
assert_eq "$(jq -r --arg p "$ORCA_MOCK_WORKTREES/t-orca-ready" '.projects[$p].hasTrustDialogAccepted' "$CLAUDE_CONFIG_DIR/.claude.json")" "true" "backend_spawn pre-trusts the new worktree"
backend_spawn_cleanup "t-orca-ready" "$WORK/project" "chief/t-orca-ready"

# The task's own agent drives the launch command, the readiness check and the
# command override (recorded in meta by chief-spawn.sh).
chief_meta_set t-orca-cx agent codex; chief_meta_set t-orca-cx model gpt-5
: > "$ORCA_MOCK_LOG"
ORCA_MOCK_NO_BYPASS=1 ORCA_MOCK_SCREEN_TEXT="  100% context left" backend_spawn "t-orca-cx" "$WORK/project" "$BRIEF" "chief/t-orca-cx" >/dev/null 2>&1
assert_eq "$?" "0" "backend_spawn succeeds for a codex task once its own ready text shows"
assert_contains "$(cat "$ORCA_MOCK_LOG")" "--command codex --dangerously-bypass-approvals-and-sandbox --model gpt-5 --json" "backend_spawn launches the task's agent with its model"
backend_spawn_cleanup "t-orca-cx" "$WORK/project" "chief/t-orca-cx"
chief_meta_set t-orca-args agent claude; chief_meta_set t-orca-args model opus; chief_meta_set t-orca-args args "--verbose"
: > "$ORCA_MOCK_LOG"
backend_spawn "t-orca-args" "$WORK/project" "$BRIEF" "chief/t-orca-args" >/dev/null 2>&1
assert_contains "$(cat "$ORCA_MOCK_LOG")" "--command claude --dangerously-skip-permissions --model opus --verbose --json" "backend_spawn launches the agent with model and extra args"
backend_spawn_cleanup "t-orca-args" "$WORK/project" "chief/t-orca-args"
chief_meta_set t-orca-cmd agent claude; chief_meta_set t-orca-cmd command "my-claude --flag"
: > "$ORCA_MOCK_LOG"
backend_spawn "t-orca-cmd" "$WORK/project" "$BRIEF" "chief/t-orca-cmd" >/dev/null 2>&1
assert_contains "$(cat "$ORCA_MOCK_LOG")" "--command my-claude --flag --json" "backend_spawn launches a command override as given"
backend_spawn_cleanup "t-orca-cmd" "$WORK/project" "chief/t-orca-cmd"

# Spawn failure modes: each fails the spawn AND rolls back its own worktree,
# branch and terminals, leaving nothing for chief-spawn.sh to clean up.
spawn_fails() {  # <label> <id> [env assignments...] - runs backend_spawn with the env set
  local label=$1 sid=$2; shift 2
  : > "$ORCA_MOCK_LOG"
  chief_meta_set "$sid" agent claude
  env "$@" bash -c '. "$0"; . "$1"; . "$2"; . "$7"; . "$3"; backend_spawn "$4" "$5" "$6" "chief/$4"' \
    "$CHIEF_BIN/lib/paths.sh" "$CHIEF_BIN/lib/meta.sh" "$CHIEF_BIN/lib/backends/orca.sh" /dev/null "$sid" "$WORK/project" "$BRIEF" "$CHIEF_BIN/lib/agents/agent.sh" 2>"$WORK/fail.err"
  assert_eq "$?" "1" "backend_spawn fails: $label"
  assert_file_missing "$ORCA_MOCK_WORKTREES/$sid" "backend_spawn rolls back its worktree: $label"
  assert_eq "$(git -C "$WORK/project" branch --list "chief/$sid" | wc -l | tr -d ' ')" "0" "backend_spawn rolls back its branch: $label"
  assert_contains "$(cat "$ORCA_MOCK_LOG")" "terminal close --worktree path:$ORCA_MOCK_WORKTREES/$sid --all" "backend_spawn closes the terminals: $label"
  assert_eq "$(jq -r --arg p "$ORCA_MOCK_WORKTREES/$sid" '.projects[$p].hasTrustDialogAccepted // "unset"' "$CLAUDE_CONFIG_DIR/.claude.json")" "unset" "backend_spawn releases the pre-trust: $label"
}
spawn_fails "agent not ready" t-orca-nobypass ORCA_MOCK_NO_BYPASS=1
assert_contains "$(cat "$WORK/fail.err")" "agent not ready" "the not-ready failure message says what is wrong"
spawn_fails "a lost prompt that can't be resent" t-orca-lost ORCA_MOCK_PROMPT_LANDS=0 ORCA_MOCK_SEND_FAIL=1

# Relaunch also refuses an agent that is not ready.
chief_meta_set "t-orca-relnb" agent claude
chief_meta_set "t-orca-relnb" worktree "$ORCA_MOCK_WORKTREES/t-orca-keep"
: > "$ORCA_MOCK_LOG"
ORCA_MOCK_NO_BYPASS=1 backend_relaunch "t-orca-relnb" "$BRIEF" 2>/dev/null
assert_eq "$?" "1" "backend_relaunch fails when the agent is not ready"
assert_contains "$(cat "$ORCA_MOCK_LOG")" "terminal close --terminal term_mock-1 --tab" "backend_relaunch closes the terminal it opened"

# backend_teardown makes Orca forget the worktree.
: > "$ORCA_MOCK_LOG"
backend_teardown "t-orca-keep" "$WORK/project" "$ORCA_MOCK_WORKTREES/t-orca-keep"
assert_contains "$(cat "$ORCA_MOCK_LOG")" "worktree rm --worktree path:$ORCA_MOCK_WORKTREES/t-orca-keep --force" \
  "backend_teardown has Orca remove the worktree"

# The real lifecycle scripts end to end on this backend, same flow as herdr:
# spawn -> send -> interrupt -> relaunch -> teardown, ending with no worktree,
# branch or terminal left behind.
export CHIEF_BACKEND=orca
FLOW=t-orca-flow
: > "$ORCA_MOCK_LOG"
"$CHIEF_BIN/chief-spawn.sh" "$FLOW" "$WORK/project" --mode builder --branch feat/flow --intent "flow" >"$WORK/flow.out" 2>&1
assert_eq "$?" "0" "chief-spawn.sh succeeds on the orca backend"
FLOW_WT=$(chief_meta_get "$FLOW" worktree)
assert_eq "$FLOW_WT" "$ORCA_MOCK_WORKTREES/$FLOW" "chief-spawn.sh records the worktree path Orca chose"
assert_eq "$(chief_meta_get "$FLOW" endpoint)" "orca:term_mock-1" "chief-spawn.sh records the orca:<handle> endpoint"
assert_eq "$(chief_meta_get "$FLOW" status)" "working" "chief-spawn.sh marks the task working"
assert_eq "$(git -C "$FLOW_WT" rev-parse --abbrev-ref HEAD)" "feat/flow" "the task worktree is on the requested branch"

"$CHIEF_BIN/task/chief-send.sh" "$FLOW" "please continue" >/dev/null 2>&1
assert_contains "$(cat "$ORCA_MOCK_LOG")" "terminal send --terminal term_mock-1 --text chief: instruction waiting in" \
  "chief-send.sh rings the doorbell in the task's terminal"

"$CHIEF_BIN/task/chief-control.sh" "$FLOW" interrupt >/dev/null 2>&1
assert_contains "$(cat "$ORCA_MOCK_LOG")" "terminal send --terminal term_mock-1 --text $(printf '\033')" \
  "chief-control.sh interrupt sends Escape to the task's terminal"

: > "$ORCA_MOCK_LOG"
"$CHIEF_BIN/task/chief-control.sh" "$FLOW" relaunch --note "halfway" >/dev/null 2>&1
assert_eq "$?" "0" "chief-control.sh relaunch succeeds on the orca backend"
assert_contains "$(cat "$ORCA_MOCK_LOG")" "terminal close --worktree path:$FLOW_WT --all" "relaunch first closes the old terminals"
assert_contains "$(cat "$ORCA_MOCK_LOG")" "terminal create --worktree path:$FLOW_WT --command claude --dangerously-skip-permissions" \
  "relaunch starts a fresh bypass-permissions claude in the same worktree"
assert_contains "$(cat "$ORCA_MOCK_LOG")" "halfway" "relaunch delivers the checkpoint note in the brief"

: > "$ORCA_MOCK_LOG"
"$CHIEF_BIN/chief-teardown.sh" "$FLOW" --abandon >/dev/null 2>&1
assert_eq "$?" "0" "chief-teardown.sh --abandon succeeds on the orca backend"
assert_contains "$(cat "$ORCA_MOCK_LOG")" "terminal close --worktree path:$FLOW_WT --all" "teardown closes the task's terminals"
assert_contains "$(cat "$ORCA_MOCK_LOG")" "worktree rm --worktree path:$FLOW_WT --force" "teardown has Orca forget the worktree"
assert_file_missing "$FLOW_WT" "teardown removes the worktree"
assert_eq "$(git -C "$WORK/project" branch --list 'feat/flow' | wc -l | tr -d ' ')" "0" "teardown deletes the task's branch"

# A brainstormer records the attach hint (unverified live: fake orca only); a builder does not.
assert_not_contains "$(cat "$WORK/flow.out")" "attach:" "chief-spawn.sh prints no attach line for a builder"
BS=t-orca-bs
"$CHIEF_BIN/chief-spawn.sh" "$BS" "$WORK/project" --mode brainstormer --branch feat/bs --intent "bs" >"$WORK/bs.out" 2>&1
assert_contains "$(cat "$WORK/bs.out")" "attach: in Orca, open worktree $BS (terminal term_mock-1)" "chief-spawn.sh prints the orca attach hint for a brainstormer"
assert_eq "$(chief_meta_get "$BS" attach)" "in Orca, open worktree $BS (terminal term_mock-1)" "chief-spawn.sh records the orca attach hint in meta"
"$CHIEF_BIN/chief-teardown.sh" "$BS" >/dev/null 2>&1

# A spawn whose brief can't be delivered rolls back through chief-spawn.sh.
FAIL=t-orca-flowfail
ORCA_MOCK_PROMPT_LANDS=0 ORCA_MOCK_SEND_FAIL=1 "$CHIEF_BIN/chief-spawn.sh" "$FAIL" "$WORK/project" --mode builder --branch feat/flowfail --intent "x" >/dev/null 2>&1
assert_eq "$?" "1" "chief-spawn.sh fails when the orca backend can't deliver the brief"
assert_file_missing "$ORCA_MOCK_WORKTREES/$FAIL" "chief-spawn.sh's rollback leaves no Orca worktree behind"
assert_eq "$(git -C "$WORK/project" branch --list 'feat/flowfail' | wc -l | tr -d ' ')" "0" "chief-spawn.sh's rollback leaves no branch behind"
assert_file_missing "$CHIEF_HOME/tasks/$FAIL/meta" "chief-spawn.sh's rollback leaves no meta record"

harness_summary
