#!/usr/bin/env bash
# Create a timestamped Markdown note under <vault>/omarchy-notes.
set -euo pipefail

vault="${1:-}"
content="${2:-}"

if [[ -z $vault || ! -d $vault ]]; then
  printf 'Vault directory does not exist\n' >&2
  exit 2
fi

notes_dir="$vault/omarchy-notes"
mkdir -p -- "$notes_dir"

stamp="$(date '+%Y-%m-%d-%H%M%S')"
note="$notes_dir/$stamp.md"
counter=1
while [[ -e $note ]]; do
  note="$notes_dir/$stamp-$counter.md"
  ((counter++))
done

( set -o noclobber; printf '%s\n' "$content" > "$note" )
printf 'omarchy-notes/%s\n' "${note##*/}"
