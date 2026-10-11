import Foundation

@main
struct SubtitleAudioParserChecks {
  static var checks = 0

  static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else {
      fputs("FAIL: \(message)\n", stderr)
      exit(1)
    }
  }

  static func main() throws {
    guard let directory = ProcessInfo.processInfo.environment["CHECK_FIXTURE_DIR"] else {
      fatalError("CHECK_FIXTURE_DIR is missing")
    }
    let root = URL(fileURLWithPath: directory, isDirectory: true)

    let webVTT = """
    \u{feff}WEBVTT - captions

    Kind: captions
    Language: en

    NOTE metadata should not become cue text

    chapter-one
    00:00:01.000 --> 00:00:02.000 align:start position:0%
    Hello there friend.

    chapter-two
    00:00:03.000 --> 00:00:04.000 line:80% align:center
    We are safe here.
    """
    let webURL = root.appendingPathComponent("settings-and-identifiers.vtt")
    try Data(webVTT.replacingOccurrences(of: "\n", with: "\r\n").utf8).write(to: webURL)
    let webCues = SubtitleAudioMatcher.parseForCheck(fileURL: webURL) ?? []
    check(webCues.map(\.text) == ["Hello there friend.", "We are safe here."],
          "WebVTT cue settings and identifiers are excluded from dialogue text")

    let srt = """
    1
    00:00:01,000 --> 00:00:02,000
    First cue is here.

    2
    00:00:03,000 --> 00:00:04,000
    Second cue is here.
    """
    let srtURL = root.appendingPathComponent("numbered.srt")
    try Data(srt.utf8).write(to: srtURL)
    let srtCues = SubtitleAudioMatcher.parseForCheck(fileURL: srtURL) ?? []
    check(srtCues.map(\.text) == ["First cue is here.", "Second cue is here."],
          "SRT cue numbers remain excluded from dialogue text")

    let oversizedVTT = """
    WEBVTT

    00:00:01.000 --> 00:00:02.000
    \(String(repeating: "A", count: 3_000))
    \(String(repeating: "B", count: 3_000))
    """
    let oversizedURL = root.appendingPathComponent("oversized-cue.vtt")
    try Data(oversizedVTT.utf8).write(to: oversizedURL)
    let oversizedCues = SubtitleAudioMatcher.parseForCheck(fileURL: oversizedURL) ?? []
    check(oversizedCues.count == 1 && oversizedCues[0].text.utf16.count <= 4_096,
          "WebVTT cue text retains the parser's per-cue size bound")

    let oversizedLineVTT = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n" +
      String(repeating: "A", count: 4_097) + "\n\n" +
      "00:00:03.000 --> 00:00:04.000\nBounded line survives.\n"
    let oversizedLineURL = root.appendingPathComponent("oversized-line.vtt")
    try Data(oversizedLineVTT.utf8).write(to: oversizedLineURL)
    let oversizedLineCues = SubtitleAudioMatcher.parseForCheck(fileURL: oversizedLineURL) ?? []
    check(oversizedLineCues.map(\.text) == ["Bounded line survives."],
          "An overlong WebVTT line drops only its block without copying or accepting that line")

    let oversizedBlockVTT = "WEBVTT\n\nidentifier\n00:00:01.000 --> 00:00:02.000\n" +
      String(repeating: "filler\n", count: 31) + "\n" +
      "00:00:03.000 --> 00:00:04.000\nBounded block survives.\n"
    let oversizedBlockURL = root.appendingPathComponent("oversized-block.vtt")
    try Data(oversizedBlockVTT.utf8).write(to: oversizedBlockURL)
    let oversizedBlockCues = SubtitleAudioMatcher.parseForCheck(fileURL: oversizedBlockURL) ?? []
    check(oversizedBlockCues.map(\.text) == ["Bounded block survives."],
          "An overlong WebVTT block is discarded at the configured line-count bound")

    let newlineDenseVTT = "WEBVTT\n" + String(repeating: "\n", count: 200_001) +
      "00:00:01.000 --> 00:00:02.000\nThis cue is beyond the line limit.\n"
    let newlineDenseURL = root.appendingPathComponent("newline-dense-under-byte-cap.vtt")
    let newlineDenseData = Data(newlineDenseVTT.utf8)
    check(newlineDenseData.count < 10 * 1024 * 1024,
          "newline-dense fixture exercises the line bound below production's 10 MiB byte cap")
    try newlineDenseData.write(to: newlineDenseURL)
    let newlineDenseCues = SubtitleAudioMatcher.parseForCheck(fileURL: newlineDenseURL) ?? []
    check(newlineDenseCues.isEmpty,
          "A newline-dense WebVTT stops at the line bound before reaching trailing cue data")

    print("\(checks) subtitle audio parser checks passed")
  }
}
