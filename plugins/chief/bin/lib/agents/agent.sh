#!/usr/bin/env bash
# agent.sh - loads a task's agent adapter and selects a new task's agent
# profile. Sourced after paths.sh and meta.sh.
#
# Adapter contract - each agents/<name>.sh defines all of:
#   agent_name             -> the agent's native kind and executable (herdr --kind)
#   agent_command          -> its complete default launch line: the executable,
#                             the unattended flag, ${CHIEF_AGENT_MODEL:+ --model ..}
#                             and ${CHIEF_AGENT_ARGS:+ ...} (extra args from args=)
#   agent_prepare <dir>    -> before a worker starts: pre-accept its folder trust
#   agent_release <dir>    -> undo agent_prepare for <dir> (teardown, spawn rollback)
#   agent_ready_text       -> screen text (egrep) meaning it is ready for a prompt
#   agent_paste_text       -> screen text (egrep) it shows for a long pasted prompt
#   agent_trust_text       -> screen text (egrep) of its folder-trust dialog
#   agent_trust_keys       -> keys (herdr send-keys words) that accept that dialog
#                             for a worktree Chief created; empty: never auto-accepted
#   agent_input_marker     -> the glyph (egrep) its input line starts with
# Backends run chief_agent_command: the task's command= if set, else agent_command.
#
# A task's agent, model, args and command come from its meta (chief-spawn.sh
# records them); a task without them runs claude.

. "$CHIEF_ROOT/bin/lib/lock.sh"

# --- loading ---------------------------------------------------------------

