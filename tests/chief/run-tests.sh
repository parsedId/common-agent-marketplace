#!/usr/bin/env bash
# run-tests.sh - runs every tests/chief/test-*.sh and reports a summary.
#
# These are functional/integration tests of Chief's own bash scripts. Most
# run against the `mock` backend (no `claude` CLI, zero tokens).
# test-backend-orca-mock.sh is also zero-cost - it unit-tests
# backends/orca.sh against a fake `orca` CLI. test-backend-herdr.sh,
# test-backend-orca.sh, test-backend-copilot.sh and
# test-backend-copilot-brief.sh are the exceptions: each
# opts into a real herdr/orca install and a real agent turn, skipped by
# default - see this directory's README.md. Skill-BEHAVIOR tests (does Claude actually follow
# using-chief/dispatch/setup correctly) live in tests/claude-code/
# instead.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================"
echo " Chief plugin - functional test suite"
echo "========================================"
echo ""

# Mock-backend workers (argv0 chief-mock-*) this run started are logged to
# CHIEF_MOCK_RUN_LOG by mock.sh at spawn time; any still alive after the sweep
# leaked. Other runs' workers are never in the log.
source "$SCRIPT_DIR/lib/harness.sh"
CHIEF_MOCK_RUN_LOG=$(mktemp)
export CHIEF_MOCK_RUN_LOG

total_files=0
failed_files=0

for f in "$SCRIPT_DIR"/test-*.sh; do
  [ -e "$f" ] || continue
  total_files=$((total_files + 1))
  echo "--- $(basename "$f") ---"
  if ! bash "$f"; then
    failed_files=$((failed_files + 1))
  fi
  echo ""
done

LEAKED_PIDS=$(harness_leaked_mock_pids "$CHIEF_MOCK_RUN_LOG")
LEAKED=$(printf '%s\n' "$LEAKED_PIDS" | grep -c .)
[ -z "$LEAKED_PIDS" ] || kill $LEAKED_PIDS 2>/dev/null
rm -f "$CHIEF_MOCK_RUN_LOG"
echo "mock workers left behind: $LEAKED"
[ "$LEAKED" -eq 0 ] || failed_files=$((failed_files + 1))

echo "========================================"
if [ "$failed_files" -eq 0 ]; then
  echo " ALL PASS ($total_files test files)"
else
  echo " $failed_files of $total_files test files had failures"
fi
echo "========================================"

[ "$failed_files" -eq 0 ]
