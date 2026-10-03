import CryptoKit
import Foundation
import PromiseKit
import whisper

enum SubtitleAudioMatchStatus: Equatable {
  case pending
  case timingMatch
  case timingOtherLanguage
  case dialogueMatch
  case possibleDialogueMatch
  case noDialogueMatch
  case differentLanguage
  case unverified

  var displayString: String {
    let key: String
    switch self {
    case .pending: key = "subtitle.audioMatch.pending"
    case .timingMatch: key = "subtitle.audioMatch.timing"
    case .timingOtherLanguage: key = "subtitle.audioMatch.timingOtherLanguage"
    case .dialogueMatch: key = "subtitle.audioMatch.dialogue"
    case .possibleDialogueMatch: key = "subtitle.audioMatch.possible"
    case .noDialogueMatch: key = "subtitle.audioMatch.noMatch"
    case .differentLanguage: key = "subtitle.audioMatch.otherLanguage"
    case .unverified: key = "subtitle.audioMatch.unverified"
    }
    return NSLocalizedString(key, comment: "Online subtitle audio-match status")
  }
}

/// Checks at most three OpenSubtitles candidates against a short excerpt decoded locally.
/// A hash plus speech/cue timing can establish synchronization, but only a same-language
/// Whisper text comparison can establish a dialogue match.
enum SubtitleAudioMatcher {
  final class Cancellation {
    private let lock = NSLock()
    private var cancelled = false
    private var tasks: [UUID: URLSessionTask] = [:]

    var isCancelled: Bool {
      lock.lock()
      defer { lock.unlock() }
      return cancelled
    }

    func cancel() {
      lock.lock()
      cancelled = true
      let activeTasks = Array(tasks.values)
      tasks.removeAll()
      lock.unlock()
      activeTasks.forEach { $0.cancel() }
    }

    func register(_ task: URLSessionTask, identifier: UUID) -> Bool {
      lock.lock()
      guard !cancelled else {
        lock.unlock()
        task.cancel()
        return false
      }
      tasks[identifier] = task
      lock.unlock()
      return true
    }

    func finish(_ identifier: UUID) {
      lock.lock()
      tasks.removeValue(forKey: identifier)
      lock.unlock()
    }
  }

  private struct Cue {
    let start: Double
    let end: Double
    let text: String
    let dialogueWordCount: Int

    init(start: Double, end: Double, text: String) {
      self.start = start
      self.end = end
      self.text = text
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty,
            !trimmed.hasPrefix("["), !trimmed.hasPrefix("("),
            !trimmed.hasPrefix("♪"), !trimmed.hasPrefix("♫") else {
        dialogueWordCount = 0
        return
      }
      dialogueWordCount = Self.wordCount(in: trimmed)
    }

    var isDialogue: Bool { dialogueWordCount >= 2 }

    private static func wordCount(in text: String) -> Int {
      var count = 0
      var insideWord = false
      for scalar in text.unicodeScalars {
        let category = scalar.properties.generalCategory
        let isWord = CharacterSet.alphanumerics.contains(scalar) ||
          category == .nonspacingMark || category == .spacingMark || category == .enclosingMark
        if isWord && !insideWord { count += 1 }
        insideWord = isWord
      }
      return count
    }
  }

  private struct Candidate {
    let subtitle: OpenSub.Subtitle
    let cues: [Cue]
  }

  private struct SamplePlan {
    let start: Double
    let duration: Double = 12
    var end: Double { start + duration }
  }

  private struct SpeechSegment {
    let start: Double
    let end: Double
  }

  private struct VADAssessment {
    let timingMatches: Set<ObjectIdentifier>
  }

  private struct Transcript {
    let text: String
    let language: String?
  }

  /// Prefix sums let the excerpt planner score every candidate window in O(log n), even for a
  /// large or unusually dense subtitle file.
  private struct CueMetric {
    let time: Double
    let words: Int
  }

  private struct CueWindowIndex {
    let starts: [CueMetric]
    let ends: [CueMetric]
    private let startWordPrefix: [Int]
    private let endWordPrefix: [Int]

