#!/usr/bin/env bash
# Shared path checks and note splitting for the Obsidian notes plugin.
# Sourced by the helpers. A note must be a real Markdown file inside the vault.

note_fail() {
  printf 'ERR\t%s\n' "$1"
  exit 2
}

note_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

note_yaml_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

note_resolve() {
  local vault="$1" rel="$2" part vault_real entry entry_real bytes
  [[ -n $vault && -d $vault ]] || note_fail "Vault directory does not exist"
  [[ -n $rel && $rel == *.md && $rel != /* ]] || note_fail "Note path must be a markdown file inside the vault"
  local IFS=/
  for part in $rel; do
    [[ -n $part && $part != "." && $part != ".." ]] || note_fail "Note path must stay inside the vault"
  done
  unset IFS
  vault_real=$(realpath -e -- "$vault") || note_fail "Vault directory does not exist"
  entry="$vault_real/$rel"
  [[ -L $entry ]] && note_fail "Refusing to change a symlink"
  [[ -f $entry ]] || note_fail "Note does not exist"
  entry_real=$(realpath -e -- "$entry") || note_fail "Note does not exist"
  case $entry_real in
    "$vault_real"/*) ;;
    *) note_fail "Note path must stay inside the vault" ;;
  esac
  bytes=$(stat -c '%s' -- "$entry")
  (( bytes <= 262144 )) || note_fail "Note is too large to edit here"
  NOTE_VAULT_REAL=$vault_real
  NOTE_ENTRY=$entry
  NOTE_REL=$rel
}

# Sets NOTE_MODE, NOTE_TITLE, NOTE_BODY, NOTE_HAS_FM, NOTE_CLOSE, NOTE_KEY_INDEX, NOTE_TITLE_KEY.
# Modes: frontmatter, heading, plain, raw.
note_split() {
  local fallback="$1"
  NOTE_LINES=()
  mapfile -t NOTE_LINES < "$NOTE_ENTRY"
  NOTE_MODE="plain"
  NOTE_TITLE=$fallback
  NOTE_HAS_FM=0
  NOTE_CLOSE=-1
  NOTE_KEY_INDEX=-1
  NOTE_TITLE_KEY="title"
  local i line close=-1 body_start=0 val

  if (( ${#NOTE_LINES[@]} > 0 )) && [[ ${NOTE_LINES[0]} == "---" ]]; then
    for ((i = 1; i < ${#NOTE_LINES[@]}; i++)); do
      if [[ ${NOTE_LINES[$i]} == "---" ]]; then
        close=$i
        break
      fi
    done
    if (( close < 0 )); then
      NOTE_MODE="raw"
      NOTE_TITLE=$fallback
      body_start=0
    else
      NOTE_HAS_FM=1
      NOTE_CLOSE=$close
      for ((i = 1; i < close; i++)); do
        line=${NOTE_LINES[$i]}
        if [[ $line =~ ^(title|titulo):[[:space:]]*(.*)$ ]]; then
          NOTE_KEY_INDEX=$i
          NOTE_TITLE_KEY=${BASH_REMATCH[1]}
          val=$(note_trim "${BASH_REMATCH[2]}")
          if [[ ${#val} -ge 2 && ${val:0:1} == '"' && ${val: -1} == '"' ]]; then
            val=${val:1:$((${#val} - 2))}
            val=${val//\\\"/\"}
            val=${val//\\\\/\\}
          elif [[ ${#val} -ge 2 && ${val:0:1} == "'" && ${val: -1} == "'" ]]; then
            val=${val:1:$((${#val} - 2))}
          fi
          NOTE_TITLE=$val
          NOTE_MODE="frontmatter"
          break
        fi
      done
      body_start=$((close + 1))
      if [[ $NOTE_MODE != "frontmatter" ]]; then
        local after_fm=$body_start
        for ((i = body_start; i < ${#NOTE_LINES[@]}; i++)); do
          line=${NOTE_LINES[$i]}
          if [[ $line =~ ^#[[:space:]]+(.*)$ ]]; then
            NOTE_TITLE=$(note_trim "${BASH_REMATCH[1]}")
            body_start=$((i + 1))
            if (( body_start < ${#NOTE_LINES[@]} )) && [[ -z ${NOTE_LINES[$body_start]} ]]; then
              body_start=$((body_start + 1))
            fi
            NOTE_MODE="heading"
            break
          fi
          [[ -n $line ]] && break
        done
        if [[ $NOTE_MODE != "heading" ]]; then
          NOTE_MODE="plain"
          NOTE_TITLE=$fallback
          body_start=$after_fm
        fi
      fi
    fi
  else
    for ((i = 0; i < ${#NOTE_LINES[@]}; i++)); do
      line=${NOTE_LINES[$i]}
      if [[ $line =~ ^#[[:space:]]+(.*)$ ]]; then
        NOTE_TITLE=$(note_trim "${BASH_REMATCH[1]}")
        body_start=$((i + 1))
        if (( body_start < ${#NOTE_LINES[@]} )) && [[ -z ${NOTE_LINES[$body_start]} ]]; then
          body_start=$((body_start + 1))
        fi
        NOTE_MODE="heading"
        break
      fi
      [[ -n $line ]] && break
    done
  fi

  if (( body_start >= ${#NOTE_LINES[@]} )); then
    NOTE_BODY=""
  else
    NOTE_BODY=$(printf '%s\n' "${NOTE_LINES[@]:body_start}")
    NOTE_BODY=${NOTE_BODY%$'\n'}
  fi
}

note_read_stdin() {
  local tmp bytes
  tmp=$(mktemp)
  head -c 262145 > "$tmp"
  bytes=$(stat -c '%s' -- "$tmp")
  if (( bytes > 262144 )); then
    rm -f -- "$tmp"
    note_fail "Note is too large"
  fi
  NOTE_STDIN=$(cat "$tmp"; printf x)
  NOTE_STDIN=${NOTE_STDIN%x}
  rm -f -- "$tmp"
  if [[ -n $NOTE_STDIN && $NOTE_STDIN != *$'\n' ]]; then
    NOTE_STDIN+=$'\n'
  fi
}
