#!/usr/bin/env bash
# test-backend-herdr-mock.sh - backends/herdr.sh against a fake `herdr` whose
# screens (fixtures/herdr/) and JSON shapes were captured from a live herdr
# 0.9.3 + Claude Code 2.1.296. Zero cost. Covers what a spawn/relaunch may
# report as success: only a ready screen followed by an observed started turn.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
CHIEF_BIN="$REPO_ROOT/plugins/chief/bin"
FX="$TEST_DIR/fixtures/herdr"
. "$TEST_DIR/lib/harness.sh"

WORK=$(mktemp -d)
harness_trap 'rm -rf "$WORK"'
mkdir -p "$WORK/bin" "$WORK/fake"
export CHIEF_HOME="$WORK/chief" FAKE="$WORK/fake" PATH="$WORK/bin:$PATH"
export CHIEF_HERDR_SUBMIT_TIMEOUT_MS=2000 CHIEF_HERDR_START_WAIT=2 CHIEF_HERDR_PROMPT_WAIT=1

# Fake herdr: every call is appended to $FAKE/calls; behaviour is data in $FAKE:
#   start.json/start.rc   `agent start` reply (default: idle, rc 0)
#   prompt.json/.rc       `agent prompt` reply; prompt.N.json/.rc for the N-th call
#   screen                what `agent read` prints; screen.N overrides the N-th read;
#                         prompt.N.screen replaces `screen` after the N-th prompt;
#                         keys.screen replaces it after any `send-keys ... enter`
#   get.json              `agent get` reply; wait.rc  `agent wait` exit code
cat > "$WORK/bin/herdr" <<'FAKE_HERDR'
#!/usr/bin/env bash
case "$1 $2" in "agent prompt") echo "$1 $2 $3 <${#4}B> ${*:5}" >> "$FAKE/calls";; *) echo "$*" >> "$FAKE/calls";; esac
bump() { local n=$(( $(cat "$FAKE/n.$1" 2>/dev/null || echo 0) + 1 )); echo $n > "$FAKE/n.$1"; echo $n; }
reply() {  # <stem> <n>: <stem>.<n>.json else <stem>.json; exit code from the matching .rc else 0
  local f=$FAKE/$1.$2; [ -f "$f.json" ] || f=$FAKE/$1
  cat "$f.json" 2>/dev/null; return "$(cat "$f.rc" 2>/dev/null || echo 0)"; }
case "$1 $2" in
  "worktree create") d=; b=; while [ $# -gt 0 ]; do case "$1" in --cwd) c=$2;; --branch) b=$2;; --path) d=$2;; esac; shift; done
                     git -C "$c" worktree add -q -b "$b" "$d" >/dev/null 2>&1
                     echo '{"result":{"root_pane":{"pane_id":"w9:p1"}}}' ;;
  "worktree open")   echo '{"result":{"root_pane":{"pane_id":"w9:p1"}}}' ;;
  "workspace list")  echo '{"result":{"workspaces":[]}}' ;;
  "workspace close") ;;
  "agent start")     n=$(bump start); if [ -f "$FAKE/start.json" ] || [ -f "$FAKE/start.$n.json" ]; then reply start $n; exit $?; fi
                     echo '{"result":{"agent":{"agent_status":"idle","interactive_ready":true}}}' ;;
  "agent prompt")    n=$(bump prompt); [ -f "$FAKE/prompt.$n.screen" ] && cp "$FAKE/prompt.$n.screen" "$FAKE/screen"; reply prompt $n; exit $? ;;
  "agent read")      n=$(bump read); if [ -f "$FAKE/screen.$n" ]; then cat "$FAKE/screen.$n"; else cat "$FAKE/screen" 2>/dev/null; fi ;;
  "agent get")       cat "$FAKE/get.json" 2>/dev/null || echo '{"result":{"agent":{"agent_status":"idle"}}}' ;;
  "agent wait")      exit "$(cat "$FAKE/wait.rc" 2>/dev/null || echo 1)" ;;
  "agent send-keys") case "$*" in *enter*) [ -f "$FAKE/keys.screen" ] && cp "$FAKE/keys.screen" "$FAKE/screen";; esac ;;
esac
FAKE_HERDR
chmod +x "$WORK/bin/herdr"

