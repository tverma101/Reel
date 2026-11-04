#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
SOURCE="$ROOT/iina/SubtitleAudioMatcher.swift"
TESTS="$SCRIPT_DIR/check_bounded_subtitle_model_tests.swift"

python3 - "$SOURCE" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
start = source.index("private static func ensureModel(")
end = source.index("private static func download(", start)
ensure_model = source[start:end]
assert "removeItem(at: destination)" not in ensure_model, \
    "a stale checksum result must not delete a newer installed model"
download_start = source.index("private static func download(")
download_end = source.index("private static func hasExpectedChecksum(", download_start)
download = source[download_start:download_end]
assert "subtitleModelStagingLeaseNeedsTransfer" in download, \
    "model downloads must recheck for an installed model while holding the staging lock"
assert "if needsTransfer" in download and "transfer.start()" in download, \
    "only a locked recheck that still finds a missing model may start a transfer"
assert "subtitleModelInstallStagingFile(stagingURL, at: destination)" in source, \
    "verified models must use the same-directory atomic install helper"
assert "Darwin.rename(sourcePath, destinationPath)" in source, \
    "the model installation helper must atomically replace the destination"
vad_start = source.index("assessmentPromise = ensureModel(vadModel")
vad_end = source.index(".recover { error -> Promise<VADAssessment>", vad_start)
vad_worker = source[vad_start:vad_end]
assert "subtitleCancellableWork(isCancelled: { cancellation.isCancelled })" in vad_worker, \
    "queued VAD analysis must check cancellation before beginning CPU-heavy work"
print("model retries preserve concurrent installs and promote by atomic rename")
PY

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

{
  cat <<'SWIFT'
import CryptoKit
import Foundation
import Darwin
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum SubtitleAudioMatcher {
  final class Cancellation {
    private let lock = NSLock()
    private var cancelled = false
    private var tasks: [UUID: URLSessionTask] = [:]

    var isCancelled: Bool {
      lock.lock()
      defer { lock.unlock() }
      return cancelled
    }

    func cancel() {
      lock.lock()
      cancelled = true
      let active = Array(tasks.values)
      tasks.removeAll()
      lock.unlock()
      active.forEach { $0.cancel() }
    }

    func register(_ task: URLSessionTask, identifier: UUID) -> Bool {
      lock.lock()
      guard !cancelled else {
        lock.unlock()
        task.cancel()
        return false
      }
      tasks[identifier] = task
      lock.unlock()
      return true
    }

    func finish(_ identifier: UUID) {
      lock.lock()
      tasks.removeValue(forKey: identifier)
      lock.unlock()
    }
  }
}
SWIFT
  awk '
    /^private enum SubtitleModelTransferError/ { found = 1 }
    /^private func subtitleMatcherWhisperAbortCallback/ { exit }
    found { print }
  ' "$SOURCE"
  cat "$TESTS"
} > "$WORK/main.swift"

swiftc -parse-as-library -O "$WORK/main.swift" -o "$WORK/check"
"$WORK/check"
