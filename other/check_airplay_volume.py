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
CHANGE = "\n".join(extract(marker) for marker in [
    "  func volumeChanged() {", "  private func rebuildForVolume() {",
    "  private func scheduleVolumeRebuild() {", "  private func cancelVolumeRebuild() {"])
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
check(AirPlayPCMVolume.apply(to: input, gain: 2) == pcm([-32768, -32000, -2, 0, 2, 32000, 32767]),
      "amplified PCM does not saturate")
check(AirPlayPCMVolume.apply(to: input, gain: .nan) == Data(count: input.count), "invalid gain is not silent")
check(AirPlayPCMVolume.apply(to: Data(), gain: 0.5).isEmpty, "empty PCM fails")
check(AirPlayPCMVolume.gain(volume: 100, muted: true) == 0, "mute does not override volume")
check(AirPlayPCMVolume.gain(volume: 0, muted: false) == 0, "zero volume is not silent")
// mpv's software volume is cubic; 50% is an eighth of full amplitude on the Mac.
check(AirPlayPCMVolume.gain(volume: 50, muted: false) == 0.125, "volume does not follow mpv's cubic curve")
check(AirPlayPCMVolume.gain(volume: 100, muted: false) == 1, "full volume is not unity gain")
check(AirPlayPCMVolume.gain(volume: 200, muted: false) == 8, "volume above 100% does not amplify like mpv")
check(AirPlayPCMVolume.gain(volume: 2000, muted: false) == AirPlayPCMVolume.maximumGain,
      "over-range volume is not bounded")
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
  static let volumeRebuildDelay: TimeInterval = 0.35
  var volumeRebuildTimer: Timer?
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
check(bridge.loader!.gain == 0.125 && bridge.replacements.count == 2, "unmute did not restore the user's gain")
check(bridge.avPlayer!.volume == 1 && !bridge.avPlayer!.isMuted, "native gain would square PCM volume")
func settle() { RunLoop.main.run(until: Date().addingTimeInterval(Bridge.volumeRebuildDelay + 0.25)) }
// A slider drag reports every step; each rebuild silences the speaker and holds the picture.
for volume in [60.0, 70, 80] {
  bridge.player!.info.volume = volume
  bridge.volumeChanged()
}
check(bridge.replacements.count == 2, "slider drag rebuilt the stream before it settled")
settle()
check(bridge.replacements.count == 3 && abs(bridge.loader!.gain - 0.512) < 1e-12,
      "slider drag did not rebuild once at its final volume")
bridge.player!.info.volume = 90
bridge.volumeChanged()
bridge.player!.info.volume = 80
bridge.volumeChanged()
settle()
check(bridge.replacements.count == 3, "returning to the playing gain still rebuilt the stream")
bridge.player!.info.volume = 0
bridge.volumeChanged()
check(bridge.loader!.gain == 0 && bridge.avPlayer!.isMuted && bridge.replacements.count == 4,
      "zero volume did not silence buffered audio at once")
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
    (GAIN.replace("min(linear * linear * linear, maximumGain)", "min(linear, maximumGain)"), CHANGE,
     "volume does not follow mpv's cubic curve"),
    (GAIN.replace("Int16(min(max(scaled, Double(Int16.min)), Double(Int16.max)))",
                  "Int16(truncatingIfNeeded: Int(scaled))"), CHANGE, "amplified PCM does not saturate"),
    (GAIN, CHANGE.replace("scheduleVolumeRebuild()\n        return", "rebuildForVolume()\n        return"),
     "slider drag rebuilt the stream before it settled"),
]:
    negative = run(gain, change)
    assert negative.returncode != 0 and message in negative.stdout, negative.stdout + negative.stderr
print("All six unsafe-volume negative controls failed as expected")
