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

# Mock-backend workers (argv0 chief-mock-*) alive now; a test that leaves one
# behind shows up as a new pid after the sweep.
mock_pids() { ps -eo pid=,args= | awk '$2 ~ /^chief-mock-/ { print $1 }' | sort; }
MOCK_BEFORE=$(mock_pids)

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

LEAKED=$(comm -13 <(echo "$MOCK_BEFORE") <(mock_pids) | wc -l | tr -d ' ')
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