WORKING='{"result":{"agent":{"agent_status":"working"}}}'
BLOCKED='{"result":{"agent":{"agent_status":"blocked"}}}'
STALLED='{"error":{"code":"agent_prompt_stalled","message":"agent prompt produced no observed working or blocked state within 5000 ms; current status is idle"}}'
NOT_READY='{"error":{"code":"agent_not_ready","message":"agent t1 is blocked during startup and is not ready for prompts"}}'
reset() { rm -rf "$FAKE"; mkdir -p "$FAKE"; : > "$FAKE/calls"; }
count() { grep -c -- "$1" "$FAKE/calls" || true; }
# the trust dialog fixture for <path>, wrapped like the terminal wraps it
dialog_for() {
  awk -v p="$1" '/@WORKTREE@/ { for (i = 1; i <= length(p); i += 60) print " " substr(p, i, 60); next } { print }' "$FX/screen-trust-dialog.txt"
}

. "$CHIEF_BIN/lib/paths.sh"; . "$CHIEF_BIN/lib/meta.sh"; . "$CHIEF_BIN/lib/agents/agent.sh"
. "$CHIEF_BIN/lib/backends/herdr.sh"
chief_agent_use t1 >/dev/null 2>&1
WT="$WORK/chief/worktrees/t1"
BRIEF="You are a researcher: an autonomous worker agent dispatched by Chief. $(printf 'line %s\n' $(seq 1 40))"

echo "test-backend-herdr-mock:"

echo "[start] readiness comes from the screen, not from 'agent start'"
reset; cp "$FX/screen-ready.txt" "$FAKE/screen"
_chief_herdr_start_agent t1 w9:p1 "$WT" >/dev/null 2>&1
assert_eq "$?" "0" "a ready screen -> ready"
reset; cp "$FX/screen-shell-only.txt" "$FAKE/screen"
err=$(_chief_herdr_start_agent t1 w9:p1 "$WT" 2>&1 >/dev/null); rc=$?
assert_eq "$rc" "1" "only the shell line (TUI not rendered) -> not ready after the wait"
assert_contains "$err" "no ready screen" "...and the failure says so"
assert_contains "$err" "claude --dangerously-skip-permissions" "...and shows the last screen lines"
reset; cp "$FX/screen-shell-only.txt" "$FAKE/screen"; cp "$FX/screen-ready.txt" "$FAKE/screen.3"
_chief_herdr_start_agent t1 w9:p1 "$WT" >/dev/null 2>&1
assert_eq "$?" "0" "ready from the 3rd read -> start waits and succeeds"
assert_eq "$(( $(count 'agent read') >= 3 ))" "1" "...having polled the screen"
reset; echo "$NOT_READY" > "$FAKE/start.json"; echo 1 > "$FAKE/start.rc"; cp "$FX/screen-ready.txt" "$FAKE/screen"
_chief_herdr_start_agent t1 w9:p1 "$WT" >/dev/null 2>&1
assert_eq "$?" "0" "'agent start' reporting agent_not_ready does not decide: the screen does"
BUSY='{"error":{"code":"agent_pane_busy","message":"agent target pane w9:p1 is not an available shell"}}'
reset; echo "$BUSY" > "$FAKE/start.1.json"; echo 1 > "$FAKE/start.1.rc"; cp "$FX/screen-ready.txt" "$FAKE/screen"
_chief_herdr_start_agent t1 w9:p1 "$WT" >/dev/null 2>&1
assert_eq "$?" "0" "a pane whose shell is not up yet (agent_pane_busy) is retried"
assert_eq "$(count 'agent start')" "2" "...once it is up, started once more"
reset; echo "$BUSY" > "$FAKE/start.json"; echo 1 > "$FAKE/start.rc"
err=$(_chief_herdr_start_agent t1 w9:p1 "$WT" 2>&1 >/dev/null); rc=$?
assert_eq "$rc" "1" "a pane that stays busy fails after the wait"
assert_contains "$err" "agent_pane_busy" "...with herdr's error"
reset; echo '{"error":{"code":"unknown_kind"}}' > "$FAKE/start.json"; echo 1 > "$FAKE/start.rc"
err=$(_chief_herdr_start_agent t1 w9:p1 "$WT" 2>&1 >/dev/null); rc=$?
assert_eq "$rc" "1" "any other 'agent start' failure fails at once"
assert_eq "$(count 'agent read')" "0" "...without polling"
assert_contains "$err" "unknown_kind" "...with herdr's own error"

