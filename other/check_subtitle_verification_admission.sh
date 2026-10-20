#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/iina/SubtitleAudioMatcher.swift"
TEST="$ROOT/other/check_subtitle_verification_admission_tests.swift"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

awk '
  /^final class SubtitleVADWorkGate([: ]|[{])/ { capturing = 1 }
  /^enum SubtitleAudioMatcher \{/ { capturing = 0 }
  capturing { print }
' "$SOURCE" > "$TMP_DIR/gate.swift"
test -s "$TMP_DIR/gate.swift"

python3 - "$SOURCE" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
start = source.index("static func verify(mediaURL: URL,")
end = source.index("private struct DownloadedCandidate", start)
verify = source[start:end]
acquire = verify.index("verificationWorkGate.tryAcquire()")
download = verify.index("downloadCandidates(")
assert acquire < download, "admission must precede subtitle download, parsing, and audio decoding"
busy = verify[verify.index("guard let permit = verificationWorkGate.tryAcquire()"):
              verify.index("guard !cancellation.isCancelled else {\n      permit.release()")]
assert "audioMatchStatus = .unverified" in busy, "busy verification must preserve usable results as unverified"
assert "return .value(())" in busy, "busy verification must return without queuing retained work"
assert "return verification.ensure {\n      permit.release()\n    }" in verify, "the session permit must be released after success or failure"
assert verify.index("!cancellation.isCancelled") < acquire, "pre-cancelled work must not acquire a permit"
print("PASS: source guard confirms admission precedes retained work and release covers both outcomes")
PY

cat "$TMP_DIR/gate.swift" "$TEST" > "$TMP_DIR/main.swift"
swiftc -parse-as-library "$TMP_DIR/main.swift" -o "$TMP_DIR/subtitle-verification-admission-tests"
"$TMP_DIR/subtitle-verification-admission-tests"