    init(cues: [Cue]) {
      let dialogue = cues.filter(\.isDialogue)
      let sortedStarts = dialogue.map { CueMetric(time: $0.start, words: $0.dialogueWordCount) }
        .sorted { $0.time < $1.time }
      let sortedEnds = dialogue.map { CueMetric(time: $0.end, words: $0.dialogueWordCount) }
        .sorted { $0.time < $1.time }
      starts = sortedStarts
      ends = sortedEnds
      startWordPrefix = Self.wordPrefix(for: sortedStarts)
      endWordPrefix = Self.wordPrefix(for: sortedEnds)
    }

    func overlaps(_ plan: SamplePlan) -> (cueCount: Int, wordCount: Int) {
      let started = prefixCount(in: starts, while: { $0 <= plan.end })
      let alreadyEnded = prefixCount(in: ends, while: { $0 < plan.start })
      return (started - alreadyEnded, startWordPrefix[started] - endWordPrefix[alreadyEnded])
    }

    private func prefixCount(in values: [CueMetric], while predicate: (Double) -> Bool) -> Int {
      var lower = 0
      var upper = values.count
      while lower < upper {
        let middle = lower + (upper - lower) / 2
        if predicate(values[middle].time) {
          lower = middle + 1
        } else {
          upper = middle
        }
      }
      return lower
    }

    private static func wordPrefix(for values: [CueMetric]) -> [Int] {
      var prefix = [0]
      prefix.reserveCapacity(values.count + 1)
      for value in values { prefix.append(prefix[prefix.count - 1] + value.words) }
      return prefix
    }
  }

  private enum MatcherError: LocalizedError {
    case cancelled
    case noUsableAudio
    case modelLoadFailed
    case transcriptionFailed
    case badModelDownload

    var errorDescription: String? {
      switch self {
      case .cancelled: return "Subtitle search was cancelled"
      case .noUsableAudio: return "Could not decode an audio excerpt"
      case .modelLoadFailed: return "Could not load the local Whisper model"
      case .transcriptionFailed: return "Local Whisper did not return a transcript"
      case .badModelDownload: return "The local audio model failed its integrity check"
      }
    }
  }

  private static let sampleRate = 16_000
  private static let maxSubtitleBytes = 10 * 1024 * 1024
  private static let modelDirectory: URL = {
    let url = Utility.appSupportDirUrl.appendingPathComponent("SubtitleAudioModels", isDirectory: true)
    Utility.createDirIfNotExist(url: url)
    return url
  }()

  private static let vadModel = Model(
    name: "ggml-silero-v6.2.0.bin",
    url: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v6.2.0.bin")!,
    sha256: "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"
  )

  private static let whisperModel = Model(
    name: "ggml-base-q5_1.bin",
    url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/f281eb45af861ab5e5297d23694b7d46e090c02c/ggml-base-q5_1.bin")!,
    sha256: "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898"
  )

  private struct Model {
    let name: String
    let url: URL
    let sha256: String
  }

