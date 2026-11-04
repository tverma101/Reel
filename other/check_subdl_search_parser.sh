#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swiftc "$ROOT/iina/SubDLSearchResultParser.swift" \
  "$SCRIPT_DIR/check_subdl_search_parser.swift" \
  -o "$WORK/check-subdl-search-parser"
"$WORK/check-subdl-search-parser"
