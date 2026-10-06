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

  var textAttributes: [NSAttributedString.Key: Any] {
    var attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: textColor,
      .paragraphStyle: paragraphStyle,
    ]
    if let strokeColor, let strokeWidth {
      attributes[.strokeColor] = strokeColor
      attributes[.strokeWidth] = strokeWidth
    }
    if let shadow {
      attributes[.shadow] = shadow
    }
    if characterSpacing != 0 {
      attributes[.kern] = characterSpacing
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
    textField.translatesAutoresizingMaskIntoConstraints = false
    textField.isBordered = false
    textField.isEditable = false
    textField.isSelectable = false
    textField.drawsBackground = false
    textField.focusRingType = .none
    textField.lineBreakMode = .byWordWrapping
    textField.usesSingleLineMode = false
    textField.maximumNumberOfLines = 0
    textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
      return
    }
    textField.attributedStringValue = NSAttributedString(string: displayedText,
                                                          attributes: captionAppearance.textAttributes)
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
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
}

/// Mutable state and AppKit objects are confined to the main thread; background decode and Speech
/// tasks return to the main thread before reading or updating the instance.
final class AppleLiveCaptions: @unchecked Sendable {
  private weak var player: PlayerCore?
  private weak var videoContainer: NSView?
  private let overlay = LiveCaptionOverlay(frame: .zero)
  private let decodeQueue = DispatchQueue(label: "io.iina.live-captions.decode", qos: .userInitiated)
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
  private var boundsObserver: NSObjectProtocol?
  private var previouslyPostedBoundsChanges: Bool?
  private var appearanceObserver: Preference.Observer?
  private var appearanceNotificationsInstalled = false
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
  private var playbackTimeline = SpeechCaptionPlaybackTimeline()
  private var decodeCancellation: LiveCaptionDecodeCancellation?
  private var unavailableSpeechLocales = Set<String>()
  private var installedSpeechLanguageCodes: Set<String>?
  private var speechLocaleCheckTask: Task<Void, Never>?
  private let chunkDuration: Double = 10

  init(player: PlayerCore) { self.player = player }

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
    NSLayoutConstraint.activate([
      centeredX,
      bottomY,
      widthLimit,
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
    let safeSubtitleScale = subtitleScale.isFinite ? min(10, max(0.1, subtitleScale)) : 1
    let unitScale = (scalesWithWindow ? videoHeight / 720 : 1 / max(backingScale, 1)) * safeSubtitleScale

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

    let strokeWidth: CGFloat? = borderStyle == .outlineAndShadow && borderSize > 0 ?
      -min(50, borderSize / fontSize * 100) : nil
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
    let verticalEdgeInset = min(max(16, marginY), videoHeight / 2)
    let maximumCaptionHeight = max(1, videoHeight - 2 * verticalEdgeInset)
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
    let renderedCaptionHeight = min(videoHeight, overlay.measuredCaptionHeight())
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
      verticalConstraint.constant = (-marginY + positionOffset).clamped(
        to: -(verticalEdgeInset + remainingHeight)...(-verticalEdgeInset))
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
    updateAppearance()
  }

  private func stopAppearanceTracking() {
    appearanceObserver = nil
    if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    boundsObserver = nil
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
          let url = player.info.currentURL, url.isFileURL else {
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
    cancelDecode()
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
    playbackTimeline.reset()
    inFlight = false
    recognitionStartedAt = nil
    captionResults.removeAll()
    overlay.isHidden = true
    overlay.setCaptionText("")
  }

  private func startTimer() {
    timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
      self?.tick()
    }
  }

  private func cancelDecode() {
    decodeCancellation?.cancel()
    decodeCancellation = nil
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
      cancelDecode()
      task?.cancel()
      task = nil
      analyzerTask?.cancel()
      analyzerTask = nil
      inFlight = false
      recognitionStartedAt = nil
      requestedStart = nil
      exhaustedAtPosition = nil
      captionResults.removeAll()
      playbackTimeline.reset()
      activeURL = url
    }
    // The UI timer stops after the OSC hides. Keep the cached position current so the chunk
    // scheduler continues through a normal playback session with no visible controls.
    player.syncPositionIfNeeded()
    guard let position = player.info.videoPosition?.second, position.isFinite, position >= 0 else {
      stop()
      return
    }
    if playbackTimeline.movedBack(to: position) {
      // The playhead can move backward without crossing the current recognition chunk boundary.
      // Invalidate that work and clear text from the previous pass through this time range.
      generation += 1
      cancelDecode()
      task?.cancel()
      task = nil
      analyzerTask?.cancel()
      analyzerTask = nil
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
    let text = captionResults.text(at: position, playbackRate: player.info.playSpeed)
    if overlay.setCaptionText(text) {
      updateAppearance()
    }
    overlay.isHidden = text.isEmpty

    guard player.info.state == .playing else { return }
    if inFlight, let recognitionStartedAt,
       Date().timeIntervalSince(recognitionStartedAt) > 15 {
      generation += 1
      cancelDecode()
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
      cancelDecode()
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
    let decodeCancellation = LiveCaptionDecodeCancellation()
    self.decodeCancellation = decodeCancellation
    decodeQueue.async { [weak self] in
      let data = FFmpegController.readMonoAudio(fromFile: url.path, startTime: start, duration: duration,
                                                cancellationCheck: { decodeCancellation.isCancelled })
      DispatchQueue.main.async {
        guard let self else { return }
        if self.decodeCancellation === decodeCancellation { self.decodeCancellation = nil }
        guard self.generation == token, self.player?.info.currentURL == url else { return }
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
