#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/check_airplay_package_integrity_archive.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/first/bin" "$WORK/second/bin"
printf 'manifest\n' > "$WORK/first/Info.json"
printf 'helper\n' > "$WORK/first/bin/airplay-helper"
printf 'ui\n' > "$WORK/first/main.js"
printf 'ui\n' > "$WORK/second/main.js"
printf 'helper\n' > "$WORK/second/bin/airplay-helper"
printf 'manifest\n' > "$WORK/second/Info.json"
chmod 644 "$WORK/first/Info.json" "$WORK/first/main.js" \
  "$WORK/second/Info.json" "$WORK/second/main.js"
chmod 755 "$WORK/first/bin/airplay-helper" "$WORK/second/bin/airplay-helper"
touch -t 202410101010 "$WORK/first/Info.json" "$WORK/first/main.js" \
  "$WORK/first/bin/airplay-helper"
touch -t 202610101010 "$WORK/second/Info.json" "$WORK/second/main.js" \
  "$WORK/second/bin/airplay-helper"

airplay_create_deterministic_archive "$WORK/first" "$WORK/first.zip" "$WORK/first.entries"
airplay_create_deterministic_archive "$WORK/second" "$WORK/second.zip" "$WORK/second.entries"
cmp "$WORK/first.zip" "$WORK/second.zip"
cmp "$WORK/first.entries" "$WORK/second.entries"
unzip -tq "$WORK/first.zip"
unzip -Z1 "$WORK/first.zip" | cmp - "$WORK/first.entries"
mkdir "$WORK/extracted"
unzip -q "$WORK/first.zip" -d "$WORK/extracted"
diff -r "$WORK/first" "$WORK/extracted"
echo "AirPlay package archive determinism/integrity check passed."
