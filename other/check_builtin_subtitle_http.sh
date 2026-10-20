#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
SOURCE="$ROOT/iina/OnlineSubtitle.swift"
TESTS="$SCRIPT_DIR/check_builtin_subtitle_http_tests.swift"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

{
  cat <<'SWIFT'
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum SubtitleAudioMatcher {
  final class Cancellation {
    private let lock = NSLock()
    private var cancelled = false
    private var tasks: [UUID: URLSessionTask] = [:]
    private var handlers: [UUID: () -> Void] = [:]

    var isCancelled: Bool {
      lock.lock()
      defer { lock.unlock() }
      return cancelled
    }

    func cancel() {
      lock.lock()
      cancelled = true
      let activeTasks = Array(tasks.values)
      let activeHandlers = Array(handlers.values)
      tasks.removeAll()
      handlers.removeAll()
      lock.unlock()
      activeTasks.forEach { $0.cancel() }
      activeHandlers.forEach { $0() }
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

    func onCancel(_ handler: @escaping () -> Void) {
      lock.lock()
      guard !cancelled else {
        lock.unlock()
        handler()
        return
      }
      handlers[UUID()] = handler
      lock.unlock()
    }
  }
}
SWIFT
  awk '
    /^enum BuiltinSubtitleResponseLimit/ { found = 1 }
    /^fileprivate protocol ProviderProtocol/ { exit }
    found { print }
  ' "$SOURCE"
  cat "$TESTS"
} > "$WORK/main.swift"

swiftc -parse-as-library "$WORK/main.swift" -o "$WORK/check"
"$WORK/check"

DISCARD_BLOCK="$(sed -n '/override func discardCachedDownload()/,/^    }/p' "$ROOT/iina/OpenSubSubtitle.swift")"
if ! grep -Fq 'downloadCache.discardFileIfUnleased(url)' <<<"$DISCARD_BLOCK" || \
   grep -Fq 'FileManager.default.removeItem' <<<"$DISCARD_BLOCK"; then
  echo 'FAIL: OpenSub discard must route file removal through the cache lease check' >&2
  exit 1
fi
echo 'OpenSub cancellation uses the lease-aware cache discard path'

if grep -Eq 'leasedDirectories|leaseFileDescriptors' "$SOURCE"; then
  echo 'FAIL: subtitle cache retains per-result lease sets or descriptors' >&2
  exit 1
fi
grep -Fq 'private static var sessionLeases' "$SOURCE"
echo 'subtitle cache lease bookkeeping retains only one sentinel descriptor per root'

check_provider_policy_wiring() {
  local provider="$1"
  local expected_transfers="$2"
  local provider_source="$ROOT/iina/$provider.swift"
  local transfer_count
  transfer_count="$(grep -c 'let transfer = BuiltinSubtitleHTTPTransfer' "$provider_source" || true)"
  if [ "$transfer_count" -ne "$expected_transfers" ]; then
    echo "FAIL: unexpected $provider transfer count: $transfer_count" >&2
    exit 1
  fi
  shift 2
  while [ "$#" -gt 0 ]; do
    local policy="$1"
    local expected_count="$2"
    local actual_count
    actual_count="$(grep -F -c "$policy" "$provider_source" || true)"
    if [ "$actual_count" -ne "$expected_count" ]; then
      echo "FAIL: $provider must use '$policy' $expected_count time(s), got $actual_count" >&2
      exit 1
    fi
    shift 2
  done
}

check_provider_policy_wiring AssrtSubtitle 3 \
  'allowsAssrtDownload($0)' 1 'allowsAssrtAPI($0)' 2
check_provider_policy_wiring ShooterSubtitle 2 'allowsShooter($0)' 2
check_provider_policy_wiring SubDLSubtitle 2 \
  'host: "dl.subdl.com"' 1 'host: "api.subdl.com"' 1
echo 'all built-in transfers use their expected provider URL policies'

HANDOFF_BLOCK="$(awk '
  /provider\.fetchSubtitles\(url: url, player: player, cancellation: cancellation\)\.done \{ urls in/ { active = 1 }
  active && /\.ensure \{/ { exit }
  active { print }
' "$SOURCE")"
if ! grep -Fq 'BuiltinSubtitleCache.discardUnhandedFiles(urls)' <<<"$HANDOFF_BLOCK"; then
  echo 'FAIL: stale search results must release cache files that never reached the consumer' >&2
  exit 1
fi
echo 'stale subtitle search results release their unhanded cache files'
