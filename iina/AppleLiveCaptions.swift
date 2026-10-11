//
//  AppleLiveCaptions.swift
//  iina
//
//  Caption local or streamed video audio with Apple's on-device Speech recognizer when no subtitle
//  track exists. Audio is decoded from the current file or http(s) stream in short chunks (a stream
//  is fetched again from its own server); it is never recorded from the microphone or sent to an
//  online subtitle provider. Each transcription is tied to its media and playback time.
//

import AVFoundation
import CoreAudio
import Cocoa
import Speech

/// Keeps a cancelled SpeechAnalyzer session alive until Speech has finished releasing it. A new
/// chunk must not start while the previous analyzer is still draining its input and results.
@available(macOS 26, *)
private final class SpeechAnalyzerCancellation: @unchecked Sendable {
  private let analyzer: SpeechAnalyzer
  private let lock = NSLock()
  private var cancellationRequested = false
  private var cancellationTask: Task<Void, Never>?

  init(analyzer: SpeechAnalyzer) {
    self.analyzer = analyzer
  }

  func cancel() {
    lock.lock()
    defer { lock.unlock() }
    guard !cancellationRequested else { return }
    cancellationRequested = true
    let analyzer = analyzer
    cancellationTask = Task { await analyzer.cancelAndFinishNow() }
  }

  func waitUntilCancelled() async {
    await currentCancellationTask()?.value
  }

  private func currentCancellationTask() -> Task<Void, Never>? {
    lock.lock()
    defer { lock.unlock() }
    return cancellationTask
  }
}

private struct LiveCaptionAppearance {
  let font: NSFont
  let textColor: NSColor
  let alignment: NSTextAlignment
  let paragraphStyle: NSParagraphStyle
  let strokeColor: NSColor?
  let strokeWidth: CGFloat?
  let shadow: NSShadow?
  let backgroundColor: NSColor?
  let maximumTextWidth: CGFloat
  let horizontalPadding: CGFloat
  let verticalPadding: CGFloat
  let cornerRadius: CGFloat
  let characterSpacing: CGFloat

  private var baseAttributes: [NSAttributedString.Key: Any] {
    var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraphStyle]
    if characterSpacing != 0 {
      attributes[.kern] = characterSpacing
    }
    return attributes
  }

  /// The letters themselves. They carry the shadow only when there is no outline layer to cast it.
  var textAttributes: [NSAttributedString.Key: Any] {
    var attributes = baseAttributes
    attributes[.foregroundColor] = textColor
    if outlineAttributes == nil, let shadow {
      attributes[.shadow] = shadow
    }
    return attributes
  }

  /// The outline, drawn as a filled and stroked copy behind the letters. A stroke drawn on the
  /// letters themselves would cover half of every glyph and make the text look thin and grey.
  var outlineAttributes: [NSAttributedString.Key: Any]? {
    guard let strokeColor, let strokeWidth else { return nil }
    var attributes = baseAttributes
    attributes[.foregroundColor] = strokeColor
    attributes[.strokeColor] = strokeColor
    attributes[.strokeWidth] = strokeWidth
    if let shadow {
      attributes[.shadow] = shadow
    }
    return attributes
  }

  func resized(toFontSize size: CGFloat) -> LiveCaptionAppearance {
    let scale = size / font.pointSize
    let scaledShadow: NSShadow? = shadow.map { original in
      let value = NSShadow()
      value.shadowColor = original.shadowColor
      value.shadowOffset = NSSize(width: original.shadowOffset.width * scale,
                                  height: original.shadowOffset.height * scale)
      value.shadowBlurRadius = original.shadowBlurRadius * scale
      return value
    }
    return LiveCaptionAppearance(
      font: font.withSize(size),
      textColor: textColor,
      alignment: alignment,
      paragraphStyle: paragraphStyle,
      strokeColor: strokeColor,
      strokeWidth: strokeWidth,
      shadow: scaledShadow,
      backgroundColor: backgroundColor,
      maximumTextWidth: maximumTextWidth,
      horizontalPadding: max(3, horizontalPadding * scale),
      verticalPadding: max(3, verticalPadding * scale),
      cornerRadius: cornerRadius * scale,
      characterSpacing: characterSpacing * scale
    )
  }
}

private final class LiveCaptionOverlay: NSView {
  let textField = NSTextField(labelWithString: "")
  private let outlineField = NSTextField(labelWithString: "")
  private var displayedText = ""
  private var captionAppearance: LiveCaptionAppearance?
  private var textLeadingConstraint: NSLayoutConstraint!
  private var textTrailingConstraint: NSLayoutConstraint!
  private var textTopConstraint: NSLayoutConstraint!
  private var textBottomConstraint: NSLayoutConstraint!

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.masksToBounds = true
    for field in [outlineField, textField] {
      field.translatesAutoresizingMaskIntoConstraints = false
      field.isBordered = false
      field.isEditable = false
      field.isSelectable = false
      field.drawsBackground = false
      field.focusRingType = .none
      field.lineBreakMode = .byWordWrapping
      field.usesSingleLineMode = false
      field.maximumNumberOfLines = 0
      field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      field.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }
    outlineField.setAccessibilityElement(false)
    addSubview(outlineField)
    addSubview(textField)
    textLeadingConstraint = textField.leadingAnchor.constraint(equalTo: leadingAnchor)
    textTrailingConstraint = textField.trailingAnchor.constraint(equalTo: trailingAnchor)
    textTopConstraint = textField.topAnchor.constraint(equalTo: topAnchor)
    textBottomConstraint = textField.bottomAnchor.constraint(equalTo: bottomAnchor)
    NSLayoutConstraint.activate([
      textLeadingConstraint,
      textTrailingConstraint,
      textTopConstraint,
      textBottomConstraint,
      outlineField.leadingAnchor.constraint(equalTo: textField.leadingAnchor),
      outlineField.trailingAnchor.constraint(equalTo: textField.trailingAnchor),
      outlineField.topAnchor.constraint(equalTo: textField.topAnchor),
      outlineField.bottomAnchor.constraint(equalTo: textField.bottomAnchor),
    ])
    isHidden = true
    setAccessibilityLabel(NSLocalizedString("live_captions.accessibility", comment: ""))
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  @discardableResult
  func setCaptionText(_ text: String) -> Bool {
    guard displayedText != text else { return false }
    displayedText = text
    renderText()
    return true
  }

  func apply(_ appearance: LiveCaptionAppearance) {
    captionAppearance = appearance
    textField.font = appearance.font
    textField.textColor = appearance.textColor
    textField.alignment = appearance.alignment
    textField.maximumNumberOfLines = 0
    textField.preferredMaxLayoutWidth = appearance.maximumTextWidth
    outlineField.preferredMaxLayoutWidth = appearance.maximumTextWidth
    textLeadingConstraint.constant = appearance.horizontalPadding
    textTrailingConstraint.constant = -appearance.horizontalPadding
    textTopConstraint.constant = appearance.verticalPadding
    textBottomConstraint.constant = -appearance.verticalPadding
    layer?.backgroundColor = appearance.backgroundColor?.cgColor
    layer?.cornerRadius = appearance.cornerRadius
    renderText()
  }

  private func renderText() {
    guard let captionAppearance else {
      textField.stringValue = displayedText
      outlineField.stringValue = ""
      return
    }
    textField.attributedStringValue = NSAttributedString(string: displayedText,
                                                          attributes: captionAppearance.textAttributes)
    if let outlineAttributes = captionAppearance.outlineAttributes {
      outlineField.attributedStringValue = NSAttributedString(string: displayedText, attributes: outlineAttributes)
      outlineField.isHidden = false
    } else {
      outlineField.stringValue = ""
      outlineField.isHidden = true
    }
  }