echo "[start] folder-trust dialog"
reset; dialog_for "$WT" > "$FAKE/screen"; cp "$FX/screen-ready.txt" "$FAKE/keys.screen"
_chief_herdr_start_agent t1 w9:p1 "$WT" >/dev/null 2>&1
assert_eq "$?" "0" "the dialog for Chief's own worktree is accepted, then ready"
assert_eq "$(count 'send-keys t1 down enter')" "1" "...with down enter, once"
reset; dialog_for "$WT" > "$FAKE/screen"
err=$(_chief_herdr_start_agent t1 w9:p1 "$WT" 2>&1 >/dev/null); rc=$?
assert_eq "$rc" "1" "a dialog that stays after accepting -> not ready"
assert_eq "$(count 'send-keys')" "1" "...accepted only once"
assert_contains "$err" "folder-trust dialog" "...and the failure names the dialog"
assert_contains "$err" "Yes, I trust this folder" "...and shows it"
reset; dialog_for "$WORK/elsewhere/other" > "$FAKE/screen"; cp "$FX/screen-ready.txt" "$FAKE/keys.screen"
_chief_herdr_start_agent t1 w9:p1 "$WT" >/dev/null 2>&1
assert_eq "$?" "1" "the dialog for another folder is not accepted"
assert_eq "$(count 'send-keys')" "0" "...no keys sent"
reset; dialog_for "$WT" > "$FAKE/screen"; cp "$FX/screen-ready.txt" "$FAKE/keys.screen"
chief_meta_set t2 agent codex; chief_agent_use t2
_chief_herdr_start_agent t1 w9:p1 "$WT" >/dev/null 2>&1
assert_eq "$(count 'send-keys')" "0" "an agent without agent_trust_keys never has a dialog auto-accepted"
chief_agent_use t1 >/dev/null 2>&1

echo "[prompt] 'blocked' is not 'turn started'"
reset; cp "$FX/screen-trust-dialog.txt" "$FAKE/screen"; echo "$BLOCKED" > "$FAKE/prompt.json"
err=$(_chief_herdr_prompt t1 "$BRIEF" 2>&1 >/dev/null); rc=$?
assert_eq "$rc" "1" "a reply of blocked -> failure"
assert_eq "$(count 'agent prompt')" "1" "...not retried"
assert_not_contains "$(cat "$FAKE/calls")" "--until blocked" "...and blocked is not awaited"
reset; echo "$WORKING" > "$FAKE/prompt.json"; cp "$FX/screen-ready.txt" "$FAKE/screen"
_chief_herdr_prompt t1 "$BRIEF" >/dev/null 2>&1
assert_eq "$?" "0" "a reply of working -> success"
reset; echo '{"error":{"code":"agent_blocked"}}' > "$FAKE/prompt.json"; echo 1 > "$FAKE/prompt.rc"
err=$(_chief_herdr_prompt t1 "$BRIEF" 2>&1 >/dev/null); rc=$?
assert_eq "$rc" "1" "herdr rejecting the prompt -> failure"
assert_contains "$err" "agent_blocked" "...with herdr's error"

