#!/usr/bin/env python3
"""Exercise production PCM gain and route-buffer replacement without playing audible media."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "iina/AirPlayAudioBridge.swift").read_text()

def extract(marker):
    start = SOURCE.index(marker)
    brace = SOURCE.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (SOURCE[end] == "{") - (SOURCE[end] == "}")
        end += 1
    return SOURCE[start:end]

GAIN = extract("enum AirPlayPCMVolume {")
CHANGE = extract("  func volumeChanged() {")
assert "let adjusted = AirPlayPCMVolume.apply(to: data, gain: gain)" in SOURCE
assert "dataRequest.respond(with: adjusted[skip..<(skip + length)])" in SOURCE
assert "gain: AirPlayPCMVolume.gain(volume: player.info.volume," in SOURCE
HARNESS = r'''import Foundation
extension Comparable {
  func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
__GAIN__
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() { print("FAIL: \(message)"); exit(1) }
}
func pcm(_ values: [Int16]) -> Data {
  Data(values.flatMap { v -> [UInt8] in
    let b = UInt16(bitPattern: v)
    return [UInt8(truncatingIfNeeded: b), UInt8(truncatingIfNeeded: b >> 8)]
  })
}
let input = pcm([-32768, -16000, -1, 0, 1, 16000, 32767])
check(AirPlayPCMVolume.apply(to: input, gain: 0) == Data(count: input.count), "muted PCM is not silent")
check(AirPlayPCMVolume.apply(to: input, gain: 1) == input, "unity gain changes PCM")
check(AirPlayPCMVolume.apply(to: input, gain: 0.5) == pcm([-16384, -8000, -1, 0, 1, 8000, 16384]),
      "half volume does not scale signed little-endian samples")
check(AirPlayPCMVolume.apply(to: input, gain: .nan) == Data(count: input.count), "invalid gain is not silent")
check(AirPlayPCMVolume.apply(to: Data(), gain: 0.5).isEmpty, "empty PCM fails")
check(AirPlayPCMVolume.gain(volume: 100, muted: true) == 0, "mute does not override volume")
check(AirPlayPCMVolume.gain(volume: 0, muted: false) == 0, "zero volume is not silent")
check(AirPlayPCMVolume.gain(volume: 50, muted: false) == 0.5, "volume is not normalized")
check(AirPlayPCMVolume.gain(volume: 200, muted: false) == 1, "over-range volume is not bounded")
check(AirPlayPCMVolume.gain(volume: -.infinity, muted: false) == 0, "invalid volume is not silent")
final class Info { var volume = 100.0; var isMuted = false }
final class Player { let info = Info() }
final class AVPlayer {
  var volume: Float = 1
  var isMuted = false
  var pauses = 0
  func pause() { pauses += 1 }
}
struct Loader { let gain: Double }
enum Selection { case supported(Int), waiting }
final class Bridge {
  var avPlayer: AVPlayer? = AVPlayer()
  var player: Player? = Player()
  var loader: Loader? = Loader(gain: 1)
  var isCarrying = true
  var available = Selection.supported(7)
  var replacements: [Int] = []
  func audioSelection() -> Selection { available }
  func replaceItem(with selection: Int) {
    replacements.append(selection)
    loader = Loader(gain: AirPlayPCMVolume.gain(volume: player!.info.volume, muted: player!.info.isMuted))
    volumeChanged()
  }
  __CHANGE__
}
let bridge = Bridge()
bridge.player!.info.isMuted = true
bridge.volumeChanged()
check(bridge.loader!.gain == 0, "mute did not create silent PCM")
check(bridge.replacements == [7] && bridge.avPlayer!.pauses == 1, "mute did not discard buffered audio once")
check(bridge.avPlayer!.isMuted, "native immediate mute was lost")
bridge.volumeChanged()
bridge.player!.info.volume = 50
bridge.volumeChanged()
check(bridge.replacements.count == 1, "unchanged muted gain rebuilt the stream")
bridge.player!.info.isMuted = false
bridge.volumeChanged()
check(bridge.loader!.gain == 0.5 && bridge.replacements.count == 2, "unmute did not restore the user's gain")
check(bridge.avPlayer!.volume == 1 && !bridge.avPlayer!.isMuted, "native gain would square PCM volume")
bridge.player!.info.volume = 0
bridge.volumeChanged()
check(bridge.loader!.gain == 0 && bridge.avPlayer!.isMuted, "zero volume left audible PCM")
let waiting = Bridge()
waiting.available = .waiting
waiting.player!.info.isMuted = true
waiting.volumeChanged()
check(waiting.avPlayer!.isMuted && waiting.avPlayer!.pauses == 1 && waiting.replacements.isEmpty,
      "unready metadata did not pause and mute old buffered audio")
print("AirPlay PCM mute, volume and buffered-audio replacement checks passed")
'''

def run(gain, change):
    with tempfile.TemporaryDirectory(prefix="reel-airplay-volume-") as folder:
        folder = Path(folder)
        source = folder / "main.swift"
        source.write_text(HARNESS.replace("__GAIN__", gain).replace("__CHANGE__", change))
        binary = folder / "check"
        compiled = subprocess.run(["swiftc", str(source), "-o", str(binary)], capture_output=True, text=True)
        assert compiled.returncode == 0, compiled.stdout + compiled.stderr
        return subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)

result = run(GAIN, CHANGE)
assert result.returncode == 0, result.stdout + result.stderr
print(result.stdout.strip())
for gain, change, message in [
    (GAIN.replace("guard gain > 0 else { return Data(count: data.count) }", "guard gain > 0 else { return data }"),
     CHANGE, "muted PCM is not silent"),
    (GAIN, CHANGE.replace("replaceItem(with: selection)", "_ = selection"), "mute did not create silent PCM"),
    (GAIN, CHANGE.replace("avPlayer.volume = 1", "avPlayer.volume = Float(gain)"), "native gain would square PCM volume"),
]:
    negative = run(gain, change)
    assert negative.returncode != 0 and message in negative.stdout, negative.stdout + negative.stderr
print("All three unsafe-volume negative controls failed as expected")
