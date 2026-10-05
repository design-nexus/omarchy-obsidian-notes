#!/usr/bin/env bash
# Rewrite an existing note. The file path does not change.
#   write-note.sh <vault> <relative-path> <title>
# The editor body is read from stdin.
# Frontmatter is kept. An existing title: or titulo: line is updated.
# Otherwise the first heading is written from the title.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$here/note-lib.sh"

note_resolve "${1:-}" "${2:-}"
title="${3:-}"
[[ $title != *$'\n'* && $title != *$'\r'* ]] || note_fail "Title cannot contain a newline"
title=$(note_trim "$title")
(( ${#title} <= 200 )) || note_fail "Title is too long"

fallback=${NOTE_REL##*/}
fallback=${fallback%.md}
note_split "$fallback"
note_read_stdin

if [[ $NOTE_MODE != "raw" && -z $title ]]; then
  note_fail "Add a title before saving"
fi

tmp=$(mktemp "${NOTE_VAULT_REAL}/.editing.XXXXXX")
cleanup() { rm -f -- "$tmp"; }
trap cleanup EXIT

{
  if [[ $NOTE_MODE == "raw" ]]; then
    printf '%s' "$NOTE_STDIN"
  elif [[ $NOTE_MODE == "frontmatter" ]]; then
    local_i=0
    for ((local_i = 0; local_i <= NOTE_CLOSE; local_i++)); do
      if (( local_i == NOTE_KEY_INDEX )); then
        printf '%s: %s\n' "$NOTE_TITLE_KEY" "$(note_yaml_quote "$title")"
      else
        printf '%s\n' "${NOTE_LINES[$local_i]}"
      fi
    done
    printf '%s' "$NOTE_STDIN"
  else
    if (( NOTE_HAS_FM )); then
      for ((local_i = 0; local_i <= NOTE_CLOSE; local_i++)); do
        printf '%s\n' "${NOTE_LINES[$local_i]}"
      done
    fi
    printf '# %s\n\n%s' "$title" "$NOTE_STDIN"
  fi
} > "$tmp"

mv -f -- "$tmp" "$NOTE_ENTRY"
trap - EXIT
printf 'OK\t%s\n' "$NOTE_REL"
