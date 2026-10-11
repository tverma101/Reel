#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/iina-bounded-process-lifecycle.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

xcrun swiftc "$ROOT/iina/BoundedProcessOutput.swift" \
  "$ROOT/other/check_bounded_process_output.swift" \
  -o "$TEMP_DIR/check-bounded-process-lifecycle"
"$TEMP_DIR/check-bounded-process-lifecycle" --synthetic-lifecycle-only
