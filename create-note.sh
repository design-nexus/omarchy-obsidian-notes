#!/usr/bin/env bash
# Create a Markdown note under <vault>/Notes.
#   create-note.sh <vault> <title>
# The body is read from stdin. An empty title uses a timestamp filename and
# no heading. A title becomes the slug and the first heading.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$here/note-lib.sh"

vault="${1:-}"
title="${2:-}"

[[ -n $vault && -d $vault ]] || note_fail "Vault directory does not exist"
[[ $title != *$'\n'* && $title != *$'\r'* ]] || note_fail "Title cannot contain a newline"
title=$(note_trim "$title")
(( ${#title} <= 200 )) || note_fail "Title is too long"

note_read_stdin

notes_dir="$vault/Notes"
mkdir -p -- "$notes_dir"

slug=""
if [[ -n $title ]]; then
  slug=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  slug=${slug:0:80}
  slug=${slug%-}
fi
if [[ -z $slug ]]; then
  slug=$(date '+%Y-%m-%d-%H%M%S')
fi

note="$notes_dir/$slug.md"
counter=2
while [[ -e $note || -L $note ]]; do
  note="$notes_dir/$slug-$counter.md"
  ((counter++))
done

tmp=$(mktemp "$notes_dir/.creating.XXXXXX")
cleanup() { rm -f -- "$tmp"; }
trap cleanup EXIT

{
  if [[ -n $title ]]; then
    printf '# %s\n\n' "$title"
  fi
  printf '%s' "$NOTE_STDIN"
} > "$tmp"

mv -n -- "$tmp" "$note" || note_fail "Could not create the note"
trap - EXIT
printf 'OK\tNotes/%s\n' "${note##*/}"
