#!/usr/bin/env bash

# Shared helpers for deterministic AirPlay package archives. ZIP's DOS time
# format starts at 1980-01-01; pin every file to that timestamp and sort the
# explicit file list before handing it to Info-ZIP.
AIRPLAY_ARCHIVE_MTIME="198001010000"

airplay_require_regular_file() {
  local path="$1" label="${2:-$1}"
  if [ ! -f "$path" ] || [ -L "$path" ]; then
    echo "Required regular file is missing or is a symlink: $label" >&2
    return 1
  fi
}

airplay_sha256_file() {
  local path="$1"
  airplay_require_regular_file "$path" || return
  shasum -a 256 "$path" | awk '{ print $1 }'
}

airplay_assert_sha256() {
  local path="$1" expected="$2" label="${3:-$1}" actual
  if [[ ! "$expected" =~ ^[[:xdigit:]]{64}$ ]]; then
    echo "Expected SHA-256 is malformed for $label" >&2
    return 1
  fi
  actual="$(airplay_sha256_file "$path")" || return
  if [ "$actual" != "$expected" ]; then
    echo "SHA-256 mismatch for $label: expected $expected, got $actual" >&2
    return 1
  fi
}

airplay_assert_files_equal() {
  local expected_file="$1" actual_file="$2" label="${3:-$2}"
  airplay_require_regular_file "$expected_file" "reference for $label" || return
  airplay_require_regular_file "$actual_file" "$label" || return
  if ! cmp -s "$expected_file" "$actual_file"; then
    echo "File contents do not match for $label" >&2
    return 1
  fi
}

airplay_assert_archive_entry_matches_file() {
  local archive="$1" entry="$2" expected_file="$3" label="${4:-$2}"
  airplay_require_regular_file "$archive" "archive for $label" || return
  airplay_require_regular_file "$expected_file" "reference for $label" || return
  case "$entry" in
    ""|/*|../*|*/../*|*/..|..|*\\*)
      echo "Refusing unsafe archive entry path for $label: $entry" >&2
      return 1
      ;;
  esac
  if ! unzip -Z1 "$archive" | awk -v expected="$entry" '$0 == expected { count++ } END { exit count == 1 ? 0 : 1 }'; then
    echo "Expected exactly one archive entry for $label: $entry" >&2
    return 1
  fi
  if ! (set -o pipefail; unzip -p "$archive" "$entry" | cmp -s "$expected_file" -); then
    echo "Archive entry does not match its staged file: $label" >&2
    return 1
  fi
}

airplay_normalize_archive_tree() {
  local tree="$1"
  [ -d "$tree" ] || { echo "Archive input is not a directory: $tree" >&2; return 1; }

  local symlink
  symlink="$(find "$tree" -type l -print -quit)"
  if [ -n "$symlink" ]; then
    echo "Refusing to package symlink: $symlink" >&2
    return 1
  fi
  TZ=UTC find "$tree" -type f -exec touch -t "$AIRPLAY_ARCHIVE_MTIME" {} +
  while IFS= read -r -d '' file; do
    if [ -x "$file" ]; then
      chmod 755 "$file"
    else
      chmod 644 "$file"
    fi
  done < <(find "$tree" -type f -print0)
}

airplay_write_archive_entries() {
  local tree="$1" entries="$2"
  (
    cd "$tree"
    find . -type f -print | sed 's#^./##' | LC_ALL=C sort > "$entries"
  )
}

airplay_create_deterministic_archive() {
  local tree="$1" archive="$2" entries="$3"
  airplay_normalize_archive_tree "$tree"
  airplay_write_archive_entries "$tree" "$entries"
  (
    cd "$tree"
    TZ=UTC zip -q -X -D -9 "$archive" -@ < "$entries"
  )
}
