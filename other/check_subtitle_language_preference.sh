#!/bin/bash
#
#  check_subtitle_language_preference.sh
#  iina
#
#  Regression check for `SubtitleLanguagePreference` and `SubtitleSelectionPlan`, the two pieces
#  that decide whether a result is in a language the user asked for and which result is loaded
#  without asking.
#
#  The *Preferred language* setting is written by a token field, so it can hold `en`, `eng`, or a
#  name; providers report `en`, a catalog code with a region (`pt-br`), a lowercase language name,
#  or a Chinese description. Treating those strings as literals silently drops a preference, and the
#  plan decides whether a subtitle is downloaded and made active with no prompt. Both live in the app
#  target, which has no test target, so this extracts them straight out of `iina/OnlineSubtitle.swift`
#  — keeping a single source of truth — compiles them with
#  `other/check_subtitle_language_preference_tests.swift`, and runs the result.
#
#  Usage:  bash other/check_subtitle_language_preference.sh
#  Exits non-zero if any check fails.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
SOURCE="$ROOT/iina/OnlineSubtitle.swift"
TESTS="$SCRIPT_DIR/check_subtitle_language_preference_tests.swift"
# The scorer precedes the language rules in the file, and the plan is written against
# `SubtitleMatchScorer.perfectMatch`, so the slice starts where the matcher check starts.
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

# The rules below only matter if the providers actually hand them a language and the chooser
# actually applies the plan, which no executable check can see from the extracted slice alone.
python3 - "$ROOT" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
online = (root / "iina/OnlineSubtitle.swift").read_text()
opensub = (root / "iina/OpenSubSubtitle.swift").read_text()
subdl = (root / "iina/SubDLSubtitle.swift").read_text()
assrt = (root / "iina/AssrtSubtitle.swift").read_text()
shooter = (root / "iina/ShooterSubtitle.swift").read_text()
chooser = (root / "iina/SubChooseViewController.swift").read_text()
player = (root / "iina/PlayerCore.swift").read_text()

assert "var languageHint: String? { nil }" in online, "the base result must report no language"
for name, source in (("OpenSubtitles", opensub), ("SubDL", subdl), ("assrt.net", assrt)):
    assert "override var languageHint" in source, f"{name} must report its result's language"

# A provider that answers a search without asking downloads every result it returned. Shooter's
# search returns up to thirty files, so it must route through the same chooser as the rest.
for name, source in (("OpenSubtitles", opensub), ("SubDL", subdl), ("assrt.net", assrt),
                     ("Shooter", shooter)):
    assert "OnlineSubtitle.resolveSelection(subs, mediaName: mediaName" in source, \
        f"{name} must let the chooser decide which result is downloaded"

assert "SubtitleSelectionPlan.decide" in chooser, "the chooser must apply the selection plan"
assert ("SubtitleLanguagePreference.rank(of: $0.languageHint, in: preferredLanguages)" in chooser), \
    "the chooser must rank each result's reported language"

cancel_start = player.index("func cancelOnlineSubtitleSearchIfNeeded()")
cancel_end = player.index("  /// For supporting mpv", cancel_start)
cancel_body = player[cancel_start:cancel_end]
assert "guard Thread.isMainThread" in cancel_body and "DispatchQueue.main.async" in cancel_body, \
    "plugin-thread Stop must marshal chooser and AppKit cancellation cleanup to the main thread"

start = opensub.index("func filterLanguageCodes()")
body = opensub[start:opensub.index("languages = filteredCodes", start)]
assert "var filteredCodes = languages.filter { supportedCodes.contains($0) }" in body, \
    "OpenSubtitles must filter using the exact supported provider codes"
assert "supportedCodes.contains(language)" not in body, \
    "a literal code comparison silently drops a preference stored in another form"

assert "SubtitleLanguagePreference.providerCodes(" in opensub, \
    "OpenSubtitles must preserve supported regional language codes"
assert "SubtitleLanguagePreference.preferred(from: Preference.string(for: .subLang))" in subdl, \
    "SubDL must search for the canonical preferred languages"

print("PASS: source guard confirms provider language, chooser, and filtering wiring")
PY

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The slice starts at the marker, so it has no imports of its own; supply one explicitly rather than
# relying on the tests file that is concatenated after it.
{
  printf 'import Foundation\n\n'
  awk -v marker="$MARKER" 'index($0, marker) { found = 1 } found { print }' "$SOURCE"
} > "$WORK/selection.swift"
if [[ ! -s "$WORK/selection.swift" ]]; then
  echo "error: '$MARKER' not found in $SOURCE" >&2
  exit 2
fi
if ! grep -q 'enum SubtitleLanguagePreference' "$WORK/selection.swift"; then
  echo "error: SubtitleLanguagePreference was not found after '$MARKER' in $SOURCE" >&2
  exit 2
fi
if ! grep -q 'struct SubtitleSelectionPlan' "$WORK/selection.swift"; then
  echo "error: SubtitleSelectionPlan was not found after '$MARKER' in $SOURCE" >&2
  exit 2
fi

# `main.swift` is the entry point, so the concatenation is what actually gets executed.
cat "$WORK/selection.swift" "$TESTS" > "$WORK/main.swift"

swiftc -O "$WORK/main.swift" -o "$WORK/check" >&2
"$WORK/check"
