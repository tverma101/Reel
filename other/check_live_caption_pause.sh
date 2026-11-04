#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
SOURCE="$ROOT/iina/AppleLiveCaptions.swift"
TESTS="$SCRIPT_DIR/check_live_caption_pause_tests.swift"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

{
  cat <<'SWIFT'
import Foundation
SWIFT
  awk '
    /^private final class LiveCaptionDecodeQueueOrder/ { found = 1 }
    /^\/\/\/ Mutable state and AppKit objects/ { exit }
    found { print }
  ' "$SOURCE"
  cat "$TESTS"
} > "$WORK/main.swift"

swiftc -parse-as-library "$WORK/main.swift" -o "$WORK/check"
"$WORK/check"

PAUSE_BLOCK="$(sed -n '/func pauseChanged(_ paused: Bool)/,/^  }/p' "$SOURCE")"
for required in 'workState.pause()' 'cancelSpeechLocaleCheck()' 'cancelDecode()' 'cancelLegacySpeechTask()' 'analyzerTask?.cancel()' 'inFlight = false' 'enqueueChunkReaderRetirement()'; do
  if ! grep -Fq "$required" <<<"$PAUSE_BLOCK"; then
    echo "FAIL: pauseChanged is missing $required" >&2
    exit 1
  fi
done
if ! grep -Fq 'enqueueChunkReaderRetirement()' <<<"$PAUSE_BLOCK"; then
  echo 'FAIL: pause does not enqueue FFmpeg reader retirement' >&2
  exit 1
fi
RETIREMENT_CALL_LINE="$(grep -n -F 'enqueueChunkReaderRetirement()' <<<"$PAUSE_BLOCK" | cut -d: -f1)"
CANCEL_DECODE_LINE="$(grep -n -F 'cancelDecode()' <<<"$PAUSE_BLOCK" | cut -d: -f1)"
if (( RETIREMENT_CALL_LINE <= CANCEL_DECODE_LINE )); then
  echo 'FAIL: reader retirement is not queued after cancellation is requested' >&2
  exit 1
fi
if grep -Fq 'analyzerTask = nil' <<<"$PAUSE_BLOCK"; then
  echo 'FAIL: pauseChanged releases the analyzer task before its cancellation cleanup drains' >&2
  exit 1
fi
echo 'pause cancellation and analyzer-drain source checks passed'

LEGACY_CANCEL_BLOCK="$(sed -n '/private func cancelLegacySpeechTask()/,/private func cancelSpeechLocaleCheck()/p' "$SOURCE")"
SCHEDULER_BLOCK="$(sed -n '/guard let audioSelection = activeAudioSelection else { return }/,+5p' "$SOURCE")"
if ! grep -Fq 'task?.cancel()' <<<"$LEGACY_CANCEL_BLOCK" ||
   ! grep -Fq 'task = nil' <(sed -n '/private func finishLegacySpeechTask(/,/^  }/p' "$SOURCE") ||
   ! grep -Fq '!legacySpeechTaskState.hasActiveTask' <<<"$SCHEDULER_BLOCK" ||
   ! grep -Fq 'task?.state == .completed' "$SOURCE"; then
  echo 'FAIL: legacy Speech cancellation does not retain and drain its single admission slot' >&2
  exit 1
fi
echo 'legacy Speech cancellation retains one task until terminal completion'

RETIREMENT_BLOCK="$(sed -n '/private func enqueueChunkReaderRetirement()/,/^  }/p' "$SOURCE")"
for required in 'decodeWorkOrder.enqueueReaderRetirement' 'self?.chunkReader = nil' 'self?.chunkReaderSource = nil'; do
  if ! grep -Fq "$required" <<<"$RETIREMENT_BLOCK"; then
    echo "FAIL: queue-confined reader retirement is missing $required" >&2
    exit 1
  fi
done
TRANSCRIBE_BLOCK="$(sed -n '/private func transcribe(url:/,/private func transcribeWithSpeechAnalyzer/p' "$SOURCE")"
if ! grep -Fq 'decodeWorkOrder.enqueueRead' <<<"$TRANSCRIBE_BLOCK"; then
  echo 'FAIL: resumed FFmpeg reads do not use bounded decode admission' >&2
  exit 1
fi
for required in 'pendingRetirement' 'pendingRead' 'guard !drainScheduled else { return }' \
                'drainScheduled = true' 'pendingRead = nil' 'operation()'; do
  if ! grep -Fq "$required" "$SOURCE"; then
    echo "FAIL: bounded decode admission is missing $required" >&2
    exit 1
  fi
