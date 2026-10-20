#!/usr/bin/env bash
# brief.sh - helpers for updating a task's tasks/<id>/brief.md in place.

# chief_brief_strip_section <brief_file> <heading_prefix> - drops any
# existing top-level section whose heading starts with heading_prefix (from
# that heading line up to the next top-level "# " heading, or EOF). Callers
# use this before appending a fresh version of the same section, so a
# repeat update (e.g. a second relaunch) replaces what the builder is told
# instead of stacking a changelog of past notes behind it.
chief_brief_strip_section() {
  local file=$1 prefix=$2
  [ -f "$file" ] || return 0
  local tmp skip=0 line
  tmp=$(mktemp "$(dirname "$file")/.brief.XXXXXX")
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" == "$prefix"* ]]; then
      skip=1
    elif [[ "$line" == '# '* ]]; then
      skip=0
    fi
    [ "$skip" = 0 ] && printf '%s\n' "$line"
  done < "$file" > "$tmp"
  mv "$tmp" "$file"
}