  static func verify(mediaURL: URL, candidates: [OpenSub.Subtitle], cancellation: Cancellation) -> Promise<Void> {
    downloadCandidates(candidates, index: 0, prepared: [], cancellation: cancellation).then { prepared -> Promise<Void> in
      guard !cancellation.isCancelled else { throw MatcherError.cancelled }
      let parsed = prepared.compactMap { item -> Candidate? in
        guard let url = item.fileURL, let cues = SubtitleCueParser.parse(fileURL: url), !cues.isEmpty else {
          item.subtitle.audioMatchStatus = .unverified
          return nil
        }
        return Candidate(subtitle: item.subtitle, cues: cues)
      }
      guard mediaURL.isFileURL, let plan = samplePlan(for: parsed), !parsed.isEmpty else {
        prepared.forEach { $0.subtitle.audioMatchStatus = .unverified }
        return .value(())
      }

      return onWorker {
        guard !cancellation.isCancelled,
              let data = FFmpegController.readMonoAudio(fromFile: mediaURL.path,
                                                       startTime: plan.start,
                                                       duration: plan.duration),
              data.count >= MemoryLayout<Float>.size * sampleRate * 2 else {
          throw cancellation.isCancelled ? MatcherError.cancelled : MatcherError.noUsableAudio
        }
        let samples = data.withUnsafeBytes { rawBuffer -> [Float] in
          Array(rawBuffer.bindMemory(to: Float.self))
        }
        return (parsed, plan, samples)
      }.then { parsed, plan, samples -> Promise<Void> in
        guard !cancellation.isCancelled else { throw MatcherError.cancelled }
        let assessmentPromise: Promise<VADAssessment>
        assessmentPromise = ensureModel(vadModel, cancellation: cancellation).then { vadURL in
          onWorker { assessTiming(candidates: parsed, plan: plan, samples: samples, vadModelURL: vadURL) }
        }.recover { error -> Promise<VADAssessment> in
          if cancellation.isCancelled { throw MatcherError.cancelled }
          Logger.log("Local voice-activity check unavailable: \(error.localizedDescription)",
                     level: .warning, subsystem: Logger.Sub.opensub)
          return .value(VADAssessment(timingMatches: []))
        }
        return assessmentPromise.then { assessment -> Promise<Void> in
          guard !cancellation.isCancelled else { throw MatcherError.cancelled }
          for candidate in parsed where assessment.timingMatches.contains(ObjectIdentifier(candidate.subtitle)) {
            candidate.subtitle.audioMatchStatus = .timingMatch
          }
          if assessment.timingMatches.count == parsed.count, !parsed.isEmpty {
            return .value(())
          }
          return ensureModel(whisperModel, cancellation: cancellation).then { modelURL -> Promise<Void> in
            onWorker {
              guard !cancellation.isCancelled else { throw MatcherError.cancelled }
              let transcript = try transcribe(samples: samples, modelURL: modelURL, vadModelURL: nil)
              applyTranscript(transcript, candidates: parsed, plan: plan, timingMatches: assessment.timingMatches)
            }
          }.recover { error -> Promise<Void> in
            if case MatcherError.cancelled = error { throw error }
            Logger.log("Local Whisper check unavailable: \(error.localizedDescription)",
                       level: .warning, subsystem: Logger.Sub.opensub)
            for candidate in parsed where !assessment.timingMatches.contains(ObjectIdentifier(candidate.subtitle)) {
              candidate.subtitle.audioMatchStatus = .unverified
            }
            return .value(())
          }
        }
      }
    }
  }

  private struct DownloadedCandidate {
    let subtitle: OpenSub.Subtitle
    let fileURL: URL?
  }

  private static func downloadCandidates(_ candidates: [OpenSub.Subtitle],
                                         index: Int,
                                         prepared: [DownloadedCandidate],
                                         cancellation: Cancellation) -> Promise<[DownloadedCandidate]> {
    guard index < candidates.count else { return .value(prepared) }
    guard !cancellation.isCancelled else { return Promise(error: MatcherError.cancelled) }
    let subtitle = candidates[index]
    return subtitle.download().then { urls -> Promise<[DownloadedCandidate]> in
      var next = prepared
      next.append(DownloadedCandidate(subtitle: subtitle, fileURL: urls.first))
      return downloadCandidates(candidates, index: index + 1, prepared: next, cancellation: cancellation)
    }.recover { error -> Promise<[DownloadedCandidate]> in
      if cancellation.isCancelled { throw MatcherError.cancelled }
      subtitle.audioMatchStatus = .unverified
      Logger.log("Could not download candidate subtitle for local checking: \(error.localizedDescription)",
                 level: .warning, subsystem: Logger.Sub.opensub)
      return downloadCandidates(candidates, index: index + 1, prepared: prepared, cancellation: cancellation)
    }
  }

  private static func samplePlan(for candidates: [Candidate]) -> SamplePlan? {
    let starts = Set(candidates.flatMap { candidate in
      candidate.cues.filter(\.isDialogue).map { floor($0.start / 6) * 6 }
    }).sorted()
    guard !starts.isEmpty else { return nil }

    let indexes = candidates.map { CueWindowIndex(cues: $0.cues) }
    var best: (plan: SamplePlan, score: Int)?
    for start in starts {
      let plan = SamplePlan(start: start)
      var candidatesWithDialogue = 0
      var cueCount = 0
      var wordCount = 0
      for index in indexes {
        let overlap = index.overlaps(plan)
        if overlap.cueCount > 0 { candidatesWithDialogue += 1 }
        cueCount += overlap.cueCount
        wordCount += overlap.wordCount
      }
      let score = candidatesWithDialogue * 1000 + min(cueCount, 30) * 20 + min(wordCount, 80) + (start >= 15 ? 2 : 0)
      if best == nil || score > best!.score || (score == best!.score && start < best!.plan.start) {
        best = (plan, score)
      }
    }
    return best?.plan
  }

