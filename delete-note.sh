#!/usr/bin/env bash
# Move a note into <vault>/.trash/, keeping its folder path.
#   delete-note.sh <vault> <relative-path>
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$here/note-lib.sh"

note_resolve "${1:-}" "${2:-}"

rel_dir=$(dirname -- "$NOTE_REL")
base=$(basename -- "$NOTE_REL")
if [[ $rel_dir == "." ]]; then
  dest_dir="$NOTE_VAULT_REAL/.trash"
  dest="$dest_dir/$base"
else
  dest_dir="$NOTE_VAULT_REAL/.trash/$rel_dir"
  dest="$dest_dir/$base"
fi
mkdir -p -- "$dest_dir"
if [[ -e $dest || -L $dest ]]; then
  stem=${base%.md}
  dest="$dest_dir/${stem}-$(date '+%Y-%m-%d-%H%M%S').md"
  counter=2
  while [[ -e $dest || -L $dest ]]; do
    dest="$dest_dir/${stem}-$(date '+%Y-%m-%d-%H%M%S')-$counter.md"
    ((counter++))
  done
fi

mv -- "$NOTE_ENTRY" "$dest"
printf 'OK\t%s\n' "${dest#"$NOTE_VAULT_REAL"/}"
