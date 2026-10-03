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

    init(chunkStart: Double, start: Double, end: Double, audioEnd: Double, text: String) {
      self.chunkStart = chunkStart
      self.start = start
      self.end = end
      self.audioEnd = audioEnd
      self.text = text
    }
  }

  private(set) var cues: [Cue] = []

  mutating func applyProgressiveResult(chunkStart: Double, audioStart: Double, audioEnd: Double, text: String) {
    guard chunkStart.isFinite, audioStart.isFinite, audioEnd.isFinite,
          chunkStart >= 0, audioStart >= 0, audioEnd > audioStart else { return }

    cues.removeAll {
      $0.chunkStart == chunkStart && $0.start < audioEnd && audioStart < $0.audioEnd
    }

    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    cues.append(Cue(chunkStart: chunkStart, start: audioStart,
                    end: max(audioStart + 0.7, audioEnd), audioEnd: audioEnd, text: text))
    sortCues()
  }

  mutating func replaceChunk(_ chunkStart: Double, with replacements: [Cue]) {
    guard chunkStart.isFinite else { return }
    cues.removeAll { $0.chunkStart == chunkStart }
    cues.append(contentsOf: replacements.filter {
      $0.chunkStart == chunkStart && $0.start.isFinite && $0.end.isFinite && $0.audioEnd.isFinite &&
        $0.start >= 0 && $0.end > $0.start && $0.audioEnd > $0.start && !$0.text.isEmpty
    })
    sortCues()
  }

  mutating func removeCues(endingBefore position: Double) {
    cues.removeAll { $0.end < position }
  }

  mutating func removeAll() {
    cues.removeAll()
  }

  func text(at position: Double) -> String {
    cues.filter { position >= $0.start - 0.15 && position <= $0.end + 0.6 }
      .suffix(2).map(\.text).joined(separator: " ")
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
