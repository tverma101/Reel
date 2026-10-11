#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/iina-plugin-unload-barrier.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT
cat iina/EventController.swift other/check_plugin_unload_barrier_tests.swift > "$temporary_directory/main.swift"
swift "$temporary_directory/main.swift"
