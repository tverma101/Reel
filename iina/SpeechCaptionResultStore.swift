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

  /// A recognized word (or a run of words sharing one timestamp) with its media-time range. The text
  /// keeps the recognizer's own spacing and punctuation.
  struct TimedWord: Equatable {
    let text: String
    let start: Double
    let end: Double
  }

  private static let lateCueArrivalGrace: TimeInterval = 3
  private static let maximumLateCueMediaLag: Double = 10
  /// How long a line stays up after its last word when nothing follows, so short pauses do not
  /// make the caption blink.
  private static let lineHold: Double = 1
  /// A caption may appear this much before its first word.
  private static let leadIn: Double = 0.15

  /// Groups words into subtitle-sized lines: at most `maxCharacters`, at most `maxDuration` seconds,
  /// and broken at sentence ends and at pauses, so each line is on screen while it is being said.
  static func captionLines(from words: [TimedWord], maxCharacters: Int = 42, maxDuration: Double = 4,
                           pauseBreak: Double = 0.8) -> [TimedWord] {
    var lines: [TimedWord] = []
    var text = ""
    var start = 0.0
    var end = 0.0
    func flush() {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { lines.append(TimedWord(text: trimmed, start: start, end: end)) }
      text = ""
    }
    for word in words where word.start.isFinite && word.end.isFinite && word.end >= word.start {
      let pending = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !pending.isEmpty {
        let combined = (text + word.text).trimmingCharacters(in: .whitespacesAndNewlines)
        if combined.count > maxCharacters || word.end - start > maxDuration || word.start - end > pauseBreak {
          flush()
        }
      }
      if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { start = word.start }
      text += word.text
      end = max(end, word.end)
      if let last = word.text.trimmingCharacters(in: .whitespacesAndNewlines).last, ".?!".contains(last) {
        flush()
      }
    }
    flush()
    return lines
  }

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

  /// Stores a final result as caption lines built from its word timings.
  mutating func applyFinalResult(chunkStart: Double, words: [TimedWord],
                                 receivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    let lines = Self.captionLines(from: words)
    guard chunkStart.isFinite, chunkStart >= 0, let first = lines.first, let last = lines.last,
          last.end > first.start else { return }
    cues.removeAll {
      $0.chunkStart == chunkStart && $0.start < last.end && first.start < $0.audioEnd
    }
    for line in lines where line.start >= 0 {
      let audioEnd = max(line.end, line.start + 0.001)
      cues.append(Cue(chunkStart: chunkStart, start: line.start, end: max(line.start + 0.7, audioEnd),
                      audioEnd: audioEnd, text: line.text, receivedAt: receivedAt))
    }
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
    // One line at a time: the latest line that has started replaces the one before it, and stays
    // up briefly after its last word.
    if let current = cues.last(where: { position >= $0.start - Self.leadIn }),
       position <= current.end + Self.lineHold {
      return current.text
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
