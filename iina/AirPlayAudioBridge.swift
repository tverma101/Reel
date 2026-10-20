//
//  AirPlayAudioBridge.swift
//  iina
//
//  Sends one Reel player's audio to the AirPlay speaker picked in that player's own route picker;
//  every other app keeps the Mac's output. macOS routes a single app's audio only through an
//  AVPlayer bound to an AVRoutePickerView, and AVFoundation can't open most files mpv plays, so the
//  selected audio track is decoded to PCM and served to a hidden AVPlayer as a WAV stream. mpv keeps
//  the picture, subtitles, Live Text and live captions. Its own audio output is switched to `null`,
//  and its picture is held until the speaker starts, then kept on the speaker's clock.
//

import AVFoundation
import AVKit
import Cocoa

// MARK: - WAV stream

enum AirPlayPCMVolume {
  static func gain(volume: Double, muted: Bool) -> Double {
    guard !muted, volume.isFinite else { return 0 }
    return min(max(volume / 100, 0), 1)
  }

  /// Apply Reel's gain before handing PCM to the external route. The receiver must never
  /// depend on AVPlayer's local mixer honoring its mute or volume settings.
  static func apply(to data: Data, gain: Double) -> Data {
    let gain = gain.isFinite ? min(max(gain, 0), 1) : 0
    guard gain < 1 else { return data }
    guard gain > 0 else { return Data(count: data.count) }
    var result = data
    result.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
      for offset in stride(from: 0, to: bytes.count - 1, by: 2) {
        let bits = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        let scaled = Int16((Double(Int16(bitPattern: bits)) * gain).rounded())
        let output = UInt16(bitPattern: scaled)
        bytes[offset] = UInt8(truncatingIfNeeded: output)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: output >> 8)
      }
    }
    return result
  }
}

struct AirPlayAudioStartupClock {
  private(set) var startedAt: Date?

  mutating func markBlocked() {
    startedAt = nil
  }

  mutating func markCanProgress(at now: Date = Date()) {
    if startedAt == nil { startedAt = now }
  }

  mutating func reset() {
    startedAt = nil
  }

  func hasExpired(at now: Date, timeout: TimeInterval) -> Bool {
    guard let startedAt else { return false }
    return now.timeIntervalSince(startedAt) > timeout
  }
}

/// Tracks AVPlayer's media clock separately from its time-control status. AVPlayer can report
/// `.playing` while an external route has stopped advancing the audio item.
struct AirPlaySpeakerClock {
  private(set) var lastPosition: Double?
  private(set) var monitoringStartedAt: Date?
  private(set) var lastAdvancedAt: Date?
  private(set) var hasAdvanced = false

  mutating func reset(position: Double? = nil) {
    lastPosition = Self.valid(position)
    monitoringStartedAt = nil
    lastAdvancedAt = nil
    hasAdvanced = false
  }

  /// Buffering and user pauses start a fresh monitoring window when AVPlayer plays again.
  mutating func markBlocked(position: Double?) {
    reset(position: position)
  }

  @discardableResult
  mutating func observe(position: Double?, at now: Date = Date(), epsilon: Double = 0.001) -> Bool {
    guard epsilon.isFinite, epsilon >= 0 else { return false }
    if monitoringStartedAt == nil { monitoringStartedAt = now }
    guard let position = Self.valid(position) else { return false }
    guard let lastPosition else {
      self.lastPosition = position
      return false
    }
    // Seeks reset this tracker. Keeping the high-water mark avoids counting clock jitter or a
    // small backward correction as playback progress.
    guard position > lastPosition + epsilon else { return false }
    self.lastPosition = position
    hasAdvanced = true
    lastAdvancedAt = now
    return true
  }

  func hasStalled(at now: Date = Date(), stallTimeout: TimeInterval,
                  startupTimeout: TimeInterval) -> Bool {
    guard let monitoringStartedAt else { return false }
    if hasAdvanced, let lastAdvancedAt {
      return now.timeIntervalSince(lastAdvancedAt) > stallTimeout
    }
    return now.timeIntervalSince(monitoringStartedAt) > startupTimeout
  }

  private static func valid(_ position: Double?) -> Double? {
    guard let position, position.isFinite, position >= 0 else { return nil }
    return position
  }
}

final class AirPlayRequestCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock(); defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock(); defer { lock.unlock() }
    cancelled = true
  }
}

/// Serves decoded audio to AVFoundation as a WAV file. Range callbacks arrive on `delegateQueue`;
/// decoding runs on `queue` a quarter second at a time, staying about 20 seconds ahead of playback.
final class AirPlayPCMResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
  static let scheme = "reel-airplay"
  static let sampleRate = Double(FFmpegPCMStreamReader.sampleRate)
  private static let bytesPerFrame = Int64(FFmpegPCMStreamReader.channelCount * 2)
  private static let headerLength: Int64 = 44
  /// A WAV header stores sizes in 32 bits, which limits one stream to about six hours.
  static let maximumFrames = (Int64(UInt32.max) - 64) / bytesPerFrame
  static func frameCount(for duration: Double) -> Int64 {
    guard duration.isFinite, duration > 0 else {
      return maximumFrames
    }
    let requestedFrames = (duration + 2) * Self.sampleRate
    guard requestedFrames.isFinite else { return maximumFrames }
    guard requestedFrames < Double(maximumFrames) else { return maximumFrames }
    return max(1, Int64(requestedFrames))
  }
  static func audioClockHasAdvanced(from previous: Double?, to current: Double,
                                   epsilon: Double = 0.001) -> Bool {
    guard current.isFinite, let previous, previous.isFinite, epsilon.isFinite, epsilon >= 0 else {
      return false
    }
    return abs(current - previous) > epsilon
  }
  private static let chunkFrames = Int64(sampleRate / 4)
  /// How far ahead of the speaker the stream is kept. AVFoundation pulls this much decoded audio
  /// into its own buffer: 60 s measured 16.6 MB streamed per 30 s of playback, 20 s measured 9.6 MB.
  /// A 20 s lead still refills in well under a second (decoding runs far faster than playback).
  private static let leadFrames = Int64(sampleRate * 20)
  /// A new range is always served this far, so a seek never waits for the playhead to be updated.
  private static let burstFrames = Int64(sampleRate * 10)

  /// Thread-safe state shared with the bridge and AVPlayer observer queues.
  private final class SharedState: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false
    private var playheadFrame: Int64 = 0

    var isInvalidated: Bool {
      lock.lock(); defer { lock.unlock() }
      return invalidated
    }

    func invalidate() {
      lock.lock(); defer { lock.unlock() }
      invalidated = true
    }

    var playhead: Int64 {
      get { lock.lock(); defer { lock.unlock() }; return playheadFrame }
      set { lock.lock(); defer { lock.unlock() }; playheadFrame = newValue }
    }
  }

  private final class Request {
    let loading: AVAssetResourceLoadingRequest
    let cancellation = AirPlayRequestCancellation()
    let start: Int64
    let end: Int64
    var offset: Int64

    init(loading: AVAssetResourceLoadingRequest, start: Int64, end: Int64) {
      self.loading = loading
      self.start = start
      self.end = end
      offset = start
    }
  }

  let queue = DispatchQueue(label: "com.colliderli.iina.airplay-audio", qos: .userInitiated)
  let delegateQueue = DispatchQueue(label: "com.colliderli.iina.airplay-audio-delegate", qos: .userInitiated)
  let frameCount: Int64
  let gain: Double
  private let source: String
  private let streamIndex: Int
  private let mediaOrigin: Double?
  private let onFailure: () -> Void
  private let shared = SharedState()
  private let requestCancellationLock = NSLock()
  private var requestCancellations: [ObjectIdentifier: AirPlayRequestCancellation] = [:]

  // Confined to `queue`.
  private var reader: FFmpegPCMStreamReader?
  private var readerOpened = false
  private var requests: [Request] = []
  private var pumpToken = 0

  init(source: String, streamIndex: Int, mediaOrigin: Double?, frameCount: Int64, gain: Double = 1,
       onFailure: @escaping () -> Void) {
    self.source = source
    self.streamIndex = streamIndex
    self.mediaOrigin = mediaOrigin
    self.frameCount = min(max(frameCount, 1), Self.maximumFrames)
    self.gain = gain.isFinite ? min(max(gain, 0), 1) : 0
    self.onFailure = onFailure
    super.init()
  }

  var duration: Double { Double(frameCount) / Self.sampleRate }

  private var contentLength: Int64 { Self.headerLength + frameCount * Self.bytesPerFrame }

  /// Called from the bridge or AVPlayer observer queue with the current speaker playhead.
  func setPlayhead(seconds: Double) {
    guard seconds.isFinite else { return }
    shared.playhead = Int64(max(0, seconds) * Self.sampleRate)
    queue.async { [weak self] in self?.schedulePump() }
  }

  func invalidate() {
    shared.invalidate()
    queue.async { [self] in
      let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
      for request in requests {
        if !request.loading.isFinished && !request.loading.isCancelled {
          finish(request, error: error)
        } else {
          removeCancellation(for: request.loading)
        }
      }
      requests.removeAll()
      reader = nil
    }
  }

  func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                      shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
    guard !shared.isInvalidated, loadingRequest.request.url?.scheme == Self.scheme else { return false }
    if let information = loadingRequest.contentInformationRequest {
      information.contentType = AVFileType.wav.rawValue
      information.contentLength = contentLength
      information.isByteRangeAccessSupported = true
    }
    guard let dataRequest = loadingRequest.dataRequest else {
      loadingRequest.finishLoading()
      return true
    }
    let start = dataRequest.requestedOffset
    let end = dataRequest.requestsAllDataToEndOfResource
      ? contentLength : min(contentLength, start + Int64(dataRequest.requestedLength))
    guard start < end else {
      loadingRequest.finishLoading()
      return true
    }
    let request = Request(loading: loadingRequest, start: start, end: end)
    requestCancellationLock.lock()
    requestCancellations[ObjectIdentifier(loadingRequest)] = request.cancellation
    requestCancellationLock.unlock()
    queue.async { [weak self] in
      guard let self else { return }
      guard !self.shared.isInvalidated else {
        self.removeCancellation(for: loadingRequest)
        loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        return
      }
      self.requests.append(request)
      self.schedulePump()
    }
    return true
  }

  func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                      didCancel loadingRequest: AVAssetResourceLoadingRequest) {
    let identifier = ObjectIdentifier(loadingRequest)
    requestCancellationLock.lock()
    let cancellation = requestCancellations[identifier]
    requestCancellationLock.unlock()
    cancellation?.cancel()
    queue.async { [weak self] in
      guard let self else { return }
      self.requests.removeAll { $0.loading === loadingRequest }
      self.removeCancellation(for: loadingRequest)
      self.schedulePump()
    }
  }

  /// Each call supersedes any pump still waiting, so there is only ever one chain of work.
  private func schedulePump(after delay: Double = 0) {
    pumpToken &+= 1
    let token = pumpToken
    let work: () -> Void = { [weak self] in
      guard let self, self.pumpToken == token else { return }
      self.pump()
    }
    if delay > 0 {
      queue.asyncAfter(deadline: .now() + delay, execute: work)
    } else {
      queue.async(execute: work)
    }
  }

  /// Serves one chunk, then yields so cancellations and new requests are seen promptly.
  private func pump() {
    guard !shared.isInvalidated else { return }
    requests.removeAll { request in
      let shouldRemove = request.cancellation.isCancelled || request.loading.isCancelled || request.loading.isFinished
      if shouldRemove { removeCancellation(for: request.loading) }
      return shouldRemove
    }
    guard !requests.isEmpty else { return }
    let limit = Self.byteOffset(ofFrame: shared.playhead + Self.leadFrames)
    let burst = Self.burstFrames * Self.bytesPerFrame
    // The newest request first: after a seek it is the range AVFoundation is waiting for.
    guard let request = requests.last(where: { $0.offset < max(limit, $0.start + burst) }) else {
      schedulePump(after: 0.25)
      return
    }
    guard serve(request) else {
      fail()
      return
    }
    schedulePump()
  }

  private func serve(_ request: Request) -> Bool {
    guard !request.cancellation.isCancelled else { return true }
    guard let dataRequest = request.loading.dataRequest else {
      finish(request)
      return true
    }
    if request.offset < Self.headerLength {
      let header = Self.header(frameCount: frameCount)
      let upper = min(Self.headerLength, request.end)
      dataRequest.respond(with: header[Int(request.offset)..<Int(upper)])
      request.offset = upper
    }
    if request.offset < request.end {
      let audioOffset = request.offset - Self.headerLength
      let firstFrame = audioOffset / Self.bytesPerFrame
      let skip = Int(audioOffset % Self.bytesPerFrame)
      let upper = min(request.end, request.offset + Self.chunkFrames * Self.bytesPerFrame)
      let endFrame = (upper - Self.headerLength + Self.bytesPerFrame - 1) / Self.bytesPerFrame
      guard let data = readFrames(at: firstFrame, count: Int(endFrame - firstFrame), request: request) else {
        if request.cancellation.isCancelled {
          // FFmpeg may have marked the interrupted reader as failed; reopen from the next live range.
          reader = nil
          readerOpened = false
          return true
        }
        return shared.isInvalidated
      }
      guard !request.cancellation.isCancelled else { return true }
      let length = Int(upper - request.offset)
      let adjusted = AirPlayPCMVolume.apply(to: data, gain: gain)
      dataRequest.respond(with: adjusted[skip..<(skip + length)])
      request.offset = upper
    }
    if request.offset >= request.end {
      finish(request)
    }
    return true
  }

  private func readFrames(at frame: Int64, count: Int, request: Request) -> Data? {
    let shared = shared
    let requestCancellation = request.cancellation
    let cancelled: () -> Bool = { shared.isInvalidated || requestCancellation.isCancelled }
    if !readerOpened {
      // Opened on first use: the source may be a network stream.
      readerOpened = true
      reader = FFmpegPCMStreamReader(source: source, audioStreamIndex: streamIndex,
                                     mediaOrigin: mediaOrigin.map { NSNumber(value: $0) },
                                     cancellationCheck: cancelled)
    }
    guard let reader, !reader.failed else { return nil }
    return reader.readFrames(at: frame, count: count, cancellationCheck: cancelled)
  }

  private func finish(_ request: Request, error: NSError? = nil) {
    if let error {
      request.loading.finishLoading(with: error)
    } else {
      request.loading.finishLoading()
    }
    removeCancellation(for: request.loading)
  }

  private func removeCancellation(for request: AVAssetResourceLoadingRequest) {
    requestCancellationLock.lock(); defer { requestCancellationLock.unlock() }
    requestCancellations.removeValue(forKey: ObjectIdentifier(request))
  }

  private func fail() {
    let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotDecodeContentData)
    for request in requests {
      if !request.loading.isFinished && !request.loading.isCancelled {
        finish(request, error: error)
      } else {
        removeCancellation(for: request.loading)
      }
    }
    requests.removeAll()
    guard !shared.isInvalidated else { return }
    shared.invalidate()
    DispatchQueue.main.async(execute: onFailure)
  }

  private static func byteOffset(ofFrame frame: Int64) -> Int64 {
    headerLength + max(0, frame) * bytesPerFrame
  }

  static func header(frameCount: Int64) -> Data {
    let channels = UInt16(FFmpegPCMStreamReader.channelCount)
    let rate = UInt32(FFmpegPCMStreamReader.sampleRate)
    let blockAlign = UInt16(bytesPerFrame)
    let dataLength = UInt32(frameCount * bytesPerFrame)
    var header = Data(capacity: Int(headerLength))
    func append(_ text: String) { header.append(contentsOf: Array(text.utf8)) }
    func append<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
    }
    append("RIFF"); append(UInt32(36) + dataLength); append("WAVE")
    append("fmt "); append(UInt32(16)); append(UInt16(1)); append(channels); append(rate)
    append(rate * UInt32(blockAlign)); append(blockAlign); append(UInt16(16))
    append("data"); append(dataLength)
    return header
  }
}

/// Feeds the resource loader from AVPlayer's clock without reading bridge state on its callback queue.
private final class AirPlayPlayheadFeeder: @unchecked Sendable {
  private let lock = NSLock()
  private weak var loader: AirPlayPCMResourceLoader?
  private var observedPosition: Double?
  private var lastFedPosition: Double?
  private var pendingSeekPosition: Double?

  /// Read the observer's last sample without entering AVFoundation during a route transition.
  var position: Double? {
    lock.lock(); defer { lock.unlock() }
    return observedPosition
  }

  func attach(_ loader: AirPlayPCMResourceLoader?) {
    lock.lock(); defer { lock.unlock() }
    self.loader = loader
    observedPosition = nil
    lastFedPosition = nil
    pendingSeekPosition = nil
  }

  func prepareForSeek(to position: Double) {
    lock.lock(); defer { lock.unlock() }
    observedPosition = nil
    lastFedPosition = nil
    pendingSeekPosition = position
  }

  func update(_ time: CMTime) {
    let seconds = time.seconds
    lock.lock()
    guard seconds.isFinite, seconds >= 0, let loader else {
      observedPosition = nil
      lastFedPosition = nil
      lock.unlock()
      return
    }
    // Time-observer callbacks already in flight can still carry the pre-seek clock. Accept the
    // seek's time-jump callback before monitoring motion or feeding its new decoding window.
    if let pendingSeekPosition, abs(seconds - pendingSeekPosition) > 0.25 {
      lock.unlock()
      return
    }
    pendingSeekPosition = nil
    observedPosition = seconds
    // The sync clock needs fine samples, but the decoder only needs a quarter-second feeder.
    let shouldFeed = lastFedPosition.map { abs(seconds - $0) >= 0.25 } ?? true
    if shouldFeed { lastFedPosition = seconds }
    lock.unlock()
    if shouldFeed { loader.setPlayhead(seconds: seconds) }
  }
}

