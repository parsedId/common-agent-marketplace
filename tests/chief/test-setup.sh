#!/usr/bin/env bash
# test-setup.sh - chief-setup.sh: one-time backend config + gitignore.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
BIN="$REPO_ROOT/plugins/chief/bin"
. "$TEST_DIR/lib/harness.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SETUP="$BIN/chief-setup.sh"

echo "test-setup:"

export CHIEF_HOME="$WORK/refused/.chief"
assert_failure "refuses with no --backend" -- "$SETUP"
assert_failure "refuses an invalid backend name" -- "$SETUP" --backend bogus

mkdir -p "$WORK/p1" && cd "$WORK/p1" && git init -q
export CHIEF_HOME="$WORK/p1/.chief"
assert_success "writes the backend config" -- "$SETUP" --backend herdr
assert_eq "$(cat "$CHIEF_HOME/config/backend")" "herdr" "config/backend contains the chosen backend"
assert_file_exists "$WORK/p1/.gitignore" ".gitignore is created if absent"
assert_eq "$(grep -c '^\.chief/$' "$WORK/p1/.gitignore")" "1" ".chief/ is added to .gitignore exactly once"

assert_success "re-running is safe (idempotent)" -- "$SETUP" --backend herdr
assert_eq "$(grep -c '^\.chief/$' "$WORK/p1/.gitignore")" "1" "re-running does not duplicate the gitignore line"

assert_success "switching backend updates the config" -- "$SETUP" --backend orca
assert_eq "$(cat "$CHIEF_HOME/config/backend")" "orca" "config/backend reflects the switch"

mkdir -p "$WORK/p2" && cd "$WORK/p2" && git init -q
echo "node_modules/" > .gitignore
export CHIEF_HOME="$WORK/p2/.chief"
"$SETUP" --backend herdr >/dev/null
assert_eq "$(cat "$WORK/p2/.gitignore")" "$(printf 'node_modules/\n.chief/')" "existing .gitignore content is preserved, .chief/ appended"

mkdir -p "$WORK/nogit" && cd "$WORK/nogit"
export CHIEF_HOME="$WORK/nogit/.chief"
assert_success "does not fail outside a git repo" -- "$SETUP" --backend herdr
assert_file_missing "$WORK/nogit/.gitignore" "no gitignore is invented outside a git repo"

harness_summary
