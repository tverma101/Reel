#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
SOURCE="$ROOT/iina/SubtitleAudioMatcher.swift"
TESTS="$SCRIPT_DIR/check_subtitle_audio_parser_tests.swift"
MARKER='  private enum SubtitleCueParser {'

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

{
  cat <<'SWIFT'
import Foundation

enum SubtitleAudioMatcher {
  static let maxSubtitleBytes = 32 * 1024 * 1024

  struct Cue {
    let start: Double
    let end: Double
    let text: String
  }
SWIFT
  awk -v marker="$MARKER" 'index($0, marker) { found = 1 } found { print }' "$SOURCE" | sed '$d'
  printf '}\n'
  cat <<'SWIFT'

extension SubtitleAudioMatcher {
  static func parseForCheck(fileURL: URL) -> [Cue]? {
    SubtitleCueParser.parse(fileURL: fileURL)
  }
}

SWIFT
  cat "$TESTS"
} > "$WORK/main.swift"

swiftc -parse-as-library -O "$WORK/main.swift" -o "$WORK/check"
CHECK_FIXTURE_DIR="$WORK" "$WORK/check"