done
echo 'queue-confined reader retirement source checks passed'

LOCALE_BLOCK="$(sed -n '/private func checkInstalledSpeechLocales(/,/^  }/p' "$SOURCE")"
for required in 'speechLocaleLookupState.request(request)' 'startInstalledSpeechLocaleLookup(lookup)' ; do
  if ! grep -Fq "$required" <<<"$LOCALE_BLOCK"; then
    echo "FAIL: locale discovery is missing $required" >&2
    exit 1
  fi
done
LOOKUP_BLOCK="$(sed -n '/private func startInstalledSpeechLocaleLookup(/,/^  }/p' "$SOURCE")"
for required in 'await SpeechTranscriber.installedLocales' \
                'speechLocaleLookupState.finish(lookup.id)' \
                'case .start(let nextLookup)' 'case .publish(let request)' \
                'workState.accepts(request.generation)' \
                'currentURL == request.mediaURL' \
                'canonicalLocaleID(self.selectedSpeechLocale) == request.localeID' \
                'installedSpeechLanguageCodes = languageCodes'; do
  if ! grep -Fq "$required" <<<"$LOOKUP_BLOCK"; then
    echo "FAIL: locale lookup completion is missing $required" >&2
    exit 1
  fi
done
if grep -Fq 'guard !Task.isCancelled else { return }' <<<"$LOOKUP_BLOCK"; then
  echo 'FAIL: a cancelled lookup can return without retiring its single-flight slot' >&2
  exit 1
fi
CANCEL_BLOCK="$(sed -n '/private func cancelSpeechLocaleCheck()/,/^  }/p' "$SOURCE")"
for required in 'speechLocaleLookupState.cancel()' 'speechLocaleCheckTask?.cancel()'; do
  if ! grep -Fq "$required" <<<"$CANCEL_BLOCK"; then
    echo "FAIL: locale cancellation is missing $required" >&2
    exit 1
  fi
done
if grep -Fq 'speechLocaleCheckTask = nil' <<<"$CANCEL_BLOCK"; then
  echo 'FAIL: locale cancellation releases the in-flight lookup handle before await returns' >&2
  exit 1
fi
FINISH_LINE="$(grep -n -F 'self.speechLocaleLookupState.finish(lookup.id)' <<<"$LOOKUP_BLOCK" | cut -d: -f1)"
HANDLE_LINE="$(grep -n -F 'self.speechLocaleCheckTask = nil' <<<"$LOOKUP_BLOCK" | cut -d: -f1)"
PUBLISH_LINE="$(grep -n -F 'self.installedSpeechLanguageCodes = languageCodes' <<<"$LOOKUP_BLOCK" | cut -d: -f1)"
if (( FINISH_LINE >= HANDLE_LINE || HANDLE_LINE >= PUBLISH_LINE )); then
  echo 'FAIL: locale result publication is not ordered behind slot retirement' >&2
  exit 1
fi
if ! grep -Fq 'cancelSpeechLocaleCheck()' <(sed -n '/func stop()/,/^  }/p' "$SOURCE"); then
  echo 'FAIL: stop does not retire a locale lookup' >&2
  exit 1
fi
echo 'stale locale-result source checks passed'

DISPLAY_BLOCK="$(sed -n '/private func observeWindowDisplayChanges()/,/^  }/p' "$SOURCE")"
for required in 'NSWindow.didChangeBackingPropertiesNotification' 'NSWindow.didChangeScreenNotification' 'self.updateAppearance()'; do
  if ! grep -Fq "$required" <<<"$DISPLAY_BLOCK"; then
    echo "FAIL: window display tracking is missing $required" >&2
    exit 1
  fi
done
if ! grep -Fq 'observeWindowDisplayChanges()' <(sed -n '/private func observeAppearancePreferences()/,/^  }/p' "$SOURCE"); then
  echo 'FAIL: eligible captions do not observe the current window' >&2
  exit 1
fi
if ! grep -Fq 'displayObservers.removeAll()' <(sed -n '/private func stopAppearanceTracking()/,/^  }/p' "$SOURCE"); then
  echo 'FAIL: display observers are not cleaned up with appearance tracking' >&2
  exit 1
fi
echo 'backing-scale observation and cleanup source checks passed'

CAPTION_INSTALL_BLOCK="$(sed -n '/func install(/,/^  private func observeAppearancePreferences()/p' "$SOURCE")"
for required in 'player.observe(.iinaSubScaleChanged)' 'player.observe(.iinaSubPositionChanged)' 'self?.updateAppearance()'; do
  if ! grep -Fq "$required" <<<"$CAPTION_INSTALL_BLOCK"; then
    echo "FAIL: native caption controls are missing the $required update path" >&2
    exit 1
  fi
