#!/usr/bin/env bash
# test-leak-check.sh - run-tests.sh's mock-worker leak check is scoped to the
# workers this run logged: a logged survivor is caught, a foreign one ignored.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/lib/harness.sh"

WORK=$(mktemp -d)
PIDS=""
trap 'kill $PIDS 2>/dev/null; rm -rf "$WORK"' EXIT

echo "test-leak-check:"

( exec -a chief-mock-leak-test-own sleep 100000 ) >/dev/null 2>&1 & OWN=$!
( exec -a chief-mock-leak-test-foreign sleep 100000 ) >/dev/null 2>&1 & FOREIGN=$!
PIDS="$OWN $FOREIGN"
sleep 0.2

echo "$OWN" > "$WORK/log"
assert_eq "$(harness_leaked_mock_pids "$WORK/log")" "$OWN" "a logged worker still alive is reported"
assert_not_contains "$(harness_leaked_mock_pids "$WORK/log")" "$FOREIGN" "a chief-mock-* process outside the log is ignored"

kill "$OWN"; wait "$OWN" 2>/dev/null
assert_eq "$(harness_leaked_mock_pids "$WORK/log")" "" "a logged worker that exited is not reported"
assert_eq "$(harness_leaked_mock_pids "$WORK/missing")" "" "a missing log reports nothing"

# Through the runner: a test that drops its EXIT trap and leaves a worker.
RUN="$WORK/run"; mkdir -p "$RUN/lib"
cp "$TEST_DIR/run-tests.sh" "$RUN/"; cp "$TEST_DIR/lib/harness.sh" "$RUN/lib/"
cat > "$RUN/test-leaky.sh" <<EOF
. "$TEST_DIR/lib/harness.sh"
. "$TEST_DIR/../../plugins/chief/bin/lib/backends/mock.sh"
chief_agent_use() { :; }; agent_prepare() { :; }
chief_task_path() { echo "$WORK/\$1.\$2"; }; chief_meta_get() { :; }
harness_trap ':'
backend_relaunch leaky-run /dev/null
trap - EXIT
exit 0
EOF
OUT=$(bash "$RUN/run-tests.sh" 2>&1); RC=$?
assert_contains "$OUT" "mock workers left behind: 1" "the runner reports a worker left by a test that dropped its trap"
assert_eq "$((RC != 0))" "1" "the runner fails on that leak"

harness_summary
