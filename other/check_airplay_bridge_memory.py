"""Check the AirPlay audio bridge's streaming memory.

The bridge decodes ahead of the speaker and hands the audio to AVFoundation as a WAV stream. Only
20 s should ever be in flight (AirPlayPCMResourceLoader.leadFrames), so a fixed playback window
streams a bounded number of bytes; the speaker itself buffers about two seconds. This check builds
the loader with a trace hook, plays a 120 s file for a fixed window, and fails when more audio than
the lead allows was streamed. It also reports the process's peak resident size.

Needs the downloaded deps (`other/download_libs.sh`) and an ffmpeg command, like
other/test_pcm_stream_reader.py.
"""

import argparse
import os
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEPS = ROOT / "deps"
LIBRARIES = DEPS / "lib"
FFMPEG = shutil.which("ffmpeg")
# 48 kHz stereo s16.
BYTES_PER_SECOND = 48000 * 4
DURATION = 120.0


def run_checked(command):
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"{command[0]} failed ({result.returncode}):\n{result.stdout}\n{result.stderr}")
    return result.stdout


def extract(path, start, end, after=None):
    text = path.read_text()
    begin = text.index(start)
    finish = text.index(end, text.index(after, begin) if after else begin)
    return text[begin:finish + len(end)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--play-seconds", type=float, default=20.0)
    parser.add_argument("--budget-mb", type=float, default=None,
                        help="maximum streamed megabytes (default: the lead plus the window, plus slack)")
    arguments = parser.parse_args()
    lead_seconds = 20.0
    budget = arguments.budget_mb
    if budget is None:
        budget = (lead_seconds + arguments.play_seconds + 8) * BYTES_PER_SECOND / 1_048_576

    work = Path(tempfile.mkdtemp(prefix="reel-airplay-memory-"))

    interface = extract(ROOT / "iina/FFmpegController.h", "@interface FFmpegPCMStreamReader", "@end")
    (work / "pcm_stream_reader.h").write_text("#import <Foundation/Foundation.h>\n" + interface + "\n")
    implementation = extract(ROOT / "iina/FFmpegController.m", "// MARK: - FFmpegPCMStreamReader",
                             "\n@end", after="@implementation FFmpegPCMStreamReader")
    (work / "pcm_stream_reader.m").write_text("\n".join([
        "#import <Foundation/Foundation.h>", "#include <errno.h>", "#include <limits.h>",
        '#import "FFmpegAudioLimits.h"', "#import <libavcodec/avcodec.h>",
        "#import <libavformat/avformat.h>", "#import <libavutil/channel_layout.h>",
        "#import <libswresample/swresample.h>", '#import "pcm_stream_reader.h"', implementation, ""]))

    loader = extract(ROOT / "iina/AirPlayAudioBridge.swift", "// MARK: - WAV stream", "// MARK: - Bridge")
    anchor = "  private func readFrames(at frame: Int64, count: Int) -> Data? {\n"
    assert anchor in loader, "the loader's read entry point moved; update this check"
    loader = loader.replace(anchor, anchor + "    AirPlayTrace.read(count: count)\n", 1)
    (work / "loader.swift").write_text("import AVFoundation\nimport Foundation\n\n" + loader + "\n")

    (work / "main.swift").write_text('''
import AVFoundation
import Foundation

final class AirPlayTrace {
  private static let lock = NSLock()
  private static var streamedBytes: Int64 = 0
  private static var reads = 0
  static func read(count: Int) {
    lock.lock(); defer { lock.unlock() }
    reads += 1
    streamedBytes += Int64(count) * 4
  }
  static func summary() -> (reads: Int, mb: Double) {
    lock.lock(); defer { lock.unlock() }
    return (reads, Double(streamedBytes) / 1_048_576)
  }
}

let arguments = CommandLine.arguments
guard arguments.count == 5, let streamIndex = Int(arguments[2]), let duration = Double(arguments[3]),
      let playSeconds = Double(arguments[4]) else { exit(2) }
let frames = Int64((duration + 2) * AirPlayPCMResourceLoader.sampleRate)
let loader = AirPlayPCMResourceLoader(source: arguments[1], streamIndex: streamIndex, mediaOrigin: nil,
                                      frameCount: frames) { print("loader failed") }
let asset = AVURLAsset(url: URL(string: "\\(AirPlayPCMResourceLoader.scheme)://audio/1.wav")!)
asset.resourceLoader.setDelegate(loader, queue: loader.queue)
let item = AVPlayerItem(asset: asset)
let player = AVPlayer(playerItem: item)
player.isMuted = true

func wait(_ timeout: TimeInterval, until condition: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
  return condition()
}
func rssMB() -> Double {
  var info = mach_task_basic_info()
  var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
  let result = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
    }
  }
  return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
}

_ = wait(15) { item.status != .unknown }
guard item.status == .readyToPlay else {
  print("ready failed status=\\(item.status.rawValue)")
  exit(1)
}
var peakRSS = rssMB()
player.play()
_ = wait(5) { player.timeControlStatus == .playing }

let started = Date()
while Date().timeIntervalSince(started) < playSeconds {
  RunLoop.main.run(until: Date().addingTimeInterval(0.05))
  loader.setPlayhead(seconds: player.currentTime().seconds)
  peakRSS = max(peakRSS, rssMB())
}
let summary = AirPlayTrace.summary()
print(String(format: "played=%.1fs streamedMB=%.2f reads=%d peakRSSMB=%.1f", playSeconds, summary.mb,
             summary.reads, peakRSS))
player.pause()
loader.invalidate()
''')

    clang = ["/usr/bin/xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-O2", "-Wall", "-Wextra",
             "-Wno-unused-parameter", "-Werror", "-I", str(DEPS / "include"), "-I", str(ROOT / "iina"),
             "-I", str(work)]
    run_checked(clang + ["-c", str(work / "pcm_stream_reader.m"), "-o", str(work / "reader.o")])
    run_checked(["/usr/bin/xcrun", "--sdk", "macosx", "swiftc", "-O",
                 "-import-objc-header", str(work / "pcm_stream_reader.h"), str(work / "loader.swift"),
                 str(work / "main.swift"), str(work / "reader.o"),
                 "-L", str(LIBRARIES), "-Xlinker", "-rpath", "-Xlinker", str(LIBRARIES),
                 "-lavcodec.63", "-lavformat.63", "-lavutil.61", "-lswresample.7",
                 "-o", str(work / "loader")])

    media = work / "media.mkv"
    run_checked([FFMPEG, "-v", "error", "-y",
                 "-f", "lavfi", "-i", f"testsrc2=size=320x240:rate=24:duration={DURATION:.0f}",
                 "-f", "lavfi", "-i", f"anoisesrc=d={DURATION:.0f}:c=pink:r=48000:a=0.3:seed=7",
                 "-filter_complex", "[1:a]lowpass=f=4000,lowpass=f=4000[a]",
                 "-map", "0:v", "-map", "[a]", "-c:v", "mpeg4", "-g", "48", "-c:a", "aac",
                 "-b:a", "192k", str(media)])

    environment = dict(os.environ, DYLD_LIBRARY_PATH=str(LIBRARIES))
    result = subprocess.run([str(work / "loader"), str(media), "1", f"{DURATION:.0f}",
                             str(arguments.play_seconds)],
                            cwd=ROOT, env=environment, capture_output=True, text=True, timeout=300)
    output = result.stdout.strip()
    print(output)
    if result.returncode != 0:
        print(result.stderr[-2000:])
        raise SystemExit(f"loader exited {result.returncode}")
    streamed = float(output.split("streamedMB=")[1].split()[0])
    if streamed > budget:
        raise SystemExit(f"streamed {streamed:.2f} MB > budget {budget:.2f} MB "
                         f"(the lead or the buffering grew)")
    print(f"ok: streamed {streamed:.2f} MB <= {budget:.2f} MB budget")
    shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