done
APPEARANCE_BLOCK="$(sed -n '/private func updateAppearance()/,/private func observeAppearancePreferences()/p' "$SOURCE")"
for required in 'player?.info.subScale' 'player?.info.subPos' 'horizontalConstraint.isActive = true' 'verticalConstraint.isActive = true'; do
  if ! grep -Fq "$required" <<<"$APPEARANCE_BLOCK"; then
    echo "FAIL: caption scale or position is missing $required" >&2
    exit 1
  fi
done
if ! grep -Fq 'LiveCaptionVerticalPosition.bottomConstraintConstant' <<<"$APPEARANCE_BLOCK"; then
  echo 'FAIL: bottom-aligned subtitle position bypasses the safe adjustable range' >&2
  exit 1
fi
if ! grep -Fq 'overlay.heightAnchor.constraint(lessThanOrEqualToConstant: 0)' "$SOURCE" ||
   ! grep -Fq 'maximumHeightConstraint?.constant = maximumCaptionHeight' <<<"$APPEARANCE_BLOCK"; then
  echo 'FAIL: caption overlay is missing its video-height cap' >&2
  exit 1
fi
OVERLAY_BLOCK="$(sed -n '/private final class LiveCaptionOverlay/,/private final class LiveCaptionDecodeCancellation/p' "$SOURCE")"
if ! grep -Fq 'layer?.masksToBounds = true' <<<"$OVERLAY_BLOCK" ||
   ! grep -Fq 'for: .vertical' <<<"$OVERLAY_BLOCK"; then
  echo 'FAIL: caption text is not compressible and clipped to the bounded overlay' >&2
  exit 1
fi
for required in 'player.setSubPos' 'player.setSubScale'; do
  if ! grep -Fq "$required" "$ROOT/iina/SidebarSubtitlesPane.swift"; then
    echo "FAIL: the native subtitle sidebar is missing $required" >&2
    exit 1
  fi
done
echo 'native caption scale and position control wiring checks passed'
echo 'long-caption height cap and clipping source checks passed'

TRACK_SOURCE="$ROOT/iina/MPVTrack.swift"
FFMPEG_SOURCE="$ROOT/iina/FFmpegController.m"
for required in 'var ffIndex: Int?' 'dict["ff-index"]' 'ffIndex = Int(exactly: value)'; do
  if ! grep -Fq "$required" "$TRACK_SOURCE"; then
    echo "FAIL: mpv audio stream identity is missing $required" >&2
    exit 1
  fi
done
AUDIO_SELECTION_BLOCK="$(sed -n '/private func updateAudioStreamSelection(for player:/,/^  }/p' "$SOURCE")"
for required in 'isExternal: track?.isExternal' 'streamIndex: track?.ffIndex' \
                'workState.pause()' 'cancelDecode()' 'analyzerTask?.cancel()' \
                'captionResults.removeAll()' 'enqueueChunkReaderRetirement()'; do
  if ! grep -Fq "$required" <<<"$AUDIO_SELECTION_BLOCK"; then
    echo "FAIL: selected audio changes are missing $required" >&2
    exit 1
  fi
done
if ! grep -Fq 'audioStreamIndex: streamIndex' "$SOURCE" ||
   ! grep -Fq 'requestedAudioStreamIndex:(NSInteger)' "$FFMPEG_SOURCE" ||
   ! grep -Fq 'av_find_best_stream(formatContext, AVMEDIA_TYPE_AUDIO' "$FFMPEG_SOURCE"; then
  echo 'FAIL: FFmpeg selected-stream decoding or matcher fallback is missing' >&2
  exit 1
fi
OPEN_BLOCK="$(sed -n '/AVDictionary \*openOptions = NULL;/,/^  int ret = avformat_open_input/p' "$FFMPEG_SOURCE")"
CANCEL_BLOCK="$(sed -n '/if (_cancellationCheck != nil && _cancellationCheck()) {/,/^  }/p' <<<"$OPEN_BLOCK")"
if ! grep -Fq 'av_dict_free(&openOptions);' <<<"$CANCEL_BLOCK"; then
  echo 'FAIL: cancelled FFmpeg reader initialization leaks its network option dictionary' >&2
  exit 1
fi
echo 'selected internal audio stream wiring and external-track fail-closed checks passed'
echo 'cancelled FFmpeg reader initialization frees its temporary options'
