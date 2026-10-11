import Foundation

@main
enum SubtitleTimingIndexChecks {
  private static var checks = 0

  private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else {
      fputs("FAIL: \(message)\n", stderr)
      exit(1)
    }
  }

  static func main() {
    typealias Cue = SubtitleAudioMatcher.Cue
    typealias Segment = SubtitleAudioMatcher.SpeechSegment

    let sparseCues = (0..<50_000).map { index in
      let start = Double(index * 10)
      return Cue(start: start, end: start + 1, isDialogue: true)
    }
    let sparseSegments = (0..<128).map { index in
      let start = 1_000_000.0 + Double(index * 3)
      return Segment(start: start, end: start + 1)
    }
    check(!SubtitleAudioMatcher.indexedMatchesForCheck(cues: sparseCues, segments: sparseSegments,
                                                        planStart: 0).contains(true),
          "sparse subtitle timelines with no nearby cues do not align")

    let cueEndBoundary = [Cue(start: 102, end: 103, isDialogue: true)]
    let cueEndResults = SubtitleAudioMatcher.indexedMatchesForCheck(
      cues: cueEndBoundary,
      segments: [Segment(start: 3.7, end: 4), Segment(start: 3.7001, end: 4)],
      planStart: 100)
    check(cueEndResults == [true, false], "cue-end tolerance is inclusive at exactly 700 ms")

    let cueStartBoundary = [Cue(start: 104, end: 104.5, isDialogue: true)]
    let cueStartResults = SubtitleAudioMatcher.indexedMatchesForCheck(
      cues: cueStartBoundary,
      segments: [Segment(start: 2.5, end: 3.3), Segment(start: 2.5, end: 3.2999)],
      planStart: 100)
    check(cueStartResults == [true, false], "cue-start tolerance is inclusive at exactly 700 ms")

    let overlappingCues = [
      Cue(start: 0, end: 100, isDialogue: true),
      Cue(start: 10, end: 10.1, isDialogue: true),
      Cue(start: 20, end: 20.1, isDialogue: true),
    ]
    let overlapResult = SubtitleAudioMatcher.indexedMatchesForCheck(
      cues: overlappingCues, segments: [Segment(start: 50, end: 50.1)], planStart: 0)
    check(overlapResult == [true], "prefix maximum end finds an early long cue among later short cues")

    let nondialogueResult = SubtitleAudioMatcher.indexedMatchesForCheck(
      cues: [Cue(start: 0, end: 100, isDialogue: false)],
      segments: [Segment(start: 50, end: 51)], planStart: 0)
    check(nondialogueResult == [false], "non-dialogue cues remain excluded")

    // Compare against the previous per-segment contains predicate over deterministic overlapping,
    // sparse, boundary, and reversed intervals to ensure the index keeps its exact inclusive rule.
    let referenceCues = (0..<200).map { index -> Cue in
      let start = Double((index * 37) % 97) - 20
      let duration = Double((index * 19) % 12) / 3
      return Cue(start: start, end: start + duration, isDialogue: index % 5 != 0)
    }
    let referenceSegments = (0..<180).map { index -> Segment in
      let start = Double((index * 11) % 120) - 20
      let duration = Double(index % 7) / 4
      return index % 9 == 0
        ? Segment(start: start + duration, end: start)
        : Segment(start: start, end: start + duration)
    }
    let planStart = 5.25
    let indexedResults = SubtitleAudioMatcher.indexedMatchesForCheck(
      cues: referenceCues, segments: referenceSegments, planStart: planStart)
    let referenceResults = referenceSegments.map { segment in
      referenceCues.contains { cue in
        cue.isDialogue && cue.start <= planStart + segment.end + 0.7 &&
          cue.end + 0.7 >= planStart + segment.start
      }
    }
    check(indexedResults == referenceResults, "indexed lookup matches the former scan across adversarial intervals")

    print("PASS: \(checks) subtitle timing index checks passed (50,000 sparse cues, inclusive boundaries, overlap, and differential cases)")
  }
}
