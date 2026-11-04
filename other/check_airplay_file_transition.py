#!/usr/bin/env python3
"""Exercise the production selector while MPV and AppKit cross a file boundary."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "iina/AirPlayAudioBridge.swift").read_text()
start = source.index("  private func audioSelection()")
end = source.index("  private func replaceItem(", start)
selector = source[start:end].replace("private func", "func", 1)

HARNESS = r'''
import Foundation
enum TrackType { case audio }
struct Track {
  var ffIndex: Int? = 1
  var isExternal = false
  var externalFilename: String?
}
struct Snapshot {
  var fileTransitionGeneration: UInt64 = 4
  var currentPlaylistEntryID: Int64? = 10
  var rebaseStartTime: Bool? = true
  var demuxerStartTime: Double? = 0
  var streamOpenFilename: String?
}
final class MPV { var airPlayPlaybackSnapshot = Snapshot() }
final class Info {
  var aid: Int? = 1
  var track: Track? = Track()
  var currentURL: URL? = URL(fileURLWithPath: "/fixture.mkv")
  func currentTrack(_ type: TrackType) -> Track? { track }
}
final class Player { let info = Info(); var mpv: MPV! = MPV() }
final class Bridge {
  struct Selection { let source: String; let streamIndex: Int; let origin: Double? }
  enum AudioSelection { case pending, noAudio, unsupported(String), supported(Selection) }
  let player: Player? = Player()
  var currentFileTransitionGeneration: UInt64? = 4
  var currentPlaylistEntryID: Int64? = 10
  __SELECTOR__
}
func check(_ value: Bridge.AudioSelection, _ expected: String, _ message: String) {
  let actual: String
  switch value {
  case .pending: actual = "pending"
  case .noAudio: actual = "none"
  case .unsupported: actual = "unsupported"
  case .supported: actual = "supported"
  }
  guard actual == expected else { print("FAIL: \(message): \(actual)"); exit(1) }
}
let bridge = Bridge()
let player = bridge.player!
check(bridge.audioSelection(), "supported", "loaded file")
// MPV has published START_FILE; queued metadata callbacks arrive before AppKit's fileStarted.
player.mpv.airPlayPlaybackSnapshot.fileTransitionGeneration = 5
check(bridge.audioSelection(), "pending", "stale file metadata crossed START_FILE")
bridge.currentFileTransitionGeneration = 5
player.mpv.airPlayPlaybackSnapshot.currentPlaylistEntryID = 11
check(bridge.audioSelection(), "pending", "stale playlist entry crossed START_FILE")
bridge.currentPlaylistEntryID = 11
player.info.track = nil
check(bridge.audioSelection(), "pending", "track-list temporarily precedes aid")
player.info.aid = nil
check(bridge.audioSelection(), "pending", "aid not yet reported")
player.info.aid = 0
check(bridge.audioSelection(), "none", "confirmed no-audio file")
player.info.aid = 1
player.info.track = Track(ffIndex: 2)
check(bridge.audioSelection(), "supported", "new file metadata ready")
player.info.currentURL = nil
check(bridge.audioSelection(), "pending", "URL not yet reported")
player.info.currentURL = URL(fileURLWithPath: "/next.mkv")
check(bridge.audioSelection(), "supported", "metadata recovery after URL")
player.info.currentURL = URL(string: "HTTPS://media.example.test/audio.mp4")
player.mpv.airPlayPlaybackSnapshot.streamOpenFilename = "HTTPS://media.example.test/audio.mp4"
check(bridge.audioSelection(), "supported", "uppercase HTTP URL must remain bridgeable")
player.mpv.airPlayPlaybackSnapshot.streamOpenFilename = "file:///unexpected-audio.mp4"
check(bridge.audioSelection(), "unsupported", "unsupported opened stream scheme")
player.mpv.airPlayPlaybackSnapshot.streamOpenFilename = nil
player.info.currentURL = URL(fileURLWithPath: "/next.mkv")
player.info.track = Track(ffIndex: nil)
check(bridge.audioSelection(), "unsupported", "unbridgeable stream still falls back")
print("AirPlay file-transition selector passed")
'''


def run(method):
    with tempfile.TemporaryDirectory(prefix="reel-file-transition-") as directory:
        swift = Path(directory) / "main.swift"
        swift.write_text(HARNESS.replace("__SELECTOR__", method))
        binary = Path(directory) / "check"
        subprocess.run(["swiftc", str(swift), "-o", str(binary)], check=True)
        return subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)


result = run(selector)
assert result.returncode == 0, result.stdout + result.stderr
print(result.stdout.strip())
for mutated, expected in [
    (selector.replace("guard currentFileTransitionGeneration == snapshot.fileTransitionGeneration,\n"
                      "          currentPlaylistEntryID == snapshot.currentPlaylistEntryID else { return .pending }",
                      ""), "stale file metadata"),
    (selector.replace("// aid and track-list are separate events, including when a track is changed mid-file.\n"
                      "      return .pending", 'return .unsupported("missing track")'), "track-list temporarily"),
    (selector.replace("guard let aid = player.info.aid else { return .pending }",
                      "guard let aid = player.info.aid else { return .noAudio }"),
     "aid not yet reported"),
    (selector.replace("guard let url = player.info.currentURL else { return .pending }",
                      'guard let url = player.info.currentURL else { return .unsupported("no URL") }'),
     "URL not yet reported"),
    (selector.replace('guard let openedScheme = URL(string: opened)?.scheme?.lowercased(),\n'
                      '          ["http", "https"].contains(openedScheme) else {',
                      'guard opened.hasPrefix("http://") || opened.hasPrefix("https://") else {'),
     "uppercase HTTP URL"),
]:
    assert mutated != selector, "negative control did not mutate production code"
    negative = run(mutated)
    assert negative.returncode != 0 and expected in negative.stdout, negative.stdout + negative.stderr
print("All five pre-fix negative controls failed as expected")
