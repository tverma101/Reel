//
//  AppleLiveCaptions.swift
//  iina
//
//  Caption local video audio with Apple's on-device Speech recognizer when no subtitle track exists.
//  Audio is decoded from the current file in short chunks; it is never recorded from the microphone
//  or sent to an online subtitle provider. Each transcription is tied to its file and playback time.
//

import AVFoundation
import Cocoa
import Speech

private final class LiveCaptionOverlay: NSView {
  let textField = NSTextField(labelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
    layer?.cornerRadius = 8
    textField.translatesAutoresizingMaskIntoConstraints = false
    textField.font = .systemFont(ofSize: 19, weight: .semibold)
    textField.textColor = .white
    textField.alignment = .center
    textField.lineBreakMode = .byWordWrapping
    textField.usesSingleLineMode = false
    textField.maximumNumberOfLines = 2
    addSubview(textField)
    NSLayoutConstraint.activate([
      textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      textField.topAnchor.constraint(equalTo: topAnchor, constant: 9),
      textField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
    ])
    isHidden = true
    setAccessibilityLabel(NSLocalizedString("live_captions.accessibility", comment: ""))
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // Caption text must not block player controls or clicks on the video.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Mutable state and AppKit objects are confined to the main thread; background decode and Speech
/// tasks return to the main thread before reading or updating the instance.
final class AppleLiveCaptions: @unchecked Sendable {
  private weak var player: PlayerCore?
  private let overlay = LiveCaptionOverlay(frame: .zero)
  private let decodeQueue = DispatchQueue(label: "io.iina.live-captions.decode", qos: .userInitiated)
  private var timer: Timer?
  private var recognizer: SFSpeechRecognizer?
  private var task: SFSpeechRecognitionTask?
  private var analyzerTask: Task<Void, Never>?
  private var generation = 0
  private var requestedStart: Double?
  private var exhaustedAtPosition: Double?
  private var activeURL: URL?
  private var inFlight = false
  private var recognitionStartedAt: Date?
  private var authorizationRequested = false
  private var captionResults = SpeechCaptionResultStore()
  private var unavailableSpeechLocales = Set<String>()
  private var installedSpeechLanguageCodes: Set<String>?
  private var speechLocaleCheckTask: Task<Void, Never>?
  private let chunkDuration: Double = 10

  init(player: PlayerCore) { self.player = player }

  func install(in contentView: NSView, above videoContainer: NSView) {
    contentView.addSubview(overlay, positioned: .above, relativeTo: videoContainer)
    NSLayoutConstraint.activate([
      overlay.centerXAnchor.constraint(equalTo: videoContainer.centerXAnchor),
      overlay.bottomAnchor.constraint(equalTo: videoContainer.bottomAnchor, constant: -64),
      overlay.widthAnchor.constraint(lessThanOrEqualTo: videoContainer.widthAnchor, multiplier: 0.85),
      overlay.leadingAnchor.constraint(greaterThanOrEqualTo: videoContainer.leadingAnchor, constant: 16),
      overlay.trailingAnchor.constraint(lessThanOrEqualTo: videoContainer.trailingAnchor, constant: -16),
    ])
  }

  /// Called when media or tracks change. A real subtitle immediately supersedes generated text.
  func updateEligibility() {
    guard let player else { stop(); return }
    guard Preference.bool(for: .appleLiveCaptionsFallback) else {
      // Let a user retry after installing a speech model while the app is open.
      unavailableSpeechLocales.removeAll()
      installedSpeechLanguageCodes = nil
      stop()
      return
    }
    guard player.info.state.loaded,
          player.info.vid != nil, player.info.vid != 0,
          player.info.subTracks.isEmpty,
          let url = player.info.currentURL, url.isFileURL else {
      Logger.log("Apple live captions ineligible: state=\(player.info.state), video=\(player.info.vid ?? -1), subtitleTracks=\(player.info.subTracks.count)",
                 level: .debug, subsystem: Logger.Sub.onlinesub)
      stop()
      return
    }

    // Apple's newer transcriber runs entirely on-device and does not use the legacy Speech
    // Recognition authorization prompt. Keep SFSpeechRecognizer for older macOS releases.
    if #available(macOS 26, *), SpeechTranscriber.isAvailable {
      let locale = selectedSpeechLocale
      let localeID = canonicalLocaleID(locale)
      guard !unavailableSpeechLocales.contains(localeID) else {
        stop()
        return
      }
      guard let installedSpeechLanguageCodes else {
        checkInstalledSpeechLocales(for: locale, localeID: localeID, mediaURL: url)
        return
      }
      guard let languageCode = locale.language.languageCode?.identifier,
            installedSpeechLanguageCodes.contains(languageCode) else {
        unavailableSpeechLocales.insert(localeID)
        Logger.log("Apple live captions have no installed on-device model for \(locale.identifier)",
                   level: .warning, subsystem: Logger.Sub.onlinesub)
        stop()
        return
      }
      if timer == nil, player.info.state == .playing { startTimer() }
      tick()
      return
    }

    let authorization = SFSpeechRecognizer.authorizationStatus()
    Logger.log("Apple live captions eligibility: speechAuthorization=\(authorization.rawValue)",
               level: .debug, subsystem: Logger.Sub.onlinesub)
    switch authorization {
    case .authorized:
      if recognizer == nil {
        let selected = Preference.string(for: .appleLiveCaptionsLanguage) ?? ""
        let locale = selected.isEmpty ? Locale.current : Locale(identifier: selected)
        recognizer = SFSpeechRecognizer(locale: locale)
      }
      guard recognizer?.supportsOnDeviceRecognition == true,
            recognizer?.isAvailable == true else {
        Logger.log("Apple live captions unavailable for the selected language or on-device recognizer",
                   level: .warning, subsystem: Logger.Sub.onlinesub)
        stop()
        return
      }
      if timer == nil, player.info.state == .playing { startTimer() }
      tick()
    case .notDetermined:
      guard !authorizationRequested else { return }
      authorizationRequested = true
      SFSpeechRecognizer.requestAuthorization { [weak self] _ in
        DispatchQueue.main.async {
          self?.authorizationRequested = false
          self?.updateEligibility()
        }
      }
    default:
      stop()
    }
  }

  func pauseChanged(_ paused: Bool) {
    if paused {
      timer?.invalidate()
      timer = nil
    } else {
      updateEligibility()
    }
  }

  func stop() {
    generation += 1
    timer?.invalidate()
    timer = nil
    task?.cancel()
    task = nil
    analyzerTask?.cancel()
    analyzerTask = nil
    speechLocaleCheckTask?.cancel()
    speechLocaleCheckTask = nil
    recognizer = nil
    requestedStart = nil
    exhaustedAtPosition = nil
    activeURL = nil
    inFlight = false
    recognitionStartedAt = nil
    captionResults.removeAll()
    overlay.isHidden = true
    overlay.textField.stringValue = ""
  }

  private func startTimer() {
    timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
      self?.tick()
    }
  }

