#!/usr/bin/env bash
# id.sh - the task-id rules. Sourced by scripts that already sourced paths.sh and meta.sh.

CHIEF_ID_MAX=32  # herdr's agent-name limit; Orca has none, so one rule for both

# chief_id_check <id> - fails, suggesting a valid id, unless <id> is lowercase
# letters, digits and -, starts with a letter and fits CHIEF_ID_MAX.
chief_id_check() {
  [[ $1 =~ ^[a-z][a-z0-9-]*$ ]] && [ "${#1}" -le "$CHIEF_ID_MAX" ] && return 0
  echo "invalid task id '$1': lowercase letters, digits and -, starting with a letter, at most $CHIEF_ID_MAX chars (try '$(chief_id_compose "$1")')" >&2
  return 1
}

# chief_id_compose <base> [suffix] -> <base>-<suffix> as a valid id: the base
# cut by whole words to fit, -2, -3... while a task with that id exists. The
# suffix is capped at 16 chars so the base always keeps room.
chief_id_compose() {
  local base suffix tail id n=1
  base=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/-/g; s/^[^a-z]+//; s/-+$//')
  suffix=$(printf '%s' "${2:-}" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  suffix=$(printf '%s' "${suffix:0:16}" | sed -E 's/-+$//')
  while :; do
    tail=${suffix:+-$suffix}; [ "$n" = 1 ] || tail+="-$n"
    id=${base:-t}
    while [ $(( ${#id} + ${#tail} )) -gt "$CHIEF_ID_MAX" ]; do
      case $id in *-*) id=${id%-*} ;; *) id=${id:0:$(( CHIEF_ID_MAX - ${#tail} ))} ;; esac
    done
    id+=$tail
    chief_meta_exists "$id" || { printf '%s\n' "$id"; return; }
    n=$((n + 1))
  done
}