  func measuredCaptionHeight() -> CGFloat {
    guard !displayedText.isEmpty, let captionAppearance,
          captionAppearance.maximumTextWidth > 0 else { return 0 }
    let textBounds = textField.attributedStringValue.boundingRect(
      with: NSSize(width: captionAppearance.maximumTextWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    let strokeInset = (captionAppearance.strokeWidth ?? 0) < 0 ?
      captionAppearance.font.pointSize * abs(captionAppearance.strokeWidth ?? 0) / 100 / 2 : 0
    let shadowInset = captionAppearance.shadow.map {
      abs($0.shadowOffset.height) + $0.shadowBlurRadius
    } ?? 0
    return ceil(textBounds.height + 2 * (captionAppearance.verticalPadding + strokeInset + shadowInset))
  }

  // Caption text must not block player controls or clicks on the video.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class LiveCaptionDecodeCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private let deadline: TimeInterval
  private var cancelled = false

  init(timeout: TimeInterval) {
    deadline = ProcessInfo.processInfo.systemUptime + timeout
  }

  /// A single monotonic deadline covers time waiting on the serial queue as well as FFmpeg open,
  /// probe, seek, and packet reads. FFmpeg polls this through its interrupt callback.
  var shouldInterrupt: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled || ProcessInfo.processInfo.systemUptime >= deadline
  }

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  var deadlineExceeded: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !cancelled && ProcessInfo.processInfo.systemUptime >= deadline
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
}

private struct LiveCaptionChunkRead {
  let data: Data?
  let seekUnsupported: Bool
}

/// Bounds work waiting behind a slow FFmpeg call. At most one drain is submitted to the serial
/// queue, one reader retirement is retained, and one latest read is retained. Pause discards a
/// pending read and coalesces retirement; a later resume keeps only its newest read. The drain
/// always retires the reader before running that resumed read.
private final class LiveCaptionDecodeQueueOrder {
  private let queue: DispatchQueue
  private let lock = NSLock()
  private var pendingRetirement: (() -> Void)?
  private var pendingRead: (() -> Void)?
  private var drainScheduled = false

  init(queue: DispatchQueue) {
    self.queue = queue
  }

  func enqueueRead(_ operation: @escaping () -> Void) {
    lock.lock()
    pendingRead = operation
    scheduleDrainIfNeededLocked()
    lock.unlock()
  }

  func enqueueReaderRetirement(_ operation: @escaping () -> Void) {
    lock.lock()
    pendingRetirement = operation
    pendingRead = nil
    scheduleDrainIfNeededLocked()
    lock.unlock()
  }

  /// Exposed internally so the focused synthetic harness can assert the admission bound.
  var pendingOperationCountForTesting: Int {
    lock.lock()
    defer { lock.unlock() }
    return (pendingRetirement == nil ? 0 : 1) + (pendingRead == nil ? 0 : 1)
  }

  private func scheduleDrainIfNeededLocked() {
    guard !drainScheduled else { return }
    drainScheduled = true
    queue.async { [self] in drain() }
  }

  private func drain() {
    while true {
      let operation: (() -> Void)?
      lock.lock()
      if let retirement = pendingRetirement {
        pendingRetirement = nil
        operation = retirement
      } else if let read = pendingRead {
        pendingRead = nil
        operation = read
      } else {
        drainScheduled = false
        operation = nil
      }
      lock.unlock()

      guard let operation else { return }
      operation()
    }
  }
}

/// Resolves the mpv-selected internal audio track to its FFmpeg stream index. External tracks are
/// unsupported because this reader opens the video URL and cannot reproduce mpv's external-track
/// timestamp offset; returning nil prevents captions from silently using an unrelated embedded track.
private struct LiveCaptionAudioStreamSelection: Equatable {
  let trackID: Int
  let streamIndex: Int

  static func resolve(selectedTrackID: Int?, candidateTrackID: Int?, isExternal: Bool?,
                      streamIndex: Int?) -> LiveCaptionAudioStreamSelection? {
    guard let selectedTrackID, selectedTrackID > 0,
          candidateTrackID == selectedTrackID,
          isExternal == false,
          let streamIndex, streamIndex >= 0 else { return nil }
    return LiveCaptionAudioStreamSelection(trackID: selectedTrackID, streamIndex: streamIndex)
  }
}

/// The playback-time state needed to retire a chunk and safely choose a fresh excerpt after pause.
/// Kept independent of AppKit/Speech so the generation and resume policy can be exercised directly.
private struct LiveCaptionWorkState {
  var generation = 0
  var requestedStart: Double?

  mutating func pause() {
    generation &+= 1
    requestedStart = nil
  }

  func accepts(_ token: Int) -> Bool { generation == token }

  func nextStart(position: Double, chunkDuration: Double) -> Double {
    requestedStart.map { $0 + chunkDuration } ?? floor(position / chunkDuration) * chunkDuration
  }
}

/// Retains one legacy Speech task's admission slot through asynchronous cancellation. Cancelling
/// invalidates output through `LiveCaptionWorkState`, but only its terminal callback may release
/// the slot, preventing rapid pause/resume from stacking Speech tasks.
private struct LiveCaptionLegacySpeechTaskState {
  private(set) var activeIdentifier: UUID?

  var hasActiveTask: Bool { activeIdentifier != nil }

  mutating func begin() -> UUID? {
    guard activeIdentifier == nil else { return nil }
    let identifier = UUID()
    activeIdentifier = identifier
    return identifier
  }

  mutating func finish(_ identifier: UUID) -> Bool {
    guard activeIdentifier == identifier else { return false }
    activeIdentifier = nil
    return true
  }
}

/// Keeps locale discovery single-flight per caption controller. A task handle is not released by
/// cancellation because `installedLocales` may remain suspended until the system lookup returns.
/// While it is suspended, repeated pause/resume or locale changes only replace `latestRequest`.
private struct LiveCaptionLocaleLookupRequest: Equatable {
  let localeID: String
  let mediaURL: URL
  let generation: Int
}

private struct LiveCaptionLocaleLookupStart {
  let id: Int
  let request: LiveCaptionLocaleLookupRequest
}

private enum LiveCaptionLocaleLookupCompletion {
  case publish(LiveCaptionLocaleLookupRequest)
  case start(LiveCaptionLocaleLookupStart)
  case discard
}

private struct LiveCaptionLocaleLookupState {
  private(set) var activeLookupID: Int?
  private var nextLookupID = 0
  private var activeRequest: LiveCaptionLocaleLookupRequest?
  private var activeWasCancelled = false
  private var latestRequest: LiveCaptionLocaleLookupRequest?

  /// Records the newest desired check. Only an idle state admits a new system lookup.
  mutating func request(_ request: LiveCaptionLocaleLookupRequest) -> LiveCaptionLocaleLookupStart? {
    latestRequest = request
    guard activeLookupID == nil else { return nil }
    return start(request)
  }

  /// Invalidates publication and queued intent, but leaves the active identity occupied until its
  /// nonthrowing async lookup actually returns.
  mutating func cancel() -> Int? {
    latestRequest = nil
    guard let activeLookupID else { return nil }
    activeWasCancelled = true
    return activeLookupID
  }

  mutating func finish(_ lookupID: Int) -> LiveCaptionLocaleLookupCompletion? {
    guard activeLookupID == lookupID, let finishedRequest = activeRequest else { return nil }
    let mayPublish = !activeWasCancelled && latestRequest == finishedRequest
    activeLookupID = nil
    activeRequest = nil
    activeWasCancelled = false

    if mayPublish {
      latestRequest = nil
      return .publish(finishedRequest)
    }
    guard let latestRequest else { return .discard }
    return .start(start(latestRequest))
  }