echo "[prompt] stall recovery"
# text landed as a placeholder, Enter lost -> Enter only, never a resend on top
reset; cp "$FX/screen-pasted-placeholder.txt" "$FAKE/screen"; cp "$FX/screen-ready.txt" "$FAKE/keys.screen"
echo "$STALLED" > "$FAKE/prompt.json"; echo 1 > "$FAKE/prompt.rc"; echo 0 > "$FAKE/wait.rc"
_chief_herdr_prompt t1 "$BRIEF" >/dev/null 2>&1; rc=$?
assert_eq "$(count 'agent prompt')" "1" "placeholder in the input box: no resend"
assert_eq "$(count 'send-keys t1 enter')" "1" "...a bare Enter instead"
assert_eq "$rc" "0" "...and success once the turn starts"
reset; cp "$FX/screen-pasted-placeholder.txt" "$FAKE/screen"; cp "$FX/screen-ready.txt" "$FAKE/keys.screen"
echo "$STALLED" > "$FAKE/prompt.json"; echo 1 > "$FAKE/prompt.rc"; echo 1 > "$FAKE/wait.rc"
_chief_herdr_prompt t1 "$BRIEF" >/dev/null 2>&1
assert_eq "$?" "1" "Enter sent but no turn started -> failure"
assert_eq "$(count 'agent prompt')" "1" "...still no resend"
# raw text in the input box
reset; printf '%s\n' "─────" "❯ $(printf '%s' "$BRIEF" | head -c 60)" "─────" "  ⏵⏵ bypass permissions on" > "$FAKE/screen"
cp "$FX/screen-ready.txt" "$FAKE/keys.screen"; echo "$STALLED" > "$FAKE/prompt.json"; echo 1 > "$FAKE/prompt.rc"; echo 0 > "$FAKE/wait.rc"
_chief_herdr_prompt t1 "$BRIEF" >/dev/null 2>&1
assert_eq "$(count 'send-keys t1 enter')" "1" "the raw head of the brief in the input line -> Enter"
# already submitted (text above a fresh empty box): wait, no Enter, no resend
reset; printf '%s\n' "❯ [Pasted text #1 +34 lines]" "● working" "─────" "❯ Try \"edit <filepath> to...\"" "  ⏵⏵ bypass permissions on" > "$FAKE/screen"
echo "$STALLED" > "$FAKE/prompt.json"; echo 1 > "$FAKE/prompt.rc"; echo 0 > "$FAKE/wait.rc"
_chief_herdr_prompt t1 "$BRIEF" >/dev/null 2>&1
assert_eq "$?" "0" "a brief already submitted -> wait for the turn"
assert_eq "$(count 'agent prompt')$(count 'send-keys')" "10" "...no Enter, no resend"
# never arrived, agent ready -> resend once
reset; cp "$FX/screen-ready.txt" "$FAKE/screen"
echo "$STALLED" > "$FAKE/prompt.1.json"; echo 1 > "$FAKE/prompt.1.rc"; echo "$WORKING" > "$FAKE/prompt.json"
_chief_herdr_prompt t1 "$BRIEF" >/dev/null 2>&1
assert_eq "$?" "0" "a brief that never arrived (ready, empty box) -> resent, succeeds"
assert_eq "$(count 'agent prompt')" "2" "...exactly once"
reset; cp "$FX/screen-ready.txt" "$FAKE/screen"; echo "$STALLED" > "$FAKE/prompt.json"; echo 1 > "$FAKE/prompt.rc"
err=$(_chief_herdr_prompt t1 "$BRIEF" 2>&1 >/dev/null)
assert_eq "$(count 'agent prompt')" "2" "stalled again after the resend -> not resent a third time"
assert_contains "$err" "no turn started" "...and the failure says no turn started"
# TUI not rendered yet: the text is queued in the pty
reset; cp "$FX/screen-shell-only.txt" "$FAKE/screen"; echo "$STALLED" > "$FAKE/prompt.json"; echo 1 > "$FAKE/prompt.rc"
_chief_herdr_prompt t1 "$BRIEF" >/dev/null 2>&1
assert_eq "$?" "1" "shell line only -> failure after the wait"
assert_eq "$(count 'agent prompt')" "1" "...never resent while the TUI is not rendered"
reset; cp "$FX/screen-shell-only.txt" "$FAKE/screen"; cp "$FX/screen-pasted-placeholder.txt" "$FAKE/screen.2"
cp "$FX/screen-ready.txt" "$FAKE/keys.screen"; echo "$STALLED" > "$FAKE/prompt.json"; echo 1 > "$FAKE/prompt.rc"; echo 0 > "$FAKE/wait.rc"
_chief_herdr_prompt t1 "$BRIEF" >/dev/null 2>&1
assert_eq "$?" "0" "the queued text appearing once the TUI renders -> Enter, success"
assert_eq "$(count 'agent prompt')" "1" "...no resend"
# unanswered permission prompt
reset; cp "$FX/screen-trust-dialog.txt" "$FAKE/screen"; echo "$STALLED" > "$FAKE/prompt.json"; echo 1 > "$FAKE/prompt.rc"; echo "$BLOCKED" > "$FAKE/get.json"
err=$(_chief_herdr_prompt t1 "$BRIEF" 2>&1 >/dev/null)
assert_contains "$err" "unanswered permission/approval prompt" "a stall at a blocked agent says so"

