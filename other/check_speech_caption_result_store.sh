#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
swiftc -O -o "$tmpdir/check-speech-caption-result-store" \
  iina/SpeechCaptionResultStore.swift other/check_speech_caption_result_store.swift
"$tmpdir/check-speech-caption-result-store"
