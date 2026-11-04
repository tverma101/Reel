#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
CLIENT_SOURCE="$ROOT/iina/OpenSubClient.swift"
CANCELLATION_SOURCE="$ROOT/iina/SubtitleAudioMatcher.swift"
TESTS="$SCRIPT_DIR/check_opensub_cancellable_delay_tests.swift"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

{
  cat <<'SWIFT'
import Foundation
import Dispatch
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct CaseInsensitiveDictionary<Key: Hashable, Value> {
  let values: [Key: Value]
  subscript(_ key: Key) -> Value? { values[key] }
}

final class OpenSubClient {
  enum LogLevel { case warning }
  static let shared = OpenSubClient()
  func log(_ message: String, level: LogLevel = .warning) {}
}

enum SubtitleAudioMatcher {
SWIFT

  # Extract the production cancellation implementation and expose its handler map only inside
  # this generated fixture so the regression can assert registration retirement directly.
  awk '
    /^  final class Cancellation \{/ { copying = 1 }
    copying {
      line = $0
      opens = gsub(/\{/, "{", line)
      closes = gsub(/\}/, "}", line)
      depth += opens - closes
      sub(/^  /, "", $0)
      print
      if (depth == 0) exit
    }
  ' "$CANCELLATION_SOURCE" | sed 's/private var cancellationHandlers/internal var cancellationHandlers/'

  cat <<'SWIFT'
}
SWIFT

  awk '
    /^private final class OpenSubCancellableDelay/ { copying = 1 }
    /^\/\/\/ \[Open Subtitles\]/ { if (copying) exit }
    copying { print }
  ' "$CLIENT_SOURCE"

  cat <<'SWIFT'
final class OpenSubClientRateLimiterOwner {
  enum LogLevel { case warning }
  static let shared = OpenSubClientRateLimiterOwner()
  func log(_ message: String, level: LogLevel = .warning) {}
SWIFT

  awk '
    /^  class RateLimiter \{/ { copying = 1 }
    copying {
      line = $0
      opens = gsub(/\{/, "{", line)
      closes = gsub(/\}/, "}", line)
      depth += opens - closes
      sub(/^  /, "", $0)
      print
      if (depth == 0) exit
    }
  ' "$CLIENT_SOURCE"

  cat <<'SWIFT'
}
SWIFT

  cat "$TESTS"
} > "$WORK/main.swift"

swiftc -parse-as-library "$WORK/main.swift" -o "$WORK/check"
"$WORK/check"

# Keep this fixture tied to all six production call sites and to the synchronized limiter reset.
if grep -Fq 'after(seconds: rateLimiter.delayBeforeCall())' "$CLIENT_SOURCE"; then
  echo 'FAIL: a rate-limited call still uses a non-cancellable PromiseKit delay' >&2
  exit 1
fi
if [ "$(grep -Fc 'cancellableRateLimitDelay(cancellation)' "$CLIENT_SOURCE")" -ne 6 ]; then
  echo 'FAIL: expected all six rate-limited methods to use the cancellable delay' >&2
  exit 1
fi
grep -Fq 'private let rateLimiter = RateLimiter()' "$CLIENT_SOURCE"
grep -Fq 'self.rateLimiter.reset()' "$CLIENT_SOURCE"
echo 'OpenSub cancellable-delay call-site guards passed'
