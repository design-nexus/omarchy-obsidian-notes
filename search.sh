#!/usr/bin/env bash
# Search notes inside an Obsidian vault and print a JSON array of matches.
#
#   search.sh <vault-root> [query...]
#
# With no query, every note is listed, newest modified first. With a query,
# title/path matches rank ahead of full-text matches. Everything is read-only:
# only the filesystem is touched, never Obsidian itself. JSON is built by hand
# so there are no dependencies beyond coreutils, grep and (optionally) rg.
#
# Hardening: bounded enumeration (file count via MAX_FILES, file size via
# find -size and gawk head limit), bounded per-file I/O (head -n 80 for
# titles, head -c MAX_SNIPPET_BYTES for snippets, no shell variable ever
# holds a complete note body), truncated query/title lengths, and a
# whole-operation deadline via SECONDS plus a hard find(1) timeout. The
# helper always prints a valid JSON array even when the budget is exhausted
# (partial results) and the QML caller kills the helper after its own
# deadline, so a large or adversarially growing Markdown file cannot drive
# unbounded helper memory/time while the search Process remains running.
set -uo pipefail
vault="${1:-}"
shift || true
query="${*:-}"
if [[ -z $vault || ! -d $vault ]]; then printf '[]\n'; exit 0; fi
limit=40
MAX_FILES=2500
MAX_SNIPPET_BYTES=$((64 * 1024))
MAX_QUERY_LEN=120
MAX_TITLE_LEN=200
SEARCH_TIMEOUT_SECS=4
FIND_TIMEOUT_SECS=2
query="${query:0:$MAX_QUERY_LEN}"
deadline=$((SECONDS + SEARCH_TIMEOUT_SECS))
timed_out() { (( SECONDS >= deadline )); }
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
emit() {
  local path title mtime snippet
  path="$(json_escape "$1")"
  title="$(json_escape "$2")"
  mtime="${3:-0}"
  mtime=$((10#$mtime))
  snippet="$(json_escape "$4")"
  printf '{"path":"%s","title":"%s","modified":%s,"snippet":"%s"}' "$path" "$title" "$mtime" "$snippet"
}
first_match() {
  local note="$1" q="$2" line=""
  if command -v rg >/dev/null 2>&1; then
    line="$(awk '
      NR == 1 && $0 == "---" { in_fm = 1; next }
      in_fm && /^---$/ { in_fm = 0; next }
      !in_fm
    ' "$note" 2>/dev/null | head -c "$MAX_SNIPPET_BYTES" | LC_ALL=C rg -i -F --no-messages -m1 -N -- "$q" 2>/dev/null || true)"
  else
    line="$(awk '
      NR == 1 && $0 == "---" { in_fm = 1; next }
      in_fm && /^---$/ { in_fm = 0; next }
      !in_fm
    ' "$note" 2>/dev/null | head -c "$MAX_SNIPPET_BYTES" | LC_ALL=C grep -i -F -m1 -- "$q" 2>/dev/null || true)"
  fi
  line="$(printf '%s' "$line" | sed 's/^[[:space:]]*#\{1,6\}[[:space:]]*//' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  if (( ${#line} > 120 )); then printf '%s...' "${line:0:117}"; else printf '%s' "$line"; fi
}
# Bulk enumeration + title extraction: single find|gawk pipeline, bounded by
# file size, count and hard timeout. Avoids per-file fork for title.
bulk_notes() {
  local out
  if command -v timeout >/dev/null 2>&1; then
    timeout "${FIND_TIMEOUT_SECS}s" find "$vault" -type f -name '*.md' -size -512k \
      -not -path '*/.obsidian/*' -not -path '*/.trash/*' -not -path '*/.git/*' \
      -printf '%T@|%p\n' 2>/dev/null | timeout "${FIND_TIMEOUT_SECS}s" gawk -F'|' -v vault="$vault" -v max_title_len="$MAX_TITLE_LEN" '
      {
        mtime=$1; path=$2;
        rel=substr(path, length(vault)+2);
        if (rel=="") rel=path;
        title=""; found=""; heading=""; in_fm=0; n=0;
        while ((getline line < path) >0) {
          n++;
          if (n>80) break;
          if (n==1 && line=="---") { in_fm=1; continue; }
          if (in_fm) {
            if (line=="---") { in_fm=0; continue; }
            if (line ~ /^(title|titulo):[ \t]*/) {
              sub(/^(title|titulo):[ \t]*/, "", line);
              gsub(/^["\x27]/, "", line); gsub(/["\x27]$/, "", line);
              gsub(/^[ \t]+|[ \t]+$/, "", line);
              if (line!="") found=line;
            }
            continue;
          }
          if (line ~ /^#[ \t]/) {
            sub(/^#[ \t]*/, "", line);
            gsub(/^[ \t]+|[ \t]+$/, "", line);
            if (heading=="") heading=line;
          }
        }
        close(path);
        if (found!="") title=found;
        else if (heading!="") title=heading;
        else {
          nn=split(path, parts, "/");
          title=parts[nn];
          sub(/\.md$/, "", title);
        }
        if (length(title)>max_title_len) title=substr(title,1,max_title_len-3)"...";
        mtime_int=int(mtime);
        printf "%s\t%d\t%s\n", rel, mtime_int, title;
      }' 2>/dev/null | head -n "$MAX_FILES" || true
  else
    find "$vault" -type f -name '*.md' -size -512k \
      -not -path '*/.obsidian/*' -not -path '*/.trash/*' -not -path '*/.git/*' \
      -printf '%T@|%p\n' 2>/dev/null | gawk -F'|' -v vault="$vault" -v max_title_len="$MAX_TITLE_LEN" '
      {
        mtime=$1; path=$2;
        rel=substr(path, length(vault)+2);
        if (rel=="") rel=path;
        title=""; found=""; heading=""; in_fm=0; n=0;
        while ((getline line < path) >0) {
          n++;
          if (n>80) break;
          if (n==1 && line=="---") { in_fm=1; continue; }
          if (in_fm) {
            if (line=="---") { in_fm=0; continue; }
            if (line ~ /^(title|titulo):[ \t]*/) {
              sub(/^(title|titulo):[ \t]*/, "", line);
              gsub(/^["\x27]/, "", line); gsub(/["\x27]$/, "", line);
              gsub(/^[ \t]+|[ \t]+$/, "", line);
              if (line!="") found=line;
            }
            continue;
          }
          if (line ~ /^#[ \t]/) {
            sub(/^#[ \t]*/, "", line);
            gsub(/^[ \t]+|[ \t]+$/, "", line);
            if (heading=="") heading=line;
          }
        }
        close(path);
        if (found!="") title=found;
        else if (heading!="") title=heading;
        else {
          nn=split(path, parts, "/");
          title=parts[nn];
          sub(/\.md$/, "", title);
        }
        if (length(title)>max_title_len) title=substr(title,1,max_title_len-3)"...";
        mtime_int=int(mtime);
        printf "%s\t%d\t%s\n", rel, mtime_int, title;
      }' 2>/dev/null | head -n "$MAX_FILES" || true
  fi
}
# Collect all notes with titles, bounded
declare -a all_rels=() all_mtimes=() all_titles=()
while IFS=$'\t' read -r rel mtime title; do
  timed_out && break
  [[ -z $rel ]] && continue
  all_rels+=("$rel")
  all_mtimes+=("$mtime")
  all_titles+=("$title")
done < <(bulk_notes)

q_lower="${query,,}"
declare -a title_hits_rels=() title_hits_mtimes=() title_hits_titles=()
declare -a content_hits_rels=() content_hits_mtimes=() content_hits_titles=()
declare -A content_set=()
if [[ -n $query ]]; then
  if command -v rg >/dev/null 2>&1; then
    while IFS= read -r f; do
      [[ -z $f ]] && continue
      rel="${f#"$vault"/}"
      [[ -z $rel ]] && continue
      content_set["$rel"]=1
    done < <(timeout 2s rg -l -i -F --no-messages --type md --glob '!/.obsidian/*' --glob '!/.trash/*' --glob '!/.git/*' -- "$query" "$vault" 2>/dev/null | head -n "$MAX_FILES" || true)
  else
    while IFS= read -r f; do
      [[ -z $f ]] && continue
      rel="${f#"$vault"/}"
      [[ -z $rel ]] && continue
      content_set["$rel"]=1
    done < <(timeout 2s grep -R -l -i -F --include='*.md' --exclude-dir=.obsidian --exclude-dir=.trash --exclude-dir=.git -- "$query" "$vault" 2>/dev/null | head -n "$MAX_FILES" || true)
  fi
fi
if [[ -z $query ]]; then
  for ((i=0; i<${#all_rels[@]}; i++)); do
    timed_out && break
    title_hits_rels+=("${all_rels[$i]}")
    title_hits_mtimes+=("${all_mtimes[$i]}")
    title_hits_titles+=("${all_titles[$i]}")
  done
else
  for ((i=0; i<${#all_rels[@]}; i++)); do
    timed_out && break
    rel="${all_rels[$i]}"
    mtime="${all_mtimes[$i]}"
    title="${all_titles[$i]}"
    p_lower="${rel,,}"
    if [[ $p_lower == *"$q_lower"* ]]; then
      title_hits_rels+=("$rel"); title_hits_mtimes+=("$mtime"); title_hits_titles+=("$title")
      continue
    fi
    t_lower="${title,,}"
    if [[ $t_lower == *"$q_lower"* ]]; then
      title_hits_rels+=("$rel"); title_hits_mtimes+=("$mtime"); title_hits_titles+=("$title")
    elif [[ -n ${content_set["$rel"]:-} ]]; then
      content_hits_rels+=("$rel"); content_hits_mtimes+=("$mtime"); content_hits_titles+=("$title")
    fi
  done
fi
ranked_with_titles() {
  local -n _rels=$1; local -n _mtimes=$2; local -n _titles=$3
  local n=${#_rels[@]}
  for ((i=0; i<n; i++)); do
    printf '%012d\t%s\t%s\n' "${_mtimes[$i]}" "${_rels[$i]}" "${_titles[$i]}"
  done | sort -r
}
first=1
emit_group_with_titles() {
  local -n _r=$1; local -n _m=$2; local -n _t=$3
  local count=0
  # ranked output is sorted, need to parse
  while IFS=$'\t' read -r mtime rel title; do
    [[ -z $rel ]] && continue
    ((count++))
    ((count > limit)) && break
    if timed_out && ((count > 5)); then break; fi
    snippet=""
    if [[ -n $query ]]; then
      snippet="$(first_match "$vault/$rel" "$query")"
    fi
    ((first)) || printf ','
    first=0
    emit "$rel" "$title" "$mtime" "$snippet"
  done < <(ranked_with_titles _r _m _t)
}
printf '['
if (( ${#title_hits_rels[@]} )); then
  emit_group_with_titles title_hits_rels title_hits_mtimes title_hits_titles
fi
if ! timed_out && (( ${#content_hits_rels[@]} )); then
  emit_group_with_titles content_hits_rels content_hits_mtimes content_hits_titles
fi
printf ']\n'