struct AirPlayTimingRestorePlan: Equatable {
  let property: String
  let value: Double

  static func afterFailure(property: String, value: Double, result: Int32,
                           canRestoreSynchronously: Bool,
                           hasNewerWriteQueued: Bool = false) -> Self? {
    guard canRestoreSynchronously, result < 0, value.isFinite,
          !hasNewerWriteQueued,
          property == "speed" || property == "audio-delay" else { return nil }
    return Self(property: property, value: value)
  }
}

enum AirPlayTimingOSDMode: Equatable {
  case automatic
  case none
  case bar
  case message
  case messageAndBar
}

struct AirPlayUserSpeedTarget {
  let value: Double
  let osdMode: AirPlayTimingOSDMode
}

struct AirPlayUserAudioDelayTarget: Equatable {
  let userValue: Double
  let mpvValue: Double
  let osdMode: AirPlayTimingOSDMode
}

struct AirPlayUserAudioDelayTargets {
  private(set) var values: [AirPlayUserAudioDelayTarget] = []

  mutating func append(userValue: Double, correction: Double,
                       osdMode: AirPlayTimingOSDMode) {
    let mpvValue = userValue + correction
    guard userValue.isFinite, correction.isFinite, mpvValue.isFinite else { return }
    values.append(AirPlayUserAudioDelayTarget(userValue: userValue, mpvValue: mpvValue,
                                               osdMode: osdMode))
  }

  func target(forMPVValue value: Double) -> AirPlayUserAudioDelayTarget? {
    guard value.isFinite else { return nil }
    return values.last { AirPlayTimingRestorePolicy.stillOwnsValue($0.mpvValue,
                                                                    expectedValue: value) }
  }

  mutating func complete(userValue: Double) -> AirPlayTimingOSDMode? {
    guard let index = values.lastIndex(where: {
      AirPlayTimingRestorePolicy.stillOwnsValue($0.userValue, expectedValue: userValue)
    }) else {
      values.removeAll()
      return nil
    }
    let osdMode = values[index].osdMode
    values.removeFirst(index + 1)
    return osdMode
  }

  mutating func complete(_ target: AirPlayUserAudioDelayTarget) -> AirPlayTimingOSDMode? {
    guard let index = values.lastIndex(of: target) else {
      values.removeAll()
      return nil
    }
    values.removeFirst(index + 1)
    return target.osdMode
  }

  mutating func reset() {
    values.removeAll(keepingCapacity: false)
  }
}

struct AirPlayTimingRestorePolicy {
  static func stillOwnsValue(_ currentValue: Double?, expectedValue: Double) -> Bool {
    guard let currentValue, currentValue.isFinite, expectedValue.isFinite else { return false }
    // mpv stores some timing options as floats, even when the client API uses a Double. Match
    // their round-trip precision so an internal correction cannot become a user delay/OSD.
    let tolerance = max(1e-6, abs(expectedValue) * Double(Float.ulpOfOne) * 2)
    return abs(currentValue - expectedValue) <= tolerance
  }
}

struct AirPlayTimingRestoreBarrier {
  private(set) var pendingReplyUserdata: UInt64?

  var blocksDrain: Bool { pendingReplyUserdata != nil }

  mutating func begin(replyUserdata: UInt64) -> Bool {
    guard pendingReplyUserdata == nil else { return false }
    pendingReplyUserdata = replyUserdata
    return true
  }

  mutating func finish(replyUserdata: UInt64) -> Bool {
    guard pendingReplyUserdata == replyUserdata else { return false }
    pendingReplyUserdata = nil
    return true
  }

  mutating func cancel() {
    pendingReplyUserdata = nil
  }
}

struct AirPlayAudioOutputRestorePolicy {
  static func shouldEnqueue(_ output: String, pendingOutputs: [String],
                            observedOutput: String?, forceReload: Bool) -> Bool {
    if let lastPendingOutput = pendingOutputs.last {
      return lastPendingOutput != output
    }
    return observedOutput != output || forceReload
  }
}

struct AirPlayInternalWrites {
  private struct Write {
    let token: UInt64
    let value: Double
    var commandPending: Bool
    var eventObserved = false
  }

  private var writes: [Write] = []
  private var nextToken: UInt64 = 0
  private var observedValue: Double?

  init(observedValue: Double? = nil) {
    self.observedValue = observedValue
  }

  @discardableResult
  mutating func record(_ value: Double, commandPending: Bool = false) -> UInt64? {
    guard value.isFinite else { return nil }
    let previousValue = writes.last?.value ?? observedValue
    if let previousValue, abs(previousValue - value) < 1e-9 { return nil }
    nextToken &+= 1
    writes.append(Write(token: nextToken, value: value, commandPending: commandPending))
    return nextToken
  }

  mutating func cancel(_ token: UInt64?) {
    guard let token else { return }
    writes.removeAll { $0.token == token }
  }

  mutating func complete(_ token: UInt64?) {
    guard let token, let index = writes.firstIndex(where: { $0.token == token }) else { return }
    if writes[index].eventObserved {
      writes.remove(at: index)
    } else {
      writes[index].commandPending = false
    }
  }

  /// Keep ownership until mpv reports the matching value; queue delays can exceed playback timers.
  mutating func consume(_ value: Double) -> Bool {
    guard value.isFinite else { return false }
    observedValue = value
    // mpv can coalesce property notifications. A newer observed value retires older completed
    // writes, but a still-pending command can apply after this event and must keep its marker.
    writes.removeAll {
      !$0.commandPending && !AirPlayTimingRestorePolicy.stillOwnsValue($0.value, expectedValue: value)
    }
    guard let matchedIndex = writes.lastIndex(where: {
      AirPlayTimingRestorePolicy.stillOwnsValue($0.value, expectedValue: value)
    }) else {
      return false
    }
    if writes[matchedIndex].commandPending {
      writes[matchedIndex].eventObserved = true
    } else {
      writes.remove(at: matchedIndex)
    }
    return true
  }

  mutating func reset(observedValue: Double? = nil) {
    writes.removeAll(keepingCapacity: false)
    self.observedValue = observedValue
  }
}

// MARK: - Bridge

/// Apple's picker remains the interactive/accessibility surface. Its persistent route animation
/// is replaced with a static toolbar glyph so playback and internal rebuffering don't pulse.
private final class AirPlayRouteGlyph: NSImageView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class AirPlayRouteControl: NSView {
  private let glyph = AirPlayRouteGlyph()

  init(picker: AVRoutePickerView) {
    super.init(frame: .zero)
    // Hide only Apple's animated ink, not the view/its accessibility-owned receiver popover.
    for state: AVRoutePickerView.ButtonState in [.normal, .normalHighlighted, .active, .activeHighlighted] {
      picker.setRoutePickerButtonColor(.clear, for: state)
    }
    picker.translatesAutoresizingMaskIntoConstraints = false
    addSubview(picker)
    glyph.image = Preference.ToolBarButton.airPlay.image()
    glyph.imageScaling = .scaleProportionallyDown
    glyph.translatesAutoresizingMaskIntoConstraints = false
    glyph.setAccessibilityHidden(true)
    addSubview(glyph)
    NSLayoutConstraint.activate([
      picker.leadingAnchor.constraint(equalTo: leadingAnchor),
      picker.trailingAnchor.constraint(equalTo: trailingAnchor),
      picker.topAnchor.constraint(equalTo: topAnchor),
      picker.bottomAnchor.constraint(equalTo: bottomAnchor),
      glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
      glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
      glyph.widthAnchor.constraint(equalToConstant: 24),
      glyph.heightAnchor.constraint(equalToConstant: 24),
    ])
    update(selected: false)
  }

