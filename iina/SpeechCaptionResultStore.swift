import Foundation

/// Stores the latest transcription for each audio range. SpeechTranscriber can revise or revoke
/// a volatile result, so replacing only results with an identical start time leaves stale text.
struct SpeechCaptionResultStore {
  struct Cue: Equatable {
    let chunkStart: Double
    let start: Double
    let end: Double
    let audioEnd: Double
    let text: String
    let receivedAt: TimeInterval

    init(chunkStart: Double, start: Double, end: Double, audioEnd: Double, text: String,
         receivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
      self.chunkStart = chunkStart
      self.start = start
      self.end = end
      self.audioEnd = audioEnd
      self.text = text
      self.receivedAt = receivedAt
    }
  }

  private static let lateCueArrivalGrace: TimeInterval = 3
  private static let maximumLateCueMediaLag: Double = 10

  private(set) var cues: [Cue] = []

  mutating func applyProgressiveResult(chunkStart: Double, audioStart: Double, audioEnd: Double, text: String,
                                      receivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    guard chunkStart.isFinite, audioStart.isFinite, audioEnd.isFinite,
          chunkStart >= 0, audioStart >= 0, audioEnd > audioStart else { return }

    cues.removeAll {
      $0.chunkStart == chunkStart && $0.start < audioEnd && audioStart < $0.audioEnd
    }

    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    cues.append(Cue(chunkStart: chunkStart, start: audioStart,
                    end: max(audioStart + 0.7, audioEnd), audioEnd: audioEnd,
                    text: text, receivedAt: receivedAt))
    sortCues()
  }

  mutating func replaceChunk(_ chunkStart: Double, with replacements: [Cue]) {
    guard chunkStart.isFinite else { return }
    cues.removeAll { $0.chunkStart == chunkStart }
    let receivedAt = ProcessInfo.processInfo.systemUptime
    cues.append(contentsOf: replacements.filter {
      $0.chunkStart == chunkStart && $0.start.isFinite && $0.end.isFinite && $0.audioEnd.isFinite &&
        $0.start >= 0 && $0.end > $0.start && $0.audioEnd > $0.start && !$0.text.isEmpty
    }.map {
      Cue(chunkStart: $0.chunkStart, start: $0.start, end: $0.end, audioEnd: $0.audioEnd,
          text: $0.text, receivedAt: receivedAt)
    })
    sortCues()
  }

  mutating func removeCues(endingBefore position: Double) {
    cues.removeAll { $0.end < position }
  }

  mutating func removeAll() {
    cues.removeAll()
  }

  func text(at position: Double, now: TimeInterval = ProcessInfo.processInfo.systemUptime,
            playbackRate: Double = 1) -> String {
    guard position.isFinite, now.isFinite else { return "" }
    var activeCues: [Cue] = []
    for cue in cues.reversed() where position >= cue.start - 0.15 && position <= cue.end + 0.6 {
      activeCues.append(cue)
      if activeCues.count == 2 { break }
    }
    if !activeCues.isEmpty {
      return activeCues.reversed().map(\.text).joined(separator: " ")
    }

    // Recognition runs on a decoded chunk and may finish after the playhead has passed a cue.
    // Briefly show the newest recently-arrived past cue so chunk latency does not create a visual gap.
    let rate = playbackRate.isFinite && playbackRate != 0 ? abs(playbackRate) : 1
    let allowedMediaLag = min(Self.maximumLateCueMediaLag, max(1.5, rate * Self.lateCueArrivalGrace))
    var latestLateCue: Cue?
    for cue in cues where cue.end + 0.6 < position && position - cue.end <= allowedMediaLag {
      let age = now - cue.receivedAt
      guard age >= 0, age <= Self.lateCueArrivalGrace else { continue }
      if latestLateCue == nil || cue.end > latestLateCue!.end {
        latestLateCue = cue
      }
    }
    return latestLateCue?.text ?? ""
  }

  private mutating func sortCues() {
    cues.sort { $0.start < $1.start }
  }
}

/// Tracks the media playhead so live captions can discard results from before a backward seek,
/// including seeks that remain inside the result store's retention window.
struct SpeechCaptionPlaybackTimeline {
  private(set) var lastPosition: Double?
  private let backwardSeekTolerance: Double = 1

  mutating func movedBack(to position: Double) -> Bool {
    guard position.isFinite, position >= 0 else {
      lastPosition = nil
      return false
    }
    defer { lastPosition = position }
    guard let lastPosition else { return false }
    return position < lastPosition - backwardSeekTolerance
  }

  mutating func reset() {
    lastPosition = nil
  }
}
