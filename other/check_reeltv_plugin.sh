#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if ! command -v node >/dev/null; then
  echo "error: node is required for the Reel TV plugin checks" >&2
  exit 2
fi
node "$SCRIPT_DIR/check_reeltv_plugin.js"
