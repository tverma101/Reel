#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/iina/SubtitleAudioMatcher.swift"
TEST="$ROOT/other/check_subtitle_timing_index_tests.swift"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

awk '
  /^  private struct CueTimingIndex \{/ { capturing = 1 }
  /^  private enum MatcherError/ { capturing = 0 }
  capturing { print }
' "$SOURCE" > "$TMP_DIR/index.swift"
test -s "$TMP_DIR/index.swift"

python3 - "$SOURCE" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
start = source.index("  private static func assessTiming(")
end = source.index("  private static func detectSpeech(", start)
stage = source[start:end]
assert "CueTimingIndex(cues: candidate.cues)" in stage, "timing checks must use the cue interval index"
assert "candidate.cues.contains" not in stage, "timing checks must not rescan all cues per speech segment"
assert "timingIndex.overlaps(segment, planStart: plan.start)" in stage
print("PASS: assessTiming queries the bounded interval index per speech segment")
PY

{
  cat <<'SWIFT'
import Foundation

enum SubtitleAudioMatcher {
  struct Cue {
    let start: Double
    let end: Double
    let isDialogue: Bool
  }

  struct SpeechSegment {
    let start: Double
    let end: Double
  }
SWIFT
  cat "$TMP_DIR/index.swift"
  cat <<'SWIFT'
}

extension SubtitleAudioMatcher {
  static func indexedMatchesForCheck(cues: [Cue], segments: [SpeechSegment], planStart: Double) -> [Bool] {
    let index = CueTimingIndex(cues: cues)
    return segments.map { index.overlaps($0, planStart: planStart) }
  }
}

SWIFT
  cat "$TEST"
} > "$TMP_DIR/main.swift"

swiftc -parse-as-library -O "$TMP_DIR/main.swift" -o "$TMP_DIR/subtitle-timing-index-tests"
"$TMP_DIR/subtitle-timing-index-tests"