  private static func assessTiming(candidates: [Candidate],
                                   plan: SamplePlan,
                                   samples: [Float],
                                   vadModelURL: URL) -> VADAssessment {
    guard let speech = detectSpeech(samples: samples, modelURL: vadModelURL), speech.count >= 2 else {
      return VADAssessment(timingMatches: [])
    }
    var matches = Set<ObjectIdentifier>()
    for candidate in candidates {
      let aligned = speech.filter { segment in
        candidate.cues.contains { cue in
          cue.isDialogue && cue.start <= plan.start + segment.end + 0.7 &&
            cue.end + 0.7 >= plan.start + segment.start
        }
      }.count
      if aligned >= 2 && Double(aligned) / Double(speech.count) >= 0.75 {
        matches.insert(ObjectIdentifier(candidate.subtitle))
      }
    }
    return VADAssessment(timingMatches: matches)
  }

  private static func detectSpeech(samples: [Float], modelURL: URL) -> [SpeechSegment]? {
    var params = whisper_vad_default_context_params()
    params.n_threads = Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount)))
    params.use_gpu = false
    let context = modelURL.path.withCString {
      whisper_vad_init_from_file_with_params($0, params)
    }
    guard let context else { return nil }
    defer { whisper_vad_free(context) }

    var vadParams = whisper_vad_default_params()
    vadParams.min_speech_duration_ms = 250
    vadParams.min_silence_duration_ms = 100
    vadParams.speech_pad_ms = 120
    let segments = samples.withUnsafeBufferPointer { buffer in
      whisper_vad_segments_from_samples(context, vadParams, buffer.baseAddress, Int32(buffer.count))
    }
    guard let segments else { return nil }
    defer { whisper_vad_free_segments(segments) }
    let count = whisper_vad_segments_n_segments(segments)
    return (0..<count).compactMap { index in
      let start = whisper_vad_segments_get_segment_t0(segments, index)
      let end = whisper_vad_segments_get_segment_t1(segments, index)
      return end > start ? SpeechSegment(start: Double(start), end: Double(end)) : nil
    }
  }

  private static func transcribe(samples: [Float], modelURL: URL, vadModelURL: URL?) throws -> Transcript {
    var contextParams = whisper_context_default_params()
    contextParams.use_gpu = true
    let context = modelURL.path.withCString { whisper_init_from_file_with_params($0, contextParams) }
    guard let context else { throw MatcherError.modelLoadFailed }
    defer { whisper_free(context) }

    var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
    params.n_threads = Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount)))
    params.no_context = true
    params.no_timestamps = true
    params.print_progress = false
    params.print_realtime = false
    params.print_timestamps = false
    params.print_special = false
    params.suppress_blank = true
    params.suppress_nst = true

    let result: (String, String?) = "auto".withCString { language in
      params.language = language
      params.detect_language = true
      if let vadModelURL {
        return vadModelURL.path.withCString { vadPath in
          params.vad = true
          params.vad_model_path = vadPath
          return runTranscription(context: context, params: params, samples: samples)
        }
      }
      return runTranscription(context: context, params: params, samples: samples)
    }
    guard !result.0.isEmpty else { throw MatcherError.transcriptionFailed }
    return Transcript(text: result.0, language: result.1)
  }

  private static func runTranscription(context: OpaquePointer,
                                       params: whisper_full_params,
                                       samples: [Float]) -> (String, String?) {
    let result = samples.withUnsafeBufferPointer { buffer in
      whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
    }
    guard result == 0 else { return ("", nil) }
    let texts = (0..<whisper_full_n_segments(context)).compactMap { index -> String? in
      guard let pointer = whisper_full_get_segment_text(context, index) else { return nil }
      return String(cString: pointer)
    }
    let languageID = whisper_full_lang_id(context)
    let language = whisper_lang_str(languageID).map { String(cString: $0) }
    return (texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines), language)
  }

  private static func applyTranscript(_ transcript: Transcript,
                                     candidates: [Candidate],
                                     plan: SamplePlan,
                                     timingMatches: Set<ObjectIdentifier>) {
    let detectedLanguage = transcript.language.flatMap(whisperLanguageCode(for:))
    let transcriptTokens = normalizedTokens(transcript.text)
    for candidate in candidates {
      let identifier = ObjectIdentifier(candidate.subtitle)
      let hasTimingMatch = timingMatches.contains(identifier)
      guard let detectedLanguage,
            let subtitleLanguage = whisperLanguageCode(forOpenSubtitles: candidate.subtitle.subtitleLanguage) else {
        candidate.subtitle.audioMatchStatus = hasTimingMatch ? .timingMatch : .unverified
        continue
      }
      guard detectedLanguage == subtitleLanguage else {
        candidate.subtitle.audioMatchStatus = hasTimingMatch ? .timingOtherLanguage : .differentLanguage
        continue
      }
      let subtitleText = candidate.cues.filter {
        $0.isDialogue && $0.end >= plan.start - 0.8 && $0.start <= plan.end + 0.8
      }.map(\.text).joined(separator: " ")
      let subtitleTokens = normalizedTokens(subtitleText)
      guard transcriptTokens.count >= 5, subtitleTokens.count >= 5 else {
        candidate.subtitle.audioMatchStatus = hasTimingMatch ? .timingMatch : .unverified
        continue
      }
      let score = tokenF1(transcriptTokens, subtitleTokens)
      if score >= 0.60 {
        candidate.subtitle.audioMatchStatus = .dialogueMatch
      } else if score >= 0.35 {
        candidate.subtitle.audioMatchStatus = .possibleDialogueMatch
      } else {
        candidate.subtitle.audioMatchStatus = .noDialogueMatch
      }
    }
  }

  private static func whisperLanguageCode(forOpenSubtitles code: String) -> String? {
    let locale = Locale(identifier: code.trimmingCharacters(in: .whitespacesAndNewlines))
    let language: String
    if #available(macOS 13.0, *) {
      language = locale.language.languageCode?.identifier ?? ""
    } else {
      language = locale.languageCode ?? ""
    }
    return whisperLanguageCode(for: language)
  }

  private static func whisperLanguageCode(for code: String) -> String? {
    guard !code.isEmpty else { return nil }
    let identifier = code.withCString { whisper_lang_id($0) }
    guard identifier >= 0, let language = whisper_lang_str(identifier) else { return nil }
    return String(cString: language)
  }

  private static func normalizedTokens(_ text: String) -> [String] {
    let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                              locale: Locale(identifier: "en_US_POSIX"))
    var tokens: [String] = []
    var word = ""
    var unspacedRun: [Character] = []

    func flushWord() {
      if !word.isEmpty { tokens.append(word); word.removeAll(keepingCapacity: true) }
    }
    func flushUnspacedRun() {
      guard !unspacedRun.isEmpty else { return }
      if unspacedRun.count == 1 {
        tokens.append(String(unspacedRun[0]))
      } else {
        for index in 0..<(unspacedRun.count - 1) {
          tokens.append(String(unspacedRun[index...index + 1]))
        }
      }
      unspacedRun.removeAll(keepingCapacity: true)
    }

    for character in folded {
      if isUnspacedScriptCharacter(character) {
        flushWord()
        unspacedRun.append(character)
      } else if character.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) {
        flushUnspacedRun()
        word.append(character)
      } else {
        flushWord()
        flushUnspacedRun()
      }
    }
    flushWord()
    flushUnspacedRun()
    return tokens
  }

  private static func isUnspacedScriptCharacter(_ character: Character) -> Bool {
    guard let base = character.unicodeScalars.first else { return false }
    let value = base.value
    let isScriptScalar = (0x3400...0x4DBF).contains(value) ||
      (0x4E00...0x9FFF).contains(value) || (0xF900...0xFAFF).contains(value) ||
      (0x20000...0x3134F).contains(value) ||
      (0x3040...0x30FF).contains(value) || (0x31F0...0x31FF).contains(value) ||
      (0xFF66...0xFF9D).contains(value) ||
      (0x1100...0x11FF).contains(value) || (0x3130...0x318F).contains(value) ||
      (0xA960...0xA97F).contains(value) || (0xAC00...0xD7AF).contains(value) ||
      (0xD7B0...0xD7FF).contains(value) ||
      (0x0E00...0x0E7F).contains(value) || (0x0E80...0x0EFF).contains(value) ||
      (0x1000...0x109F).contains(value) || (0x1780...0x17FF).contains(value)
    guard isScriptScalar else { return false }
    return character.unicodeScalars.dropFirst().allSatisfy {
      let category = $0.properties.generalCategory
      return category == .nonspacingMark || category == .spacingMark || category == .enclosingMark
    }
  }

  private static func tokenF1(_ first: [String], _ second: [String]) -> Double {
    guard !first.isEmpty, !second.isEmpty else { return 0 }
    var counts: [String: Int] = [:]
    for token in first { counts[token, default: 0] += 1 }
    var overlap = 0
    for token in second {
      guard let count = counts[token], count > 0 else { continue }
      overlap += 1
      counts[token] = count - 1
    }
    return (2 * Double(overlap)) / Double(first.count + second.count)
  }

  private static func ensureModel(_ model: Model, cancellation: Cancellation) -> Promise<URL> {
    let destination = modelDirectory.appendingPathComponent(model.name, isDirectory: false)
    return onWorker {
      guard !cancellation.isCancelled else { throw MatcherError.cancelled }
      return hasExpectedChecksum(destination, expected: model.sha256)
    }.then { isValid -> Promise<URL> in
      guard !cancellation.isCancelled else { throw MatcherError.cancelled }
      if isValid { return .value(destination) }
      try? FileManager.default.removeItem(at: destination)
      return download(model, to: destination, cancellation: cancellation)
    }
  }

  private static func download(_ model: Model, to destination: URL, cancellation: Cancellation) -> Promise<URL> {
    Promise { resolver in
      let taskIdentifier = UUID()
      let task = URLSession.shared.downloadTask(with: model.url) { temporaryURL, response, error in
        cancellation.finish(taskIdentifier)
        if let error {
          if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
          resolver.reject(error)
          return
        }
        guard let temporaryURL,
              (response as? HTTPURLResponse)?.statusCode == 200 else {
          if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
          resolver.reject(MatcherError.badModelDownload)
          return
        }
        let stagingURL = destination.appendingPathExtension("\(taskIdentifier.uuidString).download")
        do {
          try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
          try FileManager.default.moveItem(at: temporaryURL, to: stagingURL)
        } catch {
          resolver.reject(error)
          return
        }
        onWorker {
          defer { try? FileManager.default.removeItem(at: stagingURL) }
          guard !cancellation.isCancelled else { throw MatcherError.cancelled }
          guard hasExpectedChecksum(stagingURL, expected: model.sha256) else {
            throw MatcherError.badModelDownload
          }
          guard !cancellation.isCancelled else { throw MatcherError.cancelled }
          do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: stagingURL, to: destination)
          } catch {
            // A concurrent verification of the same model can have installed the destination first.
            // That file passes the same pinned checksum, so treat it as success instead of failing
            // the whole verification.
            guard hasExpectedChecksum(destination, expected: model.sha256) else { throw error }
          }
          return destination
        }.pipe { result in
          resolver.resolve(result)
        }
      }
      guard cancellation.register(task, identifier: taskIdentifier) else {
        resolver.reject(MatcherError.cancelled)
        return
      }
      task.resume()
    }
  }

  private static func hasExpectedChecksum(_ url: URL, expected: String) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    var hasher = SHA256()
    do {
      while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
        hasher.update(data: data)
      }
    } catch {
      return false
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return digest == expected
  }

  private static func onWorker<T>(_ work: @escaping () throws -> T) -> Promise<T> {
    Promise { resolver in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          resolver.fulfill(try work())
        } catch {
          resolver.reject(error)
        }
      }
    }
  }

  private enum SubtitleCueParser {
    private static let timingRegex = try! NSRegularExpression(
      pattern: #"(?m)(\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}|\d{1,2}:\d{2}[,.]\d{1,3})[ \t]*-->[ \t]*(\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}|\d{1,2}:\d{2}[,.]\d{1,3})"#
    )
    private static let htmlRegex = try! NSRegularExpression(pattern: #"<[^>]+>"#)
    private static let assTagRegex = try! NSRegularExpression(pattern: #"\{[^}]*\}"#)
    private static let numericLineRegex = try! NSRegularExpression(pattern: #"(?m)^\s*\d+\s*$"#)

    static func parse(fileURL: URL) -> [Cue]? {
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let size = attributes[.size] as? NSNumber,
            size.int64Value > 0, size.int64Value <= Int64(SubtitleAudioMatcher.maxSubtitleBytes),
            let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return nil }
      let text = String(data: data, encoding: .utf8)
        ?? String(data: data, encoding: .utf16)
        ?? String(data: data, encoding: .windowsCP1252)
        ?? String(data: data, encoding: .isoLatin1)
      guard let text else { return nil }
      let assCues = parseASS(text)
      if !assCues.isEmpty { return assCues }
      return parseTimedText(text)
    }

    private static func parseASS(_ text: String) -> [Cue] {
      var cues: [Cue] = []
      text.enumerateLines { line, stop in
        guard line.utf16.count <= 4_096, line.hasPrefix("Dialogue:") else { return }
        let fields = line.split(maxSplits: 9, omittingEmptySubsequences: false) { $0 == "," }
        guard fields.count == 10,
              let start = parseTime(String(fields[1])),
              let end = parseTime(String(fields[2])), end > start else { return }
        let body = cleanText(String(fields[9]).replacingOccurrences(of: #"\\[Nn]"#, with: " ", options: .regularExpression))
        if !body.isEmpty { cues.append(Cue(start: start, end: end, text: body)) }
        if cues.count >= 50_000 { stop = true }
      }
      return cues
    }

    private static func parseTimedText(_ text: String) -> [Cue] {
      let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
      var matches: [NSTextCheckingResult] = []
      timingRegex.enumerateMatches(in: text, range: fullRange) { match, _, stop in
        guard let match else { return }
        if matches.count >= 50_000 {
          // The cue-body limit below bounds the final cue even without a lookahead timestamp.
          stop.pointee = true
          return
        }
        matches.append(match)
      }
      guard !matches.isEmpty else { return [] }
      var cues: [Cue] = []
      for (index, match) in matches.prefix(50_000).enumerated() {
        guard let startRange = Range(match.range(at: 1), in: text),
              let endRange = Range(match.range(at: 2), in: text),
              let start = parseTime(String(text[startRange])),
              let end = parseTime(String(text[endRange])), end > start else { continue }
        let contentStart = match.range.location + match.range.length
        let nextStart = index + 1 < matches.count ? matches[index + 1].range.location : fullRange.length
        guard nextStart >= contentStart else { continue }
        let bodyLength = min(nextStart - contentStart, 4_096)
        let rawBody = (text as NSString).substring(with: NSRange(location: contentStart, length: bodyLength))
        let body = cleanText(rawBody)
        if !body.isEmpty { cues.append(Cue(start: start, end: end, text: body)) }
        if cues.count >= 50_000 { break }
      }
      return cues
    }

    private static func cleanText(_ text: String) -> String {
      let range = NSRange(text.startIndex..<text.endIndex, in: text)
      let withoutHTML = htmlRegex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
      let htmlRange = NSRange(withoutHTML.startIndex..<withoutHTML.endIndex, in: withoutHTML)
      let withoutASS = assTagRegex.stringByReplacingMatches(in: withoutHTML, range: htmlRange, withTemplate: " ")
      let assRange = NSRange(withoutASS.startIndex..<withoutASS.endIndex, in: withoutASS)
      let withoutIndices = numericLineRegex.stringByReplacingMatches(in: withoutASS, range: assRange, withTemplate: " ")
      return withoutIndices.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseTime(_ raw: String) -> Double? {
      let normalized = raw.replacingOccurrences(of: ",", with: ".")
      let parts = normalized.split(separator: ":", omittingEmptySubsequences: false)
      guard parts.count == 2 || parts.count == 3 else { return nil }
      let seconds = Double(parts.last ?? "")
      let minutes = Double(parts[parts.count - 2])
      guard let seconds, let minutes, seconds >= 0, minutes >= 0 else { return nil }
      if parts.count == 2 { return minutes * 60 + seconds }
      guard let hours = Double(parts[0]), hours >= 0 else { return nil }
      return hours * 3600 + minutes * 60 + seconds
    }
  }
}
