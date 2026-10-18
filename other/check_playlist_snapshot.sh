#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/iina-playlist-snapshot.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT
cat iina/Regex.swift iina/MPVPlaylistItem.swift other/check_playlist_snapshot_tests.swift > "$temporary_directory/main.swift"
swift "$temporary_directory/main.swift"