  private mutating func start(_ request: LiveCaptionLocaleLookupRequest) -> LiveCaptionLocaleLookupStart {
    nextLookupID &+= 1
    activeLookupID = nextLookupID
    activeRequest = request
    activeWasCancelled = false
    return LiveCaptionLocaleLookupStart(id: nextLookupID, request: request)
  }
}

private struct LiveCaptionDisplayScale {
  static func unitScale(videoHeight: CGFloat, backingScale: CGFloat, scalesWithWindow: Bool,
                        subtitleScale: CGFloat) -> CGFloat {
    let safeHeight = videoHeight.isFinite && videoHeight > 0 ? videoHeight : 720
    let safeBackingScale = backingScale.isFinite ? max(backingScale, 1) : 1
    let safeSubtitleScale = subtitleScale.isFinite ? min(10, max(0.1, subtitleScale)) : 1
    let displayScale = scalesWithWindow ? safeHeight / 720 : 1 / safeBackingScale
    return displayScale * safeSubtitleScale
  }
}

/// Maps mpv's 0...150 subtitle position into the safe visible range for bottom-aligned captions.
/// Keeping 100 at the configured subtitle margin leaves real, bounded movement on both sides;
/// clamping the raw video-height offset made every value above 100 a dead zone at the default
/// bottom margin.
private enum LiveCaptionVerticalPosition {
  static func bottomConstraintConstant(position: CGFloat, videoHeight: CGFloat,
                                       captionHeight: CGFloat, marginY: CGFloat,
                                       edgeInset: CGFloat, minimumGap: CGFloat) -> CGFloat {
    let height = videoHeight.isFinite && videoHeight > 0 ? videoHeight : 720
    let textHeight = min(height, max(0, captionHeight.isFinite ? captionHeight : 0))
    let inset = min(height / 2, max(0, edgeInset.isFinite ? edgeInset : 16))
    let margin = min(height / 2, max(0, marginY.isFinite ? marginY : inset))
    let minGap = min(min(inset, margin), max(0, minimumGap.isFinite ? minimumGap : 0))
    let value = min(150, max(0, position.isFinite ? position : 100))
    let availableTravel = max(0, height - textHeight - 2 * inset)
    let topLimit = -(inset + availableTravel)
    let baseline = -min(margin, inset + availableTravel)
    if value <= 100 {
      let fraction = value / 100
      return topLimit + (baseline - topLimit) * fraction
    }
    let fraction = (value - 100) / 50
    return baseline + (-minGap - baseline) * fraction
  }
}

/// Keeps the caption frame inside the usable video area even when its text cannot be reduced
/// enough to fit. In that case the view is constrained and clipped instead of expanding offscreen.
private enum LiveCaptionVerticalBounds {
  static func edgeInset(videoHeight: CGFloat, requestedInset: CGFloat,
                        minimumContentHeight: CGFloat = 1) -> CGFloat {
    let height = videoHeight.isFinite && videoHeight > 0 ? videoHeight : 720
    let inset = max(0, requestedInset.isFinite ? requestedInset : 16)
    let contentHeight = min(height, max(0, minimumContentHeight.isFinite ? minimumContentHeight : 1))
    return min(inset, max(0, (height - contentHeight) / 2))
  }

  static func maximumCaptionHeight(videoHeight: CGFloat, edgeInset: CGFloat) -> CGFloat {
    let height = videoHeight.isFinite && videoHeight > 0 ? videoHeight : 720
    let inset = min(height / 2, max(0, edgeInset.isFinite ? edgeInset : 0))
    return max(0, height - 2 * inset)
  }

  static func renderedCaptionHeight(measuredHeight: CGFloat, maximumHeight: CGFloat) -> CGFloat {
    let measured = max(0, measuredHeight.isFinite ? measuredHeight : 0)
    let maximum = max(0, maximumHeight.isFinite ? maximumHeight : 0)
    return min(measured, maximum)
  }
}

/// Mutable state and AppKit objects are confined to the main thread; background decode and Speech
/// tasks return to the main thread before reading or updating the instance.
final class AppleLiveCaptions: @unchecked Sendable {
  private weak var player: PlayerCore?
  private weak var videoContainer: NSView?
  private let overlay = LiveCaptionOverlay(frame: .zero)
  private let decodeWorkOrder = LiveCaptionDecodeQueueOrder(
    queue: DispatchQueue(label: "io.iina.live-captions.decode", qos: .userInitiated))
  private var leftPositionConstraint: NSLayoutConstraint?
  private var horizontalPositionConstraint: NSLayoutConstraint?
  private var centerXPositionConstraint: NSLayoutConstraint?
  private var rightPositionConstraint: NSLayoutConstraint?
  private var topPositionConstraint: NSLayoutConstraint?
  private var verticalPositionConstraint: NSLayoutConstraint?
  private var centerPositionConstraint: NSLayoutConstraint?
  private var bottomPositionConstraint: NSLayoutConstraint?
  private var leadingLimitConstraint: NSLayoutConstraint?
  private var trailingLimitConstraint: NSLayoutConstraint?
  private var maximumHeightConstraint: NSLayoutConstraint?
  private var boundsObserver: NSObjectProtocol?
  private var displayObservers: [NSObjectProtocol] = []
  private weak var observedDisplayWindow: NSWindow?
  private var previouslyPostedBoundsChanges: Bool?
  private var appearanceObserver: Preference.Observer?
  private var appearanceNotificationsInstalled = false
  private var timer: Timer?
  private var recognizer: SFSpeechRecognizer?
  private var task: SFSpeechRecognitionTask?
  private var legacySpeechTaskState = LiveCaptionLegacySpeechTaskState()
  private var analyzerTask: Task<Void, Never>?
  private var workState = LiveCaptionWorkState()
  private var generation: Int {
    get { workState.generation }
    set { workState.generation = newValue }
  }
  private var requestedStart: Double? {
    get { workState.requestedStart }
    set { workState.requestedStart = newValue }
  }
  private var exhaustedAtPosition: Double?
  private var activeURL: URL?
  private var activeAudioSelection: LiveCaptionAudioStreamSelection?
  private var inFlight = false
  private var recognitionStartedAt: Date?
  private var authorizationRequested = false
  private var captionResults = SpeechCaptionResultStore()
  private var playbackTimeline = SpeechCaptionPlaybackTimeline()
  private var decodeCancellation: LiveCaptionDecodeCancellation?
  private var unavailableSpeechLocales = Set<String>()
  private var installedSpeechLanguageCodes: Set<String>?
  private var speechLocaleCheckTask: Task<Void, Never>?
  private var speechLocaleLookupState = LiveCaptionLocaleLookupState()
  private let chunkDuration: Double = 10
  /// Consecutive chunks of the active stream that could not be opened or decoded.
  private var streamDecodeFailures = 0
  /// Set after repeated stream failures so an unreadable URL is not refetched every chunk.
  private var abandonedURL: URL?
  /// Keeps the media open between chunks so a stream is not reconnected and re-probed each time.
  /// Confined to `decodeQueue`.
  private var chunkReader: FFmpegAudioChunkReader?
  private var chunkReaderSource: String?
  private var chunkReaderStreamIndex: Int?
  /// How far the audio being heard is ahead of the picture (audio delay plus output latency), as
  /// last measured. Kept between measurements so the caption clock never jumps when mpv briefly
  /// cannot report the audio position.
  private var audioOffset: Double?

  init(player: PlayerCore) { self.player = player }

  /// Turns live captions on or off from the player and confirms the change on screen.
  static func setEnabled(_ enabled: Bool, osdPlayer player: PlayerCore?) {
    Preference.set(enabled, for: .appleLiveCaptionsFallback)
    let key = enabled ? "osd.apple_live_captions_on" : "osd.apple_live_captions_off"
    player?.sendOSD(.custom(NSLocalizedString(key, comment: key)))
  }