echo "[spawn] chief-spawn.sh prints 'spawned:' only when a turn started"
mkproj() { rm -rf "$WORK/proj"; mkdir -p "$WORK/proj"; ( cd "$WORK/proj" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init ); }
spawn() { CHIEF_BACKEND=herdr bash "$CHIEF_BIN/chief-spawn.sh" "$1" "$WORK/proj" --mode researcher --branch "res/$1" --intent "x" 2>&1; }
mkproj; reset; cp "$FX/screen-ready.txt" "$FAKE/screen"; echo "$BLOCKED" > "$FAKE/prompt.json"; dialog_for "$CHIEF_HOME/worktrees/s1" > "$FAKE/prompt.1.screen"
out=$(spawn s1); rc=$?
assert_eq "$((rc != 0))" "1" "a dialog and a 'blocked' reply -> non-zero"
assert_not_contains "$out" "spawned:" "...no 'spawned:' line"
assert_file_missing "$CHIEF_HOME/state/s1.meta" "...rolled back, no meta left"
mkproj; reset; cp "$FX/screen-shell-only.txt" "$FAKE/screen"
out=$(spawn s3); rc=$?
assert_eq "$((rc != 0))" "1" "a pane that never renders -> non-zero"
assert_not_contains "$out" "spawned:" "...no 'spawned:' line"
assert_file_missing "$CHIEF_HOME/state/s3.meta" "...rolled back, no meta left"
mkproj; reset; cp "$FX/screen-ready.txt" "$FAKE/screen"; echo "$WORKING" > "$FAKE/prompt.json"
out=$(spawn s2); rc=$?
assert_eq "$rc" "0" "a healthy spawn succeeds"
assert_contains "$out" "spawned: s2" "...and prints 'spawned: s2'"
mkproj; reset; dialog_for "$CHIEF_HOME/worktrees/s4" > "$FAKE/screen"; cp "$FX/screen-ready.txt" "$FAKE/keys.screen"; echo "$WORKING" > "$FAKE/prompt.json"
out=$(spawn s4); rc=$?
assert_eq "$rc" "0" "a lost pre-trust (dialog for the new worktree) is accepted and the spawn succeeds"
assert_contains "$out" "spawned: s4" "...and prints 'spawned: s4'"

echo "[relaunch] backend_relaunch shares the path"
mkproj; reset; R_WT="$CHIEF_HOME/worktrees/r1"; git -C "$WORK/proj" worktree add -q -b res/r1 "$R_WT"
chief_meta_set r1 project "$WORK/proj"; chief_meta_set r1 worktree "$R_WT"; chief_meta_set r1 mode researcher; chief_meta_set r1 agent claude
printf 'brief\n' > "$WORK/brief.md"
cp "$FX/screen-ready.txt" "$FAKE/screen"; echo "$BLOCKED" > "$FAKE/prompt.json"
backend_relaunch r1 "$WORK/brief.md" >/dev/null 2>&1
assert_eq "$(( $? != 0 ))" "1" "a 'blocked' reply -> relaunch fails"
assert_eq "$(chief_meta_get r1 endpoint 2>/dev/null)" "" "...and records no endpoint"
reset; cp "$FX/screen-ready.txt" "$FAKE/screen"; echo "$WORKING" > "$FAKE/prompt.json"
backend_relaunch r1 "$WORK/brief.md" >/dev/null 2>&1
assert_eq "$?" "0" "a started turn -> relaunch succeeds"
assert_eq "$(chief_meta_get r1 endpoint)" "herdr:w9:p1" "...and records the endpoint"

echo "[name] herdr agent names are valid, deterministic and unique"
LONG1=build-dotnet-common-keycloak-by-name-review-copilot-gpt-6-1-sol
LONG2=build-dotnet-common-keycloak-by-name-review-copilot-gpt-6-1-sul
N1=$(_chief_herdr_name "$LONG1"); N2=$(_chief_herdr_name "$LONG2")
assert_eq "$(_chief_herdr_name t1)" "t1" "a valid short id is used as is"
assert_success "a long id maps to a valid herdr name" -- grep -Eq '^[a-z][a-z0-9_-]{0,31}$' <<<"$N1"
assert_eq "$N1" "$(_chief_herdr_name "$LONG1")" "...deterministically"
assert_eq "$([ "$N1" != "$N2" ] && echo ok)" "ok" "...and ids sharing a prefix stay distinct"
assert_success "an uppercase/dotted id maps to a valid name" -- grep -Eq '^[a-z][a-z0-9_-]{0,31}$' <<<"$(_chief_herdr_name 9Task.Foo)"
reset; backend_send "$LONG1" hi
assert_contains "$(cat "$FAKE/calls")" "agent prompt $N1 <2B>" "backend_send uses the derived name"

harness_summary
