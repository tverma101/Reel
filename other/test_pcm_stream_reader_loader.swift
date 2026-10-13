// Driver for test_pcm_stream_reader.py: plays the WAV stream of AirPlayPCMResourceLoader (extracted
// from iina/AirPlayAudioBridge.swift) in a muted AVPlayer.
//
//   loader <media> <ffIndex> <duration>
import AVFoundation
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4, let streamIndex = Int(arguments[2]), let duration = Double(arguments[3]) else {
  print("usage: loader <media> <ffIndex> <duration>")
  exit(2)
}
let frames = Int64((duration + 2) * AirPlayPCMResourceLoader.sampleRate)
let loader = AirPlayPCMResourceLoader(source: arguments[1], streamIndex: streamIndex, mediaOrigin: nil,
                                      frameCount: frames) { print("loader failed") }
let asset = AVURLAsset(url: URL(string: "\(AirPlayPCMResourceLoader.scheme)://audio/1.wav")!)
asset.resourceLoader.setDelegate(loader, queue: loader.queue)
let item = AVPlayerItem(asset: asset)
let player = AVPlayer(playerItem: item)
player.isMuted = true

func wait(_ timeout: TimeInterval, until condition: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while !condition() && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
  }
  return condition()
}
func position() -> Double { player.currentTime().seconds }

let opened = Date()
_ = wait(10) { item.status != .unknown }
print(String(format: "ready status=%d seconds=%.3f duration=%.3f expected=%.3f", item.status.rawValue,
             Date().timeIntervalSince(opened), item.duration.seconds, Double(frames) / AirPlayPCMResourceLoader.sampleRate))
guard item.status == .readyToPlay else { exit(1) }

player.play()
_ = wait(5) { player.timeControlStatus == .playing }
loader.setPlayhead(seconds: position())
RunLoop.main.run(until: Date().addingTimeInterval(1.5))
print(String(format: "play advanced=%.3f", position()))

for target in [duration * 0.75, duration * 0.25] {
  var finished = false
  player.pause()
  player.seek(to: CMTime(seconds: target, preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero) {
    finished = $0
  }
  loader.setPlayhead(seconds: target)
  _ = wait(10) { finished }
  let landed = position()
  player.play()
  _ = wait(5) { player.timeControlStatus == .playing }
  RunLoop.main.run(until: Date().addingTimeInterval(1))
  print(String(format: "seek target=%.3f finished=%d landed=%.3f advanced=%.3f", target, finished ? 1 : 0,
               landed, position() - landed))
}
player.pause()
loader.invalidate()
print(String(format: "done status=%d", item.status.rawValue))
