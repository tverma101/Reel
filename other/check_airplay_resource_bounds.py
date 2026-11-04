#!/usr/bin/env python3
"""Compile production-extracted AirPlay clock, range, and playhead regressions.

Run: python3 other/check_airplay_resource_bounds.py
No receiver, Xcode or FFmpeg required; this does not test AirPlay routing.
"""
from pathlib import Path
import subprocess
import tempfile

SOURCE = (Path(__file__).resolve().parents[1] / "iina/AirPlayAudioBridge.swift").read_text()

def extract(marker):
    start = SOURCE.index(marker)
    opening = SOURCE.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (SOURCE[end] == "{") - (SOURCE[end] == "}")
        end += 1
    return SOURCE[start:end]

CLOCK = extract("static func audioClockHasAdvanced(")
PLAYHEAD = extract("static func playheadFrame(")
RANGE = extract("static func requestedRange(")
OFFSET = extract("private static func byteOffset(")

SWIFT = r'''import Foundation
enum Loader {
  static let sampleRate = 48_000.0
  static let bytesPerFrame: Int64 = 4
  static let headerLength: Int64 = 44
  static let maximumFrames: Int64 = (Int64(UInt32.max) - 64) / bytesPerFrame
  __CLOCK__
  __PLAYHEAD__
  __RANGE__
  __OFFSET__
  static func checkedByteOffset(_ frame: Int64) -> Int64 { byteOffset(ofFrame: frame) }
}
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
  guard condition() else { print("FAIL: " + label); exit(1) }
}
check(Loader.audioClockHasAdvanced(from: 30, to: 30.2), "forward clock progress")
check(Loader.audioClockHasAdvanced(from: -2, to: -1), "negative-PTS pre-roll must advance")
check(!Loader.audioClockHasAdvanced(from: 30, to: 29), "backward motion counted as progress")
check(!Loader.audioClockHasAdvanced(from: 30, to: 30.0002), "clock jitter counted as progress")
check(!Loader.audioClockHasAdvanced(from: nil, to: 1), "missing baseline")
check(!Loader.audioClockHasAdvanced(from: 5, to: .nan), "invalid clock")
check(!Loader.audioClockHasAdvanced(from: -Double.greatestFiniteMagnitude,
                                   to: Double.greatestFiniteMagnitude),
      "overflowing clock delta must not count as progress")
check(Loader.playheadFrame(for: -.greatestFiniteMagnitude) == 0, "negative playhead")
check(Loader.playheadFrame(for: Double.greatestFiniteMagnitude) == Loader.maximumFrames,
      "huge finite playhead should be bounded, not trap")
check(Loader.playheadFrame(for: .infinity) == nil, "infinite playhead")
check(Loader.playheadFrame(for: .nan) == nil, "NaN playhead")
check(Loader.playheadFrame(for: 0.25) == 12_000, "valid playhead")
check(Loader.checkedByteOffset(Int64.max) ==
      Loader.headerLength + Loader.maximumFrames * Loader.bytesPerFrame, "frame-to-byte overflow")
check(Loader.requestedRange(start: 10, currentOffset: 10, requestedLength: 5,
      allDataToEnd: false, contentLength: 100) == 10..<15, "ordinary range")
check(Loader.requestedRange(start: 98, currentOffset: 98, requestedLength: 1000,
      allDataToEnd: false, contentLength: 100) == 98..<100, "truncated at EOF")
check(Loader.requestedRange(start: 98, currentOffset: 98, requestedLength: 1,
      allDataToEnd: true, contentLength: 100) == 98..<100, "all-data-to-end")
check(Loader.requestedRange(start: -1, currentOffset: -1, requestedLength: 5,
      allDataToEnd: false, contentLength: 100) == nil, "negative offset")
check(Loader.requestedRange(start: 100, currentOffset: 100, requestedLength: 5,
      allDataToEnd: false, contentLength: 100) == nil, "EOF")
check(Loader.requestedRange(start: 90, currentOffset: 90, requestedLength: 0,
      allDataToEnd: false, contentLength: 100) == nil, "zero length")
check(Loader.requestedRange(start: Int64.max - 3, currentOffset: Int64.max - 3, requestedLength: Int.max,
      allDataToEnd: false, contentLength: Int64.max) == (Int64.max - 3)..<Int64.max,
      "huge request length arithmetic overflow")
check(Loader.requestedRange(start: 10, currentOffset: 0, requestedLength: 5,
      allDataToEnd: false, contentLength: 100) == 10..<15,
      "initial currentOffset may be zero for a nonzero requestedOffset")
check(Loader.requestedRange(start: 10, currentOffset: 12, requestedLength: 5,
      allDataToEnd: false, contentLength: 100) == 12..<15,
      "partially supplied request must resume at currentOffset")
check(Loader.requestedRange(start: 10, currentOffset: 15, requestedLength: 5,
      allDataToEnd: false, contentLength: 100) == nil,
      "fully supplied request must not replay bytes")
check(Loader.requestedRange(start: 10, currentOffset: 20, requestedLength: 5,
      allDataToEnd: false, contentLength: 100) == nil,
      "past-end currentOffset must not exceed original requested range")
check(Loader.requestedRange(start: 98, currentOffset: 99, requestedLength: 1000,
      allDataToEnd: false, contentLength: 100) == 99..<100,
      "partial request truncated at WAV EOF")
check(Loader.requestedRange(start: 90, currentOffset: 95, requestedLength: 1,
      allDataToEnd: true, contentLength: 100) == 95..<100,
      "all-data-to-end resumes from supplied offset")
check(Loader.requestedRange(start: Int64.max - 3, currentOffset: Int64.max - 2,
      requestedLength: Int.max, allDataToEnd: false, contentLength: Int64.max) ==
      (Int64.max - 2)..<Int64.max, "partial huge range must not overflow")
print("AirPlay PCM bounds and progress checks passed")
'''

def run(clock=CLOCK, playhead=PLAYHEAD, requested_range=RANGE, offset=OFFSET):
    source = (SWIFT.replace("__CLOCK__", clock).replace("__PLAYHEAD__", playhead)
              .replace("__RANGE__", requested_range).replace("__OFFSET__", offset))
    with tempfile.TemporaryDirectory(prefix="reel-airplay-resource-bounds-") as tmp:
        swift = Path(tmp) / "main.swift"
        swift.write_text(source)
        binary = Path(tmp) / "check"
        result = subprocess.run(["swiftc", str(swift), "-o", str(binary)],
                                capture_output=True, text=True)
        assert result.returncode == 0, result.stdout + result.stderr
        return subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)

result = run()
assert result.returncode == 0, result.stdout + result.stderr
print(result.stdout.strip())
mutated = CLOCK.replace("advance.isFinite && advance > epsilon",
                        "abs(current - previous) > epsilon")
assert mutated != CLOCK
negative = run(clock=mutated)
assert negative.returncode != 0 and "backward motion" in negative.stdout, negative.stdout
mutated_offset = OFFSET.replace("min(max(0, frame), maximumFrames)", "max(0, frame)")
assert mutated_offset != OFFSET
negative = run(offset=mutated_offset)
assert negative.returncode != 0, "unbounded offset unexpectedly passed"
mutated_range = RANGE.replace("let next = max(start, currentOffset)", "let next = start")
assert mutated_range != RANGE
negative = run(requested_range=mutated_range)
assert negative.returncode != 0 and "partially supplied request" in negative.stdout, negative.stdout
print("All three unsafe-code negative controls failed as expected")
