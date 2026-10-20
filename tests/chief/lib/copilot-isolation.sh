#!/usr/bin/env bash
# copilot-isolation.sh - sourced by the opt-in real-Copilot tests, after the
# harness and their own opt-in check: prerequisites, a scrubbed environment
# with its own HOME/XDG dirs and herdr server, and the isolation guard.
# Leaves $ISO, $LOGIN_SRC and $HERDR_SOCKET_PATH set; the caller's cleanup
# must not outlive $ISO (harness_trap below already removes it).
for cli in herdr copilot jq ss; do
  command -v "$cli" >/dev/null 2>&1 || { echo "  (skipped - $cli not on PATH)"; exit 0; }
done
LOGIN_SRC="${COPILOT_HOME:-$HOME/.copilot}/config.json"
grep -q '"authTokens"' "$LOGIN_SRC" 2>/dev/null \
  || { echo "  (skipped - no copilot login at $LOGIN_SRC)"; exit 0; }

# Every socket the caller's environment or defaults could reach.
FORBIDDEN_SOCKS=(
  "${HERDR_SOCKET_PATH:-}" "${HERDR_CLIENT_SOCKET_PATH:-}"
  "$HOME/.config/herdr/herdr.sock" "$HOME/.config/herdr/herdr-client.sock"
  "${XDG_CONFIG_HOME:-$HOME/.config}/herdr/herdr.sock"
  /home/vscode/.config/herdr/herdr.sock
)
ISO=$(mktemp -d)

# Scrubbed environment: only what the tools need, own HOME and XDG dirs, own socket.
for v in $(compgen -e); do
  case $v in PATH|TERM|LANG|LC_*|USER|LOGNAME|SHELL|TMPDIR|PWD|OLDPWD|SHLVL|_|CHIEF_TEST_COPILOT*) ;; *) unset "$v" ;; esac
done
export HOME="$ISO/home" XDG_CONFIG_HOME="$ISO/xdg-config" XDG_RUNTIME_DIR="$ISO/xdg-run" XDG_DATA_HOME="$ISO/xdg-data"
export HERDR_SOCKET_PATH="$ISO/xdg-run/herdr.sock"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR" "$XDG_DATA_HOME"
chmod 700 "$ISO" "$XDG_RUNTIME_DIR"

SERVER_PID=""
stop_server() {
  [ -n "$SERVER_PID" ] || return 0
  case $HERDR_SOCKET_PATH in "$ISO"/*) herdr server stop >/dev/null 2>&1 ;; esac
  for _ in $(seq 1 20); do kill -0 "$SERVER_PID" 2>/dev/null || break; sleep 0.25; done
  case $(ps -o args= -p "$SERVER_PID" 2>/dev/null) in *"herdr server"*) kill "$SERVER_PID" 2>/dev/null ;; esac
}
cleanup() {
  stop_server
  rm -f "$HOME/.copilot/config.json"
  rm -rf "$ISO"
}
harness_trap cleanup

echo "  isolation: socket $HERDR_SOCKET_PATH"
echo "  isolation: home   $HOME"

abort() { echo "  [ABORT] isolation not proven: $1 - nothing was run"; exit 1; }

sock_owner() {  # <socket> -> pid listening on it, empty if none
  ss -xlpH 2>/dev/null | awk -v s="$1" '$5 == s' | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2
}

# isolation_guard - proves the test's herdr is its own, before any client call.
isolation_guard() {
  local forbidden sock=$HERDR_SOCKET_PATH default_owner own_owner before listing
  case $sock in "$ISO"/*) ;; *) abort "socket is outside the temp dir" ;; esac
  for forbidden in $(printf '%s\n' "${FORBIDDEN_SOCKS[@]}" | sort -u); do
    [ "$sock" != "$forbidden" ] && [ "$(realpath -m "$sock")" != "$(realpath -m "$forbidden")" ] \
      || abort "socket equals $forbidden"
    echo "  [PASS] socket differs from $forbidden"
  done
  [ ! -e "$sock" ] || abort "socket already exists"

  default_owner=$(sock_owner /home/vscode/.config/herdr/herdr.sock)
  before=$(pgrep -f 'herdr server' || true)
  nohup herdr server >"$ISO/server.log" 2>&1 < /dev/null &
  SERVER_PID=$!
  disown
  for _ in $(seq 1 40); do [ -S "$sock" ] && break; sleep 0.25; done
  [ -S "$sock" ] || abort "own server did not come up"

  own_owner=$(sock_owner "$sock")
  [ -n "$own_owner" ] || abort "cannot find the server owning the socket"
  [ "$own_owner" = "$SERVER_PID" ] || abort "socket is owned by pid $own_owner, not the server started here ($SERVER_PID)"
  [ "$own_owner" != "$default_owner" ] || abort "server pid equals the default server's"
  case " $(echo $before) " in *" $own_owner "*) abort "server pid was already running" ;; esac
  echo "  [PASS] own server pid $own_owner differs from the default server's (${default_owner:-none})"

  listing=$(herdr workspace list 2>&1)
  [ "$(printf '%s' "$listing" | jq -r '.result.workspaces | length' 2>/dev/null)" = "0" ] \
    || abort "own server's workspace list is not empty"
  echo "  [PASS] own server has no workspaces"
}

isolation_guard

if [ "${CHIEF_TEST_COPILOT_GUARD_ONLY:-0}" = "1" ]; then
  echo "  (guard only - copilot not run)"
  exit 0
fi
