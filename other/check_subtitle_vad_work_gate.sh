#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/iina/SubtitleAudioMatcher.swift"
TEST="$ROOT/other/check_subtitle_vad_work_gate_tests.swift"
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
start = source.index("assessmentPromise = ensureModel(vadModel, cancellation: cancellation)")
end = source.index("}.recover { error -> Promise<VADAssessment>", start)
stage = source[start:end]
acquire = stage.index("vadWorkGate.tryAcquire()")
dispatch = stage.index("return onWorker")
assert acquire < dispatch, "VAD admission must precede worker creation/dispatch"
assert "return .value(VADAssessment(timingMatches: []))" in stage, "contention must use the bounded VAD fallback"
assert "defer { permit.release() }" in stage, "every settled worker must retire its permit"
assert stage.index("subtitleCancellableWork") < stage.index("assessTiming("), "queued workers must check cancellation before VAD"
print("PASS: source guard confirms admission precedes dispatch and worker cleanup is unconditional")
PY

cat "$TMP_DIR/gate.swift" "$TEST" > "$TMP_DIR/main.swift"
swiftc -parse-as-library "$TMP_DIR/main.swift" -o "$TMP_DIR/subtitle-vad-gate-tests"
"$TMP_DIR/subtitle-vad-gate-tests"