  /// Local files and direct http(s) sources are candidates for transcription. Network sources must
  /// support seeking to excerpts; the decoder abandons them when the source cannot seek.
  static func canTranscribe(_ url: URL) -> Bool {
    if url.isFileURL { return true }
    let scheme = url.scheme?.lowercased()
    return scheme == "http" || scheme == "https"
  }

  func install(in contentView: NSView, above videoContainer: NSView) {
    self.videoContainer = videoContainer
    if !appearanceNotificationsInstalled, let player {
      player.observe(.iinaSubScaleChanged) { [weak self] _ in
        self?.updateAppearance()
      }
      player.observe(.iinaSubPositionChanged) { [weak self] _ in
        self?.updateAppearance()
      }
      player.observe(.iinaSubStyleChanged) { [weak self] _ in
        self?.updateAppearance()
      }
      player.observe(.iinaAIDChanged) { [weak self] _ in
        guard let self, let player = self.player else { return }
        self.updateAudioStreamSelection(for: player)
      }
      appearanceNotificationsInstalled = true
    }
    contentView.addSubview(overlay, positioned: .above, relativeTo: videoContainer)
    let centeredX = overlay.centerXAnchor.constraint(equalTo: videoContainer.centerXAnchor)
    let leftX = overlay.leadingAnchor.constraint(equalTo: videoContainer.leadingAnchor, constant: 16)
    let rightX = overlay.trailingAnchor.constraint(equalTo: videoContainer.trailingAnchor, constant: -16)
    let topY = overlay.topAnchor.constraint(equalTo: videoContainer.topAnchor, constant: 16)
    let centerY = overlay.centerYAnchor.constraint(equalTo: videoContainer.centerYAnchor)
    let bottomY = overlay.bottomAnchor.constraint(equalTo: videoContainer.bottomAnchor, constant: -16)
    let widthLimit = overlay.widthAnchor.constraint(lessThanOrEqualTo: videoContainer.widthAnchor,
                                                     multiplier: 0.9)
    let heightLimit = overlay.heightAnchor.constraint(lessThanOrEqualToConstant: 0)
    let leadingLimit = overlay.leadingAnchor.constraint(greaterThanOrEqualTo: videoContainer.leadingAnchor,
                                                        constant: 16)
    let trailingLimit = overlay.trailingAnchor.constraint(lessThanOrEqualTo: videoContainer.trailingAnchor,
                                                          constant: -16)
    leftPositionConstraint = leftX
    horizontalPositionConstraint = centeredX
    centerXPositionConstraint = centeredX
    rightPositionConstraint = rightX
    topPositionConstraint = topY
    centerPositionConstraint = centerY
    verticalPositionConstraint = bottomY
    bottomPositionConstraint = bottomY
    leadingLimitConstraint = leadingLimit
    trailingLimitConstraint = trailingLimit
    maximumHeightConstraint = heightLimit
    NSLayoutConstraint.activate([
      centeredX,
      bottomY,
      widthLimit,
      heightLimit,
      leadingLimit,
      trailingLimit,
    ])

    updateAppearance()
  }

  deinit {
    stopAppearanceTracking()
  }

