#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/iina-airplay-integrity.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT

awk '
  /BEGIN AIRPLAY PACKAGE INTEGRITY SUPPORT/ { inside = 1; next }
  /END AIRPLAY PACKAGE INTEGRITY SUPPORT/ { inside = 0; exit }
  inside { print }
' "$repo_root/iina/AppDelegate.swift" > "$temporary_directory/Integrity.swift"

if [[ ! -s "$temporary_directory/Integrity.swift" ]]; then
  echo "AirPlay integrity support markers were not found" >&2
  exit 1
fi

# Keep first-install validation wired before constructing or committing a plugin model.
if ! awk '
  /static func installIfNeeded\(\)/ { in_install = 1 }
  in_install && /packageSnapshot\.matches\(at: stagedRoot\)/ { verified = NR }
  in_install && /JavascriptPlugin\(filename: stagedRoot\.lastPathComponent\)/ {
    constructs = NR
    exit
  }
  END { if (!verified || !constructs || verified >= constructs) exit 1 }
' "$repo_root/iina/AppDelegate.swift"; then
  echo "Fresh bundled AirPlay installation must validate the staged package before loading it" >&2
  exit 1
fi

{
  printf 'import Foundation\nimport CryptoKit\nimport Darwin\n\n'
  cat "$temporary_directory/Integrity.swift"
  cat "$repo_root/other/check_airplay_package_integrity_tests.swift"
} > "$temporary_directory/main.swift"

swift "$temporary_directory/main.swift"