  func update(selected: Bool) {
    glyph.contentTintColor = selected ? .controlAccentColor : .controlTextColor
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class AirPlayAudioBridge: NSObject {
  /// Runs the bridge on the Mac's own output, so sync can be checked without a speaker.
  private static let localTestKey = "ReelAirPlayBridgeLocalTest"
  /// Seconds to subtract from AVPlayer's clock, for a receiver whose latency it does not include.
  private static let latencyKey = "ReelAirPlayBridgeLatencyCompensation"
  /// Stay in mpv's pitch-correction range. A 0.01x hold builds seconds of stale audio on resume.
  private static let holdSpeed = 0.25
  private static let holdTimeout: TimeInterval = 10
  /// A speaker that claims to play but never advances the item clock is not a usable route.
  private static let speakerClockStartupTimeout: TimeInterval = 4
  private static let speakerClockStallTimeout: TimeInterval = 1
  /// Refresh the routed item after a long pause, when AirPlay may have discarded its buffered stream.
  private static let longPauseStreamRefreshThreshold: TimeInterval = 30
  private static let correctionThreshold = 0.075
  private static let resyncThreshold = 1.0
  /// How long mpv's audio clock may stay still before the bridge pauses the speaker.
  private static let audioClockStallTimeout: TimeInterval = 0.6
  /// A clock movement smaller than this is not considered playback progress.
  private static let audioClockMotionEpsilon = 0.001

  private enum AudioSelection {
    case pending
    case noAudio
    case unsupported(String)
    case supported(Selection)
  }

  private struct MPVCommandRequest {
    enum Operation {
      case command(MPVCommand, [String?])
      case stringProperty(String, String)
      case doubleProperty(String, Double)

      func matches(_ other: Operation) -> Bool {
        switch (self, other) {
        case let (.command(command, arguments), .command(otherCommand, otherArguments)):
          return command.rawValue == otherCommand.rawValue && arguments == otherArguments
        case let (.stringProperty(name, value), .stringProperty(otherName, otherValue)):
          return name == otherName && value == otherValue
        case let (.doubleProperty(name, value), .doubleProperty(otherName, otherValue)):
          return name == otherName && value == otherValue
        default:
          return false
        }
      }

      var name: String {
        switch self {
        case .command(let command, _): command.rawValue
        case .stringProperty(let name, _), .doubleProperty(let name, _): name
        }
      }

      var audioOutputTarget: String? {
        switch self {
        case .command(let command, let arguments):
          guard command.rawValue == MPVCommand.set.rawValue,
                arguments.first == MPVOption.Audio.ao,
                arguments.count > 1 else { return nil }
          return arguments[1]
        case .stringProperty(let name, let value):
          return name == MPVOption.Audio.ao ? value : nil
        case .doubleProperty:
          return nil
        }
      }

      var isAudioOutputSetter: Bool { audioOutputTarget != nil }

      func timingRestorePlan(afterFailure result: Int32,
                             canRestoreSynchronously: Bool,
                             hasNewerWriteQueued: Bool) -> AirPlayTimingRestorePlan? {
        guard case let .doubleProperty(name, value) = self else { return nil }
        return AirPlayTimingRestorePlan.afterFailure(
          property: name, value: value, result: result,
          canRestoreSynchronously: canRestoreSynchronously,
          hasNewerWriteQueued: hasNewerWriteQueued)
      }
    }

    let operation: Operation
    let requiredForOutput: Bool
    let coalescingKey: String?
    /// A synchronous recovery value to use if an async restore is rejected or loses its reply.
    let restoreAudioOutput: String?
    /// Identifies one disengage pair so its fallback cannot remove a later route's restore.
    let restoreAudioOutputToken: UInt64?
    /// Intent epoch that fences this bridge-owned AO write; restore retries keep the same epoch.
    let expectedAudioOutputIntentGeneration: UInt64?
    /// Identifies the property-change echo that belongs to this internal timing write.
    var timingWriteToken: UInt64? = nil
    /// A START_FILE restore must not overwrite timing that mpv has already applied for the next item.
    var expectedCurrentTimingValue: Double? = nil
    /// The final async submission must still belong to the file whose timing was captured.
    var expectedFileTransitionGeneration: UInt64? = nil
    /// Playlist identity for the file whose timing was captured.
    var expectedPlaylistEntryID: Int64? = nil
    /// END_FILE may leave no active playlist entry; restore only while the player remains idle.
    var allowsNoActivePlaylistEntry = false
    var replyUserdata: UInt64? = nil
    /// Used to publish the confirmed AO value if the cached output is still the pre-submit value
    /// and no newer direct intent superseded it.
    var audioOutputBeforeSubmission: String? = nil
    var capturedAudioOutputBeforeSubmission = false
    var audioOutputIntentGenerationBeforeSubmission: UInt64? = nil
    /// Route epoch checked by background AO submission and queue-pressure recovery.
    var routeOwnershipGenerationBeforeSubmission: UInt64? = nil

    func targetsFile(fileTransitionGeneration: UInt64?, playlistEntryID: Int64?) -> Bool {
      guard expectedFileTransitionGeneration != nil || expectedPlaylistEntryID != nil else {
        return true
      }
      guard let expectedFileTransitionGeneration, let expectedPlaylistEntryID,
            let fileTransitionGeneration, let playlistEntryID else { return false }
      return expectedFileTransitionGeneration == fileTransitionGeneration &&
        expectedPlaylistEntryID == playlistEntryID
    }

    func matches(_ other: MPVCommandRequest) -> Bool {
      operation.matches(other.operation) &&
        expectedCurrentTimingValue == other.expectedCurrentTimingValue &&
        expectedFileTransitionGeneration == other.expectedFileTransitionGeneration &&
        expectedPlaylistEntryID == other.expectedPlaylistEntryID &&
        allowsNoActivePlaylistEntry == other.allowsNoActivePlaylistEntry
    }
  }

  private struct TimingRestoreFileIdentity {
    let fileTransitionGeneration: UInt64?
    let playlistEntryID: Int64?

    func matches(fileTransitionGeneration: UInt64?, playlistEntryID: Int64?) -> Bool {
      guard let selfGeneration = self.fileTransitionGeneration,
            let selfEntryID = self.playlistEntryID,
            let fileTransitionGeneration,
            let playlistEntryID else { return false }
      return selfGeneration == fileTransitionGeneration && selfEntryID == playlistEntryID
    }
  }

  private struct Selection: Equatable {
    let source: String
    let streamIndex: Int
    /// The container time of mpv's 0, or nil for the file's own start time.
    let origin: Double?
  }

  private enum RouteAudioOwnership: Equatable {
    case available
    case waitingForTrack
    case unavailable
  }

  private weak var player: PlayerCore?
  private var avPlayer: AVPlayer?
  private var routePicker: AVRoutePickerView?
  private var routeControl: AirPlayRouteControl?
  private var observedContext: NSObject?
  private var routeObservers: [NSObjectProtocol] = []
  private var timeControlObservation: NSKeyValueObservation?
  private var itemStatusObservation: NSKeyValueObservation?
  private var loader: AirPlayPCMResourceLoader?
  private let playheadFeeder = AirPlayPlayheadFeeder()
  private let playheadQueue = DispatchQueue(label: "com.colliderli.iina.airplay-playhead",
                                             qos: .userInitiated)
  private var playheadObserver: Any?
  private var itemSelection: Selection?
  private var itemGeneration = 0
  private var syncTimer: Timer?
  private var mpvSnapshotTimer: Timer?
  private var holdTimer: Timer?
  private var mpvCommandQueue: [MPVCommandRequest] = []
  private var activeMPVCommand: MPVCommandRequest?
  /// Prevent duplicate synchronous output restores if a real reply and overflow recovery overlap.
  private var synchronousAudioOutputRestoreReplyUserdata: UInt64?
  private var synchronousTimingRestoreBarrier = AirPlayTimingRestoreBarrier()
  private var nextMPVCommandReplyId: UInt64 = 0
  private var nextAudioOutputRestoreToken: UInt64 = 0
  private var waitingForMPVEventOverflowRecovery = false
  private var activeMPVCommandNeedsResubmission = false
  private var activeMPVCommandSubmissionAttempts = 0
  /// Main-thread callbacks that must run after every submitted bridge command has replied.
  private var mpvCommandDrainCallbacks: [() -> Void] = []

  /// The picker sends this player to a speaker other than the Mac's (or the local test is on).
  private var routeActive = false
  private var routeNames: [String] = []
  private var pendingRouteNotice: (isActive: Bool, names: [String])?
  private var pendingOutputRestoreFailureNotice = false
  /// Snapshot epoch for the item whose timing this bridge currently owns.
  private var currentFileTransitionGeneration: UInt64?
  private var currentPlaylistEntryID: Int64?
  /// Keeps a release tied to its source file until a later START_FILE has received a fresh timing
  /// write. The old-file request may already have completed or been rejected by that boundary.
  private var pendingTimingRestoreFileIdentities: [String: TimingRestoreFileIdentity] = [:]
  /// A bridge timing release is enqueued once per carry session and survives duplicate cleanup.
  private var currentFileTimingReleaseStarted = true
  private var userSpeedOverride: Double?
  private var userAudioDelayOverride: Double?
  private var pendingUserSpeedTargets: [AirPlayUserSpeedTarget] = []
  private var pendingUserAudioDelayTargets = AirPlayUserAudioDelayTargets()
  private var mappedAudioDelayTarget: AirPlayUserAudioDelayTarget?
  private var routeDescription = ""
  /// The current pause's start time, retained even if the bridge fails while paused.
  private var pauseStartedAt: Date?
  /// This file's audio could not be bridged, so mpv plays it on the Mac until the next file.
  private var bridgeFailedForFile = false
  /// Whether Reel currently owns audio through the AVPlayer bridge.
  private var bridgeEngaged = false
  /// AirPlay timing transitions require the isolated MPV lifecycle hook client.
  private var lifecycleHooksAvailable = false
  private var lifecycleSafetyNoticeShown = false
  /// Prevents a route callback from re-engaging audio while stop/quit is draining MPV work.
  private var stoppingOrQuitting = false
  /// The last known local mpv output. Retain it across route transitions while `ao` is `null`.
  private var savedAudioOutput: String?
  private var savedAudioOutputIntentGeneration: UInt64?
  /// Preserve a disconnect restore until a direct AO command accepted by mpv has settled.
  private var restoreLocalAudioOutputAfterPendingRawCommand = false
  /// Retry bridge engagement after an already queued local-output restore has drained.
  private var routeEngagementDeferredForAudioOutputRestore = false
  /// Last ownership class observed as route and track metadata change.
  private var lastObservedRouteAudioOwnership: RouteAudioOwnership?
  /// Remember a canceled local restore until route ownership is settled.
  private var deferredAudioOutputRestoreAfterRouteCheck:
    (output: String, generation: UInt64, needsReload: Bool)?
  private var hasDeferredAudioOutputResolution: Bool {
    restoreLocalAudioOutputAfterPendingRawCommand ||
      routeEngagementDeferredForAudioOutputRestore ||
      deferredAudioOutputRestoreAfterRouteCheck != nil
  }
  /// Snapshot generation for which Reel most recently queued `ao = null` while connected.
  private var lastAirPlayAudioOutputDisableGeneration: UInt64?
  /// Prevents a late main-thread callback from replaying one direct output change more than once.
  private var lastProcessedDirectAudioOutputGeneration: UInt64 = 0
  private var latencyCompensation = 0.0

  private var speedWrites: AirPlayInternalWrites
  private var delayWrites: AirPlayInternalWrites
  private var holdSpeedApplied = false
  private var holding = false
  private var holdGeneration = 0
  private var holdReason = ""
  private var holdRealign = true
  private var holdStartedAt: Date?
  private var driftSamples: [Double] = []
  private var correctionCooldownUntil = Date.distantPast
  private var stalledSince: Date?
  private var waitingForMPVCache = false
  private var halfFrameDuration: Double?
  /// mpv re-creates its audio output when the bridge switches it to `null`, and it will not start
  /// that output while the bridge writes speed or audio delay. The first hold waits for the picture
  /// to move again, which cannot happen before the new output starts.
  private var waitingForMPVAudio = false
  private var audioStartupClock = AirPlayAudioStartupClock()
  private var pendingHoldReason: String?
  private var lastMPVAudioTime: Double?
  /// mpv's audio clock stopped advancing; the speaker is paused until it runs again.
  private var lastMPVAudioClockPosition: Double?
  private var audioClockMovedAt: Date?
  private var waitingForMPVAudioClock = false
  private var waitingForSeekSnapshot = false
  private var seekSnapshotStartedAt: Date?
  private var rebuildItemAfterSeek = false
  private var speakerClock = AirPlaySpeakerClock()

  /// mpv's own audio output is off; the hidden AVPlayer is what can be heard.
  var isEngaged: Bool { bridgeEngaged }

  /// The hidden AVPlayer is playing the current file's audio.
  var isCarrying: Bool { isEngaged && itemSelection != nil }

  /// The part of mpv's audio delay that keeps the picture on the speaker's clock.
  private(set) var audioDelayCorrection = 0.0

  /// The media time of the sound being heard.
  var audiblePosition: Double? {
    guard isCarrying, let seconds = playheadFeeder.position else { return nil }
    return max(0, seconds - latencyCompensation)
  }

  private var userSpeed: Double { userSpeedOverride ?? player?.info.playSpeed ?? 1 }
  private var userAudioDelay: Double { userAudioDelayOverride ?? player?.info.audioDelay ?? 0 }

  func userTimingValue(forMPVProperty property: String) -> Double? {
    switch property {
    case MPVOption.PlaybackControl.speed: return userSpeed
    case MPVOption.Audio.audioDelay: return userAudioDelay
    default: return nil
    }
  }

  init(player: PlayerCore) {
    self.player = player
    speedWrites = AirPlayInternalWrites(observedValue: player.info.playSpeed)
    delayWrites = AirPlayInternalWrites(observedValue: player.info.audioDelay)
    super.init()
  }

  deinit {
    // A repeating timer stays on the run loop until it is invalidated, and a block observer stays
    // registered until it is removed; both would outlive the player if left alone.
    syncTimer?.invalidate()
    mpvSnapshotTimer?.invalidate()
    holdTimer?.invalidate()
    if let playheadObserver, let avPlayer { avPlayer.removeTimeObserver(playheadObserver) }
    routeObservers.forEach { NotificationCenter.default.removeObserver($0) }
  }

  // MARK: Picker and route

  func makePickerView() -> NSView {
    if let routeControl { return routeControl }
    let picker = AVRoutePickerView()
    picker.isRoutePickerButtonBordered = false
    // Bound to Reel's own player, so a choice here moves only Reel's audio.
    picker.player = makePlayerIfNeeded()
    picker.delegate = self
    picker.toolTip = NSLocalizedString("osc_toolbar.airplay", comment: "Route Reel audio to an AirPlay speaker")
    picker.setAccessibilityLabel(picker.toolTip)
    routePicker = picker
    let control = AirPlayRouteControl(picker: picker)
    routeControl = control
    routeMayHaveChanged()
    return control
  }

  @discardableResult
  private func makePlayerIfNeeded() -> AVPlayer {
    if let avPlayer { return avPlayer }
    let avPlayer = AVPlayer()
    avPlayer.actionAtItemEnd = .pause
    // Only the sound is routed. The receiver must not try to fetch the stream itself.
    avPlayer.allowsExternalPlayback = false
    timeControlObservation = avPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async { self?.timeControlStatusChanged() }
    }
    let feeder = playheadFeeder
    playheadObserver = avPlayer.addPeriodicTimeObserver(
      forInterval: CMTime(value: 1, timescale: 100), queue: playheadQueue
    ) { [weak feeder] time in
      feeder?.update(time)
    }
    self.avPlayer = avPlayer
    return avPlayer
  }

  /// The player's output context exists once a picker is bound to it. These notifications are
  /// private to AVFoundation; the picker's own callbacks cover a release that renames them.
  private func observeOutputContext() {
    // The bridge keeps one AVPlayer for its lifetime. Reuse its context: querying outputContext
    // again while AVKit closes the picker can wait on the media queue and deadlock AppKit.
    guard observedContext == nil,
          let avPlayer, avPlayer.responds(to: NSSelectorFromString("outputContext")),
          let context = avPlayer.value(forKey: "outputContext") as? NSObject,
          context !== observedContext else { return }
    routeObservers.forEach { NotificationCenter.default.removeObserver($0) }
    observedContext = context
    routeObservers = ["AVOutputContextOutputDevicesDidChangeNotification",
                      "AVOutputContextOutputDeviceDidChangeNotification"].map { name in
      NotificationCenter.default.addObserver(forName: Notification.Name(name), object: context,
                                             queue: nil) { [weak self] _ in
        // A main OperationQueue observer makes the posting AVFoundation thread wait for AppKit.
        // Return to AVFoundation before reading any player or route state on the main queue.
        DispatchQueue.main.async { [weak self] in self?.routeMayHaveChanged() }
      }
    }
  }

  private func currentRoute() -> (external: Bool, names: [String], description: String) {
    var airPlayActive = false
    if let routePicker, routePicker.responds(to: NSSelectorFromString("_isAirPlayActive")) {
      airPlayActive = (routePicker.value(forKey: "isAirPlayActive") as? Bool) ?? false
    }
    var devices: [NSObject] = []
    if let observedContext, observedContext.responds(to: NSSelectorFromString("outputDevices")) {
      devices = (observedContext.value(forKey: "outputDevices") as? [NSObject]) ?? []
    }
    func property(_ device: NSObject, _ key: String) -> Any? {
      device.responds(to: NSSelectorFromString(key)) ? device.value(forKey: key) : nil
    }
    let names = devices.compactMap { property($0, "deviceName") as? String }
    let details = devices.map { device in
      ["deviceName", "deviceType", "deviceSubType", "transportType", "isLocalAirPlayDevice"].map {
        "\($0)=\(property(device, $0).map { "\($0)" } ?? "nil")"
      }.joined(separator: " ")
    }
    let description = "picker AirPlay \(airPlayActive), devices [\(details.joined(separator: "; "))]"
    // With no explicit choice the context has no devices and follows the system output.
    return (airPlayActive || !devices.isEmpty, names, description)
  }

  private func routeMayHaveChanged() {
    observeOutputContext()
    let route = currentRoute()
    let localTest = UserDefaults.standard.bool(forKey: Self.localTestKey)
    if route.description != routeDescription {
      routeDescription = route.description
      log("route: \(route.description)\(localTest ? ", local test on" : "")")
    }
    let active = route.external || localTest
    let namesChanged = route.names != routeNames
    routeNames = route.names
    guard active != routeActive || (active && namesChanged) else { return }
    player?.mpv?.advanceAirPlayRouteOwnershipGeneration()
    let wasActive = routeActive
    routeActive = active
    routeControl?.update(selected: active)
    if active && !wasActive {
      // A new choice deserves a new attempt.
      bridgeFailedForFile = false
    }
    guard let player else {
      reconcile()
      return
    }
    guard player.info.state.loaded else {
      pendingRouteNotice = (active, routeNames)
      reconcile()
      return
    }
    pendingRouteNotice = nil
    sendRouteNotice(isActive: active, names: routeNames, to: player)
    reconcile()
  }

  private func sendRouteNotice(isActive: Bool, names: [String], to player: PlayerCore) {
    // Route changes are system events, so keep their notices visible during post-load OSD suppression.
    if isActive {
      // This reports the picker selection, not successful audio playback; engage queues async MPV work.
      let name = names.isEmpty ? NSLocalizedString("osc_toolbar.airplay_output.speaker", value: "the AirPlay speaker",
                                                   comment: "Unnamed AirPlay speaker")
                               : ListFormatter.localizedString(byJoining: names)
      player.sendOSD(.custom(String(format: NSLocalizedString("osc_toolbar.airplay_output.selected",
                                                              value: "AirPlay speaker selected: %@",
                                                              comment: "The AirPlay speaker selected in the picker"), name)),
                     external: true)
    } else {
      player.sendOSD(.custom(NSLocalizedString("osc_toolbar.airplay_output.disconnected",
                                               value: "AirPlay speaker disconnected",
                                               comment: "The selected AirPlay speaker disconnected")),
                     external: true)
    }
  }

  // MARK: Engaging

  /// Brings the bridge in line with the route, the file and its audio track.
  private func reconcile() {
    guard !stoppingOrQuitting, let player, player.info.state.active, player.mpv != nil else { return }
    guard lifecycleHooksAvailable else {
      if isEngaged { disengage() }
      if routeActive, player.info.state.loaded, !lifecycleSafetyNoticeShown {
        lifecycleSafetyNoticeShown = true
        player.sendOSD(.custom(NSLocalizedString(
          "osc_toolbar.airplay_output.lifecycle_unavailable",
          value: "AirPlay was disabled because Reel could not protect a file transition; audio will play on this Mac.",
          comment: "The isolated MPV lifecycle hook client is unavailable")), external: true)
      }
      return
    }
    _ = routeAudioOwnershipNow()
    guard routeActive && !bridgeFailedForFile else {
      if isEngaged { disengage() }
      if hasDeferredAudioOutputResolution {
        runNextMPVCommand()
      }
      return
    }
    guard player.info.state.loaded else {
      if hasDeferredAudioOutputResolution {
        runNextMPVCommand()
      }
      return
    }
    let selection = audioSelection()
    if case .pending = selection {
      if hasDeferredAudioOutputResolution {
        runNextMPVCommand()
      }
      return
    }
    if case .unsupported(let reason) = selection {
      // Leaves mpv's own output on, without switching it off first.
      failForFile(reason, message: NSLocalizedString(
        "osc_toolbar.airplay_output.unsupported",
        value: "This file's audio can't be sent over AirPlay, so it plays on this Mac.",
        comment: "The bridge cannot read the current audio track"))
      if hasDeferredAudioOutputResolution {
        runNextMPVCommand()
      }
      return
    }
    if !isEngaged, !engage() { return }
    switch selection {
    case .pending:
      break
    case .supported(let selection):
      if selection != itemSelection { replaceItem(with: selection) }
    case .noAudio:
      if itemSelection != nil { replaceItem(with: nil) }
    case .unsupported:
      break
    }
  }

  @discardableResult
  private func engage() -> Bool {
    guard let mpv = player?.mpv else { return false }
    let snapshot = mpv.airPlayPlaybackSnapshot
    guard snapshot.audioOutputChangesInFlight == 0 else {
      log("waiting for mpv's audio output change before engaging", level: .verbose)
      return false
    }
    guard snapshot.pendingRawAudioOutputIntents.isEmpty,
          snapshot.pendingRawAudioOutputCommands.isEmpty else {
      log("waiting for an accepted direct AO command before engaging", level: .verbose)
      return false
    }
    guard !hasPendingAudioOutputRestore() else {
      routeEngagementDeferredForAudioOutputRestore = true
      log("waiting for the queued local-output restore before engaging", level: .verbose)
      return false
    }
    // A fast route reconnect can observe the old event-fed `ao = null` before a queued restore
    // reaches mpv. Keep the last real output as the source for this and later disengages.
    _ = rememberLatestDirectAudioOutput(from: snapshot)
    if let directAudioOutput = snapshot.directAudioOutput {
      savedAudioOutput = directAudioOutput
      savedAudioOutputIntentGeneration = snapshot.audioOutputIntentGeneration
    } else if let audioOutput = snapshot.audioOutput,
              audioOutput != "null" ||
                (savedAudioOutput == nil && pendingAudioOutputRestoreValues().isEmpty) {
      savedAudioOutput = audioOutput
      savedAudioOutputIntentGeneration = snapshot.audioOutputIntentGeneration
    }
    guard let savedAudioOutput else {
      log("cannot engage: mpv has not reported a local audio output", level: .warning)
      return false
    }
    bridgeEngaged = true
    deferredAudioOutputRestoreAfterRouteCheck = nil
    routeEngagementDeferredForAudioOutputRestore = false
    lastAirPlayAudioOutputDisableGeneration = snapshot.audioOutputGeneration
    latencyCompensation = UserDefaults.standard.double(forKey: Self.latencyKey)
    enqueueMPVCommand(.set, arguments: [MPVOption.Audio.ao, "null"], requiredForOutput: true,
                      expectedAudioOutputIntentGeneration: snapshot.audioOutputIntentGeneration)
    enqueueMPVCommand(MPVCommand("ao-reload"), arguments: [], requiredForOutput: true,
                      expectedAudioOutputIntentGeneration: snapshot.audioOutputIntentGeneration)
    makePlayerIfNeeded()
    mpv.requestAirPlayPlaybackSnapshot()
    // A four-Hz sample is enough for sync correction. Keep libmpv's shared core lock off the UI thread.
    let snapshotTimer = Timer(timeInterval: 0.25, repeats: true) { [weak mpv] _ in
      mpv?.requestAirPlayPlaybackSnapshot()
    }
    RunLoop.main.add(snapshotTimer, forMode: .common)
    mpvSnapshotTimer = snapshotTimer
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    RunLoop.main.add(timer, forMode: .common)
    syncTimer = timer
    log("engaged; mpv audio output \(savedAudioOutput) switched to null, latency compensation \(latencyCompensation)s")
    return true
  }

  private func disengage() {
    if let mpv = player?.mpv {
      let snapshot = mpv.airPlayPlaybackSnapshot
      if snapshot.audioOutputChangesInFlight == 0 {
        _ = rememberLatestDirectAudioOutput(from: snapshot)
        if snapshot.pendingRawAudioOutputIntents.isEmpty,
           snapshot.pendingRawAudioOutputCommands.isEmpty,
           snapshot.directAudioOutput == nil,
           let audioOutput = snapshot.audioOutput, audioOutput != "null",
           !pendingAudioOutputRestoreValues().contains(audioOutput) {
          // A newer async selector may have changed the event-fed AO value before its queued main
          // callback runs. Capture it before enqueueing the disconnect restore.
          savedAudioOutput = audioOutput
          savedAudioOutputIntentGeneration = snapshot.audioOutputIntentGeneration
        }
      }
    }
    replaceItem(with: nil)
    waitingForMPVAudio = false
    audioStartupClock.reset()
    pendingHoldReason = nil
    lastMPVAudioTime = nil
    syncTimer?.invalidate()
    syncTimer = nil
    mpvSnapshotTimer?.invalidate()
    mpvSnapshotTimer = nil
    bridgeEngaged = false
    lastAirPlayAudioOutputDisableGeneration = nil
    guard player?.mpv != nil, let saved = savedAudioOutput else { return }
    if let snapshot = player?.mpv?.airPlayPlaybackSnapshot,
       !snapshot.pendingRawAudioOutputIntents.isEmpty ||
       !snapshot.pendingRawAudioOutputCommands.isEmpty {
      restoreLocalAudioOutputAfterPendingRawCommand = true
      log("deferring local-output restore until the accepted async AO request is observed",
          level: .verbose)
      return
    }
    let output = saved.isEmpty ? (Preference.bool(for: .audioDriverEnableAVFoundation) ? "avfoundation" : "coreaudio") : saved
    let intentGeneration = savedAudioOutputIntentGeneration
      ?? player?.mpv?.airPlayPlaybackSnapshot.audioOutputIntentGeneration ?? 0
    enqueueAudioOutputRestore(output, intentGeneration: intentGeneration)
    log("disengaged; mpv audio output restored to \(output)")
  }

  private func audioSelection() -> AudioSelection {
    guard let player, let mpv = player.mpv else { return .pending }
    let snapshot = mpv.airPlayPlaybackSnapshot
    // Property callbacks can reach AppKit after START_FILE advanced the MPV snapshot but before
    // PlayerCore received that boundary. Its URL/track list still describe the previous file.
    // Keep the route pending instead of tearing down and reloading the AO during audio startup.
    guard currentFileTransitionGeneration == snapshot.fileTransitionGeneration,
          currentPlaylistEntryID == snapshot.currentPlaylistEntryID else { return .pending }
    guard let aid = player.info.aid, aid > 0 else { return .noAudio }
    guard let track = player.info.currentTrack(.audio) else {
      // aid and track-list are separate events, including when a track is changed mid-file.
      return .pending
    }
    guard let streamIndex = track.ffIndex, streamIndex >= 0 else {
      return .unsupported("the audio track has no FFmpeg stream index")
    }
    // mpv's clock starts at each file's start time as its demuxer reports it, which differs from
    // FFmpeg's for Matroska and MP4; external files are rebased on their own start time.
    guard let rebased = snapshot.rebaseStartTime else { return .pending }
    if track.isExternal {
      guard let file = track.externalFilename, !file.isEmpty else {
        return .unsupported("the external audio track has no file name")
      }
      return .supported(Selection(source: file, streamIndex: streamIndex, origin: rebased ? nil : 0))
    }
    let origin = rebased ? snapshot.demuxerStartTime ?? 0 : 0
    guard let url = player.info.currentURL else { return .unsupported("there is no media URL") }
    if url.isFileURL {
      return .supported(Selection(source: url.path, streamIndex: streamIndex, origin: origin))
    }
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
      return .unsupported("\(url.scheme ?? "unknown") sources are not supported")
    }
    // A hook such as ytdl can hand mpv a different stream from the page that was opened.
    let opened = snapshot.streamOpenFilename ?? url.absoluteString
    guard opened.hasPrefix("http://") || opened.hasPrefix("https://") else {
      return .unsupported("mpv opened the stream as \(opened.prefix(16))…")
    }
    return .supported(Selection(source: opened, streamIndex: streamIndex, origin: origin))
  }

