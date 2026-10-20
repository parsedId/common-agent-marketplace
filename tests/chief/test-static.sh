#!/usr/bin/env bash
# test-static.sh - cheap static checks: every script parses, every JSON file
# is valid, executable bits are where they should be. Catches typos and
# broken JSON before anything else runs.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
CHIEF="$REPO_ROOT/plugins/chief"
. "$TEST_DIR/lib/harness.sh"

echo "test-static:"

while IFS= read -r -d '' f; do
  rel="${f#"$REPO_ROOT"/}"
  assert_success "bash -n: $rel" -- bash -n "$f"
done < <(find "$CHIEF" -name '*.sh' -print0)

if command -v python3 >/dev/null 2>&1; then
  for f in "$CHIEF/.claude-plugin/plugin.json" "$CHIEF/hooks/hooks.json" "$REPO_ROOT/.claude-plugin/marketplace.json"; do
    rel="${f#"$REPO_ROOT"/}"
    assert_success "valid JSON: $rel" -- python3 -m json.tool "$f"
  done
else
  echo "  (python3 not found, skipping JSON validation)"
fi

while IFS= read -r -d '' f; do
  rel="${f#"$REPO_ROOT"/}"
  if [ -x "$f" ]; then
    echo "  [PASS] executable: $rel"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  [FAIL] executable: $rel (missing +x)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
done < <(find "$CHIEF/bin" -maxdepth 1 -name '*.sh' -print0; find "$CHIEF/bin/task" -maxdepth 1 -name '*.sh' -print0; find "$CHIEF/hooks" -maxdepth 1 -name '*.sh' -print0)

harness_summary
