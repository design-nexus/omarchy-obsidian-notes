#!/usr/bin/env bash
# Print one vault note as a JSON object: {"title","body","mode"}.
#   read-note.sh <vault> <relative-path>
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$here/note-lib.sh"

note_resolve "${1:-}" "${2:-}"
fallback=${NOTE_REL##*/}
fallback=${fallback%.md}
note_split "$fallback"

json_escape() {
  local s=$1
  s=$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  s=${s//$'\n'/\\n}
  printf '%s' "$s"
}

printf '{"title":"%s","body":"%s","mode":"%s"}\n' \
  "$(json_escape "$NOTE_TITLE")" \
  "$(json_escape "$NOTE_BODY")" \
  "$(json_escape "$NOTE_MODE")"