  private func replaceItem(with selection: Selection?) {
    rebuildItemAfterSeek = false
    let hadItem = itemSelection != nil
    if selection == nil {
      restoreTimingForCurrentFile(allowsNoActivePlaylistEntry: true)
    } else {
      // A route or track can become bridgeable again before the MPV file changes.
      currentFileTimingReleaseStarted = false
    }
    cancelHold()
    waitingForMPVAudio = false
    audioStartupClock.reset()
    pendingHoldReason = nil
    lastMPVAudioTime = nil
    resetAudioClockMotionTracking()
    setCorrection(0)
    playheadFeeder.attach(nil)
    loader?.invalidate()
    loader = nil
    itemStatusObservation = nil
    avPlayer?.pause()
    avPlayer?.replaceCurrentItem(with: nil)
    itemSelection = selection
    itemGeneration += 1
    driftSamples.removeAll()
    halfFrameDuration = nil
    defer {
      if hadItem || selection != nil, let player, player.mainWindow.loaded {
        player.mainWindow.liveCaptions.playbackBackendChanged()
      }
    }
    guard let selection, let player else { return }

    let generation = itemGeneration
    let duration = player.mpv.airPlayPlaybackSnapshot.duration ?? 0
    // Unknown lengths (live streams) get the longest stream a WAV header can describe.
    let frames = AirPlayPCMResourceLoader.frameCount(for: duration)
    let loader = AirPlayPCMResourceLoader(source: selection.source, streamIndex: selection.streamIndex,
                                          mediaOrigin: selection.origin, frameCount: frames,
                                          gain: AirPlayPCMVolume.gain(volume: player.info.volume,
                                                                     muted: player.info.isMuted)) { [weak self] in
      guard let self, self.itemGeneration == generation else { return }
      self.failForFile("the audio could not be decoded")
    }
    self.loader = loader
    playheadFeeder.attach(loader)
    // Do not hold or start the speaker yet: the next tick waits until mpv's own audio output is
    // running, so this file's start cannot be postponed by a hold (see `waitingForMPVAudio`).
    waitingForMPVAudio = true
    audioStartupClock.reset()
    pendingHoldReason = nil
    lastMPVAudioTime = nil
    resetAudioClockMotionTracking()
    let asset = AVURLAsset(url: URL(string: "\(AirPlayPCMResourceLoader.scheme)://audio/\(generation).wav")!)
    // The resource loader holds its delegate weakly; `self.loader` keeps it alive. Cancellation
    // callbacks need a separate queue so they can interrupt FFmpeg while the pump reads a URL.
    asset.resourceLoader.setDelegate(loader, queue: loader.delegateQueue)
    let item = AVPlayerItem(asset: asset)
    itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
      DispatchQueue.main.async { self?.itemStatusChanged(item, generation: generation) }
    }
    let avPlayer = makePlayerIfNeeded()
    volumeChanged()
    avPlayer.replaceCurrentItem(with: item)
    log("audio stream \(selection.streamIndex) of \(URL(fileURLWithPath: selection.source).lastPathComponent), \(String(format: "%.1f", loader.duration))s, origin \(selection.origin.map { String(format: "%.3f", $0) } ?? "container")")
  }

  private func itemStatusChanged(_ item: AVPlayerItem, generation: Int) {
    guard generation == itemGeneration, item === avPlayer?.currentItem else { return }
    switch item.status {
    case .readyToPlay:
      log("audio ready")
      startSpeaker(holdGeneration)
    case .failed:
      failForFile("AVPlayer could not play the audio: \(item.error?.localizedDescription ?? "unknown error")")
    default:
      break
    }
  }

  private func failForFile(_ reason: String, message: String? = nil) {
    guard !bridgeFailedForFile else { return }
    log("playing this file on the Mac: \(reason)", level: .warning)
    bridgeFailedForFile = true
    reconcile()
    // AVPlayer may report fallback during the post-load OSD suppression window.
    player?.sendOSD(.custom(message ?? NSLocalizedString(
      "osc_toolbar.airplay_output.failed",
      value: "AirPlay stopped playing this file's audio, so it plays on this Mac.",
      comment: "The AirPlay bridge gave up on the current file")),
                     external: true)
  }

  // MARK: Holding the picture for the speaker

  /// Holds unless mpv's audio output is still starting. Every path that wants a hold goes through
  /// here, because writing speed while that output is starting postpones it for seconds; `tick`
  /// then starts the deferred hold as soon as the picture moves.
  private func requestHold(_ reason: String, realign: Bool) {
    guard !waitingForMPVAudio else {
      pendingHoldReason = reason
      return
    }
    beginHold(reason, realign: realign)
  }

  /// Holds mpv's picture nearly still, aligns the speaker with it and starts the speaker. The hold
  /// ends once the speaker is playing the sound that belongs to the picture.
  private func beginHold(_ reason: String, realign: Bool) {
    guard isCarrying, let player, player.info.state.loaded, let mpv = player.mpv else { return }
    waitingForMPVAudio = false
    audioStartupClock.reset()
    pendingHoldReason = nil
    lastMPVAudioTime = nil
    resetAudioClockMotionTracking()
    holdGeneration += 1
    let generation = holdGeneration
    stopHoldTimer()
    stalledSince = nil
    waitingForMPVCache = false
    driftSamples.removeAll()
    setCorrection(0)
    holdReason = reason
    holdRealign = realign
    if mpv.airPlayPlaybackSnapshot.isPaused == true {
      holding = false
      setHoldSpeed(false)
      avPlayer?.pause()
    } else {
      holding = true
      holdStartedAt = Date()
      setHoldSpeed(true)
      let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in self?.pollHold(generation) }
      RunLoop.main.add(timer, forMode: .common)
      holdTimer = timer
    }
    startSpeaker(generation)
  }

  /// Aligns the AVPlayer with mpv's picture and, during a hold, plays it. Waits for the item.
  private func startSpeaker(_ generation: Int) {
    guard generation == holdGeneration, let player, let mpv = player.mpv, let avPlayer,
          let item = avPlayer.currentItem, item.status == .readyToPlay else { return }
    let videoTime = mpv.airPlayPlaybackSnapshot.timePosition ?? 0
    let target = max(0, videoTime - userAudioDelay)
    loader?.setPlayhead(seconds: target)
    let heard = playheadFeeder.position
    let gap = heard.map { abs($0 - target) } ?? .infinity
    if let heard, heard > target + 0.25, let selection = itemSelection {
      // AirPlay's buffered item can also refuse a backward seek during automatic resync after
      // pause/resume. Use the same fresh-stream path as a user seek before changing its rate.
      replaceItem(with: selection)
      return
    }
    let play: () -> Void = { [weak self] in
      guard let self, generation == self.holdGeneration, self.holding else { return }
      self.speakerClock.reset(position: self.playheadFeeder.position)
      avPlayer.rate = Float(self.userSpeed)
    }
    log("\(holding ? "holding" : "aligning") for \(holdReason): picture \(String(format: "%.3f", videoTime)), speaker \(heard.map { String(format: "%.3f", $0) } ?? "none"), target \(String(format: "%.3f", target))")
    guard gap > (holdRealign ? 0.25 : 3) else {
      play()
      return
    }
    avPlayer.pause()
    playheadFeeder.prepareForSeek(to: target)
    avPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 48_000),
                  toleranceBefore: .zero, toleranceAfter: .zero) { finished in
      // A seek that did not finish was replaced by a newer hold.
      guard finished else { return }
      DispatchQueue.main.async(execute: play)
    }
  }

  private func pollHold(_ generation: Int) {
    guard generation == holdGeneration, holding, let player, player.info.state.loaded,
          let mpv = player.mpv, let avPlayer else {
      stopHoldTimer()
      return
    }
    let videoTime = mpv.airPlayPlaybackSnapshot.timePosition
    let now = Date()
    let clockPosition = playheadFeeder.position
    if avPlayer.timeControlStatus == .playing {
      speakerClock.observe(position: clockPosition, at: now,
                           epsilon: Self.audioClockMotionEpsilon)
      let nearEnd = clockPosition.map { position in
        loader.map { position > $0.duration - 3 } ?? false
      } ?? false
      if !nearEnd, speakerClock.hasStalled(at: now,
                                           stallTimeout: Self.speakerClockStallTimeout,
                                           startupTimeout: Self.speakerClockStartupTimeout) {
        let reason = speakerClock.hasAdvanced
          ? "the speaker's playback clock stopped advancing"
          : "the speaker reported playback without advancing its clock"
        failForFile(reason)
        return
      }
    } else {
      speakerClock.markBlocked(position: clockPosition)
    }
    if avPlayer.timeControlStatus == .playing, speakerClock.hasAdvanced,
       let heard = audiblePosition, let videoTime,
       heard + userAudioDelay >= videoTime - 0.005 {
      let waited = holdStartedAt.map { Date().timeIntervalSince($0) } ?? 0
      holding = false
      stopHoldTimer()
      setHoldSpeed(false)
      correctionCooldownUntil = Date().addingTimeInterval(1.5)
      log("speaker playing after \(String(format: "%.2f", waited))s (\(holdReason)); \(currentRoute().description)")
      return
    }
    if let holdStartedAt, Date().timeIntervalSince(holdStartedAt) > Self.holdTimeout {
      failForFile("the speaker did not start within \(Int(Self.holdTimeout))s (\(holdReason)), status \(avPlayer.timeControlStatus.rawValue), waiting reason \(avPlayer.reasonForWaitingToPlay?.rawValue ?? "none")")
    }
  }

  private func cancelHold() {
    waitingForSeekSnapshot = false
    seekSnapshotStartedAt = nil
    holdGeneration += 1
    holding = false
    stopHoldTimer()
    setHoldSpeed(false)
    speakerClock.markBlocked(position: playheadFeeder.position)
    resetAudioClockMotionTracking()
  }

  /// Clears the audio-clock samples used to detect stalled mpv playback.
  private func resetAudioClockMotionTracking() {
    lastMPVAudioClockPosition = nil
    audioClockMovedAt = nil
    waitingForMPVAudioClock = false
  }

  private func stopHoldTimer() {
    holdTimer?.invalidate()
    holdTimer = nil
  }

  private func setHoldSpeed(_ hold: Bool) {
    guard hold != holdSpeedApplied, player?.mpv != nil,
          let fileTransitionGeneration = currentFileTransitionGeneration,
          let playlistEntryID = currentPlaylistEntryID else { return }
    let expectedCurrentTimingValue = hold ? nil :
      (pendingMPVPropertyValue(MPVOption.PlaybackControl.speed) ?? Self.holdSpeed)
    holdSpeedApplied = hold
    let speed = hold ? Self.holdSpeed : userSpeed
    enqueueMPVProperty(MPVCommandRequest.Operation.doubleProperty(MPVOption.PlaybackControl.speed, speed),
                       coalescingKey: "airplay-speed",
                       expectedCurrentTimingValue: expectedCurrentTimingValue,
                       expectedFileTransitionGeneration: fileTransitionGeneration,
                       expectedPlaylistEntryID: playlistEntryID,
                       allowsNoActivePlaylistEntry: !hold)
  }

  private func setCorrection(_ correction: Double) {
    guard correction != audioDelayCorrection, player?.mpv != nil,
          let fileTransitionGeneration = currentFileTransitionGeneration,
          let playlistEntryID = currentPlaylistEntryID else { return }
    let expectedCurrentTimingValue = correction == 0
      ? (pendingMPVPropertyValue(MPVOption.Audio.audioDelay) ?? userAudioDelay + audioDelayCorrection)
      : nil
    audioDelayCorrection = correction
    let delay = userAudioDelay + correction
    enqueueMPVProperty(MPVCommandRequest.Operation.doubleProperty(MPVOption.Audio.audioDelay, delay),
                       coalescingKey: "airplay-audio-delay",
                       expectedCurrentTimingValue: expectedCurrentTimingValue,
                       expectedFileTransitionGeneration: fileTransitionGeneration,
                       expectedPlaylistEntryID: playlistEntryID,
                       allowsNoActivePlaylistEntry: correction == 0)
  }

  // MARK: Keeping sync

  private func tick() {
    guard isCarrying, let player, player.info.state.loaded, let mpv = player.mpv, let avPlayer else { return }
    let snapshot = mpv.airPlayPlaybackSnapshot
    let clockPosition = playheadFeeder.position
    if player.info.isSeeking { return }
    if waitingForSeekSnapshot {
      guard snapshot.timePosition != nil else {
        if let seekSnapshotStartedAt, Date().timeIntervalSince(seekSnapshotStartedAt) > Self.holdTimeout {
          failForFile("mpv did not supply a fresh playback clock after seeking")
        }
        return
      }
      waitingForSeekSnapshot = false
      seekSnapshotStartedAt = nil
      if rebuildItemAfterSeek, let selection = itemSelection {
        // Buffered AirPlay can leave a backward seek pending on the existing WAV item. Start a
        // fresh stream on the same routed player, then align it using the new picture position.
        replaceItem(with: selection)
        return
      }
      requestHold("seek", realign: true)
      return
    }
    guard !holding, snapshot.isPaused == false else {
      if waitingForMPVAudio { audioStartupClock.markBlocked() }
      driftSamples.removeAll()
      return
    }
    if snapshot.pausedForCache == true {
      if waitingForMPVAudio { audioStartupClock.markBlocked() }
      // mpv is buffering its own copy of a stream; the speaker waits with the picture.
      if !waitingForMPVCache {
        waitingForMPVCache = true
        speakerClock.markBlocked(position: clockPosition)
        avPlayer.pause()
        log("waiting for mpv to buffer")
      }
      return
    }
    if waitingForMPVCache {
      waitingForMPVCache = false
      // While mpv's audio output is still starting, the pending wait below still owns the hold.
      if !waitingForMPVAudio {
        beginHold("mpv buffered", realign: true)
        return
      }
    }
    if waitingForMPVAudio {
      // mpv is rebuilding its audio output (`ao-reload`), and it will not start it while speed or
      // audio delay is being written. The audio clock moving again means the new output is running,
      // so only then may the bridge hold it and start the speaker.
      let now = Date()
      audioStartupClock.markCanProgress(at: now)
      speakerClock.markBlocked(position: clockPosition)
      let audioTime = snapshot.audioPTS
      if let audioTime, AirPlayPCMResourceLoader.audioClockHasAdvanced(
        from: lastMPVAudioTime, to: audioTime, epsilon: Self.audioClockMotionEpsilon) {
        log("mpv audio output running at \(String(format: "%.3f", audioTime))")
        let reason = pendingHoldReason ?? "mpv audio output running"
        pendingHoldReason = nil
        beginHold(reason, realign: true)
        return
      } else if let audioTime {
        lastMPVAudioTime = audioTime
      }
      // Observe clock progress before applying the deadline: the next 250 ms sample may arrive just
      // after the threshold even though the audio clock started moving before it.
      if audioStartupClock.hasExpired(at: now, timeout: Self.holdTimeout) {
        failForFile("mpv's audio output did not start within \(Int(Self.holdTimeout))s")
      }
      return
    }
    if let audioTime = snapshot.audioPTS {
      // time-pos advances only when a video frame is presented. A low-frame-rate video can hold one
      // picture longer than 0.6 s while audio continues, so detect stalls from mpv's audio clock.
      let now = Date()
      if AirPlayPCMResourceLoader.audioClockHasAdvanced(
        from: lastMPVAudioClockPosition, to: audioTime, epsilon: Self.audioClockMotionEpsilon) {
        audioClockMovedAt = now
      } else if audioClockMovedAt == nil {
        audioClockMovedAt = now
      }
      lastMPVAudioClockPosition = audioTime
      if let movedAt = audioClockMovedAt,
         now.timeIntervalSince(movedAt) > Self.audioClockStallTimeout {
        if !waitingForMPVAudioClock {
          waitingForMPVAudioClock = true
          driftSamples.removeAll()
          speakerClock.markBlocked(position: clockPosition)
          avPlayer.pause()
          log("mpv audio clock stopped; holding the speaker until it resumes", level: .verbose)
        }
        return
      }
      if waitingForMPVAudioClock {
        waitingForMPVAudioClock = false
        requestHold("mpv audio clock resumed", realign: true)
        return
      }
    }
    guard avPlayer.timeControlStatus == .playing, let heard = audiblePosition else {
      speakerClock.markBlocked(position: clockPosition)
      if avPlayer.rate == 0 {
        requestHold("speaker stopped", realign: true)
      } else if let stalledSince {
        if Date().timeIntervalSince(stalledSince) > 0.5 { requestHold("speaker stalled", realign: false) }
      } else {
        stalledSince = Date()
      }
      return
    }
    stalledSince = nil
    if let loader, heard > loader.duration - 3 { return }
    let now = Date()
    speakerClock.observe(position: clockPosition, at: now,
                         epsilon: Self.audioClockMotionEpsilon)
    if speakerClock.hasStalled(at: now, stallTimeout: Self.speakerClockStallTimeout,
                                startupTimeout: Self.speakerClockStartupTimeout) {
      failForFile(speakerClock.hasAdvanced
        ? "the speaker's playback clock stopped advancing"
        : "the speaker reported playback without advancing its clock")
      return
    }
    guard let videoTime = snapshot.timePosition else { return }
    if halfFrameDuration == nil {
      // time-pos is the displayed frame's start; on average the picture is half a frame later.
      let fps = snapshot.estimatedVideoFPS ?? snapshot.containerFPS
      if let fps, fps >= 1, fps <= 1000 { halfFrameDuration = 0.5 / fps }
    }
    let error = videoTime + (halfFrameDuration ?? 0) - (heard + userAudioDelay)
    // Discard samples gathered while a speed/delay write is still settling. Reusing that window
    // makes the controller integrate the same old offset repeatedly during startup.
    guard Date() >= correctionCooldownUntil,
          pendingMPVPropertyRequest(MPVOption.PlaybackControl.speed) == nil,
          pendingMPVPropertyRequest(MPVOption.Audio.audioDelay) == nil else {
      driftSamples.removeAll()
      return
    }
    driftSamples.append(error)
    if driftSamples.count > 8 { driftSamples.removeFirst() }
    guard driftSamples.count >= 4 else { return }
    let median = driftSamples.sorted()[driftSamples.count / 2]
    if abs(median) > Self.resyncThreshold {
      requestHold("picture \(String(format: "%.2f", median))s off", realign: true)
      return
    }
    guard abs(median) > Self.correctionThreshold else { return }
    // Changing mpv's audio delay moves the picture against its (silent) audio clock.
    let adjustment = median.clamped(to: -0.25...0.25)
    setCorrection(audioDelayCorrection - adjustment)
    driftSamples.removeAll()
    correctionCooldownUntil = Date().addingTimeInterval(1.5)
    log("picture \(String(format: "%+.3f", median))s from the speaker; correction now \(String(format: "%+.3f", audioDelayCorrection))s", level: .verbose)
  }

  private func timeControlStatusChanged() {
    guard isCarrying, let avPlayer else { return }
    let status: String
    switch avPlayer.timeControlStatus {
    case .paused: status = "paused"
    case .waitingToPlayAtSpecifiedRate: status = "waiting (\(avPlayer.reasonForWaitingToPlay?.rawValue ?? "unknown"))"
    case .playing: status = "playing"
    @unknown default: status = "unknown"
    }
    log("speaker \(status) at \(playheadFeeder.position.map { String(format: "%.3f", $0) } ?? "none")", level: .verbose)
  }

  // MARK: PlayerCore and MPVController hooks

  func fileLoaded(fileTransitionGeneration: UInt64? = nil) {
    if let fileTransitionGeneration {
      currentFileTransitionGeneration = fileTransitionGeneration
    }
    if pendingOutputRestoreFailureNotice, let player, player.info.state.loaded {
      showOutputRestoreFailureNotice(to: player)
    }
    if UserDefaults.standard.bool(forKey: Self.localTestKey) && !routeActive {
      routeMayHaveChanged()
    }
    if let notice = pendingRouteNotice, let player, player.info.state.loaded {
      pendingRouteNotice = nil
      sendRouteNotice(isActive: notice.isActive, names: notice.names, to: player)
    }
    reconcile()
  }

  private func showOutputRestoreFailureNotice(to player: PlayerCore) {
    guard player.info.state.loaded else {
      pendingOutputRestoreFailureNotice = true
      return
    }
    pendingOutputRestoreFailureNotice = false
    player.sendOSD(.custom(NSLocalizedString(
      "osc_toolbar.airplay_output.restore_failed",
      value: "AirPlay stopped, but Reel could not restore audio output on this Mac.",
      comment: "The native AirPlay bridge failed to restore mpv's audio output")),
      external: true)
  }

  func audioTrackChanged() {
    _ = routeAudioOwnershipNow()
    guard player?.info.state.loaded == true else { return }
    if isEngaged || routeActive { reconcile() }
  }

  func pauseChanged(_ paused: Bool) {
    if paused {
      if pauseStartedAt == nil { pauseStartedAt = Date() }
      guard isCarrying else { return }
      if waitingForMPVAudio { audioStartupClock.markBlocked() }
      cancelHold()
      avPlayer?.pause()
    } else {
      let pausedFor = pauseStartedAt.map { Date().timeIntervalSince($0) }
      pauseStartedAt = nil
      if let pausedFor { recoverAfterPause(pausedFor) }
      guard isCarrying else { return }
      if waitingForMPVAudio { audioStartupClock.markCanProgress() }
      requestHold("resume", realign: true)
    }
  }

  /// A paused AirPlay item can outlive the receiver's buffered stream. Refresh it on resume after
  /// a long pause, and retry a failure that happened while paused after checking the route again.
  private func recoverAfterPause(_ duration: TimeInterval) {
    let failedItem = avPlayer?.currentItem?.status == .failed
    guard duration >= Self.longPauseStreamRefreshThreshold || bridgeFailedForFile || failedItem else {
      return
    }
    let itemGenerationBeforeRouteCheck = itemGeneration
    routeMayHaveChanged()
    guard routeActive else { return }
    if bridgeFailedForFile || avPlayer?.currentItem?.status == .failed {
      retryFailedBridgeIfNeeded(trigger: "resume")
      return
    }
    guard itemGeneration == itemGenerationBeforeRouteCheck,
          duration >= Self.longPauseStreamRefreshThreshold, isCarrying,
          case .supported(let selection) = audioSelection() else { return }
    log("refreshing AirPlay audio after a \(Int(duration))s pause")
    replaceItem(with: selection)
  }

  /// Retries only after a failure, so ordinary picker dismissals do not rebuild the audio stream.
  private func retryFailedBridgeIfNeeded(trigger: String) {
    let failedItem = avPlayer?.currentItem?.status == .failed
    guard (bridgeFailedForFile || failedItem), routeActive, !stoppingOrQuitting,
          let player, player.info.state.loaded,
          case .supported(let selection) = audioSelection() else { return }
    log("retrying AirPlay audio after \(trigger)")
    if bridgeFailedForFile {
      bridgeFailedForFile = false
      reconcile()
    } else if isEngaged, itemSelection == selection {
      replaceItem(with: selection)
    } else {
      reconcile()
    }
  }

  func playbackSeekStarted() {
    guard isCarrying else { return }
    cancelHold()
    rebuildItemAfterSeek = true
    waitingForSeekSnapshot = true
    seekSnapshotStartedAt = Date()
    avPlayer?.pause()
  }

  func playbackRestarted() {
    guard isCarrying else { return }
    cancelHold()
    waitingForSeekSnapshot = true
    seekSnapshotStartedAt = Date()
    avPlayer?.pause()
    player?.mpv?.requestAirPlayPlaybackSnapshot()
  }

  /// mpv changed speed on the user's behalf; the hold speed, if any, was replaced.
  func userSpeedChanged(_ speed: Double) {
    if let matchedTarget = pendingUserSpeedTargets.lastIndex(where: {
      Self.sameTimingValue($0.value, speed)
    }) {
      pendingUserSpeedTargets.removeFirst(matchedTarget + 1)
      if pendingUserSpeedTargets.isEmpty { userSpeedOverride = nil }
    } else {
      pendingUserSpeedTargets.removeAll()
      userSpeedOverride = nil
    }
    guard isCarrying else { return }
    holdSpeedApplied = false
    requestHold("speed change", realign: true)
  }

  func hasPendingUserSpeedTarget(_ speed: Double) -> Bool {
    pendingUserSpeedTargets.contains { Self.sameTimingValue($0.value, speed) }
  }

  func volumeChanged() {
    guard let avPlayer, let player else { return }
    let gain = AirPlayPCMVolume.gain(volume: player.info.volume, muted: player.info.isMuted)
    if let loader, loader.gain != gain, isCarrying {
      // AVFoundation and the receiver may have already buffered seconds of the old gain.
      // Replace the stream so mute and volume changes also discard those buffered samples.
      avPlayer.pause()
      avPlayer.isMuted = true
      guard case .supported(let selection) = audioSelection() else { return }
      replaceItem(with: selection)
      return
    }
    // PCM already carries the gain; applying it here too would square the requested volume.
    avPlayer.volume = 1
    avPlayer.isMuted = gain == 0
  }

  func consumeInternalSpeed(_ speed: Double) -> Bool {
    speedWrites.consume(speed)
  }

  /// The user's audio delay for a value mpv reported, or nil when the bridge wrote that value.
  func userAudioDelay(fromMPV delay: Double) -> Double? {
    let isInternalWrite = delayWrites.consume(delay)
    if let target = pendingUserAudioDelayTargets.target(forMPVValue: delay) {
      mappedAudioDelayTarget = target
      return target.userValue
    }
    mappedAudioDelayTarget = nil
    guard !isInternalWrite else { return nil }
    let userDelay = delay - audioDelayCorrection
    // A repeated/rounded zero while a seek resets correction is not a new user adjustment.
    // Explicit UI/key requests already matched their retained target above and still get OSD.
    return Self.sameTimingValue(userDelay, userAudioDelay) ? nil : userDelay
  }

  func noteUserSpeedRequest(_ speed: Double, osdMode: AirPlayTimingOSDMode = .automatic) {
    guard isCarrying, speed.isFinite else { return }
    userSpeedOverride = speed
    pendingUserSpeedTargets.append(AirPlayUserSpeedTarget(value: speed, osdMode: osdMode))
  }

  /// Serializes a user's speed change behind bridge writes that may still be restoring the old
  /// route's speed. This includes the drain window after `isCarrying` becomes false.
  @discardableResult
  func enqueueUserSpeed(_ speed: Double,
                        osdMode: AirPlayTimingOSDMode = .automatic) -> Bool {
    let carriesAudio = isCarrying
    guard (carriesAudio || hasUndrainedMPVCommands), speed.isFinite else { return false }
    userSpeedOverride = speed
    pendingUserSpeedTargets.append(AirPlayUserSpeedTarget(value: speed, osdMode: osdMode))
    enqueueMPVProperty(.doubleProperty(MPVOption.PlaybackControl.speed, speed),
                       coalescingKey: "airplay-speed")
    return true
  }

  func noteUserAudioDelayRequest(_ delay: Double, osdMode: AirPlayTimingOSDMode = .automatic) {
    guard isCarrying, delay.isFinite else { return }
    userAudioDelayOverride = delay
    pendingUserAudioDelayTargets.append(userValue: delay, correction: audioDelayCorrection,
                                        osdMode: osdMode)
  }

  /// Serializes a user delay change behind accepted bridge writes so an older async correction
  /// cannot land after the user's newer value, including while a route is disengaging.
  @discardableResult
  func enqueueUserAudioDelay(_ delay: Double,
                             osdMode: AirPlayTimingOSDMode = .automatic) -> Bool {
    let carriesAudio = isCarrying
    guard (carriesAudio || hasUndrainedMPVCommands), delay.isFinite else { return false }
    let correction = carriesAudio ? audioDelayCorrection : 0
    let mpvDelay = delay + correction
    guard mpvDelay.isFinite else { return false }
    if carriesAudio {
      noteUserAudioDelayRequest(delay, osdMode: osdMode)
    } else {
      // The queued write is tracked as an internal timing write, so retain the target that maps
      // its property-change event back to this user's value after the route has disengaged.
      userAudioDelayOverride = delay
      pendingUserAudioDelayTargets.append(userValue: delay, correction: correction,
                                          osdMode: osdMode)
    }
    enqueueMPVProperty(.doubleProperty(MPVOption.Audio.audioDelay, mpvDelay),
                       coalescingKey: "airplay-audio-delay")
    return true
  }

  func userSpeedOSDMode(for speed: Double) -> AirPlayTimingOSDMode {
    guard let matchedTarget = pendingUserSpeedTargets.lastIndex(where: {
      Self.sameTimingValue($0.value, speed)
    }) else { return .automatic }
    return pendingUserSpeedTargets[matchedTarget].osdMode
  }

  func multiplyUserSpeed(by factor: Double, osdMode: AirPlayTimingOSDMode = .automatic) {
    guard shouldSerializeTimingChanges, factor.isFinite, factor > 0 else { return }
    let speed = userSpeed * factor
    guard speed.isFinite else { return }
    player?.setSpeed(speed, osdMode: osdMode)
  }

  func adjustUserAudioDelay(by delta: Double, osdMode: AirPlayTimingOSDMode = .automatic) {
    guard shouldSerializeTimingChanges, delta.isFinite else { return }
    let delay = userAudioDelay + delta
    guard delay.isFinite else { return }
    player?.setAudioDelay(delay, osdMode: osdMode)
  }

  func adjustUserSpeed(by delta: Double, osdMode: AirPlayTimingOSDMode = .automatic) {
    guard shouldSerializeTimingChanges, delta.isFinite else { return }
    let speed = userSpeed + delta
    guard speed.isFinite else { return }
    player?.setSpeed(speed, osdMode: osdMode)
  }

  func multiplyUserAudioDelay(by factor: Double, osdMode: AirPlayTimingOSDMode = .automatic) {
    guard shouldSerializeTimingChanges, factor.isFinite else { return }
    let delay = userAudioDelay * factor
    guard delay.isFinite else { return }
    player?.setAudioDelay(delay, osdMode: osdMode)
  }

  func adjustUserSpeedForScroll(by relativeDelta: Double, minimum: Double, maximum: Double) {
    guard shouldSerializeTimingChanges, relativeDelta.isFinite else { return }
    let newSpeed = round(1000 * (userSpeed + userSpeed * relativeDelta)
      .clamped(to: minimum...maximum)) / 1000
    guard newSpeed.isFinite else { return }
    player?.setSpeed(newSpeed)
  }

  func userAudioDelayChanged(_ delay: Double) -> AirPlayTimingOSDMode {
    let osdMode: AirPlayTimingOSDMode?
    if let mappedAudioDelayTarget,
       Self.sameTimingValue(mappedAudioDelayTarget.userValue, delay) {
      osdMode = pendingUserAudioDelayTargets.complete(mappedAudioDelayTarget)
    } else {
      osdMode = pendingUserAudioDelayTargets.complete(userValue: delay)
    }
    self.mappedAudioDelayTarget = nil
    if pendingUserAudioDelayTargets.values.isEmpty { userAudioDelayOverride = nil }
    return osdMode ?? .automatic
  }

  private static func sameTimingValue(_ lhs: Double, _ rhs: Double) -> Bool {
    AirPlayTimingRestorePolicy.stillOwnsValue(lhs, expectedValue: rhs)
  }

  private func clearUserTimingTargets() {
    userSpeedOverride = nil
    userAudioDelayOverride = nil
    pendingUserSpeedTargets.removeAll()
    pendingUserAudioDelayTargets.reset()
    mappedAudioDelayTarget = nil
  }

  /// Runs `body` with the user's own speed and audio delay in mpv, for writing watch-later files.
  func withUserTiming(_ body: () -> Void) {
    guard let mpv = player?.mpv, holdSpeedApplied || audioDelayCorrection != 0 else {
      body()
      return
    }
    // These writes must stay synchronous: `body` immediately asks mpv to persist watch-later state
    // using the user's timing, then restores the bridge values before playback resumes.
    let held = holdSpeedApplied
    let correction = audioDelayCorrection
    if held { speedWrites.record(userSpeed); mpv.setDouble(MPVOption.PlaybackControl.speed, userSpeed, level: .verbose) }
    if correction != 0 { delayWrites.record(userAudioDelay); mpv.setDouble(MPVOption.Audio.audioDelay, userAudioDelay, level: .verbose) }
    body()
    if correction != 0 {
      delayWrites.record(userAudioDelay + correction)
      mpv.setDouble(MPVOption.Audio.audioDelay, userAudioDelay + correction, level: .verbose)
    }
    if held { speedWrites.record(Self.holdSpeed); mpv.setDouble(MPVOption.PlaybackControl.speed, Self.holdSpeed, level: .verbose) }
  }

  func fileStarted(fileTransitionGeneration: UInt64? = nil, playlistEntryID: Int64? = nil) {
    pauseStartedAt = nil
    let transitionUserSpeed = userSpeed
    let transitionUserAudioDelay = userAudioDelay
    let snapshot = player?.mpv?.airPlayPlaybackSnapshot
    let transitionGeneration = fileTransitionGeneration ?? snapshot?.fileTransitionGeneration
    let transitionPlaylistEntryID = playlistEntryID ?? snapshot?.currentPlaylistEntryID
    let pendingSpeedRequest = pendingMPVPropertyRequest(MPVOption.PlaybackControl.speed)
    let pendingAudioDelayRequest = pendingMPVPropertyRequest(MPVOption.Audio.audioDelay)
    let needsUserSpeedRestore = !pendingUserSpeedTargets.isEmpty || holdSpeedApplied ||
      pendingTimingRestoreFileIdentities[MPVOption.PlaybackControl.speed].map {
        !$0.matches(fileTransitionGeneration: transitionGeneration,
                    playlistEntryID: transitionPlaylistEntryID)
      } == true || pendingSpeedRequest.map { request in
        guard case let .doubleProperty(_, value) = request.operation else { return false }
        return !Self.sameTimingValue(value, transitionUserSpeed) ||
          !request.targetsFile(fileTransitionGeneration: transitionGeneration,
                              playlistEntryID: transitionPlaylistEntryID)
      } == true
    let needsUserAudioDelayRestore = !pendingUserAudioDelayTargets.values.isEmpty ||
      audioDelayCorrection != 0 ||
      pendingTimingRestoreFileIdentities[MPVOption.Audio.audioDelay].map {
        !$0.matches(fileTransitionGeneration: transitionGeneration,
                    playlistEntryID: transitionPlaylistEntryID)
      } == true || pendingAudioDelayRequest.map { request in
        guard case let .doubleProperty(_, value) = request.operation else { return false }
        return !Self.sameTimingValue(value, transitionUserAudioDelay) ||
          !request.targetsFile(fileTransitionGeneration: transitionGeneration,
                              playlistEntryID: transitionPlaylistEntryID)
      } == true
    releaseFile()
    currentFileTransitionGeneration = transitionGeneration
    currentPlaylistEntryID = transitionPlaylistEntryID
    currentFileTimingReleaseStarted = false
    pendingTimingRestoreFileIdentities.removeAll(keepingCapacity: true)
    stoppingOrQuitting = false
    bridgeFailedForFile = false
    lifecycleSafetyNoticeShown = false
    // A missing on_before_start_file hook fences its old-file restore out at START_FILE. Reapply
    // the user's timing on the new item before route reconciliation can add another bridge write.
    if needsUserSpeedRestore {
      enqueueMPVProperty(.doubleProperty(MPVOption.PlaybackControl.speed, transitionUserSpeed),
                         coalescingKey: "airplay-speed")
    }
    if needsUserAudioDelayRestore {
      enqueueMPVProperty(.doubleProperty(MPVOption.Audio.audioDelay, transitionUserAudioDelay),
                         coalescingKey: "airplay-audio-delay")
    }
    _ = routeAudioOwnershipNow()
  }

  /// AirPlay requires an isolated event queue for its file-transition timing barrier.
  func lifecycleHookAvailabilityChanged(_ available: Bool) {
    guard lifecycleHooksAvailable != available else { return }
    lifecycleHooksAvailable = available
    lifecycleSafetyNoticeShown = false
    guard available else {
      if isEngaged {
        bridgeFailedForFile = true
        disengage()
      }
      reconcile()
      return
    }
    reconcile()
  }

  func fileEnded(fileTransitionGeneration: UInt64?, playlistEntryID: Int64?) {
    pauseStartedAt = nil
    let endedGeneration = fileTransitionGeneration ?? currentFileTransitionGeneration
    let endedPlaylistEntryID = playlistEntryID ?? currentPlaylistEntryID
    if let endedGeneration { currentFileTransitionGeneration = endedGeneration }
    if let endedPlaylistEntryID { currentPlaylistEntryID = endedPlaylistEntryID }
    releaseFile(fileTransitionGeneration: endedGeneration,
                playlistEntryID: endedPlaylistEntryID,
                allowsNoActivePlaylistEntry: endedPlaylistEntryID != nil)
    clearUserTimingTargets()
  }

  /// The player is stopping or quitting; mpv may write a watch-later file with its timing.
  func stopPlayback() {
    pauseStartedAt = nil
    stoppingOrQuitting = true
    _ = routeAudioOwnershipNow()
    if !currentFileTimingReleaseStarted {
      releaseFile()
    }
    clearUserTimingTargets()
    if bridgeEngaged { disengage() }
  }

  /// Runs after this bridge's submitted mpv commands have completed, without blocking AppKit.
  var hasUndrainedMPVCommands: Bool {
    activeMPVCommand != nil || !mpvCommandQueue.isEmpty || waitingForMPVEventOverflowRecovery ||
      hasDeferredAudioOutputResolution || synchronousTimingRestoreBarrier.blocksDrain
  }

  var shouldSerializeTimingChanges: Bool { isCarrying || hasUndrainedMPVCommands }

  func whenMPVCommandsDrained(_ completion: @escaping () -> Void) {
    let hasPendingCommands = activeMPVCommand != nil || !mpvCommandQueue.isEmpty ||
      waitingForMPVEventOverflowRecovery || synchronousTimingRestoreBarrier.blocksDrain
    guard hasPendingCommands || hasDeferredAudioOutputResolution else {
      DispatchQueue.main.async(execute: completion)
      return
    }
    mpvCommandDrainCallbacks.append(completion)
    if !hasPendingCommands { runNextMPVCommand() }
  }

  /// Pauses bridge command advancement until libmpv confirms all accepted async requests finished.
  func beginMPVEventQueueOverflowRecovery() -> UInt64? {
    waitingForMPVEventOverflowRecovery = true
    return activeMPVCommand?.replyUserdata
  }

  /// Completes a possibly lost reply only after MPVController's async-request barrier has returned.
  func finishMPVEventQueueOverflowRecovery(for replyUserdata: UInt64?) {
    let activeCommandMatches = replyUserdata != nil &&
      activeMPVCommand?.replyUserdata == replyUserdata
    let shouldResubmit = activeCommandMatches && activeMPVCommandNeedsResubmission &&
      activeMPVCommandSubmissionAttempts < 3
    if activeCommandMatches && activeMPVCommandNeedsResubmission && !shouldResubmit {
      log("mpv kept rejecting an AirPlay command after \(activeMPVCommandSubmissionAttempts) submissions; falling back",
          level: .warning)
    }
    if shouldResubmit { activeMPVCommandNeedsResubmission = false }
    waitingForMPVEventOverflowRecovery = false
    if shouldResubmit {
      submitActiveMPVCommand()
      return
    }
    if let replyUserdata, activeMPVCommand?.replyUserdata == replyUserdata {
      // Timing writes are followed by a final restore during stop/quit. Output switches cannot be
      // trusted without their reply, so take the normal fallback path if that acknowledgement was
      // lost in the overflow.
      mpvCommandCompleted(MPV_ERROR_EVENT_QUEUE_FULL.rawValue, replyUserdata: replyUserdata)
    }
    runNextMPVCommand()
  }

  /// The async API rejected this request because the event queue is full; no command was accepted.
  func mpvCommandSubmissionWasRejected(replyUserdata: UInt64) {
    guard activeMPVCommand?.replyUserdata == replyUserdata else { return }
    activeMPVCommandNeedsResubmission = true
    activeMPVCommandSubmissionAttempts += 1
  }

  /// Releases pending drain callbacks when mpv shuts down outside Reel's normal sequence.
  func playerDidShutDown() {
    pauseStartedAt = nil
    holdGeneration += 1
    holding = false
    stopHoldTimer()
    waitingForMPVAudio = false
    audioStartupClock.reset()
    pendingHoldReason = nil
    lastMPVAudioTime = nil
    resetAudioClockMotionTracking()
    syncTimer?.invalidate()
    syncTimer = nil
    mpvSnapshotTimer?.invalidate()
    mpvSnapshotTimer = nil

    // The MPV_EVENT_SHUTDOWN path cannot safely call replaceItem(with:), because that helper
    // restores timing through libmpv. Tear down the hidden AVPlayer directly so external mpv quit
    // cannot leave its current AirPlay item audible after Reel's player has shut down.
    playheadFeeder.attach(nil)
    loader?.invalidate()
    loader = nil
    itemStatusObservation = nil
    avPlayer?.pause()
    avPlayer?.replaceCurrentItem(with: nil)
    itemSelection = nil
    itemGeneration += 1

    audioDelayCorrection = 0
    holdSpeedApplied = false
    bridgeEngaged = false
    lastAirPlayAudioOutputDisableGeneration = nil
    savedAudioOutput = nil
    savedAudioOutputIntentGeneration = nil
    restoreLocalAudioOutputAfterPendingRawCommand = false
    routeEngagementDeferredForAudioOutputRestore = false
    deferredAudioOutputRestoreAfterRouteCheck = nil
    activeMPVCommand = nil
    synchronousAudioOutputRestoreReplyUserdata = nil
    synchronousTimingRestoreBarrier.cancel()
    speedWrites.reset()
    delayWrites.reset()
    activeMPVCommandNeedsResubmission = false
    activeMPVCommandSubmissionAttempts = 0
    mpvCommandQueue.removeAll()
    waitingForMPVEventOverflowRecovery = false
    lastProcessedDirectAudioOutputGeneration = 0
    notifyMPVCommandQueueDrained()
  }

  /// Hands mpv's speed and delay back to the user and drops the item. Every timing write carries
  /// the file identity so the MPV submission boundary can reject a stale release.
  private func releaseFile(fileTransitionGeneration: UInt64? = nil,
                           playlistEntryID: Int64? = nil,
                           allowsNoActivePlaylistEntry: Bool = false) {
    restoreTimingForCurrentFile(fileTransitionGeneration: fileTransitionGeneration,
                                playlistEntryID: playlistEntryID,
                                allowsNoActivePlaylistEntry: allowsNoActivePlaylistEntry)
    holdGeneration += 1
    holding = false
    stopHoldTimer()
    waitingForMPVAudio = false
    audioStartupClock.reset()
    pendingHoldReason = nil
    lastMPVAudioTime = nil
    resetAudioClockMotionTracking()
    currentFileTimingReleaseStarted = true
    holdSpeedApplied = false
    audioDelayCorrection = 0
    guard itemSelection != nil else { return }
    replaceItem(with: nil)
  }

  /// Enqueues one final timing restore for the current bridge-owned file. Route disconnects and
  /// END_FILE can both request cleanup, so the first request owns the release and later callbacks
  /// must not replace it with an expected value that is already the restore target.
  private func restoreTimingForCurrentFile(fileTransitionGeneration: UInt64? = nil,
                                           playlistEntryID: Int64? = nil,
                                           allowsNoActivePlaylistEntry: Bool = false) {
    let expectedFileTransitionGeneration = fileTransitionGeneration ?? currentFileTransitionGeneration
    let expectedPlaylistEntryID = playlistEntryID ?? currentPlaylistEntryID
    let shouldRestoreTiming = !currentFileTimingReleaseStarted &&
      expectedFileTransitionGeneration != nil && expectedPlaylistEntryID != nil
    let pendingSpeed = pendingMPVPropertyValue(MPVOption.PlaybackControl.speed)
    let pendingDelay = pendingMPVPropertyValue(MPVOption.Audio.audioDelay)
    let timingSpeedNeedsRestore = holdSpeedApplied ||
      pendingSpeed.map { !Self.sameTimingValue($0, userSpeed) } == true
    let timingDelayNeedsRestore = audioDelayCorrection != 0 ||
      pendingDelay.map { !Self.sameTimingValue($0, userAudioDelay) } == true
    let restoreSpeed = shouldRestoreTiming && timingSpeedNeedsRestore
    let restoreDelay = shouldRestoreTiming && timingDelayNeedsRestore
    let expectedSpeed = restoreSpeed
      ? (pendingSpeed ?? Self.holdSpeed) : nil
    let expectedDelay = restoreDelay
      ? (pendingDelay ?? userAudioDelay + audioDelayCorrection)
      : nil
    if player?.mpv != nil, player?.info.state != .shutDown {
      if !currentFileTimingReleaseStarted && timingSpeedNeedsRestore {
        pendingTimingRestoreFileIdentities[MPVOption.PlaybackControl.speed] =
          TimingRestoreFileIdentity(fileTransitionGeneration: expectedFileTransitionGeneration,
                                    playlistEntryID: expectedPlaylistEntryID)
      }
      if !currentFileTimingReleaseStarted && timingDelayNeedsRestore {
        pendingTimingRestoreFileIdentities[MPVOption.Audio.audioDelay] =
          TimingRestoreFileIdentity(fileTransitionGeneration: expectedFileTransitionGeneration,
                                    playlistEntryID: expectedPlaylistEntryID)
      }
      // The bridge owns these values while the corresponding flag/correction is active. A flag
      // can clear before its async write receives a reply, so also restore a pending bridge value
      // unless that request already targets the user's timing. Every transition uses the queue so
      // its final submission can recheck the captured file identity and timing value. Stop/quit
      // pause first and wait for these writes to drain before MPV writes watch-later state.
      if restoreSpeed {
        holdSpeedApplied = false
        enqueueMPVProperty(.doubleProperty(MPVOption.PlaybackControl.speed, userSpeed),
                           coalescingKey: "airplay-speed",
                           expectedCurrentTimingValue: expectedSpeed,
                           expectedFileTransitionGeneration: expectedFileTransitionGeneration,
                           expectedPlaylistEntryID: expectedPlaylistEntryID,
                           allowsNoActivePlaylistEntry: allowsNoActivePlaylistEntry)
      }
      if restoreDelay {
        audioDelayCorrection = 0
        enqueueMPVProperty(.doubleProperty(MPVOption.Audio.audioDelay, userAudioDelay),
                           coalescingKey: "airplay-audio-delay",
                           expectedCurrentTimingValue: expectedDelay,
                           expectedFileTransitionGeneration: expectedFileTransitionGeneration,
                           expectedPlaylistEntryID: expectedPlaylistEntryID,
                           allowsNoActivePlaylistEntry: allowsNoActivePlaylistEntry)
      }
    }
    currentFileTimingReleaseStarted = true
    holdSpeedApplied = false
    audioDelayCorrection = 0
  }

  // MARK: Helpers

  private func log(_ message: String, level: Logger.Level = .debug) {
    player?.log("AirPlay audio: \(message)", level: level)
  }

  private func enqueueMPVCommand(_ command: MPVCommand, arguments: [String?],
                                 requiredForOutput: Bool = false,
                                 coalescingKey: String? = nil,
                                 restoreAudioOutput: String? = nil,
                                 restoreAudioOutputToken: UInt64? = nil,
                                 expectedAudioOutputIntentGeneration: UInt64? = nil) {
    enqueueMPVRequest(MPVCommandRequest(operation: .command(command, arguments),
                                    requiredForOutput: requiredForOutput,
                                    coalescingKey: coalescingKey,
                                    restoreAudioOutput: restoreAudioOutput,
                                    restoreAudioOutputToken: restoreAudioOutputToken,
                                    expectedAudioOutputIntentGeneration:
                                      expectedAudioOutputIntentGeneration))
  }

  private func enqueueMPVProperty(_ operation: MPVCommandRequest.Operation, coalescingKey: String) {
    enqueueMPVProperty(operation, coalescingKey: coalescingKey,
                       expectedCurrentTimingValue: nil,
                       expectedFileTransitionGeneration: nil,
                       expectedPlaylistEntryID: nil,
                       allowsNoActivePlaylistEntry: false)
  }

  private func enqueueMPVProperty(_ operation: MPVCommandRequest.Operation, coalescingKey: String,
                                  expectedCurrentTimingValue: Double?,
                                  expectedFileTransitionGeneration: UInt64? = nil,
                                  expectedPlaylistEntryID: Int64? = nil,
                                  allowsNoActivePlaylistEntry: Bool = false) {
    var request = MPVCommandRequest(operation: operation, requiredForOutput: false,
                                    coalescingKey: coalescingKey,
                                    restoreAudioOutput: nil,
                                    restoreAudioOutputToken: nil,
                                    expectedAudioOutputIntentGeneration: nil)
    request.expectedCurrentTimingValue = expectedCurrentTimingValue
    request.expectedFileTransitionGeneration = expectedFileTransitionGeneration
    request.expectedPlaylistEntryID = expectedPlaylistEntryID
    request.allowsNoActivePlaylistEntry = allowsNoActivePlaylistEntry
    enqueueMPVRequest(request)
  }

  private func pendingMPVPropertyRequest(_ name: String) -> MPVCommandRequest? {
    for request in mpvCommandQueue.reversed() {
      if case let .doubleProperty(requestName, _) = request.operation,
         requestName == name {
        return request
      }
    }
    if let activeMPVCommand,
       case let .doubleProperty(activeName, _) = activeMPVCommand.operation,
       activeName == name {
      return activeMPVCommand
    }
    return nil
  }

  private func pendingMPVPropertyValue(_ name: String) -> Double? {
    if let activeMPVCommand,
       case let .doubleProperty(activeName, value) = activeMPVCommand.operation,
       activeName == name {
      return value
    }
    for request in mpvCommandQueue.reversed() {
      if case let .doubleProperty(requestName, value) = request.operation,
         requestName == name {
        return value
      }
    }
    return nil
  }

  private func enqueueMPVRequest(_ request: MPVCommandRequest) {
    var request = request
    let coalescingKey = request.coalescingKey
    if let coalescingKey {
      if let queuedIndex = mpvCommandQueue.lastIndex(where: { $0.coalescingKey == coalescingKey }) {
        if !mpvCommandQueue[queuedIndex].matches(request) {
          cancelInternalTimingWrite(for: mpvCommandQueue[queuedIndex])
          request.timingWriteToken = recordInternalTimingWrite(for: request.operation)
          mpvCommandQueue[queuedIndex] = request
        }
      } else if activeMPVCommand?.coalescingKey != coalescingKey ||
                  activeMPVCommand.map({ !$0.matches(request) }) == true {
        request.timingWriteToken = recordInternalTimingWrite(for: request.operation)
        mpvCommandQueue.append(request)
      }
    } else {
      request.timingWriteToken = recordInternalTimingWrite(for: request.operation)
      mpvCommandQueue.append(request)
    }
    runNextMPVCommand()
  }

  private func recordInternalTimingWrite(for operation: MPVCommandRequest.Operation,
                                         commandPending: Bool = true) -> UInt64? {
    guard case let .doubleProperty(name, value) = operation else { return nil }
    if name == MPVOption.PlaybackControl.speed {
      return speedWrites.record(value, commandPending: commandPending)
    }
    if name == MPVOption.Audio.audioDelay {
      return delayWrites.record(value, commandPending: commandPending)
    }
    return nil
  }

  private func cancelInternalTimingWrite(for request: MPVCommandRequest) {
    guard case let .doubleProperty(name, _) = request.operation else { return }
    if name == MPVOption.PlaybackControl.speed {
      speedWrites.cancel(request.timingWriteToken)
    } else if name == MPVOption.Audio.audioDelay {
      delayWrites.cancel(request.timingWriteToken)
    }
  }

  private func completeInternalTimingWrite(for request: MPVCommandRequest) {
    guard case let .doubleProperty(name, _) = request.operation else { return }
    if name == MPVOption.PlaybackControl.speed {
      speedWrites.complete(request.timingWriteToken)
    } else if name == MPVOption.Audio.audioDelay {
      delayWrites.complete(request.timingWriteToken)
    }
  }

  private func runNextMPVCommand() {
    guard !waitingForMPVEventOverflowRecovery, activeMPVCommand == nil else { return }
    guard !mpvCommandQueue.isEmpty else {
      refreshSavedAudioOutputFromSnapshot()
      if restoreLocalAudioOutputAfterPendingRawCommand {
        guard let snapshot = player?.mpv?.airPlayPlaybackSnapshot else {
          restoreLocalAudioOutputAfterPendingRawCommand = false
          deferredAudioOutputRestoreAfterRouteCheck = nil
          routeEngagementDeferredForAudioOutputRestore = false
          notifyMPVCommandQueueDrained()
          return
        }
        guard snapshot.pendingRawAudioOutputIntents.isEmpty,
              snapshot.pendingRawAudioOutputCommands.isEmpty else {
          // Keep stop/quit drain callbacks pending until the raw AO write settles and its saved
          // output can be restored or the returning route can reclaim ownership.
          return
        }
        switch routeAudioOwnershipNow() {
        case .available:
          restoreLocalAudioOutputAfterPendingRawCommand = false
        case .waitingForTrack:
          routeEngagementDeferredForAudioOutputRestore = true
        case .unavailable:
          restoreLocalAudioOutputAfterPendingRawCommand = false
          let needsReload = deferredAudioOutputRestoreAfterRouteCheck?.needsReload ?? false
          deferredAudioOutputRestoreAfterRouteCheck = nil
          routeEngagementDeferredForAudioOutputRestore = false
          if let output = snapshot.directAudioOutput ?? savedAudioOutput {
            restoreLatestDirectAudioOutputIfNeeded(output, snapshot: snapshot,
                                                  forceReload: needsReload)
          }
        }
        if activeMPVCommand != nil || !mpvCommandQueue.isEmpty { return }
      }
      if let deferredRestore = deferredAudioOutputRestoreAfterRouteCheck {
        switch routeAudioOwnershipNow() {
        case .available:
          routeEngagementDeferredForAudioOutputRestore = true
          reconcile()
          if bridgeEngaged {
            deferredAudioOutputRestoreAfterRouteCheck = nil
            routeEngagementDeferredForAudioOutputRestore = false
          }
        case .waitingForTrack:
          // Keep the saved output until track metadata decides whether this route can carry it.
          routeEngagementDeferredForAudioOutputRestore = true
        case .unavailable:
          if let snapshot = player?.mpv?.airPlayPlaybackSnapshot {
            if !snapshot.pendingRawAudioOutputIntents.isEmpty ||
                !snapshot.pendingRawAudioOutputCommands.isEmpty {
              restoreLocalAudioOutputAfterPendingRawCommand = true
              // Keep stop/quit drain callbacks pending until the raw AO request settles.
              return
            } else {
              deferredAudioOutputRestoreAfterRouteCheck = nil
              routeEngagementDeferredForAudioOutputRestore = false
              let output = snapshot.directAudioOutput ?? deferredRestore.output
              restoreLatestDirectAudioOutputIfNeeded(output, snapshot: snapshot,
                                                    forceReload: deferredRestore.needsReload)
            }
          } else {
            deferredAudioOutputRestoreAfterRouteCheck = nil
            routeEngagementDeferredForAudioOutputRestore = false
          }
        }
        if activeMPVCommand != nil || !mpvCommandQueue.isEmpty { return }
      }
      if routeEngagementDeferredForAudioOutputRestore {
        switch routeAudioOwnershipNow() {
        case .available:
          routeEngagementDeferredForAudioOutputRestore = false
          reconcile()
          if !bridgeEngaged { routeEngagementDeferredForAudioOutputRestore = true }
        case .waitingForTrack:
          break
        case .unavailable:
          routeEngagementDeferredForAudioOutputRestore = false
        }
        if activeMPVCommand != nil || !mpvCommandQueue.isEmpty { return }
      }
      notifyMPVCommandQueueDrained()
      return
    }
    guard let player, player.info.state != .shutDown, player.mpv != nil else { return }
    var request = mpvCommandQueue.removeFirst()
    nextMPVCommandReplyId &+= 1
    let replyUserdata = MPVController.UserData.airPlayAudioCommandBase &+ nextMPVCommandReplyId
    request.replyUserdata = replyUserdata
    activeMPVCommand = request
    activeMPVCommandNeedsResubmission = false
    activeMPVCommandSubmissionAttempts = 0
    submitActiveMPVCommand()
  }

  private func submitActiveMPVCommand() {
    guard let player, player.info.state != .shutDown,
          let mpv = player.mpv, let request = activeMPVCommand,
          let replyUserdata = request.replyUserdata else { return }
    let operation = request.operation
    if let expectedCurrentTimingValue = request.expectedCurrentTimingValue {
      let snapshot = mpv.airPlayPlaybackSnapshot
      let currentValue: Double?
      switch operation.name {
      case MPVOption.PlaybackControl.speed:
        currentValue = snapshot.speed
      case MPVOption.Audio.audioDelay:
        currentValue = snapshot.audioDelay
      default:
        currentValue = nil
      }
      let ownsCurrentFile = request.expectedFileTransitionGeneration.map {
        $0 == snapshot.fileTransitionGeneration
      } == true && request.expectedPlaylistEntryID.map {
        $0 == snapshot.currentPlaylistEntryID
      } == true
      guard ownsCurrentFile,
            AirPlayTimingRestorePolicy.stillOwnsValue(
              currentValue, expectedValue: expectedCurrentTimingValue) else {
        log("skipping stale timing restore for \(operation.name); mpv already reports a different value",
            level: .verbose)
        cancelInternalTimingWrite(for: request)
        activeMPVCommand = nil
        activeMPVCommandNeedsResubmission = false
        activeMPVCommandSubmissionAttempts = 0
        runNextMPVCommand()
        return
      }
    }
    if operation.name == "ao-reload", request.restoreAudioOutputToken == nil,
       (!bridgeEngaged || !routeMayOwnAudioOutputNow()) {
      // The preceding bridge setter may have been accepted before a disconnect, but its separate
      // reload is no longer needed. Let the queued local restore own the next AO restart.
      log("skipping stale bridge ao-reload after route ownership changed", level: .verbose)
      activeMPVCommand = nil
      activeMPVCommandNeedsResubmission = false
      activeMPVCommandSubmissionAttempts = 0
      runNextMPVCommand()
      return
    }
    if let restoreToken = request.restoreAudioOutputToken,
       let expectedGeneration = request.expectedAudioOutputIntentGeneration {
      let snapshot = mpv.airPlayPlaybackSnapshot
      if routeMayOwnAudioOutputNow() {
        if let output = request.restoreAudioOutput {
          deferredAudioOutputRestoreAfterRouteCheck = (
            output: output, generation: expectedGeneration,
            needsReload: !operation.isAudioOutputSetter)
        }
        routeEngagementDeferredForAudioOutputRestore = true
        log("deferring queued local-output restore while AirPlay ownership is active or pending",
            level: .verbose)
        mpvCommandQueue.removeAll { $0.restoreAudioOutputToken == restoreToken }
        activeMPVCommand = nil
        activeMPVCommandNeedsResubmission = false
        activeMPVCommandSubmissionAttempts = 0
        runNextMPVCommand()
        return
      }
      let hasNewerKnownIntent = snapshot.audioOutputIntentGeneration != expectedGeneration &&
        (snapshot.directAudioOutput != nil ||
          !snapshot.pendingRawAudioOutputIntents.isEmpty ||
          !snapshot.pendingRawAudioOutputCommands.isEmpty)
      if operation.isAudioOutputSetter && hasNewerKnownIntent {
        log("skipping queued audio-output restore; a newer direct AO intent is pending",
            level: .verbose)
        mpvCommandQueue.removeAll { $0.restoreAudioOutputToken == restoreToken }
        if deferredAudioOutputRestoreAfterRouteCheck?.generation == expectedGeneration {
          deferredAudioOutputRestoreAfterRouteCheck = nil
        }
        activeMPVCommand = nil
        activeMPVCommandNeedsResubmission = false
        activeMPVCommandSubmissionAttempts = 0
        runNextMPVCommand()
        return
      }
    }
    if operation.isAudioOutputSetter || request.restoreAudioOutput != nil ||
        operation.name == "ao-reload" {
      let snapshot = mpv.airPlayPlaybackSnapshot
      if operation.isAudioOutputSetter {
        activeMPVCommand?.audioOutputBeforeSubmission = snapshot.audioOutput
        activeMPVCommand?.capturedAudioOutputBeforeSubmission = true
      }
      activeMPVCommand?.audioOutputIntentGenerationBeforeSubmission =
        request.expectedAudioOutputIntentGeneration ?? snapshot.audioOutputIntentGeneration
    }
    let routeOwnershipGeneration: UInt64? =
      operation.isAudioOutputSetter || operation.name == "ao-reload"
        ? mpv.airPlayRouteOwnershipGenerationSnapshot() : nil
    activeMPVCommand?.routeOwnershipGenerationBeforeSubmission = routeOwnershipGeneration
    // Once the restore setter was accepted, its paired reload must finish unless a live route
    // took ownership. A newer AO intent can safely be the value reloaded; fencing this second
    // half could strand mpv after the setter already switched its configured output.
    let submissionIntentGeneration: UInt64? =
      request.restoreAudioOutputToken != nil && !operation.isAudioOutputSetter
        ? nil : request.expectedAudioOutputIntentGeneration
    let timingOwnership = timingOwnership(for: request)
    mpv.submitAirPlayCommand(
      ifAudioOutputIntentGeneration: submissionIntentGeneration,
      ifRouteOwnershipGeneration: routeOwnershipGeneration,
      ifTimingOwnership: timingOwnership,
      submission: {
        switch operation {
        case .command(let command, let arguments):
          return mpv.asyncCommand(command, args: arguments, checkError: false,
                                  replyUserdata: replyUserdata, level: .verbose)
        case .stringProperty(let name, let value):
          return mpv.setStringAsync(name, value, replyUserdata: replyUserdata, level: .verbose)
        case .doubleProperty(let name, let value):
          return mpv.setDoubleAsync(name, value, replyUserdata: replyUserdata, level: .verbose)
        }
      }, completion: { [weak self] result, wasSuperseded in
        guard let self else { return }
        if wasSuperseded {
          self.mpvCommandSubmissionWasSuperseded(replyUserdata: replyUserdata)
        } else if result == MPV_ERROR_EVENT_QUEUE_FULL.rawValue {
          self.mpvCommandSubmissionWasRejected(replyUserdata: replyUserdata)
        } else if result < 0 {
          self.mpvCommandCompleted(result, replyUserdata: replyUserdata)
        }
      })
  }

  private func timingOwnership(for request: MPVCommandRequest) -> MPVAirPlayTimingOwnership? {
    guard let generation = request.expectedFileTransitionGeneration,
          let playlistEntryID = request.expectedPlaylistEntryID,
          case let .doubleProperty(property, _) = request.operation,
          property == MPVOption.PlaybackControl.speed || property == MPVOption.Audio.audioDelay
    else { return nil }
    return MPVAirPlayTimingOwnership(fileTransitionGeneration: generation,
                                     playlistEntryID: playlistEntryID,
                                     property: property,
                                     expectedValue: request.expectedCurrentTimingValue,
                                     allowsNoActivePlaylistEntry: request.allowsNoActivePlaylistEntry)
  }

  /// Retire a bridge write that became stale between main-thread preflight and queue submission.
  /// It was never sent to mpv, so it must not enter the synchronous failure fallback.
  private func mpvCommandSubmissionWasSuperseded(replyUserdata: UInt64) {
    guard let request = activeMPVCommand, request.replyUserdata == replyUserdata else { return }
    let routeOwnershipChanged = request.routeOwnershipGenerationBeforeSubmission.map {
      player?.mpv?.airPlayRouteOwnershipGenerationSnapshot() != $0
    } ?? false
    if let restoreToken = request.restoreAudioOutputToken {
      if routeOwnershipChanged, let output = request.restoreAudioOutput {
        deferAudioOutputRestoreAfterRouteChange(
          output, basedOn: request, needsReload: !request.operation.isAudioOutputSetter)
      }
      mpvCommandQueue.removeAll { $0.restoreAudioOutputToken == restoreToken }
    }
    if routeOwnershipChanged, request.restoreAudioOutputToken == nil,
       bridgeEngaged, routeMayOwnAudioOutputNow(),
       let mpv = player?.mpv,
       request.expectedAudioOutputIntentGeneration ==
         mpv.airPlayPlaybackSnapshot.audioOutputIntentGeneration {
      // The route still needs this command, but its main-thread preflight went stale. Rebase it
      // ahead of later queued work so a paired AO setter cannot be overtaken by its reload.
      activeMPVCommand?.routeOwnershipGenerationBeforeSubmission = nil
      activeMPVCommand?.audioOutputIntentGenerationBeforeSubmission = nil
      activeMPVCommand?.audioOutputBeforeSubmission = nil
      activeMPVCommand?.capturedAudioOutputBeforeSubmission = false
      submitActiveMPVCommand()
      return
    }
    if routeOwnershipChanged, request.restoreAudioOutputToken == nil,
       request.operation.audioOutputTarget == "null",
       mpvCommandQueue.first?.operation.name == "ao-reload",
       mpvCommandQueue.first?.restoreAudioOutputToken == nil {
      // This setter never reached mpv. Its immediately paired reload is stale too; leave the
      // route-disconnect restore pair to restore and reload the local output in order.
      mpvCommandQueue.removeFirst()
    }
    if request.expectedFileTransitionGeneration != nil {
      log("skipping stale timing restore at MPV submission", level: .verbose)
      cancelInternalTimingWrite(for: request)
      activeMPVCommand = nil
      activeMPVCommandNeedsResubmission = false
      activeMPVCommandSubmissionAttempts = 0
      runNextMPVCommand()
      return
    }
    log("skipping stale bridge AO write; a newer AO intent arrived before submission",
        level: .verbose)
    activeMPVCommand = nil
    activeMPVCommandNeedsResubmission = false
    activeMPVCommandSubmissionAttempts = 0
    runNextMPVCommand()
  }

  private func deferAudioOutputRestoreAfterRouteChange(
    _ output: String, basedOn request: MPVCommandRequest, needsReload: Bool
  ) {
    let intentGeneration = player?.mpv?.airPlayPlaybackSnapshot.audioOutputIntentGeneration ??
      request.expectedAudioOutputIntentGeneration ?? 0
    deferredAudioOutputRestoreAfterRouteCheck = (
      output: output, generation: intentGeneration, needsReload: needsReload)
    routeEngagementDeferredForAudioOutputRestore = true
  }

  private func notifyMPVCommandQueueDrained() {
    guard !waitingForMPVEventOverflowRecovery,
          activeMPVCommand == nil, mpvCommandQueue.isEmpty,
          !synchronousTimingRestoreBarrier.blocksDrain,
          !mpvCommandDrainCallbacks.isEmpty else { return }
    let callbacks = mpvCommandDrainCallbacks
    mpvCommandDrainCallbacks.removeAll()
    DispatchQueue.main.async { callbacks.forEach { $0() } }
  }

  /// Completes one serialized libmpv command. Called on the main thread by MPVController.
  func mpvCommandCompleted(_ result: Int32, replyUserdata: UInt64) {
    guard let request = activeMPVCommand, request.replyUserdata == replyUserdata else { return }
    if result >= 0,
       request.capturedAudioOutputBeforeSubmission,
       let intentGeneration = request.audioOutputIntentGenerationBeforeSubmission,
       let output = request.operation.audioOutputTarget {
      player?.mpv?.confirmAirPlayAudioOutput(
        output, ifStillOutput: request.audioOutputBeforeSubmission,
        andNoNewerIntentThan: intentGeneration)
    }
    let timingWriteWasRejected = activeMPVCommandNeedsResubmission
    let failedWriteMayHaveApplied =
      result == MPV_ERROR_EVENT_QUEUE_FULL.rawValue && !timingWriteWasRejected
    let timingWriteMarkerWasCancelled = timingWriteWasRejected ||
      (result < 0 && !failedWriteMayHaveApplied)
    if timingWriteMarkerWasCancelled {
      cancelInternalTimingWrite(for: request)
    } else if result >= 0 || failedWriteMayHaveApplied {
      completeInternalTimingWrite(for: request)
    }
    let hasNewerTimingWriteQueued = mpvCommandQueue.contains {
      $0.operation.name == request.operation.name
    }
    if let timingRestore = request.operation.timingRestorePlan(
      afterFailure: result,
      canRestoreSynchronously: request.expectedCurrentTimingValue != nil,
      hasNewerWriteQueued: hasNewerTimingWriteQueued) {
      guard synchronousTimingRestoreBarrier.begin(replyUserdata: replyUserdata) else { return }
      if timingWriteMarkerWasCancelled || request.timingWriteToken == nil {
        var timingRequest = request
        timingRequest.timingWriteToken = recordInternalTimingWrite(
          for: .doubleProperty(timingRestore.property, timingRestore.value),
          commandPending: false)
        activeMPVCommand = timingRequest
      }
      log("async timing restore failed; applying it synchronously off AppKit",
          level: .warning)
      guard let timingOwnership = timingOwnership(for: request) else {
        log("skipping terminal timing fallback without file ownership", level: .verbose)
        cancelInternalTimingWrite(for: request)
        finishSynchronousTimingRestore(0, wasSuperseded: true,
                                       replyUserdata: replyUserdata)
        return
      }
      guard let mpv = player?.mpv else {
        finishSynchronousTimingRestore(MPV_ERROR_UNINITIALIZED.rawValue,
                                       wasSuperseded: false,
                                       replyUserdata: replyUserdata)
        return
      }
      mpv.restoreAirPlayTimingValue(timingRestore.property, value: timingRestore.value,
                                    ifStillOwned: timingOwnership) {
        [weak self] restoreResult, wasSuperseded in
        self?.finishSynchronousTimingRestore(restoreResult, wasSuperseded: wasSuperseded,
                                             replyUserdata: replyUserdata)
      }
      return
    }
    if result < 0, !failedWriteMayHaveApplied {
      cancelInternalTimingWrite(for: request)
    }
    if result < 0, let output = request.restoreAudioOutput {
      guard synchronousAudioOutputRestoreReplyUserdata != replyUserdata else { return }
      guard let intentGeneration = request.audioOutputIntentGenerationBeforeSubmission else {
        finishSynchronousAudioOutputRestore(0, wasSuperseded: true, output: output,
                                            replyUserdata: replyUserdata)
        return
      }
      synchronousAudioOutputRestoreReplyUserdata = replyUserdata
      log("async audio-output restore failed; retrying \(output) synchronously off the main thread",
          level: .warning)
      let routeGeneration = request.routeOwnershipGenerationBeforeSubmission ??
        player?.mpv?.airPlayRouteOwnershipGenerationSnapshot() ?? 0
      player?.mpv.restoreAirPlayAudioOutput(
        output, ifNoNewerIntentThan: intentGeneration,
        ifRouteOwnershipUnchangedSince: routeGeneration) {
        [weak self] restoreResult, wasSuperseded in
        self?.finishSynchronousAudioOutputRestore(restoreResult, wasSuperseded: wasSuperseded,
                                                 output: output, replyUserdata: replyUserdata)
      }
      return
    }
    activeMPVCommand = nil
    activeMPVCommandNeedsResubmission = false
    activeMPVCommandSubmissionAttempts = 0
    if result < 0 {
      let error = String(cString: mpv_error_string(result))
      log("mpv operation \(request.operation.name) failed: \(error)", level: .warning)
      if request.requiredForOutput {
        failForFile("mpv could not switch audio output: \(error)")
      } else if result == MPV_ERROR_EVENT_QUEUE_FULL.rawValue {
        failForFile("mpv lost confirmation for \(request.operation.name) during an event queue overflow")
      }
    }
    runNextMPVCommand()
  }

  /// Keeps the command queue pending until a final speed or delay write has been restored off AppKit.
  private func finishSynchronousTimingRestore(_ result: Int32, wasSuperseded: Bool,
                                             replyUserdata: UInt64) {
    guard synchronousTimingRestoreBarrier.finish(replyUserdata: replyUserdata) else { return }
    guard let request = activeMPVCommand, request.replyUserdata == replyUserdata else {
      runNextMPVCommand()
      return
    }
    if wasSuperseded {
      cancelInternalTimingWrite(for: request)
      log("skipped stale timing fallback after file ownership changed", level: .verbose)
    } else if result >= 0 {
      completeInternalTimingWrite(for: request)
    } else if player?.mpv?.hasObservedShutdownEvent != true {
      let error = String(cString: mpv_error_string(result))
      log("could not restore timing property: \(error)", level: .error)
    }
    activeMPVCommand = nil
    activeMPVCommandNeedsResubmission = false
    activeMPVCommandSubmissionAttempts = 0
    runNextMPVCommand()
  }

  /// Finishes the fail-safe restore before stop/quit drain callbacks are allowed to proceed.
  private func finishSynchronousAudioOutputRestore(_ result: Int32, wasSuperseded: Bool,
                                                   output: String,
                                                   replyUserdata: UInt64) {
    guard let request = activeMPVCommand, request.replyUserdata == replyUserdata else { return }
    synchronousAudioOutputRestoreReplyUserdata = nil
    let routeOwnershipChanged = request.routeOwnershipGenerationBeforeSubmission.map {
      player?.mpv?.airPlayRouteOwnershipGenerationSnapshot() != $0
    } ?? false
    if routeOwnershipChanged, routeMayOwnAudioOutputNow() {
      // Route ownership changed while fallback ran or before its callback reached main. Do not
      // let a stale local restore error mark this file unbridgeable; preserve its reload debt and
      // resolve the current route/track state below.
      deferAudioOutputRestoreAfterRouteChange(output, basedOn: request, needsReload: true)
      log("deferring synchronous local-output fallback after route ownership changed",
          level: .verbose)
    } else if wasSuperseded {
      if routeOwnershipChanged {
        // An inactive/unsupported route requeues the complete restore after ownership is checked.
        deferAudioOutputRestoreAfterRouteChange(output, basedOn: request, needsReload: true)
        log("deferring synchronous local-output fallback after route ownership changed",
            level: .verbose)
      } else {
        log("skipped synchronous audio-output restore to \(output); a newer AO intent took over",
            level: .verbose)
      }
    } else if player?.mpv.hasObservedShutdownEvent != true {
      if result < 0 {
        if routeMayOwnAudioOutputNow() {
          // Track/file ownership can change before a main-thread callback observes its epoch.
          // Give the current supported or pending route a chance before marking the file failed.
          deferAudioOutputRestoreAfterRouteChange(output, basedOn: request, needsReload: true)
          log("deferring failed local-output fallback while the AirPlay route can own audio",
              level: .verbose)
        } else {
          let error = String(cString: mpv_error_string(result))
          log("could not restore mpv audio output to \(output): \(error)", level: .error)
          bridgeFailedForFile = true
          if let player { showOutputRestoreFailureNotice(to: player) }
        }
      } else {
        log("synchronous fallback restored mpv audio output to \(output)", level: .warning)
      }
    }
    // The synchronous fallback already applies both the saved output and ao-reload. Remove only
    // that disengage pair; later route transitions may have queued a restore to the same device.
    if let restoreToken = activeMPVCommand?.restoreAudioOutputToken {
      mpvCommandQueue.removeAll { $0.restoreAudioOutputToken == restoreToken }
    }
    activeMPVCommand = nil
    synchronousAudioOutputRestoreReplyUserdata = nil
    activeMPVCommandNeedsResubmission = false
    activeMPVCommandSubmissionAttempts = 0
    runNextMPVCommand()
  }

  /// Retry reconciliation after mpv publishes the metadata needed to select the audio stream.
  func playbackSnapshotChanged() {
    guard let mpv = player?.mpv else { return }
    let snapshot = mpv.airPlayPlaybackSnapshot
    guard snapshot.audioOutputChangesInFlight == 0 else { return }
    let directAudioOutput = rememberLatestDirectAudioOutput(from: snapshot)
    if restoreLocalAudioOutputAfterPendingRawCommand,
       snapshot.pendingRawAudioOutputIntents.isEmpty,
       snapshot.pendingRawAudioOutputCommands.isEmpty {
      let output = snapshot.directAudioOutput ?? savedAudioOutput
      if let output {
        if snapshot.directAudioOutput != nil {
          savedAudioOutput = output
          savedAudioOutputIntentGeneration = snapshot.audioOutputIntentGeneration
        }
        switch routeAudioOwnershipNow() {
        case .available:
          // Let the route own audio without briefly restoring mpv immediately before engage.
          restoreLocalAudioOutputAfterPendingRawCommand = false
          deferredAudioOutputRestoreAfterRouteCheck = nil
          routeEngagementDeferredForAudioOutputRestore = false
        case .waitingForTrack:
          // Keep the decision pending until metadata confirms support or requires local fallback.
          break
        case .unavailable:
          restoreLocalAudioOutputAfterPendingRawCommand = false
          let needsReload = deferredAudioOutputRestoreAfterRouteCheck?.needsReload ?? false
          deferredAudioOutputRestoreAfterRouteCheck = nil
          routeEngagementDeferredForAudioOutputRestore = false
          restoreLatestDirectAudioOutputIfNeeded(output, snapshot: snapshot,
                                                forceReload: needsReload)
        }
      }
    }
    refreshSavedAudioOutputFromSnapshot()
    if let directAudioOutput, directAudioOutput != "null" {
      if routeActive && bridgeEngaged {
        lastAirPlayAudioOutputDisableGeneration = snapshot.audioOutputGeneration
        enqueueMPVCommand(.set, arguments: [MPVOption.Audio.ao, "null"], requiredForOutput: true,
                          expectedAudioOutputIntentGeneration:
                            snapshot.audioOutputIntentGeneration)
        enqueueMPVCommand(MPVCommand("ao-reload"), arguments: [], requiredForOutput: true,
                          expectedAudioOutputIntentGeneration:
                            snapshot.audioOutputIntentGeneration)
        log("reasserting AirPlay output after local audio-output change", level: .verbose)
      }
    }
    if !routeActive,
       snapshot.pendingRawAudioOutputIntents.isEmpty,
       snapshot.pendingRawAudioOutputCommands.isEmpty,
       let directAudioOutput = snapshot.directAudioOutput {
      restoreLatestDirectAudioOutputIfNeeded(directAudioOutput, snapshot: snapshot)
    }
    if hasDeferredAudioOutputResolution {
      runNextMPVCommand()
    }
    guard routeActive else { return }
    if bridgeEngaged { keepMPVAudioOutputDisabled() }
    if itemSelection == nil { reconcile() }
  }

  /// Reconciles the event-fed AO value with the route and saved output. Async raw AO commands are
  /// resolved separately from their reply-bearing completion and a fresh AO readback.
  func audioOutputObservationChanged(_ output: String?, generation: UInt64) {
    playbackSnapshotChanged()
  }

  /// Captures a completed direct AO write before a delayed route callback can replace its restore value.
  private func rememberLatestDirectAudioOutput(from snapshot: MPVAirPlaySnapshot) -> String? {
    guard snapshot.directAudioOutputGeneration > lastProcessedDirectAudioOutputGeneration else {
      return nil
    }
    lastProcessedDirectAudioOutputGeneration = snapshot.directAudioOutputGeneration
    guard snapshot.pendingRawAudioOutputIntents.isEmpty,
          snapshot.pendingRawAudioOutputCommands.isEmpty else { return nil }
    guard let audioOutput = snapshot.directAudioOutput else {
      // Preserve the prior target as a fallback until an AO event resolves the accepted selector.
      return nil
    }
    savedAudioOutput = audioOutput
    savedAudioOutputIntentGeneration = snapshot.audioOutputIntentGeneration
    return audioOutput
  }

  /// A direct write can finish after disconnect queued its restore. Append the newer intent after
  /// that pair, or repair the output if the older pair has already completed.
  private func restoreLatestDirectAudioOutputIfNeeded(_ audioOutput: String,
                                                       snapshot: MPVAirPlaySnapshot,
                                                       forceReload: Bool = false) {
    let pendingRestores = pendingAudioOutputRestoreValues()
    // The restore queue is ordered. An earlier matching entry cannot satisfy a newer intent when
    // a different restore is still queued behind it.
    guard AirPlayAudioOutputRestorePolicy.shouldEnqueue(
      audioOutput, pendingOutputs: pendingRestores, observedOutput: snapshot.audioOutput,
      forceReload: forceReload) else { return }
    enqueueAudioOutputRestore(audioOutput, intentGeneration: snapshot.audioOutputIntentGeneration)
  }

  private func pendingAudioOutputRestoreValues() -> [String] {
    var outputs: [String] = []
    if let activeMPVCommand, activeMPVCommand.operation.isAudioOutputSetter,
       let output = activeMPVCommand.restoreAudioOutput {
      outputs.append(output)
    }
    outputs.append(contentsOf: mpvCommandQueue.compactMap { request in
      guard request.operation.isAudioOutputSetter else { return nil }
      return request.restoreAudioOutput
    })
    return outputs
  }

  private func hasPendingAudioOutputRestore() -> Bool {
    activeMPVCommand?.restoreAudioOutputToken != nil ||
      mpvCommandQueue.contains { $0.restoreAudioOutputToken != nil }
  }

  private func routeAudioOwnershipNow() -> RouteAudioOwnership {
    guard routeActive, !bridgeFailedForFile, !stoppingOrQuitting,
          let player, player.info.state.active, player.mpv != nil else {
      return observeRouteAudioOwnership(.unavailable)
    }
    switch player.info.state {
    case .loading, .starting:
      // File metadata decides whether the selected route can carry this track. Keep the local
      // output restore pending until FILE_LOADED rather than briefly enabling Mac audio.
      return observeRouteAudioOwnership(.waitingForTrack)
    case .loaded, .playing, .paused:
      break
    default:
      return observeRouteAudioOwnership(.unavailable)
    }
    let ownership: RouteAudioOwnership
    switch audioSelection() {
    case .supported(_), .noAudio:
      ownership = .available
    case .pending:
      ownership = .waitingForTrack
    case .unsupported:
      ownership = .unavailable
    }
    return observeRouteAudioOwnership(ownership)
  }

  private func observeRouteAudioOwnership(_ ownership: RouteAudioOwnership) -> RouteAudioOwnership {
    guard ownership != lastObservedRouteAudioOwnership else { return ownership }
    lastObservedRouteAudioOwnership = ownership
    player?.mpv?.advanceAirPlayRouteOwnershipGeneration()
    return ownership
  }

  private func routeMayOwnAudioOutputNow() -> Bool {
    routeAudioOwnershipNow() != .unavailable
  }

  private func enqueueAudioOutputRestore(_ output: String, intentGeneration: UInt64) {
    nextAudioOutputRestoreToken &+= 1
    let restoreToken = nextAudioOutputRestoreToken
    enqueueMPVCommand(.set, arguments: [MPVOption.Audio.ao, output], requiredForOutput: true,
                      restoreAudioOutput: output, restoreAudioOutputToken: restoreToken,
                      expectedAudioOutputIntentGeneration: intentGeneration)
    enqueueMPVCommand(MPVCommand("ao-reload"), arguments: [], requiredForOutput: true,
                      restoreAudioOutput: output, restoreAudioOutputToken: restoreToken,
                      expectedAudioOutputIntentGeneration: intentGeneration)
  }

  /// A synchronous preference or plugin write can race the queued engage command after its
  /// snapshot check. Save that newly selected local output, then reassert bridge ownership.
  private func keepMPVAudioOutputDisabled() {
    guard bridgeEngaged, let mpv = player?.mpv else { return }
    let snapshot = mpv.airPlayPlaybackSnapshot
    // Let an accepted direct AO choice finish and be saved before reasserting bridge ownership.
    // Otherwise the bridge's `null` write can become the command's readback and erase that choice.
    guard snapshot.pendingRawAudioOutputIntents.isEmpty,
          snapshot.pendingRawAudioOutputCommands.isEmpty else { return }
    guard snapshot.audioOutputChangesInFlight == 0,
          let audioOutput = snapshot.audioOutput, audioOutput != "null",
          !(snapshot.directAudioOutput == audioOutput &&
            snapshot.directAudioOutputGeneration <= lastProcessedDirectAudioOutputGeneration),
          lastAirPlayAudioOutputDisableGeneration != snapshot.audioOutputGeneration else { return }
    // An accepted async selector invalidates the previous explicit target. While a route restore
    // is still pending, do not mistake that bridge-owned value for the newly selected output.
    if snapshot.pendingRawAudioOutputIntents.isEmpty,
       snapshot.pendingRawAudioOutputCommands.isEmpty,
       snapshot.directAudioOutput == nil,
       !pendingAudioOutputRestoreValues().contains(audioOutput) {
      savedAudioOutput = audioOutput
      savedAudioOutputIntentGeneration = snapshot.audioOutputIntentGeneration
    }
    lastAirPlayAudioOutputDisableGeneration = snapshot.audioOutputGeneration
    enqueueMPVCommand(.set, arguments: [MPVOption.Audio.ao, "null"], requiredForOutput: true,
                      expectedAudioOutputIntentGeneration: snapshot.audioOutputIntentGeneration)
    enqueueMPVCommand(MPVCommand("ao-reload"), arguments: [], requiredForOutput: true,
                      expectedAudioOutputIntentGeneration: snapshot.audioOutputIntentGeneration)
    log("reasserting AirPlay output after local audio-output change", level: .verbose)
  }

  /// Refresh the local-output cache only after all route restores have settled. While a restore is
  /// pending, an event-fed `ao = null` may still be the bridge's disabled output.
  private func refreshSavedAudioOutputFromSnapshot() {
    guard !bridgeEngaged,
          activeMPVCommand?.restoreAudioOutputToken == nil,
          !mpvCommandQueue.contains(where: { $0.restoreAudioOutputToken != nil }),
          let snapshot = player?.mpv?.airPlayPlaybackSnapshot,
          let audioOutput = snapshot.audioOutput else { return }
    guard snapshot.pendingRawAudioOutputIntents.isEmpty,
          snapshot.pendingRawAudioOutputCommands.isEmpty else { return }
    if let directAudioOutput = snapshot.directAudioOutput {
      guard directAudioOutput == audioOutput else { return }
      savedAudioOutput = audioOutput
      savedAudioOutputIntentGeneration = snapshot.audioOutputIntentGeneration
    } else if audioOutput != "null" || savedAudioOutput == nil {
      savedAudioOutput = audioOutput
      savedAudioOutputIntentGeneration = snapshot.audioOutputIntentGeneration
    }
  }

}

extension AirPlayAudioBridge: AVRoutePickerViewDelegate {
  func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
    // Leave AVKit's popover-close notification before querying its route/player state. Calling
    // back into AVPlayer here can deadlock the main thread against its media queue.
    DispatchQueue.main.async { [weak self] in self?.routeMayHaveChanged() }
    // The route can settle a moment after the list closes.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.routeMayHaveChanged() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      guard let self else { return }
      self.routeMayHaveChanged()
      self.retryFailedBridgeIfNeeded(trigger: "route picker close")
    }
  }
}
