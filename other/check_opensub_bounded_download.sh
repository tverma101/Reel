#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
SOURCE="$ROOT/iina/OpenSubClient.swift"
TESTS="$SCRIPT_DIR/check_opensub_bounded_download_tests.swift"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

{
  cat <<'SWIFT'
import Foundation
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
      let activeTasks = Array(tasks.values)
      tasks.removeAll()
      lock.unlock()
      activeTasks.forEach { $0.cancel() }
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
    /^private struct OpenSubResponseTooLargeError/ { found = 1 }
    /^private final class OpenSubPromiseCompletionGate/ { exit }
    found { print }
  ' "$SOURCE"
  cat "$TESTS"
} > "$WORK/main.swift"

swiftc -parse-as-library "$WORK/main.swift" -o "$WORK/check"
"$WORK/check"
