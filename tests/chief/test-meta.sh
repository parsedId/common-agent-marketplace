#!/usr/bin/env bash
# test-meta.sh - meta.sh's key=value read/write helpers.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
CHIEF_BIN="$REPO_ROOT/plugins/chief/bin"
. "$TEST_DIR/lib/harness.sh"

CHIEF_HOME=$(mktemp -d)
trap 'rm -rf "$CHIEF_HOME"' EXIT
. "$CHIEF_BIN/lib/paths.sh"
. "$CHIEF_BIN/lib/meta.sh"

echo "test-meta:"

chief_meta_set t1 project /home/foo
chief_meta_set t1 status spawned
chief_meta_set t1 status working
assert_eq "$(cat "$TASKS/t1/meta" | wc -l | tr -d ' ')" "2" "set() upserts in place, does not duplicate the key"
assert_eq "$(chief_meta_get t1 status)" "working" "get() returns the latest value"

chief_task_archive t1
assert_file_missing "$TASKS/t1" "archive moves the folder out of tasks/"
assert_file_exists "$ARCHIVE/t1/meta" "archive keeps the meta"
assert_eq "$(chief_meta_get t1 status)" "working" "get() still resolves an archived task"
assert_eq "$(chief_task_path t1 report.md)" "$ARCHIVE/t1/report.md" "paths of an archived task point into the archive"
assert_eq "$(chief_task_path t2 report.md)" "$TASKS/t2/report.md" "paths of an unknown task point into tasks/"
assert_eq "$(chief_meta_get t1 project)" "/home/foo" "get() returns an untouched key"

chief_meta_get t1 nope >/dev/null 2>&1
assert_eq "$?" "1" "get() on a missing key returns exit 1"

assert_eq "$(chief_meta_exists t1 && echo yes || echo no)" "yes" "exists() is true for a known id"
assert_eq "$(chief_meta_exists nope && echo yes || echo no)" "no" "exists() is false for an unknown id"

assert_eq "$(chief_meta_require t1 status)" "working" "require() returns the value when present"
( chief_meta_require t1 nope ) >/tmp/chief-test-meta-err.$$ 2>&1
assert_eq "$?" "1" "require() exits 1 on a missing key"
assert_contains "$(cat /tmp/chief-test-meta-err.$$)" "missing required key" "require() names the missing key, not a false 'no meta record'"
rm -f /tmp/chief-test-meta-err.$$

( chief_meta_require nope status ) >/tmp/chief-test-meta-err2.$$ 2>&1
assert_contains "$(cat /tmp/chief-test-meta-err2.$$)" "no meta record" "require() on a genuinely missing id says so"
rm -f /tmp/chief-test-meta-err2.$$

harness_summary
