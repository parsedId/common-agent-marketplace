#!/usr/bin/env bash
# test-backend-copilot-brief.sh - issue #90 against the REAL Copilot CLI on
# herdr: a brief-sized prompt (taller than the 40-row viewport) goes in through
# `chief-spawn.sh --agent copilot` and must arrive exactly once - one
# `herdr agent prompt` call and one user.message in Copilot's events.jsonl.
#
# NOT zero-cost: one trivial research turn per attempt. Opt in explicitly:
#
#   CHIEF_TEST_COPILOT_BRIEF=1 bash tests/chief/test-backend-copilot-brief.sh
#
# The failure needs herdr's 5 s `agent_prompt_stalled` while copilot already
# took the brief, a race that herdr's status lag hits on some runs only. So it
# makes CHIEF_TEST_COPILOT_BRIEF_ATTEMPTS (default 3) attempts and FAILS if
# none stalled: a run that never reached the recovery proves nothing.
#
# Skips cleanly without the opt-in or the tools; isolation as in
# test-backend-copilot.sh (lib/copilot-isolation.sh).
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
CHIEF_BIN="$REPO_ROOT/plugins/chief/bin"
. "$TEST_DIR/lib/harness.sh"

echo "test-backend-copilot-brief:"

if [ "${CHIEF_TEST_COPILOT_BRIEF:-0}" != "1" ]; then
  echo "  (skipped - opt in with CHIEF_TEST_COPILOT_BRIEF=1; spends real Copilot requests and needs herdr)"
  exit 0
fi
ATTEMPTS="${CHIEF_TEST_COPILOT_BRIEF_ATTEMPTS:-3}"
REAL_HERDR=$(command -v herdr 2>/dev/null || true)
. "$TEST_DIR/lib/copilot-isolation.sh"

REPO="$ISO/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" commit -q --allow-empty -m init
mkdir -p "$HOME/.copilot"
( umask 077
  grep -v '^[[:space:]]*//' "$LOGIN_SRC" | jq --arg r "$REPO" '. + {trustedFolders: [$r]}' > "$HOME/.copilot/config.json" ) \
  || { echo "  [FAIL] could not prepare the copilot login"; exit 1; }

# herdr shim: logs one "<id> <bytes> <stalled 0|1>" line per `agent prompt`, then defers to the real herdr
PROMPTS="$ISO/prompts.log"; : > "$PROMPTS"
mkdir -p "$ISO/shim"
cat > "$ISO/shim/herdr" <<SHIM
#!/usr/bin/env bash
[ "\$1 \$2" = "agent prompt" ] || exec "$REAL_HERDR" "\$@"
out=\$("$REAL_HERDR" "\$@" 2>&1); rc=\$?
case \$out in *agent_prompt_stalled*) s=1;; *) s=0;; esac
echo "\$3 \${#4} \$s" >> "$PROMPTS"
printf '%s\n' "\$out"; exit \$rc
SHIM
chmod +x "$ISO/shim/herdr"
export PATH="$ISO/shim:$PATH"

export CHIEF_HOME="$ISO/chief" CHIEF_BACKEND=herdr
. "$CHIEF_BIN/lib/paths.sh"
. "$CHIEF_BIN/lib/meta.sh"

# user_messages <id> - user.message events in the copilot session that got <id>'s brief
# (<id> as a whole word: t-brief-1 is not t-brief-10)
user_messages() {
  local f msgs
  for f in "$HOME"/.copilot/session-state/*/events.jsonl; do
    [ -f "$f" ] || continue
    msgs=$(jq -c 'select(.type == "user.message")' "$f" 2>/dev/null)
    printf '%s\n' "$msgs" | jq -e --arg id "$1" 'tostring | test("(^|[^A-Za-z0-9_-])" + $id + "($|[^A-Za-z0-9_-])")' >/dev/null 2>&1 || continue
    printf '%s\n' "$msgs" | wc -l
    return
  done
  echo 0
}

INTENT="Test run. Write the single word ok into the report file and report done. Do nothing else."
STALLS=0
for n in $(seq 1 "$ATTEMPTS"); do
  ID=t-brief-$n
  echo "[attempt $n/$ATTEMPTS] $ID"
  bash "$CHIEF_BIN/chief-spawn.sh" "$ID" "$REPO" --agent copilot --mode researcher \
    --branch "research/$ID" --intent "$INTENT" >"$ISO/spawn.$n.out" 2>"$ISO/spawn.$n.err"
  assert_eq "$?" "0" "the spawn reaches a started turn"
  STATUS=$(chief_task_path "$ID" status)
  for _ in $(seq 1 120); do
    case $(tail -n1 "$STATUS" 2>/dev/null) in done:*|failed:*|blocked:*|needs-decision:*) break ;; esac
    sleep 2
  done
  sleep 3  # a late second user.message would land here

  calls=$(grep -c -- "^$ID " "$PROMPTS" || true)
  bytes=$(grep -- "^$ID " "$PROMPTS" | head -1 | cut -d' ' -f2)
  stalled=$(grep -c -- "^$ID .* 1$" "$PROMPTS" || true)
  [ "$stalled" = 0 ] || STALLS=$((STALLS + 1))
  echo "  brief ${bytes:-?} B, herdr agent prompt calls: $calls, stalled: $stalled"
  assert_eq "$(( ${bytes:-0} >= 2500 ))" "1" "the prompt is brief-sized (>= 2500 B)"
  assert_eq "$calls" "1" "the brief goes through herdr agent prompt once"
  assert_eq "$(user_messages "$ID")" "1" "copilot got exactly one user.message"

  bash "$CHIEF_BIN/chief-teardown.sh" "$ID" >/dev/null 2>&1
done

echo "[stall] $STALLS of $ATTEMPTS attempts hit agent_prompt_stalled"
assert_eq "$(( STALLS >= 1 ))" "1" "at least one attempt exercised the stall recovery (else the run proves nothing)"

harness_summary
