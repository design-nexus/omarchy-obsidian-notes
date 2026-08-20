#!/usr/bin/env bash
# Search notes inside an Obsidian vault and print a JSON array of matches.
#
#   search.sh <vault-root> [query...]
#
# With no query, every note is listed, newest modified first. With a query,
# title/path matches rank ahead of full-text matches. Everything is read-only:
# only the filesystem is touched, never Obsidian itself. JSON is built by hand
# so there are no dependencies beyond coreutils, grep and (optionally) rg.
set -uo pipefail

vault="${1:-}"
shift || true
query="${*:-}"

if [[ -z $vault || ! -d $vault ]]; then
  printf '[]\n'
  exit 0
fi

limit=40

# Escape a string for safe embedding inside a JSON string literal.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//[[:cntrl:]]/}"
  printf '%s' "$s"
}

# Emit one JSON object. Rel path, title and snippet are escaped; modified is a
# raw epoch number.
emit() {
  local path title mtime snippet
  path="$(json_escape "$1")"
  title="$(json_escape "$2")"
  mtime="${3:-0}"
  mtime=$((10#$mtime))
  snippet="$(json_escape "$4")"
  printf '{"path":"%s","title":"%s","modified":%s,"snippet":"%s"}' \
    "$path" "$title" "$mtime" "$snippet"
}

# Title of a note: the `title:` field in its YAML frontmatter, else the first
# H1/H2 heading, else the file name. Frontmatter is only read when the file
# actually starts with a `---` fence.
title_of() {
  local note="$1" title=""
  title="$(awk '
    NR == 1 { if ($0 != "---") exit }
    NR > 1 && /^---$/ { exit }
    /^(title|titulo):[[:space:]]*/ {
      sub(/^(title|titulo):[[:space:]]*/, "")
      sub(/^"/, ""); sub(/"$/, "")
      sub(/^'"'"'/, ""); sub(/'"'"'$/, "")
      print; exit
    }
  ' "$note" 2>/dev/null)"
  if [[ -z $title ]]; then
    title="$(sed -n 's/^#[[:space:]]*\(.*\)$/\1/p' "$note" | head -n 1)"
  fi
  if [[ -z $title ]]; then
    title="$(basename "$note" .md)"
  fi
  printf '%s' "$title"
}

# First matching line of a note for a query, trimmed to a snippet width. The
# YAML frontmatter is stripped first so snippets come from the prose, not from
# metadata keys the user typed.
first_match() {
  local note="$1" q="$2" line=""
  local body
  body="$(awk '
    NR == 1 && $0 == "---" { in_fm = 1; next }
    in_fm && /^---$/ { in_fm = 0; next }
    !in_fm
  ' "$note" 2>/dev/null)"
  if command -v rg >/dev/null 2>&1; then
    line="$(rg -i -F --no-messages -m1 -N "$q" <<<"$body" 2>/dev/null)"
  else
    line="$(grep -i -F -m1 "$q" <<<"$body" 2>/dev/null)"
  fi
  line="$(sed 's/^[[:space:]]*#\{1,6\}[[:space:]]*//' <<<"$line")"
  line="$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<<"$line")"
  if [[ ${#line} -gt 120 ]]; then
    printf '%s...' "${line:0:117}"
  else
    printf '%s' "$line"
  fi
}

# Rel path and mtime for every note under the vault.
notes=()
while IFS= read -r -d '' f; do
  rel="${f#"$vault"/}"
  mtime="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
  notes+=("$rel" "$mtime")
done < <(find "$vault" -name '*.md' \
  -not -path '*/.obsidian/*' -not -path '*/.trash/*' -not -path '*/.git/*' \
  -print0 2>/dev/null)

q_lower="$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]')"
declare -a title_rows=() content_rows=()

for ((i = 0; i < ${#notes[@]}; i += 2)); do
  rel="${notes[$i]}"
  mtime="${notes[$((i + 1))]}"
  note="$vault/$rel"
  title="$(title_of "$note")"

  if [[ -n $query ]]; then
    t_lower="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')"
    p_lower="$(printf '%s' "$rel" | tr '[:upper:]' '[:lower:]')"
    if [[ $t_lower == *"$q_lower"* || $p_lower == *"$q_lower"* ]]; then
      title_rows+=("$rel" "$title" "$mtime")
    elif [[ -n $query ]] && grep -qiF -- "$query" "$note" 2>/dev/null; then
      content_rows+=("$rel" "$title" "$mtime")
    fi
  else
    title_rows+=("$rel" "$title" "$mtime")
  fi
done

# Rank newest-first within each group, titles ahead of content hits.
ranked() {
  local list=("$@") rel mtime
  for ((i = 0; i < ${#list[@]}; i += 3)); do
    rel="${list[$i]}"
    mtime="${list[$((i + 2))]}"
    printf '%012d\t%s\n' "$mtime" "$rel"
  done | sort -r
}

first=1
emit_group() {
  local list=("$@") rel title snippet count=0 line mtime
  while IFS=$'\t' read -r mtime rel; do
    [[ -n $rel ]] || continue
    ((count++))
    ((count > limit)) && break
    if [[ -n $query ]]; then
      note="$vault/$rel"
      title="$(title_of "$note")"
      snippet="$(first_match "$note" "$query")"
    else
      title="$(title_of "$vault/$rel")"
      snippet=""
    fi
    ((first)) || printf ','
    first=0
    emit "$rel" "$title" "$mtime" "$snippet"
  done < <(ranked "${list[@]}")
}

printf '['
emit_group "${title_rows[@]}"
emit_group "${content_rows[@]}"
printf ']\n'
