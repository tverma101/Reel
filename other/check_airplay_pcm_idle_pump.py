#!/usr/bin/env python3
"""Keep paused AirPlay PCM streams idle until the speaker clock or resource demand changes."""
from pathlib import Path
import subprocess
import tempfile

SOURCE = (Path(__file__).resolve().parents[1] / "iina/AirPlayAudioBridge.swift").read_text()

def method(marker):
    start = SOURCE.index(marker)
    begin = SOURCE.index("{", start)
    depth, end = 1, begin + 1
    while depth:
        depth += (SOURCE[end] == "{") - (SOURCE[end] == "}")
        end += 1
    return SOURCE[start:end]

PUMP = method("  private func pump() {")
SCHEDULER = method("  private func schedulePump() {")
assert "queue.async {" in SCHEDULER
assert "asyncAfter" not in SCHEDULER
assert "queue.async { [weak self] in self?.schedulePump() }" in SOURCE, (
    "speaker playhead advancement must wake a suspended PCM pump"
)
assert SOURCE.count("self.schedulePump()") >= 2, (
    "new and canceled AVFoundation range requests must wake the pump"
)

HARNESS = r'''import Foundation
final class Cancel { var isCancelled = false }
final class Loading { var isCancelled = false; var isFinished = false }
final class Request {
  let cancellation = Cancel()
  let loading = Loading()
  let start: Int64
  var offset: Int64
  init(start: Int64, offset: Int64) { self.start = start; self.offset = offset }
}
final class State { var isInvalidated = false; var playhead: Int64 = 0 }
final class Harness {
  static let leadFrames: Int64 = 20
  static let bytesPerFrame: Int64 = 4
  static let burstFrames: Int64 = 10
  let shared = State()
  var requests: [Request] = []
  var schedules = 0
  var serves = 0
  static func byteOffset(ofFrame f: Int64) -> Int64 { 44 + max(0, f) * bytesPerFrame }
  func removeCancellation(for loading: Loading) {}
  func schedulePump() { schedules += 1 }
  func serve(_ request: Request) -> Bool { serves += 1; request.loading.isFinished = true; return true }
  func fail() { fatalError("unexpected failure") }
  __PUMP__
  func tick() { pump() }
}
func check(_ value: @autoclosure () -> Bool, _ why: String) {
  if !value() { print("FAIL: " + why); exit(1) }
}
let f = Harness()
f.tick()
check(f.schedules == 0, "empty pump should not schedule work")
let request = Request(start: 1000, offset: 1100)
f.requests = [request]
f.tick()
check(f.schedules == 0 && f.serves == 0, "paused buffered stream must not poll")
f.shared.playhead = 300
f.tick()
check(f.schedules == 1 && f.serves == 1, "advanced playhead must serve and continue pumping")
f.tick()
check(f.requests.isEmpty, "finished ranges must be removed")
let canceled = Request(start: 1000, offset: 1100)
f.requests = [canceled]
canceled.cancellation.isCancelled = true
f.tick()
check(f.requests.isEmpty && f.schedules == 1, "cancelled request must not keep polling")
print("AirPlay idle PCM pump checks passed")
'''

def run(pump):
    with tempfile.TemporaryDirectory(prefix="reel-pcm-idle-") as temp:
        src = Path(temp) / "main.swift"
        out = Path(temp) / "check"
        src.write_text(HARNESS.replace("__PUMP__", pump))
        compiled = subprocess.run(["swiftc", str(src), "-o", str(out)],
                                  capture_output=True, text=True)
        assert compiled.returncode == 0, compiled.stdout + compiled.stderr
        return subprocess.run([str(out)], capture_output=True, text=True, timeout=15)

result = run(PUMP)
assert result.returncode == 0, result.stdout + result.stderr
print(result.stdout.strip())
bad = PUMP.replace("      // No request needs bytes yet.", "      schedulePump()\n      // No request needs bytes yet.")
assert bad != PUMP
failed = run(bad)
assert failed.returncode != 0 and "paused buffered stream must not poll" in failed.stdout
print("Idle polling negative control failed as expected")