  private func updateAppearance() {
    guard let videoContainer else { return }
    let bounds = videoContainer.bounds
    let videoHeight = bounds.height > 0 ? bounds.height : 720
    let videoWidth = bounds.width > 0 ? bounds.width : videoHeight * 16 / 9
    let backingScale = videoContainer.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    let player = self.player
    let scalesWithWindow = Preference.bool(for: .subScaleWithWindow)
    let subtitleScale = CGFloat(player?.info.subScale ?? 1)
    let unitScale = LiveCaptionDisplayScale.unitScale(videoHeight: videoHeight,
                                                      backingScale: backingScale,
                                                      scalesWithWindow: scalesWithWindow,
                                                      subtitleScale: subtitleScale)

    let configuredSize = CGFloat(player?.info.subtitleStyleOverrides.size ?? Double(Preference.float(for: .subTextSize)))
    let requestedSize = (configuredSize.isFinite ? max(1, configuredSize) : 55) * unitScale
    let maximumSize = max(4, min(videoHeight * 0.16, 96))
    let fontSize = min(max(requestedSize, 4), maximumSize)
    let fontName = player?.info.subtitleStyleOverrides.font ?? Preference.string(for: .subTextFont) ?? "sans-serif"
    let baseFont: NSFont
    if fontName.localizedCaseInsensitiveContains("mono") {
      baseFont = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    } else {
      baseFont = NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
    }
    var traits: NSFontTraitMask = []
    if player?.info.subtitleStyleOverrides.bold ?? Preference.bool(for: .subBold) { traits.insert(.boldFontMask) }
    if Preference.bool(for: .subItalic) { traits.insert(.italicFontMask) }
    let font = traits.isEmpty ? baseFont : NSFontManager.shared.convert(baseFont, toHaveTrait: traits)

    let textColor = color(for: .subTextColorString,
                          override: player?.info.subtitleStyleOverrides.textColor, fallback: .white)
    let borderColor = color(for: .subBorderColorString,
                            override: player?.info.subtitleStyleOverrides.borderColor, fallback: .black)
    let shadowColor = color(for: .subShadowColorString,
                            override: player?.info.subtitleStyleOverrides.backgroundColor, fallback: .clear)
    let configuredBorderSize = player?.info.subtitleStyleOverrides.borderSize ??
      Double(Preference.float(for: .subBorderSize))
    let borderSize = max(0, (configuredBorderSize.isFinite ? CGFloat(configuredBorderSize) : 0) * unitScale)
    let shadowSize = min(fontSize, max(0, scaled(.subShadowSize, by: unitScale)))
    let borderStyle = Preference.enum(for: .subBorderStyle) as Preference.SubBorderStyle
    let alignment = Preference.enum(for: .subAlignX) as Preference.SubAlignX
    let textAlignment: NSTextAlignment = switch alignment {
    case .left: .left
    case .center: .center
    case .right: .right
    }
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = textAlignment
    paragraphStyle.lineBreakMode = .byWordWrapping

    // The stroke is centred on the glyph edge and the letters cover its inner half, so it is drawn
    // at twice the outline size.
    let strokeWidth: CGFloat? = borderStyle == .outlineAndShadow && borderSize > 0 ?
      -min(100, 2 * borderSize / fontSize * 100) : nil
    let shadow: NSShadow? = shadowSize > 0 && shadowColor.alphaComponent > 0 ? {
      let value = NSShadow()
      value.shadowColor = shadowColor
      value.shadowOffset = NSSize(width: 0, height: -shadowSize)
      value.shadowBlurRadius = max(0.5, shadowSize * 0.35)
      return value
    }() : nil
    let backgroundColor: NSColor? = switch borderStyle {
    case .outlineAndShadow: nil
    case .opaqueBox: borderColor
    case .backgroundBox:
      shadowColor.alphaComponent > 0 ? shadowColor : NSColor.black.withAlphaComponent(0.55)
    }
    let glyphSafetyInset = min(14, max(4, fontSize * 0.08 + max(borderSize * 0.75,
                                                                  shadow?.shadowBlurRadius ?? 0)))
    let padding: CGFloat = backgroundColor == nil ? glyphSafetyInset :
      max(glyphSafetyInset, min(10, max(4, fontSize * 0.18)))
    let marginX = min(max(0, scaled(.subMarginX, by: unitScale)), videoWidth * 0.45)
    let sideMargin = max(16, marginX)
    let maximumOverlayWidth = max(1, min(videoWidth * 0.9, videoWidth - sideMargin * 2))
    let maximumTextWidth = max(1, maximumOverlayWidth - padding * 2)
    let verticalPadding = max(4, padding * 0.8)
    var appearance = LiveCaptionAppearance(
      font: font,
      textColor: textColor,
      alignment: textAlignment,
      paragraphStyle: paragraphStyle,
      strokeColor: borderStyle == .outlineAndShadow && borderSize > 0 ? borderColor : nil,
      strokeWidth: strokeWidth,
      shadow: shadow,
      backgroundColor: backgroundColor,
      maximumTextWidth: maximumTextWidth,
      horizontalPadding: padding,
      verticalPadding: verticalPadding,
      cornerRadius: backgroundColor == nil ? 0 : min(5, padding),
      characterSpacing: scaled(.subSpacing, by: unitScale)
    )
    let marginY = min(max(0, scaled(.subMarginY, by: unitScale)), videoHeight * 0.45)
    let verticalEdgeInset = LiveCaptionVerticalBounds.edgeInset(
      videoHeight: videoHeight, requestedInset: max(16, marginY))
    let maximumCaptionHeight = LiveCaptionVerticalBounds.maximumCaptionHeight(
      videoHeight: videoHeight, edgeInset: verticalEdgeInset)
    maximumHeightConstraint?.constant = maximumCaptionHeight
    overlay.apply(appearance)
    if fontSize > 4, overlay.measuredCaptionHeight() > maximumCaptionHeight {
      var lowerFontSize: CGFloat = 4
      var upperFontSize = fontSize
      var fittedAppearance = appearance.resized(toFontSize: lowerFontSize)
      overlay.apply(fittedAppearance)
      if overlay.measuredCaptionHeight() <= maximumCaptionHeight {
        for _ in 0..<12 {
          let candidateSize = (lowerFontSize + upperFontSize) / 2
          let candidateAppearance = appearance.resized(toFontSize: candidateSize)
          overlay.apply(candidateAppearance)
          if overlay.measuredCaptionHeight() <= maximumCaptionHeight {
            lowerFontSize = candidateSize
            fittedAppearance = candidateAppearance
          } else {
            upperFontSize = candidateSize
          }
        }
      }
      appearance = fittedAppearance
      overlay.apply(appearance)
    }

    if let horizontalPositionConstraint { horizontalPositionConstraint.isActive = false }
    let horizontalConstraint: NSLayoutConstraint
    switch alignment {
    case .left:
      horizontalConstraint = leftPositionConstraint!
      horizontalConstraint.constant = sideMargin
    case .center:
      horizontalConstraint = centerXPositionConstraint!
    case .right:
      horizontalConstraint = rightPositionConstraint!
      horizontalConstraint.constant = -sideMargin
    }
    horizontalPositionConstraint = horizontalConstraint
    horizontalConstraint.isActive = true

    if let verticalPositionConstraint { verticalPositionConstraint.isActive = false }
    let verticalAlignment = Preference.enum(for: .subAlignY) as Preference.SubAlignY
    let configuredPosition = CGFloat(player?.info.subPos ?? Double(Preference.float(for: .subPos)))
    let position = (configuredPosition.isFinite ? configuredPosition : 100).clamped(to: 0...150)
    let positionOffset = (position - 100) / 100 * videoHeight
    let renderedCaptionHeight = LiveCaptionVerticalBounds.renderedCaptionHeight(
      measuredHeight: overlay.measuredCaptionHeight(), maximumHeight: maximumCaptionHeight)
    let remainingHeight = max(0, videoHeight - renderedCaptionHeight - 2 * verticalEdgeInset)
    let verticalConstraint: NSLayoutConstraint
    switch verticalAlignment {
    case .top:
      verticalConstraint = topPositionConstraint!
      verticalConstraint.constant = (marginY + positionOffset).clamped(
        to: verticalEdgeInset...(verticalEdgeInset + remainingHeight))
    case .center:
      verticalConstraint = centerPositionConstraint!
      // Preserve mpv's positive sub-pos direction: down on screen.
      verticalConstraint.constant = positionOffset.clamped(to: (-remainingHeight / 2)...(remainingHeight / 2))
    case .bottom:
      verticalConstraint = bottomPositionConstraint!
      verticalConstraint.constant = LiveCaptionVerticalPosition.bottomConstraintConstant(
        position: position,
        videoHeight: videoHeight,
        captionHeight: renderedCaptionHeight,
        marginY: marginY,
        edgeInset: verticalEdgeInset,
        minimumGap: glyphSafetyInset
      )
    }
    verticalPositionConstraint = verticalConstraint
    verticalConstraint.isActive = true

    leadingLimitConstraint?.constant = sideMargin
    trailingLimitConstraint?.constant = -sideMargin
  }

  private func observeAppearancePreferences() {
    guard let videoContainer else { return }
    if appearanceObserver == nil {
      let observer = Preference.Observer()
      observer.addAll([
        .subTextFont, .subTextSize, .subTextColorString, .subBold, .subItalic, .subSpacing,
        .subBorderSize, .subBorderColorString, .subShadowSize, .subShadowColorString, .subBorderStyle,
        .subAlignX, .subAlignY, .subMarginX, .subMarginY, .subPos, .subScaleWithWindow,
      ]) { [weak self] key in
        guard let self else { return }
        let update = { [weak self] in
          guard let self else { return }
          self.player?.info.subtitleStyleOverrides.clear(for: key)
          self.updateAppearance()
        }
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
      }
      appearanceObserver = observer
    }
    if boundsObserver == nil {
      previouslyPostedBoundsChanges = videoContainer.postsBoundsChangedNotifications
      videoContainer.postsBoundsChangedNotifications = true
      boundsObserver = NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification, object: videoContainer, queue: .main
      ) { [weak self] _ in
        self?.updateAppearance()
      }
    }
    observeWindowDisplayChanges()
    updateAppearance()
  }

  /// The video bounds can remain identical in points when a window moves between displays. Follow
  /// both AppKit notifications so backing-scale based, unscaled captions recompute immediately.
  private func observeWindowDisplayChanges() {
    let window = videoContainer?.window
    guard observedDisplayWindow !== window else { return }
    for observer in displayObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    displayObservers.removeAll()
    observedDisplayWindow = window
    guard let window else { return }

    for notification in [NSWindow.didChangeBackingPropertiesNotification,
                         NSWindow.didChangeScreenNotification] {
      displayObservers.append(NotificationCenter.default.addObserver(
        forName: notification, object: window, queue: .main
      ) { [weak self] note in
        guard let self,
              let changedWindow = note.object as? NSWindow,
              changedWindow === self.videoContainer?.window else { return }
        self.updateAppearance()
      })
    }
  }

  private func stopAppearanceTracking() {
    appearanceObserver = nil
    if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    boundsObserver = nil
    for observer in displayObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    displayObservers.removeAll()
    observedDisplayWindow = nil
    if let videoContainer, let previouslyPostedBoundsChanges {
      videoContainer.postsBoundsChangedNotifications = previouslyPostedBoundsChanges
    }
    previouslyPostedBoundsChanges = nil
  }

  private func scaled(_ key: Preference.Key, by scale: CGFloat) -> CGFloat {
    let value = CGFloat(Preference.float(for: key))
    return value.isFinite ? value * scale : 0
  }

  private func color(for key: Preference.Key, override: String?, fallback: NSColor) -> NSColor {
    guard let value = override ?? Preference.string(for: key), let color = NSColor(mpvColorString: value) else {
      return fallback
    }
    return color
  }

