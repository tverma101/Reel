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
precondition(AirPlayPCMResourceLoader.frameCount(for: .nan) == AirPlayPCMResourceLoader.maximumFrames)
precondition(AirPlayPCMResourceLoader.frameCount(for: .infinity) == AirPlayPCMResourceLoader.maximumFrames)
precondition(AirPlayPCMResourceLoader.frameCount(for: Double.greatestFiniteMagnitude) == AirPlayPCMResourceLoader.maximumFrames)
precondition(!AirPlayPCMResourceLoader.audioClockHasAdvanced(from: nil, to: 2))
precondition(AirPlayPCMResourceLoader.audioClockHasAdvanced(from: 2, to: 2.2),
             "audio-clock movement is detected while a low-fps video may repeat its displayed frame")
precondition(!AirPlayPCMResourceLoader.audioClockHasAdvanced(from: 2, to: .nan))
var speakerClock = AirPlaySpeakerClock()
let speakerClockStart = Date(timeIntervalSince1970: 2_000)
speakerClock.reset(position: 0)
speakerClock.observe(position: 0, at: speakerClockStart)
precondition(!speakerClock.hasAdvanced, "a stationary AVPlayer clock is not playback progress")
precondition(!speakerClock.hasStalled(at: speakerClockStart.addingTimeInterval(3),
                                     stallTimeout: 1, startupTimeout: 4))
precondition(speakerClock.hasStalled(at: speakerClockStart.addingTimeInterval(4.1),
                                    stallTimeout: 1, startupTimeout: 4),
             "a route that reports playing without starting its clock must fail over")
speakerClock.reset(position: 10)
speakerClock.observe(position: 9.99, at: speakerClockStart.addingTimeInterval(5))
precondition(!speakerClock.hasAdvanced, "a backwards clock correction is not playback progress")
speakerClock.observe(position: 10.1, at: speakerClockStart.addingTimeInterval(5.1))
precondition(speakerClock.hasAdvanced)
precondition(!speakerClock.hasStalled(at: speakerClockStart.addingTimeInterval(5.9),
                                     stallTimeout: 1, startupTimeout: 4))
precondition(speakerClock.hasStalled(at: speakerClockStart.addingTimeInterval(6.2),
                                    stallTimeout: 1, startupTimeout: 4),
             "a route that stops after playback begins must fail over")
speakerClock.markBlocked(position: 10.1)
precondition(!speakerClock.hasAdvanced, "buffering resets the clock's stall window")
let requestCancellation = AirPlayRequestCancellation()
precondition(!requestCancellation.isCancelled)
requestCancellation.cancel()
precondition(requestCancellation.isCancelled, "a canceled AVFoundation range is visible to FFmpeg")
var audioStartClock = AirPlayAudioStartupClock()
let startup = Date(timeIntervalSince1970: 1_000)
audioStartClock.markBlocked()
audioStartClock.markCanProgress(at: startup)
precondition(!audioStartClock.hasExpired(at: startup.addingTimeInterval(9), timeout: 10))
audioStartClock.markBlocked() // User pause or mpv cache buffering excludes the blocked interval.
precondition(!audioStartClock.hasExpired(at: startup.addingTimeInterval(120), timeout: 10))
audioStartClock.markCanProgress(at: startup.addingTimeInterval(120))
precondition(!audioStartClock.hasExpired(at: startup.addingTimeInterval(129), timeout: 10))
precondition(audioStartClock.hasExpired(at: startup.addingTimeInterval(131), timeout: 10))
let frames = AirPlayPCMResourceLoader.frameCount(for: duration)
let loader = AirPlayPCMResourceLoader(source: arguments[1], streamIndex: streamIndex, mediaOrigin: nil,
                                      frameCount: frames) { print("loader failed") }
let asset = AVURLAsset(url: URL(string: "\(AirPlayPCMResourceLoader.scheme)://audio/1.wav")!)
asset.resourceLoader.setDelegate(loader, queue: loader.delegateQueue)
let item = AVPlayerItem(asset: asset)
let player = AVPlayer(playerItem: item)
if let outputDevice = ProcessInfo.processInfo.environment["REEL_TEST_AUDIO_UID"] {
  player.audioOutputDeviceUniqueID = outputDevice
}
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
