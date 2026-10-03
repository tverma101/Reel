import Foundation

@main
struct SpeechCaptionResultStoreChecks {
  static var checks = 0

  static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else {
      fputs("FAIL: \(message)\n", stderr)
      exit(1)
    }
  }

  static func main() {
    var store = SpeechCaptionResultStore()
    store.applyProgressiveResult(chunkStart: 10, audioStart: 10, audioEnd: 12, text: "First wording")
    store.applyProgressiveResult(chunkStart: 10, audioStart: 10.04, audioEnd: 12.1, text: "Revised wording")
    check(store.cues.count == 1 && store.cues[0].text == "Revised wording",
          "replaces a revision with a slightly shifted start and expanded range")

    store.applyProgressiveResult(chunkStart: 10, audioStart: 12.2, audioEnd: 13.4, text: "Adjacent phrase")
    store.applyProgressiveResult(chunkStart: 10, audioStart: 11.8, audioEnd: 12.5, text: "Combined phrase")
    check(store.cues.map(\.text) == ["Combined phrase"],
          "a revised range removes every overlapping prior phrase")

    store.applyProgressiveResult(chunkStart: 10, audioStart: 11.8, audioEnd: 12.5, text: "   ")
    check(store.cues.isEmpty, "empty text revokes the previous result for that range")

    store.applyProgressiveResult(chunkStart: 10, audioStart: 10, audioEnd: 11, text: "Before")
    store.applyProgressiveResult(chunkStart: 10, audioStart: 11, audioEnd: 12, text: "After")
    store.applyProgressiveResult(chunkStart: 20, audioStart: 10.2, audioEnd: 10.8, text: "Other chunk")
    check(store.cues.map(\.text) == ["Before", "Other chunk", "After"],
          "preserves endpoint-adjacent ranges and same-time results from another chunk")

    store.applyProgressiveResult(chunkStart: 10, audioStart: .nan, audioEnd: 12, text: "Invalid")
    store.applyProgressiveResult(chunkStart: 10, audioStart: 12, audioEnd: 12, text: "Zero range")
    check(store.cues.count == 3, "ignores non-finite and zero-length result ranges")

    let legacyCues = [
      SpeechCaptionResultStore.Cue(chunkStart: 30, start: 30, end: 30.7, audioEnd: 30.2, text: "Legacy one"),
      SpeechCaptionResultStore.Cue(chunkStart: 30, start: 30.3, end: 31, audioEnd: 30.6, text: "Legacy two"),
    ]
    store.replaceChunk(30, with: legacyCues)
    store.replaceChunk(30, with: [legacyCues[0]])
    check(store.cues.filter { $0.chunkStart == 30 }.count == 1,
          "legacy partial transcription replaces its chunk rather than duplicating segments")
    var displayStore = SpeechCaptionResultStore()
    displayStore.replaceChunk(40, with: [
      SpeechCaptionResultStore.Cue(chunkStart: 40, start: 40, end: 45, audioEnd: 44, text: "One"),
      SpeechCaptionResultStore.Cue(chunkStart: 40, start: 40.2, end: 45.1, audioEnd: 44.1, text: "Two"),
      SpeechCaptionResultStore.Cue(chunkStart: 40, start: 40.4, end: 45.2, audioEnd: 44.2, text: "Three"),
    ])
    check(displayStore.text(at: 41) == "Two Three",
          "renders only the latest two active cues at the requested media position")
    displayStore.replaceChunk(40, with: [
      SpeechCaptionResultStore.Cue(chunkStart: 40, start: 40, end: 40.7, audioEnd: 40.2, text: "Expired"),
      SpeechCaptionResultStore.Cue(chunkStart: 40, start: 41, end: 42, audioEnd: 41.5, text: "Current"),
    ])
    displayStore.removeCues(endingBefore: 40.8)
    check(displayStore.cues.map(\.text) == ["Current"], "prunes cues before the playback window")

    var timeline = SpeechCaptionPlaybackTimeline()
    check(!timeline.movedBack(to: 100), "the first playhead sample establishes a baseline")
    check(!timeline.movedBack(to: 99.5), "small playhead jitter does not reset captions")
    check(timeline.movedBack(to: 90), "a backward seek is detected within the cue-retention window")
    check(!timeline.movedBack(to: 90.2), "playback after a seek establishes a new baseline")
    timeline.reset()
    check(!timeline.movedBack(to: 10), "resetting the media timeline drops its old baseline")

    print("\(checks) speech caption result store checks passed")
  }
}
