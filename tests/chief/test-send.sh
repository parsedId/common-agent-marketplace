#!/usr/bin/env bash
# test-send.sh - chief-send.sh: durable steering inbox + doorbell.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
BIN="$REPO_ROOT/plugins/chief/bin"
. "$TEST_DIR/lib/harness.sh"

WORK=$(mktemp -d)
harness_trap 'rm -rf "$WORK"'
mkdir -p "$WORK/project" && cd "$WORK/project" && git init -q -b master
git commit --allow-empty -q -m init
export CHIEF_HOME="$WORK/.chief"
export CHIEF_BACKEND=mock
SEND="$BIN/task/chief-send.sh"
SPAWN="$BIN/chief-spawn.sh"

echo "test-send:"

assert_failure "refuses an unknown task id" -- "$SEND" nope "hi"

timeout 10 "$SPAWN" t-1 "$WORK/project" --mode builder --branch feat/t-1 --intent "test" --spec "test" >/dev/null

assert_failure "refuses an empty message" -- "$SEND" t-1 "   "

assert_success "sends the first message" -- "$SEND" t-1 "please also add a README note"
assert_success "sends a second message" -- "$SEND" t-1 "and run the tests"
assert_file_exists "$CHIEF_HOME/tasks/t-1/inbox/001.msg" "first message numbered 001"
assert_file_exists "$CHIEF_HOME/tasks/t-1/inbox/002.msg" "second message numbered 002"
assert_eq "$(cat "$CHIEF_HOME/tasks/t-1/inbox/001.msg")" "please also add a README note" "message text is stored verbatim"

mv "$CHIEF_HOME/tasks/t-1/inbox/001.msg" "$CHIEF_HOME/tasks/t-1/inbox/handled/"
assert_success "sends a third message after the first was handled" -- "$SEND" t-1 "third message"
assert_file_exists "$CHIEF_HOME/tasks/t-1/inbox/003.msg" "numbering continues from handled/ history, never reuses 001"

# Zero-padded numbers must count in decimal: 008/009 are invalid octal and 010-017 etc. are valid-but-wrong octal.
for last in 007 008 009 010 011 019 099; do
  tid="n-$last"
  timeout 10 "$SPAWN" "$tid" "$WORK/project" --mode builder --branch "feat/$tid" --intent "test" --spec "test" >/dev/null
  box="$CHIEF_HOME/tasks/$tid/inbox"
  mkdir -p "$box/handled"
  echo old > "$box/handled/$last.msg"
  want=$(printf '%03d' $((10#$last + 1)))
  assert_success "sends after a last message numbered $last" -- "$SEND" "$tid" "next"
  assert_file_exists "$box/$want.msg" "numbering after $last continues at $want"
done

assert_success "sends a special key" -- "$SEND" t-1 --key Enter
assert_contains "$(cat "$CHIEF_HOME/tasks/t-1/term.log")" "send: Enter" "the key reached the backend"
assert_contains "$(cat "$CHIEF_HOME/tasks/t-1/term.log")" "instruction waiting in" "an ordinary message rings a doorbell line, not the raw text"

harness_summary