chief_agent_list() {  # the available adapter names, one per line
  local f
  for f in "$CHIEF_ROOT"/bin/lib/agents/*.sh; do basename "$f" .sh; done | grep -vx agent
}

chief_agent_load() {  # <agent> - sources the adapter
  if [[ ! $1 =~ ^[a-z0-9-]+$ ]] || [ ! -f "$CHIEF_ROOT/bin/lib/agents/$1.sh" ] || [ "$1" = agent ]; then
    echo "chief-agent: unknown agent '$1' (available: $(chief_agent_list | paste -sd' ' -))" >&2
    return 1
  fi
  # shellcheck source=/dev/null
  . "$CHIEF_ROOT/bin/lib/agents/$1.sh"
}

chief_agent_use() {  # <id> - loads the adapter recorded in the task's meta
  local agent
  agent=$(chief_meta_get "$1" agent 2>/dev/null) || agent=""
  CHIEF_AGENT_MODEL=$(chief_meta_get "$1" model 2>/dev/null) || CHIEF_AGENT_MODEL=""
  CHIEF_AGENT_ARGS=$(chief_meta_get "$1" args 2>/dev/null) || CHIEF_AGENT_ARGS=""
  CHIEF_AGENT_COMMAND=$(chief_meta_get "$1" command 2>/dev/null) || CHIEF_AGENT_COMMAND=""
  chief_agent_load "${agent:-claude}"
}

chief_agent_command() { echo "${CHIEF_AGENT_COMMAND:-$(agent_command)}"; }

agent_require() {
  local exe; exe=$(chief_agent_command); exe=${exe%% *}
  command -v "$exe" >/dev/null || { echo "chief-agent: the '$exe' CLI is not installed" >&2; return 1; }
}

# chief_agent_has_text <needle> - stdin (a screen) shows the needle or the
# agent's placeholder for a long pasted prompt
chief_agent_has_text() {
  local screen; screen=$(tr -s '[:space:]' ' ')
  printf '%s' "$screen" | grep -qF -e "$1" || printf '%s' "$screen" | grep -qE "$(agent_paste_text)"
}

# chief_agent_input_line - stdin (a screen) -> its live input line: the last
# one starting with the agent's input marker
chief_agent_input_line() { grep -E "^[[:space:]]*($(agent_input_marker))" | tail -n1; }

chief_agent_release() {  # <id> <dir> - agent_release with the task's adapter
  chief_agent_use "$1" && agent_release "$2"
}

# --- selection -------------------------------------------------------------
#
# .chief/config/agents (no file: claude):
#   strategy = first | round-robin | random | weighted | all  (default first)
#                         all (reviewer only): every entry runs, one reviewer each
#   <agent>[:<model>] [weight=N] [args="<extra CLI args>"] [command="<launch command>"]
#   [builder] [researcher] [reviewer] [brainstormer]
#                         a pool (and strategy) for that role only; each falls
#                         back to the global one. '#' starts a comment.
#
# chief_agent_select <role> [peek] sets SEL_AGENT, SEL_MODEL, SEL_ARGS,
# SEL_COMMAND and POOL_SRC (the role, global, or default when no pool is
# configured). weighted and random draw from $CHIEF_AGENT_RANDOM when it is set
# (a test hook), else from $RANDOM; random ignores weights. all takes entry
# number $CHIEF_AGENT_PICK (default 1); chief_agent_fanout lists them. peek
# advances no cursor and, for weighted, random and all, picks nothing: it sets
# SEL_POOL_DESC.

CHIEF_ROLES="builder researcher reviewer brainstormer"
SEP=$'\x1f'

chief_agent_profile() {  # <agent[:model]> - validates, sets P_AGENT and P_MODEL
  local re='^([a-z0-9-]+)(:([A-Za-z0-9._/@:+-]+))?$'
  [[ $1 =~ $re ]] || { echo "chief-agent: bad profile '$1' (want <agent>[:<model>])" >&2; return 1; }
  P_AGENT=${BASH_REMATCH[1]} P_MODEL=${BASH_REMATCH[3]:-}
}

chief_agent_words() {  # <name> <value> - args and command are plain words: no quotes or shell characters
  [[ $2 =~ ^[A-Za-z0-9._/@:=+,\ -]*$ ]] && return 0
  echo "chief-agent: $1 '$2' may only use letters, digits, spaces and . _ / @ : = + , - (no quotes or shell characters)" >&2
  return 1
}

# _chief_agent_entry <line> - prints "agent SEP model SEP weight SEP command SEP args"
_chief_agent_entry() {
  local rest=$1 weight=1 cmd="" args="" profile
  local opt='^[[:space:]]+(weight=([0-9]+)|command="([^"]*)"|args="([^"]*)")(.*)$'
  read -r profile rest <<< "$rest"
  chief_agent_profile "$profile" || return 1
  rest=" $rest"
  while [[ $rest =~ $opt ]]; do
    weight=${BASH_REMATCH[2]:-$weight} cmd=${BASH_REMATCH[3]:-$cmd} args=${BASH_REMATCH[4]:-$args}
    rest=${BASH_REMATCH[5]}
  done
  [[ $rest =~ ^[[:space:]]*(#.*)?$ ]] || { echo "chief-agent: unexpected '$rest' after '$profile'" >&2; return 1; }
  chief_agent_words args "$args" && chief_agent_words command "$cmd" || return 1
  [[ $weight =~ ^[0-9]{1,4}$ ]] && [ $((10#$weight)) -le 1000 ] || { echo "chief-agent: weight $weight must be 0 to 1000" >&2; return 1; }
  weight=$((10#$weight))
  printf '%s\n' "$P_AGENT$SEP$P_MODEL$SEP$weight$SEP$cmd$SEP$args"
}

# _chief_agent_read <role> - sets STRATEGY, POOL (one entry per line) and
# POOL_SRC from the role's section, else the global lines
_chief_agent_read() {
  local want=$1 file="$CONFIG/agents" line entry section="" n=0
  local gstrategy="" sstrategy="" gpool="" spool=""
  STRATEGY=first POOL="" POOL_SRC=default
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%$'\r'}
    read -r line <<< "$line"  # trim
    case "$line" in
      ""|"#"*) continue ;;
      "["*)
        read -r entry <<< "${line%%#*}"
        section=${entry//[][]/}
        [[ " $CHIEF_ROLES " == *" $section "* ]] \
          || { echo "chief-agent: $file:$n: unknown section $entry (${CHIEF_ROLES// /, })" >&2; return 1; } ;;
      strategy*=*)
        read -r entry <<< "${line#*=}"
        entry=${entry%%#*}; read -r entry <<< "$entry"
        case "$entry" in
          first|round-robin|random|weighted|all) ;;
          *) echo "chief-agent: $file:$n: unknown strategy '$entry'" >&2; return 1 ;;
        esac
        if [ -z "$section" ]; then gstrategy=$entry; elif [ "$section" = "$want" ]; then sstrategy=$entry; fi ;;
      *)
        entry=$(_chief_agent_entry "$line") || { echo "chief-agent: $file:$n: $line" >&2; return 1; }
        if [ -z "$section" ]; then gpool+="$entry"$'\n'; elif [ "$section" = "$want" ]; then spool+="$entry"$'\n'; fi ;;
    esac
  done < "$file"
  STRATEGY=${sstrategy:-${gstrategy:-first}}
  [ "$STRATEGY" != all ] || [ "$want" = reviewer ] \
    || { echo "chief-agent: $file: strategy all is only for the reviewer role" >&2; return 1; }
  POOL=${spool:-$gpool}
  POOL=${POOL%$'\n'}
  if [ -n "$spool" ]; then POOL_SRC=$want; elif [ -n "$gpool" ]; then POOL_SRC=global; fi
}

chief_agent_select() {  # <role> [peek]
  local section=$1 peek=${2:-} cursor rec
  SEL_AGENT=claude SEL_MODEL="" SEL_ARGS="" SEL_COMMAND="" SEL_POOL_DESC=""
  _chief_agent_read "$section" || return 1
  [ -n "$POOL" ] || return 0
  if [ -n "$peek" ] && [ "$STRATEGY" != first ] && [ "$STRATEGY" != round-robin ]; then
    SEL_POOL_DESC="$STRATEGY pool: $(awk -F"$SEP" -v w="$([ "$STRATEGY" = weighted ] && echo 1 || echo 0)" \
      '{ printf "%s%s%s%s", (NR > 1 ? ", " : ""), $1, ($2 != "" ? ":" $2 : ""), (w ? " (" $3 ")" : "") }' <<< "$POOL")"
    return 0
  fi
  case "$STRATEGY" in
    first) rec=$(head -n 1 <<< "$POOL") ;;
    all) rec=$(sed -n "${CHIEF_AGENT_PICK:-1}p" <<< "$POOL")
         [ -n "$rec" ] || { echo "chief-agent: no pool entry ${CHIEF_AGENT_PICK:-1}" >&2; return 1; } ;;
    round-robin)
      chief_lock_acquire "$STATE/.agent-select.lock" 10 || { echo "chief-agent: selection lock busy" >&2; return 1; }
      cursor=$(cat "$STATE/agent-cursor-$section" 2>/dev/null || true)
      [[ $cursor =~ ^[0-9]+$ ]] || cursor=0
      [ -n "$peek" ] || echo $((cursor + 1)) > "$STATE/agent-cursor-$section"
      chief_lock_release "$STATE/.agent-select.lock"
      rec=$(sed -n "$((cursor % $(wc -l <<< "$POOL") + 1))p" <<< "$POOL") ;;
    *)  # weighted or random: a cumulative-weight pick
      rec=$(awk -F"$SEP" -v r="${CHIEF_AGENT_RANDOM:-$((RANDOM * 32768 + RANDOM))}" -v equal="$([ "$STRATEGY" = random ] && echo 1 || echo 0)" '
        { w[NR] = equal ? 1 : $3; line[NR] = $0; total += w[NR] }
        END { if (!total) exit 1
              r %= total
              for (i = 1; i <= NR; i++) { if (r < w[i]) { print line[i]; exit } r -= w[i] } }' <<< "$POOL") \
        || { echo "chief-agent: every weight in the pool is 0" >&2; return 1; } ;;
  esac
  IFS=$SEP read -r SEL_AGENT SEL_MODEL _ SEL_COMMAND SEL_ARGS <<< "$rec"
}

chief_agent_fanout() {  # <role> - one slug (agent[-model]) per reviewer to run: the pool under all, else a single empty line
  _chief_agent_read "$1" || return 1
  if [ "$STRATEGY" != all ] || [ -z "$POOL" ]; then echo ""; return 0; fi
  awk -F"$SEP" '{ s = tolower($1 ($2 != "" ? "-" $2 : "")); gsub(/[^a-z0-9]+/, "-", s); print s }' <<< "$POOL"
}

chief_agent_note() {  # after chief_agent_select - the marker for a pool that is not the role's own
  case "$POOL_SRC" in
    global) echo "(global fallback)" ;;
    default) echo "(no pool configured)" ;;
  esac
}

chief_agent_describe() {  # after chief_agent_select - "agent[:model]" (or the pool) plus the marker
  local d=${SEL_POOL_DESC:-$SEL_AGENT${SEL_MODEL:+:$SEL_MODEL}} note
  note=$(chief_agent_note)
  echo "$d${note:+ $note}"
}