  /// Called when media or tracks change. A real subtitle immediately supersedes generated text.
  func updateEligibility() {
    guard let player else { stop(); return }
    guard Preference.bool(for: .appleLiveCaptionsFallback) else {
      // Let a user retry after installing a speech model while the app is open.
      stopAppearanceTracking()
      unavailableSpeechLocales.removeAll()
      installedSpeechLanguageCodes = nil
      stop()
      return
    }
    guard player.info.state.loaded,
          player.info.vid != nil, player.info.vid != 0,
          player.info.subTracks.isEmpty,
          let url = player.info.currentURL, Self.canTranscribe(url) else {
      Logger.log("Apple live captions ineligible: state=\(player.info.state), video=\(player.info.vid ?? -1), subtitleTracks=\(player.info.subTracks.count)",
                 level: .debug, subsystem: Logger.Sub.onlinesub)
      stop()
      stopAppearanceTracking()
      return
    }
    observeAppearancePreferences()

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
        checkInstalledSpeechLocales(localeID: localeID, mediaURL: url)
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
      // A chunk already in FFmpeg or Speech must not keep consuming resources while the player is
      // paused, and its eventual callback must not publish stale text. Retire the requested start
      // so resume schedules the excerpt containing the current playhead again.
      workState.pause()
      cancelSpeechLocaleCheck()
      cancelDecode()
      cancelLegacySpeechTask()
      // Keep the handle until the analyzer's cancellation cleanup has actually drained; tick's
      // scheduler uses this to avoid overlapping SpeechAnalyzer sessions on resume.
      analyzerTask?.cancel()
      inFlight = false
      recognitionStartedAt = nil
      exhaustedAtPosition = nil
      enqueueChunkReaderRetirement()
    } else {
      updateEligibility()
    }
  }

  func stop() {
    generation += 1
    cancelSpeechLocaleCheck()
    cancelDecode()
    timer?.invalidate()
    timer = nil
    cancelLegacySpeechTask()
    analyzerTask?.cancel()
    recognizer = nil
    requestedStart = nil
    exhaustedAtPosition = nil
    activeURL = nil
    activeAudioSelection = nil
    audioOffset = nil
    playbackTimeline.reset()
    inFlight = false
    recognitionStartedAt = nil
    captionResults.removeAll()
    overlay.isHidden = true
    overlay.setCaptionText("")
    stopAppearanceTracking()
    enqueueChunkReaderRetirement()
  }

  /// Confined reader state can only be retired on its owner queue. Enqueuing this from pause puts
  /// it behind the current FFmpeg call and ahead of any read enqueued after resume.
  private func enqueueChunkReaderRetirement() {
    decodeWorkOrder.enqueueReaderRetirement { [weak self] in
      self?.chunkReader = nil
      self?.chunkReaderSource = nil
      self?.chunkReaderStreamIndex = nil
    }
  }

  /// Track selection changes arrive on the main thread from mpv. Retire old work and captions
  /// immediately so a late recognition result from the previous language cannot be displayed.
  private func updateAudioStreamSelection(for player: PlayerCore) {
    let track = player.info.currentTrack(.audio)
    let selection = LiveCaptionAudioStreamSelection.resolve(
      selectedTrackID: player.info.aid,
      candidateTrackID: track?.id,
      isExternal: track?.isExternal,
      streamIndex: track?.ffIndex
    )
    guard selection != activeAudioSelection else { return }
    activeAudioSelection = selection
    guard activeURL != nil else { return }

    workState.pause()
    cancelDecode()
    cancelLegacySpeechTask()
    analyzerTask?.cancel()
    inFlight = false
    recognitionStartedAt = nil
    exhaustedAtPosition = nil
    audioOffset = nil
    captionResults.removeAll()
    overlay.setCaptionText("")
    overlay.isHidden = true
    enqueueChunkReaderRetirement()
  }

  private func startTimer() {
    timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      self?.tick()
    }
  }

  private func cancelDecode() {
    decodeCancellation?.cancel()
    decodeCancellation = nil
  }

  private func cancelLegacySpeechTask() {
    // Keep the task and its admission identifier until Speech reports a terminal callback. This
    // invalidates results immediately without starting overlapping recognition services.
    task?.cancel()
  }

  private func finishLegacySpeechTask(_ identifier: UUID) {
    guard legacySpeechTaskState.finish(identifier) else { return }
    task = nil
  }

  private func retireCompletedLegacySpeechTaskIfNeeded() {
    guard let identifier = legacySpeechTaskState.activeIdentifier,
          task?.state == .completed else { return }
    finishLegacySpeechTask(identifier)
  }

  private func cancelSpeechLocaleCheck() {
    guard speechLocaleLookupState.cancel() != nil else { return }
    // Keep the handle and admission slot until installedLocales returns. Task cancellation is
    // cooperative, so clearing either here could accumulate concurrent system lookups on resume.
    speechLocaleCheckTask?.cancel()
  }

  private func tick() {
    guard let player,
          Preference.bool(for: .appleLiveCaptionsFallback),
          player.info.state.loaded,
          player.info.vid != nil, player.info.vid != 0,
          player.info.subTracks.isEmpty,
          let url = player.info.currentURL, Self.canTranscribe(url) else {
      stop()
      return
    }
    retireCompletedLegacySpeechTaskIfNeeded()
    if activeURL != url {
      generation += 1
      cancelDecode()
      cancelLegacySpeechTask()
      analyzerTask?.cancel()
      inFlight = false
      recognitionStartedAt = nil
      requestedStart = nil
      exhaustedAtPosition = nil
      captionResults.removeAll()
      playbackTimeline.reset()
      streamDecodeFailures = 0
      abandonedURL = nil
      audioOffset = nil
      activeAudioSelection = nil
      activeURL = url
    }
    updateAudioStreamSelection(for: player)
    // The UI timer stops after the OSC hides. Keep the cached position current so the chunk
    // scheduler continues through a normal playback session with no visible controls.
    player.syncPositionIfNeeded()
    guard let videoPosition = player.info.videoPosition?.second, videoPosition.isFinite, videoPosition >= 0 else {
      stop()
      return
    }
    let position = captionClock(videoPosition: videoPosition)
    if playbackTimeline.movedBack(to: position) {
      // The playhead can move backward without crossing the current recognition chunk boundary.
      // Invalidate that work and clear text from the previous pass through this time range.
      Logger.log("Apple live captions reset: playhead moved back to \(position)s",
                 level: .debug, subsystem: Logger.Sub.onlinesub)
      generation += 1
      cancelDecode()
      cancelLegacySpeechTask()
      analyzerTask?.cancel()
      inFlight = false
      recognitionStartedAt = nil
      requestedStart = nil
      exhaustedAtPosition = nil
      captionResults.removeAll()
      overlay.isHidden = true
    }
    // Bound result growth: chunks arrive throughout the session, so discard text the playhead can
    // no longer reach without a seek (a seek resets the store wholesale).
    captionResults.removeCues(endingBefore: position - 20)
    // Subtitle Delay applies to these captions as it does to a subtitle track: positive is later.
    let heard = position - uncountedOutputLatency(player) - player.info.subDelay
    let text = captionResults.text(at: heard, playbackRate: player.info.playSpeed)
    if overlay.setCaptionText(text) {
      updateAppearance()
    }
    overlay.isHidden = text.isEmpty

    guard player.info.state == .playing, abandonedURL != url else { return }
    if inFlight, let recognitionStartedAt,
       Date().timeIntervalSince(recognitionStartedAt) > 15 {
      Logger.log("Apple live captions: chunk \(requestedStart ?? -1)s timed out",
                 level: .debug, subsystem: Logger.Sub.onlinesub)
      generation += 1
      cancelDecode()
      cancelLegacySpeechTask()
      analyzerTask?.cancel()
      inFlight = false
      self.recognitionStartedAt = nil
    }
    // The next chunk is requested before the playhead reaches it, so the playhead is normally inside
    // the chunk before `requestedStart`. Anything outside that and the requested chunk is a seek.
    if let requestedStart,
       position < requestedStart - chunkDuration - 1 || position >= requestedStart + chunkDuration * 2 {
      // A seek invalidates both a pending recognition result and the displayed cues.
      Logger.log("Apple live captions reset: \(position)s is outside chunk \(requestedStart)s",
                 level: .debug, subsystem: Logger.Sub.onlinesub)
      generation += 1
      cancelDecode()
      cancelLegacySpeechTask()
      analyzerTask?.cancel()
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
    // Captions wait for final text, so the next chunk starts well before it is needed; a stream
    // starts earlier still in case its connection has to be reopened.
    let lookahead: Double = url.isFileURL ? 4 : 6
    guard let audioSelection = activeAudioSelection else { return }
    if !inFlight, analyzerTask == nil, !legacySpeechTaskState.hasActiveTask,
       requestedStart == nil || position >= requestedStart! + chunkDuration - lookahead {
      let start = workState.nextStart(position: position, chunkDuration: chunkDuration)
      transcribe(url: url, start: start, selection: audioSelection)
    }
  }

  /// Captions follow the sound, not the picture. mpv's audio position is the media time of the
  /// audio it has handed to the output, including the audio delay setting. The video position is
  /// used when there is no audio.
  private func captionClock(videoPosition: Double) -> Double {
    guard let player, let aid = player.info.aid, aid > 0 else { return videoPosition }
    return mpvAudioClock(videoPosition: videoPosition)
  }

  private var outputLatency: (value: Double, checkedAt: Date)?

  /// mpv's CoreAudio output leaves out the stream latency, which is where an AirPlay speaker reports
  /// its roughly two seconds of buffering, so the sound being heard is this far behind mpv's audio
  /// position. Only the displayed text uses it; the chunk scheduler stays on mpv's clock, so
  /// switching speakers does not look like a seek.
  private func uncountedOutputLatency(_ player: PlayerCore) -> Double {
    guard let aid = player.info.aid, aid > 0 else { return 0 }
    if let outputLatency, Date().timeIntervalSince(outputLatency.checkedAt) < 1 { return outputLatency.value }
    // Until mpv has opened its audio output there is nothing to measure yet.
    guard let ao = player.mpv.getString(MPVProperty.currentAo) else { return outputLatency?.value ?? 0 }
    let value = ao == "coreaudio"
      ? CoreAudioOutput.streamLatency(mpvDevice: player.mpv.getString(MPVProperty.audioDevice) ?? "auto") : 0
    if value != outputLatency?.value {
      Logger.log("Apple live captions: output stream latency \(value)s", level: .debug, subsystem: Logger.Sub.onlinesub)
    }
    outputLatency = (value, Date())
    return value
  }

  private func mpvAudioClock(videoPosition: Double) -> Double {
    guard let player else { return videoPosition }
    if let audioPosition = player.mpv.getDoubleIfAvailable(MPVProperty.audioPts), audioPosition >= 0 {
      let measured = audioPosition - videoPosition
      if abs(measured) < 30 {
        // Smooth small jitter between the two positions; follow a real change (such as a new audio
        // delay) straight away.
        if let audioOffset, abs(measured - audioOffset) < 0.3 {
          self.audioOffset = audioOffset * 0.9 + measured * 0.1
        } else {
          audioOffset = measured
        }
      }
    }
    return max(0, videoPosition + (audioOffset ?? 0))
  }

  /// Runs on `decodeQueue`. Reuses the open reader for the same media; replaces it after an error.
  private func readChunk(from source: String, streamIndex: Int, start: Double, duration: Double,
                         cancellation: LiveCaptionDecodeCancellation) -> LiveCaptionChunkRead {
    let check: () -> Bool = { cancellation.shouldInterrupt }
    if chunkReaderSource != source || chunkReaderStreamIndex != streamIndex || chunkReader?.failed != false {
      chunkReader = nil
      chunkReaderSource = source
      chunkReaderStreamIndex = streamIndex
      chunkReader = FFmpegAudioChunkReader(source: source, audioStreamIndex: streamIndex,
                                           cancellationCheck: check)
    }
    let data = chunkReader?.readMonoAudio(from: start, duration: duration, cancellationCheck: check)
    return LiveCaptionChunkRead(data: data, seekUnsupported: chunkReader?.seekUnsupported == true)
  }

  private func transcribe(url: URL, start: Double, selection: LiveCaptionAudioStreamSelection) {
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
    Logger.log("Apple live captions: transcribing \(start)s for \(duration)s",
               level: .debug, subsystem: Logger.Sub.onlinesub)
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
    let decodeCancellation = LiveCaptionDecodeCancellation(timeout: 15)
    self.decodeCancellation = decodeCancellation
    let source = url.isFileURL ? url.path : url.absoluteString
    decodeWorkOrder.enqueueRead { [weak self] in
      let read = self?.readChunk(from: source, streamIndex: selection.streamIndex,
                                 start: start, duration: duration, cancellation: decodeCancellation)
      DispatchQueue.main.async {
        guard let self else { return }
        if self.decodeCancellation === decodeCancellation { self.decodeCancellation = nil }
        guard self.workState.accepts(token), self.player?.info.currentURL == url,
              self.activeAudioSelection == selection else { return }
        guard let data = read?.data, !data.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(data.count / MemoryLayout<Float>.size)),
              let channel = buffer.floatChannelData?[0] else {
          self.inFlight = false
          self.recognitionStartedAt = nil
          if read?.data == nil, decodeCancellation.deadlineExceeded {
            Logger.log("Apple live captions: audio chunk decoding exceeded its 15s deadline",
                       level: .debug, subsystem: Logger.Sub.onlinesub)
          }
          if read?.seekUnsupported == true, !url.isFileURL {
            // Excerpt transcription must seek to each requested media-time window. A live or
            // otherwise nonseekable HTTP input cannot satisfy that contract, so stop retrying it.
            self.abandonedURL = url
            self.streamDecodeFailures = 0
            Logger.log("Apple live captions stopped for this stream: its audio source cannot seek to excerpts",
                       level: .warning, subsystem: Logger.Sub.onlinesub)
          } else if !url.isFileURL, !decodeCancellation.isCancelled {
            self.streamDecodeFailures += 1
            if self.streamDecodeFailures >= 3 {
              self.abandonedURL = url
              Logger.log("Apple live captions stopped for this stream: its audio could not be read",
                         level: .warning, subsystem: Logger.Sub.onlinesub)
            }
          }
          return
        }
        self.streamDecodeFailures = 0
        data.copyBytes(to: UnsafeMutableRawBufferPointer(start: channel, count: data.count))
        buffer.frameLength = buffer.frameCapacity
        // Start the recognition timeout after FFmpeg has finished. A slow local-container probe
        // must not make us abandon a chunk before the on-device recognizer has even started.
        self.recognitionStartedAt = Date()
        if #available(macOS 26, *), SpeechTranscriber.isAvailable {
          self.transcribeWithSpeechAnalyzer(buffer, start: start, token: token, url: url,
                                            selection: selection)
          return
        }
        guard let recognizer = self.recognizer else {
          self.inFlight = false
          self.recognitionStartedAt = nil
          return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        // Chunks are transcribed ahead of playback, so there is time to wait for the final text.
        // Partial results would be shown and then rewritten while they are on screen.
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        guard let speechTaskIdentifier = self.legacySpeechTaskState.begin() else {
          self.inFlight = false
          self.recognitionStartedAt = nil
          return
        }
        self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
          DispatchQueue.main.async {
            guard let self else { return }
            if result?.isFinal == true || error != nil {
              self.finishLegacySpeechTask(speechTaskIdentifier)
            }
            guard self.workState.accepts(token), self.player?.info.currentURL == url,
                  self.activeAudioSelection == selection else { return }
            if let result {
              let words = result.bestTranscription.segments.map { segment in
                SpeechCaptionResultStore.TimedWord(text: " " + segment.substring,
                                                   start: start + segment.timestamp,
                                                   end: start + segment.timestamp + max(segment.duration, 0.001))
              }
              self.captionResults.replaceChunk(start, with: [])
              self.captionResults.applyFinalResult(chunkStart: start, words: words)
              self.captionResults.removeCues(endingBefore: (self.player?.info.videoPosition?.second ?? 0) - 20)
            }
            if result?.isFinal == true || error != nil {
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
  private func transcribeWithSpeechAnalyzer(_ buffer: AVAudioPCMBuffer, start: Double, token: Int,
                                            url: URL, selection: LiveCaptionAudioStreamSelection) {
    let locale = selectedSpeechLocale
    let localeID = canonicalLocaleID(locale)
    analyzerTask = Task { [weak self] in
      guard let captions = self else { return }
      defer {
        Task { @MainActor [weak captions] in
          captions?.speechAnalyzerDidFinish(generation: token)
        }
      }
      do {
        try Task.checkCancellation()
        // Final results only: chunks are transcribed ahead of playback, so the text does not need to
        // be shown as a draft and rewritten on screen. Word timings place each caption line.
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        try Task.checkCancellation()
        guard let format else {
          Logger.log("Apple live captions have no installed on-device model for \(locale.identifier)",
                     level: .warning, subsystem: Logger.Sub.onlinesub)
          await MainActor.run {
            guard captions.workState.accepts(token) else { return }
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
        try Task.checkCancellation()
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
        let cancellation = SpeechAnalyzerCancellation(analyzer: analyzer)
        let results = Task {
          for try await result in transcriber.results {
            guard !Task.isCancelled else { break }
            guard result.isFinal else { continue }
            var words: [SpeechCaptionResultStore.TimedWord] = []
            for run in result.text.runs {
              let text = String(result.text[run.range].characters)
              if let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] {
                words.append(.init(text: text, start: start + range.start.seconds, end: start + range.end.seconds))
              } else if let last = words.popLast() {
                // Punctuation can arrive as its own run without a time range.
                words.append(.init(text: last.text + text, start: last.start, end: last.end))
              }
            }
            if words.isEmpty {
              let text = String(result.text.characters)
              words = [.init(text: text, start: start + result.range.start.seconds, end: start + result.range.end.seconds)]
            }
            let finalWords = words
            await MainActor.run {
              guard captions.workState.accepts(token), captions.player?.info.currentURL == url,
                    captions.activeAudioSelection == selection else { return }
              captions.captionResults.applyFinalResult(chunkStart: start, words: finalWords)
              Logger.log("Apple live captions: \(finalWords.count) words at \(finalWords.first?.start ?? -1)s for chunk \(start)s",
                         level: .debug, subsystem: Logger.Sub.onlinesub)
            }
          }
        }
        // This is an unstructured task. Always stop its result consumer when this chunk exits,
        // including cancellation and timeout paths, so it cannot outlive the analyzer session.
        defer { results.cancel() }
        try await withTaskCancellationHandler {
          do {
            try Task.checkCancellation()
            let last = try await analyzer.analyzeSequence(stream)
            try Task.checkCancellation()
            if let last { try await analyzer.finalizeAndFinish(through: last) }
            try await results.value
          } catch {
            results.cancel()
            cancellation.cancel()
            await cancellation.waitUntilCancelled()
            try? await results.value
            throw error
          }
        } onCancel: {
          cancellation.cancel()
        }
      } catch {
        if !Task.isCancelled {
          Logger.log("Apple live captions could not transcribe audio: \(error.localizedDescription)",
                     level: .warning, subsystem: Logger.Sub.onlinesub)
        }
      }
    }
  }

  @MainActor
  private func speechAnalyzerDidFinish(generation token: Int) {
    analyzerTask = nil
    guard workState.accepts(token) else { return }
    inFlight = false
    recognitionStartedAt = nil
  }

  private var selectedSpeechLocale: Locale {
    let selected = Preference.string(for: .appleLiveCaptionsLanguage) ?? ""
    return selected.isEmpty ? Locale.current : Locale(identifier: selected)
  }

  private func canonicalLocaleID(_ locale: Locale) -> String {
    Locale.canonicalIdentifier(from: locale.identifier)
  }

  @available(macOS 26, *)
  private func checkInstalledSpeechLocales(localeID: String, mediaURL: URL) {
    let request = LiveCaptionLocaleLookupRequest(localeID: localeID, mediaURL: mediaURL,
                                                generation: generation)
    guard let lookup = speechLocaleLookupState.request(request) else { return }
    startInstalledSpeechLocaleLookup(lookup)
  }

  @available(macOS 26, *)
  private func startInstalledSpeechLocaleLookup(_ lookup: LiveCaptionLocaleLookupStart) {
    speechLocaleCheckTask = Task { [weak self] in
      let locales = await SpeechTranscriber.installedLocales
      let languageCodes = Set(locales.compactMap { $0.language.languageCode?.identifier })
      DispatchQueue.main.async {
        guard let self,
              let completion = self.speechLocaleLookupState.finish(lookup.id) else { return }
        self.speechLocaleCheckTask = nil
        switch completion {
        case .start(let nextLookup):
          self.startInstalledSpeechLocaleLookup(nextLookup)
        case .discard:
          return
        case .publish(let request):
          guard self.workState.accepts(request.generation),
                Preference.bool(for: .appleLiveCaptionsFallback) else { return }
          guard self.player?.info.currentURL == request.mediaURL,
                self.canonicalLocaleID(self.selectedSpeechLocale) == request.localeID else {
            self.updateEligibility()
            return
          }
          self.installedSpeechLanguageCodes = languageCodes
          self.updateEligibility()
        }
      }
    }
  }
}

/// Output latency that mpv's CoreAudio driver does not count. mpv adds the device latency, buffer
/// size and safety offset, but not the stream latency, which is where AirPlay reports its buffering.
enum CoreAudioOutput {
  /// `mpvDevice` is mpv's audio-device value: "auto" for the system output, or "coreaudio/<UID>".
  static func streamLatency(mpvDevice: String) -> Double {
    guard let device = deviceID(mpvDevice: mpvDevice) else { return 0 }
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                             mScope: kAudioObjectPropertyScopeOutput,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
    var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr,
          let stream = streams.first else { return 0 }
    var frames: UInt32 = 0
    var rate: Float64 = 0
    guard get(stream, kAudioStreamPropertyLatency, &frames),
          get(device, kAudioDevicePropertyNominalSampleRate, &rate), rate > 0 else { return 0 }
    return Double(frames) / rate
  }

  private static func deviceID(mpvDevice: String) -> AudioObjectID? {
    var device = AudioObjectID(kAudioObjectUnknown)
    if mpvDevice == "auto" {
      guard get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &device) else {
        return nil
      }
    } else {
      guard mpvDevice.hasPrefix("coreaudio/") else { return nil }
      var uid = String(mpvDevice.dropFirst("coreaudio/".count)) as CFString
      var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
      var size = UInt32(MemoryLayout<AudioObjectID>.size)
      let status = withUnsafeMutablePointer(to: &uid) { uidPointer in
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                   UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &device)
      }
      guard status == noErr else { return nil }
    }
    return device == kAudioObjectUnknown ? nil : device
  }

  private static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
  }
}