  private func tick() {
    guard let player,
          Preference.bool(for: .appleLiveCaptionsFallback),
          player.info.state.loaded,
          player.info.subTracks.isEmpty,
          let url = player.info.currentURL, url.isFileURL else {
      stop()
      return
    }
    if activeURL != url {
      generation += 1
      task?.cancel()
      task = nil
      analyzerTask?.cancel()
      analyzerTask = nil
      inFlight = false
      recognitionStartedAt = nil
      requestedStart = nil
      exhaustedAtPosition = nil
      captionResults.removeAll()
      activeURL = url
    }
    // The UI timer stops after the OSC hides. Keep the cached position current so the chunk
    // scheduler continues through a normal playback session with no visible controls.
    player.syncPositionIfNeeded()
    guard let position = player.info.videoPosition?.second, position.isFinite, position >= 0 else {
      stop()
      return
    }
    // Bound result growth: chunks arrive throughout the session, so discard text the playhead can
    // no longer reach without a seek (a seek resets the store wholesale).
    captionResults.removeCues(endingBefore: position - 20)
    let text = captionResults.text(at: position)
    if overlay.textField.stringValue != text { overlay.textField.stringValue = text }
    overlay.isHidden = text.isEmpty

    guard player.info.state == .playing else { return }
    if inFlight, let recognitionStartedAt,
       Date().timeIntervalSince(recognitionStartedAt) > 15 {
      generation += 1
      task?.cancel()
      task = nil
      analyzerTask?.cancel()
      analyzerTask = nil
      inFlight = false
      self.recognitionStartedAt = nil
    }
    if let requestedStart,
       position < requestedStart - 1 || position >= requestedStart + chunkDuration * 2 {
      // A seek invalidates both a pending recognition result and the displayed cues.
      generation += 1
      task?.cancel()
      task = nil
      analyzerTask?.cancel()
      analyzerTask = nil
      inFlight = false
      recognitionStartedAt = nil
      self.requestedStart = nil
      self.exhaustedAtPosition = nil
      captionResults.removeAll()
      overlay.isHidden = true
    }
    if let exhaustedAtPosition {
      if position < exhaustedAtPosition - 1 {
        self.exhaustedAtPosition = nil
        requestedStart = nil
      } else {
        return
      }
    }
    if !inFlight && (requestedStart == nil || position >= requestedStart! + chunkDuration - 2) {
      let start = requestedStart.map { $0 + chunkDuration } ?? floor(position / chunkDuration) * chunkDuration
      transcribe(url: url, start: start)
    }
  }

