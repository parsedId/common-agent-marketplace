#!/usr/bin/env bash
# harness.sh - minimal assertion helpers for Chief's bash tests. No external
# framework, matching the plugin's own KISS philosophy: every assert prints
# [PASS]/[FAIL] and updates the two counters a test file reports at the end.
#
# A test file sources this, runs asserts, then calls harness_summary at the
# end and exits with its return value.

# harness_trap '<cleanup cmd>' - the test's EXIT/INT/TERM/HUP cleanup. Also
# kills the mock-backend workers (`chief-mock-<id>` sleeps) this test started,
# found through the pid log mock.sh appends to - never by name.
harness_reap_mock() {
  local pid
  [ -f "${CHIEF_MOCK_PID_LOG:-}" ] || return 0
  while read -r pid; do
    case "$(ps -o args= -p "$pid" 2>/dev/null)" in chief-mock-*) kill "$pid" 2>/dev/null ;; esac
  done < "$CHIEF_MOCK_PID_LOG"
  rm -f "$CHIEF_MOCK_PID_LOG"
}
_harness_exit() { harness_reap_mock; rm -rf "$CLAUDE_CONFIG_DIR" "$HARNESS_BIN"; eval "$HARNESS_CLEANUP"; }
harness_trap() {
  HARNESS_CLEANUP=$1
  CHIEF_MOCK_PID_LOG=$(mktemp)
  export CHIEF_MOCK_PID_LOG
  # Keep pre-trust edits off the real ~/.claude.json.
  CLAUDE_CONFIG_DIR=$(mktemp -d)
  export CLAUDE_CONFIG_DIR
  # Stand-ins for the agent CLIs chief-spawn.sh requires; a real install wins.
  HARNESS_BIN=$(mktemp -d)
  for _cli in claude codex copilot; do printf '#!/bin/sh\n' > "$HARNESS_BIN/$_cli"; chmod +x "$HARNESS_BIN/$_cli"; done
  PATH="$PATH:$HARNESS_BIN"
  trap _harness_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}

PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {  # <actual> <expected> <test-name>
  if [ "$1" = "$2" ]; then
    echo "  [PASS] $3"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  [FAIL] $3"
    echo "    expected: $2"
    echo "    actual:   $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_success() {  # <test-name> -- <command...>
  local name=$1
  shift
  [ "$1" = "--" ] && shift
  local out
  if out=$("$@" 2>&1); then
    echo "  [PASS] $name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    local rc=$?
    echo "  [FAIL] $name (exit $rc)"
    echo "$out" | sed 's/^/    /'
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_failure() {  # <test-name> -- <command...>  (asserts nonzero exit)
  local name=$1
  shift
  [ "$1" = "--" ] && shift
  local out
  if out=$("$@" 2>&1); then
    echo "  [FAIL] $name (expected nonzero exit, got 0)"
    echo "$out" | sed 's/^/    /'
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo "  [PASS] $name"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

assert_contains() {  # <haystack> <needle> <test-name>
  if grep -qF -- "$2" <<< "$1"; then
    echo "  [PASS] $3"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  [FAIL] $3"
    echo "    expected to find: $2"
    echo "    in:"
    printf '%s\n' "$1" | sed 's/^/      /'
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_not_contains() {  # <haystack> <needle> <test-name>
  if grep -qF -- "$2" <<< "$1"; then
    echo "  [FAIL] $3"
    echo "    did not expect to find: $2"
    echo "    in:"
    printf '%s\n' "$1" | sed 's/^/      /'
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo "  [PASS] $3"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

assert_file_exists() {  # <path> <test-name>
  if [ -e "$1" ]; then
    echo "  [PASS] $2"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  [FAIL] $2 (missing: $1)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_file_missing() {  # <path> <test-name>
  if [ -e "$1" ]; then
    echo "  [FAIL] $2 (should not exist: $1)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo "  [PASS] $2"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

harness_summary() {  # call at the end of every test file
  echo "  --- $PASS_COUNT passed, $FAIL_COUNT failed ---"
  [ "$FAIL_COUNT" -eq 0 ]
}
