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

harness_summary
