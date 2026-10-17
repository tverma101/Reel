#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
SOURCE="$ROOT/iina/AppDelegate.swift"
TESTS="$SCRIPT_DIR/check_command_line_boolean_tests.swift"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

awk '/^enum CommandLineBoolean \{/ { copy = 1 } /^struct CommandLineStatus \{/ { copy = 0 } copy { print }' \
  "$SOURCE" > "$WORK/main.swift"
cat "$TESTS" >> "$WORK/main.swift"
swiftc -O "$WORK/main.swift" -o "$WORK/check"
"$WORK/check"

python3 - "$ROOT/iina-cli/main.swift" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
assert 'let optionArguments = Array(userArgs.prefix(while: { $0 != "--" }))' in source
assert '!explicitlyUsesStdin' in source, "only stdin flags before -- may waive local-path preflight"
assert 'Headless mode requires a media input or stdin.' in source
print("PASS: CLI scopes stdin and headless input checks to media arguments")
PY
