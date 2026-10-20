#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
cat iina/PlaybackInfoCache.swift other/check_playback_info_cache_tests.swift | swift -
