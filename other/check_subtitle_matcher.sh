#!/bin/bash
#
#  check_subtitle_matcher.sh
#  iina
#
#  Regression check for `SubtitleMatchScorer`.
#
#  The scorer decides whether an online subtitle is downloaded and selected without asking, so a
#  wrong score of 100 silently applies the wrong subtitle to the file being played. The scorer lives
#  in the app target, which has no test target, so this extracts the enum straight out of
#  `iina/OnlineSubtitle.swift` — keeping a single source of truth — compiles it together with
#  `other/check_subtitle_matcher_tests.swift`, and runs the result.
#
#  Usage:  bash other/check_subtitle_matcher.sh
#  Exits non-zero if any check fails.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
SOURCE="$ROOT/iina/OnlineSubtitle.swift"
TESTS="$SCRIPT_DIR/check_subtitle_matcher_tests.swift"
MARKER='// MARK: - Matching a search result against the current media'

if [[ ! -f "$SOURCE" ]]; then
  echo "error: not found: $SOURCE" >&2
  exit 2
fi
if [[ ! -f "$TESTS" ]]; then
  echo "error: not found: $TESTS" >&2
  exit 2
fi
if ! command -v swiftc >/dev/null; then
  echo "error: swiftc not found in PATH" >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The slice starts at the enum, so it has no imports of its own; supply one explicitly rather than
# relying on the tests file that is concatenated after it.
{
  printf 'import Foundation\n\n'
  awk -v marker="$MARKER" 'index($0, marker) { found = 1 } found { print }' "$SOURCE"
} > "$WORK/scorer.swift"
if [[ ! -s "$WORK/scorer.swift" ]]; then
  echo "error: '$MARKER' not found in $SOURCE" >&2
  exit 2
fi

# `main.swift` is the entry point, so the concatenation is what actually gets executed.
cat "$WORK/scorer.swift" "$TESTS" > "$WORK/main.swift"

swiftc -O "$WORK/main.swift" -o "$WORK/check" >&2
"$WORK/check"