  private func transcribe(url: URL, start: Double) {
    guard let player else { return }
    if #available(macOS 26, *), SpeechTranscriber.isAvailable {
      let localeID = canonicalLocaleID(selectedSpeechLocale)
      // The model check is performed before decoding; if analyzer setup previously confirmed that
      // the selected locale has no usable model, avoid reopening and probing the media on every chunk.
      guard !unavailableSpeechLocales.contains(localeID) else { return }
    } else {
      guard recognizer?.isAvailable == true else { return }
    }
    let mediaDuration = player.info.videoDuration?.second
    let duration: Double
    if let mediaDuration, mediaDuration.isFinite, mediaDuration > 0 {
      duration = min(chunkDuration, max(0, mediaDuration - start))
    } else {
      duration = chunkDuration
    }
    requestedStart = start
    guard duration >= 1 else {
      exhaustedAtPosition = mediaDuration
      inFlight = false
      recognitionStartedAt = nil
      return
    }
    exhaustedAtPosition = nil
    inFlight = true
    recognitionStartedAt = nil
    let token = generation
    decodeQueue.async { [weak self] in
      let data = FFmpegController.readMonoAudio(fromFile: url.path, startTime: start, duration: duration)
      DispatchQueue.main.async {
        guard let self, self.generation == token, self.player?.info.currentURL == url else { return }
        guard let data, !data.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(data.count / MemoryLayout<Float>.size)),
              let channel = buffer.floatChannelData?[0] else {
          self.inFlight = false
          self.recognitionStartedAt = nil
          return
        }
        data.copyBytes(to: UnsafeMutableRawBufferPointer(start: channel, count: data.count))
        buffer.frameLength = buffer.frameCapacity
        // Start the recognition timeout after FFmpeg has finished. A slow local-container probe
        // must not make us abandon a chunk before the on-device recognizer has even started.
        self.recognitionStartedAt = Date()
        if #available(macOS 26, *), SpeechTranscriber.isAvailable {
          self.transcribeWithSpeechAnalyzer(buffer, start: start, token: token, url: url)
          return
        }
        guard let recognizer = self.recognizer else {
          self.inFlight = false
          self.recognitionStartedAt = nil
          return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
          DispatchQueue.main.async {
            guard let self, self.generation == token, self.player?.info.currentURL == url else { return }
            if let result {
              let replacements = result.bestTranscription.segments.compactMap { segment -> SpeechCaptionResultStore.Cue? in
                let text = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let begin = start + segment.timestamp
                let audioEnd = begin + max(segment.duration, 0.001)
                return SpeechCaptionResultStore.Cue(chunkStart: start, start: begin,
                                                     end: begin + max(segment.duration, 0.7),
                                                     audioEnd: audioEnd, text: text)
              }
              self.captionResults.replaceChunk(start, with: replacements)
              self.captionResults.removeCues(endingBefore: (self.player?.info.videoPosition?.second ?? 0) - 20)
            }
            if result?.isFinal == true || error != nil {
              self.task = nil
              self.inFlight = false
              self.recognitionStartedAt = nil
              if let error {
                Logger.log("Apple live captions could not transcribe audio: \(error.localizedDescription)",
                           level: .warning, subsystem: Logger.Sub.onlinesub)
              }
            }
          }
        }
        request.append(buffer)
        request.endAudio()
      }
    }
  }

  @available(macOS 26, *)
  private func transcribeWithSpeechAnalyzer(_ buffer: AVAudioPCMBuffer, start: Double, token: Int, url: URL) {
    let locale = selectedSpeechLocale
    let localeID = canonicalLocaleID(locale)
    analyzerTask = Task { [weak self] in
      guard let captions = self else { return }
      do {
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
          Logger.log("Apple live captions have no installed on-device model for \(locale.identifier)",
                     level: .warning, subsystem: Logger.Sub.onlinesub)
          await MainActor.run {
            guard captions.generation == token else { return }
            captions.unavailableSpeechLocales.insert(localeID)
            captions.timer?.invalidate()
            captions.timer = nil
            captions.inFlight = false
            captions.recognitionStartedAt = nil
            captions.captionResults.removeAll()
            captions.overlay.isHidden = true
            captions.overlay.textField.stringValue = ""
          }
          return
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: format),
              let converted = AVAudioPCMBuffer(pcmFormat: format,
                                               frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) *
                                                 format.sampleRate / buffer.format.sampleRate) + 1024) else {
          throw NSError(domain: "IINA.LiveCaptions", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Audio format conversion is unavailable"])
        }
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
          guard !consumed else { status.pointee = .endOfStream; return nil }
          consumed = true
          status.pointee = .haveData
          return buffer
        }
        if let conversionError { throw conversionError }
        let (stream, writer) = AsyncStream.makeStream(of: AnalyzerInput.self)
        writer.yield(AnalyzerInput(buffer: converted))
        writer.finish()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let results = Task {
          for try await result in transcriber.results {
            guard !Task.isCancelled else { break }
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            let begin = start + result.range.start.seconds
            let end = start + result.range.end.seconds
            await MainActor.run {
              guard captions.generation == token, captions.player?.info.currentURL == url else { return }
              captions.captionResults.applyProgressiveResult(chunkStart: start, audioStart: begin,
                                                              audioEnd: end, text: text)
            }
          }
        }
        do {
          let last = try await analyzer.analyzeSequence(stream)
          if let last { try await analyzer.finalizeAndFinish(through: last) }
          try await results.value
        } catch {
          results.cancel()
          throw error
        }
      } catch {
        if !Task.isCancelled {
          Logger.log("Apple live captions could not transcribe audio: \(error.localizedDescription)",
                     level: .warning, subsystem: Logger.Sub.onlinesub)
        }
      }
      await MainActor.run {
        guard captions.generation == token else { return }
        captions.inFlight = false
        captions.recognitionStartedAt = nil
        captions.analyzerTask = nil
      }
    }
  }

  private var selectedSpeechLocale: Locale {
    let selected = Preference.string(for: .appleLiveCaptionsLanguage) ?? ""
    return selected.isEmpty ? Locale.current : Locale(identifier: selected)
  }

  private func canonicalLocaleID(_ locale: Locale) -> String {
    Locale.canonicalIdentifier(from: locale.identifier)
  }

  @available(macOS 26, *)
  private func checkInstalledSpeechLocales(for locale: Locale, localeID: String, mediaURL: URL) {
    guard speechLocaleCheckTask == nil else { return }
    let token = generation
    speechLocaleCheckTask = Task { [weak self] in
      let locales = await SpeechTranscriber.installedLocales
      let languageCodes = Set(locales.compactMap { $0.language.languageCode?.identifier })
      DispatchQueue.main.async {
        guard let self, self.generation == token else { return }
        self.speechLocaleCheckTask = nil
        guard Preference.bool(for: .appleLiveCaptionsFallback) else { return }
        guard self.player?.info.currentURL == mediaURL,
              self.canonicalLocaleID(self.selectedSpeechLocale) == localeID else {
          self.updateEligibility()
          return
        }
        self.installedSpeechLanguageCodes = languageCodes
        self.updateEligibility()
      }
    }
  }
}
