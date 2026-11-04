#!/usr/bin/env python3
"""Exercise the production AVPlayer clock feeder with stale and current item callbacks."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "iina/AirPlayAudioBridge.swift").read_text()

start = SOURCE.index("private final class AirPlayPlayheadFeeder:")
begin = SOURCE.index("{", start)
depth = 1
end = begin + 1
while depth:
    depth += (SOURCE[end] == "{") - (SOURCE[end] == "}")
    end += 1
FEEDER = SOURCE[start:end]
assert SOURCE.count("    playheadFeeder.attach(nil)\n    stopPlayheadObserver()") == 2
assert "installPlayheadObserver(on: avPlayer, generation: observerGeneration)" in SOURCE
assert "feeder?.update(time, generation: generation)" in SOURCE
assert "avPlayer.removeTimeObserver(playheadObserver)" in SOURCE

HARNESS = r'''import Foundation
struct CMTime { let seconds: Double }
final class AirPlayPCMResourceLoader {
  var positions: [Double] = []
  func setPlayhead(seconds: Double) { positions.append(seconds) }
}
__FEEDER__
func check(_ ok: @autoclosure () -> Bool, _ why: String) {
  guard ok() else { print("FAIL: " + why); exit(1) }
}
private let feeder = AirPlayPlayheadFeeder()
let old = AirPlayPCMResourceLoader()
let first = feeder.attach(old)
feeder.update(CMTime(seconds: 10), generation: first)
check(old.positions == [10], "original item did not feed")
feeder.attach(nil)
let current = AirPlayPCMResourceLoader()
let second = feeder.attach(current)
feeder.update(CMTime(seconds: 500), generation: first)
check(feeder.position == nil && current.positions.isEmpty, "stale old item callback")
feeder.update(CMTime(seconds: 0.5), generation: second)
check(current.positions == [0.5], "new item callback missing")
feeder.update(CMTime(seconds: 0.6), generation: second)
check(feeder.position == 0.6 && current.positions == [0.5], "fine clock decimation")
feeder.prepareForSeek(to: 2)
feeder.update(CMTime(seconds: 100), generation: second)
check(feeder.position == nil, "pre-seek callback accepted")
feeder.update(CMTime(seconds: 2), generation: second)
check(current.positions == [0.5, 2], "seek destination not fed")
feeder.attach(nil)
feeder.update(CMTime(seconds: 5), generation: second)
check(feeder.position == nil && current.positions == [0.5, 2], "shutdown callback accepted")
print("AirPlay playhead generation checks passed")
'''
def run(feeder):
    with tempfile.TemporaryDirectory(prefix="reel-playhead-epoch-") as td:
        src = Path(td) / "main.swift"
        exe = Path(td) / "test"
        src.write_text(HARNESS.replace("__FEEDER__", feeder))
        compiled = subprocess.run(["swiftc", str(src), "-o", str(exe)],
                                  capture_output=True, text=True)
        assert compiled.returncode == 0, compiled.stdout + compiled.stderr
        return subprocess.run([str(exe)], capture_output=True, text=True, timeout=15)

passed = run(FEEDER)
assert passed.returncode == 0, passed.stdout + passed.stderr
print(passed.stdout.strip())
mutant = FEEDER.replace("guard generation == self.generation else {",
                        "guard generation > 0 else {")
assert mutant != FEEDER
negative = run(mutant)
assert negative.returncode != 0 and "stale old item callback" in negative.stdout
print("Stale-callback negative control failed as expected")
