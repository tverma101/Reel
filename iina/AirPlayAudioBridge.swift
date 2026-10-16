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

  init(source: String, streamIndex: Int, mediaOrigin: Double?, frameCount: Int64,
       onFailure: @escaping () -> Void) {
    self.source = source
    self.streamIndex = streamIndex
    self.mediaOrigin = mediaOrigin
    self.frameCount = min(max(frameCount, 1), Self.maximumFrames)
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
      dataRequest.respond(with: data[skip..<(skip + length)])
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

  func attach(_ loader: AirPlayPCMResourceLoader?) {
    lock.lock(); defer { lock.unlock() }
    self.loader = loader
  }

  func update(_ time: CMTime) {
    let seconds = time.seconds
    guard seconds.isFinite else { return }
    lock.lock()
    let loader = self.loader
    lock.unlock()
    loader?.setPlayhead(seconds: seconds)
  }
}

struct AirPlayTimingRestorePlan: Equatable {
  let property: String
  let value: Double

  static func afterFailure(property: String, value: Double, result: Int32,
                           whileStoppingOrQuitting: Bool,
                           hasNewerWriteQueued: Bool = false) -> Self? {
    guard whileStoppingOrQuitting, result < 0, value.isFinite,
          !hasNewerWriteQueued,
          property == "speed" || property == "audio-delay" else { return nil }
    return Self(property: property, value: value)
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
      !$0.commandPending && abs($0.value - value) >= 1e-9
    }
    guard let matchedIndex = writes.lastIndex(where: { abs($0.value - value) < 1e-9 }) else {
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

final class AirPlayAudioBridge: NSObject {
  /// Runs the bridge on the Mac's own output, so sync can be checked without a speaker.
  private static let localTestKey = "ReelAirPlayBridgeLocalTest"
  /// Seconds to subtract from AVPlayer's clock, for a receiver whose latency it does not include.
  private static let latencyKey = "ReelAirPlayBridgeLatencyCompensation"
  /// mpv's slowest speed. The picture waits at it, without pausing, while the speaker starts.
  private static let holdSpeed = 0.01
  private static let holdTimeout: TimeInterval = 10
  /// A speaker that claims to play but never advances the item clock is not a usable route.
  private static let speakerClockStartupTimeout: TimeInterval = 4
  private static let speakerClockStallTimeout: TimeInterval = 1
  private static let correctionThreshold = 0.045
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
                             whileStoppingOrQuitting: Bool,
                             hasNewerWriteQueued: Bool) -> AirPlayTimingRestorePlan? {
        guard case let .doubleProperty(name, value) = self else { return nil }
        return AirPlayTimingRestorePlan.afterFailure(
          property: name, value: value, result: result,
          whileStoppingOrQuitting: whileStoppingOrQuitting,
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
    var replyUserdata: UInt64? = nil
    /// Used to publish the confirmed AO value if the cached output is still the pre-submit value
    /// and no newer direct intent superseded it.
    var audioOutputBeforeSubmission: String? = nil
    var capturedAudioOutputBeforeSubmission = false
    var audioOutputIntentGenerationBeforeSubmission: UInt64? = nil
    /// Route epoch checked by background AO submission and queue-pressure recovery.
    var routeOwnershipGenerationBeforeSubmission: UInt64? = nil
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
  private var routeDescription = ""
  /// This file's audio could not be bridged, so mpv plays it on the Mac until the next file.
  private var bridgeFailedForFile = false
  /// Whether Reel currently owns audio through the AVPlayer bridge.
  private var bridgeEngaged = false
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
  private var speakerClock = AirPlaySpeakerClock()

  /// mpv's own audio output is off; the hidden AVPlayer is what can be heard.
  var isEngaged: Bool { bridgeEngaged }

  /// The hidden AVPlayer is playing the current file's audio.
  var isCarrying: Bool { isEngaged && itemSelection != nil }

  /// The part of mpv's audio delay that keeps the picture on the speaker's clock.
  private(set) var audioDelayCorrection = 0.0

  /// The media time of the sound being heard.
  var audiblePosition: Double? {
    guard isCarrying, let avPlayer, let seconds = Self.seconds(avPlayer.currentTime()) else { return nil }
    return max(0, seconds - latencyCompensation)
  }

  private var userSpeed: Double { player?.info.playSpeed ?? 1 }
  private var userAudioDelay: Double { player?.info.audioDelay ?? 0 }

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
    if let routePicker { return routePicker }
    let picker = AVRoutePickerView()
    picker.isRoutePickerButtonBordered = false
    // Bound to Reel's own player, so a choice here moves only Reel's audio.
    picker.player = makePlayerIfNeeded()
    picker.delegate = self
    picker.toolTip = NSLocalizedString("osc_toolbar.airplay", comment: "Route Reel audio to an AirPlay speaker")
    picker.setAccessibilityLabel(picker.toolTip)
    routePicker = picker
    routeMayHaveChanged()
    return picker
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
      forInterval: CMTime(value: 1, timescale: 4), queue: playheadQueue
    ) { [weak feeder] time in
      feeder?.update(time)
    }
    self.avPlayer = avPlayer
    return avPlayer
  }

  /// The player's output context exists once a picker is bound to it. These notifications are
  /// private to AVFoundation; the picker's own callbacks cover a release that renames them.
  private func observeOutputContext() {
    guard let avPlayer, avPlayer.responds(to: NSSelectorFromString("outputContext")),
          let context = avPlayer.value(forKey: "outputContext") as? NSObject,
          context !== observedContext else { return }
    routeObservers.forEach { NotificationCenter.default.removeObserver($0) }
    observedContext = context
    routeObservers = ["AVOutputContextOutputDevicesDidChangeNotification",
                      "AVOutputContextOutputDeviceDidChangeNotification"].map { name in
      NotificationCenter.default.addObserver(forName: Notification.Name(name), object: context,
                                             queue: .main) { [weak self] _ in
        self?.routeMayHaveChanged()
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
    var buffered = "unknown"
    if let avPlayer, avPlayer.responds(to: NSSelectorFromString("_isBufferedAirPlayActive")) {
      buffered = "\(avPlayer.value(forKey: "isBufferedAirPlayActive") ?? "nil")"
    }
    let description = "picker AirPlay \(airPlayActive), buffered AirPlay \(buffered), devices [\(details.joined(separator: "; "))]"
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
    if active && !wasActive {
      // A new choice deserves a new attempt.
      bridgeFailedForFile = false
    }
    guard let player, player.info.state.loaded else {
      reconcile()
      return
    }
    if active {
      // This reports the picker selection, not successful audio playback; engage queues async MPV work.
      let name = routeNames.isEmpty ? NSLocalizedString("osc_toolbar.airplay_output.speaker", value: "the AirPlay speaker",
                                                        comment: "Unnamed AirPlay speaker")
                                    : ListFormatter.localizedString(byJoining: routeNames)
      player.sendOSD(.custom(String(format: NSLocalizedString("osc_toolbar.airplay_output.selected",
                                                              value: "AirPlay speaker selected: %@",
                                                              comment: "The AirPlay speaker selected in the picker"), name)))
    } else if wasActive {
      player.sendOSD(.custom(NSLocalizedString("osc_toolbar.airplay_output.disconnected",
                                               value: "AirPlay speaker disconnected",
                                               comment: "The selected AirPlay speaker disconnected")))
    }
    reconcile()
  }

  // MARK: Engaging

  /// Brings the bridge in line with the route, the file and its audio track.
  private func reconcile() {
    guard !stoppingOrQuitting, let player, player.info.state.active, player.mpv != nil else { return }
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
    guard let player, let aid = player.info.aid, aid > 0 else { return .noAudio }
    guard let track = player.info.currentTrack(.audio) else {
      return .unsupported("the selected audio track is not in the track list")
    }
    guard let streamIndex = track.ffIndex, streamIndex >= 0 else {
      return .unsupported("the audio track has no FFmpeg stream index")
    }
    // mpv's clock starts at each file's start time as its demuxer reports it, which differs from
    // FFmpeg's for Matroska and MP4; external files are rebased on their own start time.
    let snapshot = player.mpv.airPlayPlaybackSnapshot
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
    let hadItem = itemSelection != nil
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
                                          mediaOrigin: selection.origin, frameCount: frames) { [weak self] in
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
    player?.sendOSD(.custom(message ?? NSLocalizedString(
      "osc_toolbar.airplay_output.failed",
      value: "AirPlay stopped playing this file's audio, so it plays on this Mac.",
      comment: "The AirPlay bridge gave up on the current file")))
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
    let heard = Self.seconds(avPlayer.currentTime())
    let gap = heard.map { abs($0 - target) } ?? .infinity
    let play: () -> Void = { [weak self] in
      guard let self, generation == self.holdGeneration, self.holding else { return }
      self.speakerClock.reset(position: Self.seconds(avPlayer.currentTime()))
      avPlayer.rate = Float(self.userSpeed)
    }
    log("\(holding ? "holding" : "aligning") for \(holdReason): picture \(String(format: "%.3f", videoTime)), speaker \(heard.map { String(format: "%.3f", $0) } ?? "none"), target \(String(format: "%.3f", target))")
    guard gap > (holdRealign ? 0.25 : 3) else {
      play()
      return
    }
    avPlayer.pause()
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
    let clockPosition = Self.seconds(avPlayer.currentTime())
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
      correctionCooldownUntil = Date().addingTimeInterval(0.5)
      log("speaker playing after \(String(format: "%.2f", waited))s (\(holdReason)); \(currentRoute().description)")
      return
    }
    if let holdStartedAt, Date().timeIntervalSince(holdStartedAt) > Self.holdTimeout {
      failForFile("the speaker did not start within \(Int(Self.holdTimeout))s (\(holdReason)), status \(avPlayer.timeControlStatus.rawValue), waiting reason \(avPlayer.reasonForWaitingToPlay?.rawValue ?? "none")")
    }
  }

  private func cancelHold() {
    holdGeneration += 1
    holding = false
    stopHoldTimer()
    setHoldSpeed(false)
    speakerClock.markBlocked(position: Self.seconds(avPlayer?.currentTime() ?? .invalid))
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
    guard hold != holdSpeedApplied, player?.mpv != nil else { return }
    holdSpeedApplied = hold
    let speed = hold ? Self.holdSpeed : userSpeed
    enqueueMPVProperty(MPVCommandRequest.Operation.doubleProperty(MPVOption.PlaybackControl.speed, speed),
                       coalescingKey: "airplay-speed")
  }

  private func setCorrection(_ correction: Double) {
    guard correction != audioDelayCorrection, player?.mpv != nil else { return }
    audioDelayCorrection = correction
    let delay = userAudioDelay + correction
    enqueueMPVProperty(MPVCommandRequest.Operation.doubleProperty(MPVOption.Audio.audioDelay, delay),
                       coalescingKey: "airplay-audio-delay")
  }

  // MARK: Keeping sync

  private func tick() {
    guard isCarrying, let player, player.info.state.loaded, let mpv = player.mpv, let avPlayer else { return }
    let snapshot = mpv.airPlayPlaybackSnapshot
    let clockPosition = Self.seconds(avPlayer.currentTime())
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
    driftSamples.append(error)
    if driftSamples.count > 8 { driftSamples.removeFirst() }
    guard driftSamples.count >= 4, Date() >= correctionCooldownUntil else { return }
    let median = driftSamples.sorted()[driftSamples.count / 2]
    if abs(median) > Self.resyncThreshold {
      requestHold("picture \(String(format: "%.2f", median))s off", realign: true)
      return
    }
    guard abs(median) > Self.correctionThreshold else { return }
    // Changing mpv's audio delay moves the picture against its (silent) audio clock.
    setCorrection(audioDelayCorrection - median)
    driftSamples.removeAll()
    correctionCooldownUntil = Date().addingTimeInterval(abs(median) + 0.75)
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
    log("speaker \(status) at \(Self.seconds(avPlayer.currentTime()).map { String(format: "%.3f", $0) } ?? "none")", level: .verbose)
  }

  // MARK: PlayerCore and MPVController hooks

  func fileLoaded() {
    if UserDefaults.standard.bool(forKey: Self.localTestKey) && !routeActive {
      routeMayHaveChanged()
    }
    reconcile()
  }

  func audioTrackChanged() {
    _ = routeAudioOwnershipNow()
    guard player?.info.state.loaded == true else { return }
    if isEngaged || routeActive { reconcile() }
  }

  func pauseChanged(_ paused: Bool) {
    guard isCarrying else { return }
    if paused {
      if waitingForMPVAudio { audioStartupClock.markBlocked() }
      cancelHold()
      avPlayer?.pause()
    } else {
      if waitingForMPVAudio { audioStartupClock.markCanProgress() }
      requestHold("resume", realign: true)
    }
  }

  func playbackRestarted() {
    requestHold("seek", realign: true)
  }

  /// mpv changed speed on the user's behalf; the hold speed, if any, was replaced.
  func userSpeedChanged() {
    guard isCarrying else { return }
    holdSpeedApplied = false
    requestHold("speed change", realign: true)
  }

  func volumeChanged() {
    guard let avPlayer, let player else { return }
    avPlayer.volume = Float((player.info.volume / 100).clamped(to: 0...1))
    avPlayer.isMuted = player.info.isMuted
  }

  func consumeInternalSpeed(_ speed: Double) -> Bool {
    speedWrites.consume(speed)
  }

  /// The user's audio delay for a value mpv reported, or nil when the bridge wrote that value.
  func userAudioDelay(fromMPV delay: Double) -> Double? {
    delayWrites.consume(delay) ? nil : delay - audioDelayCorrection
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

  func fileStarted() {
    releaseFile()
    stoppingOrQuitting = false
    bridgeFailedForFile = false
    _ = routeAudioOwnershipNow()
  }

  func fileEnded() {
    releaseFile()
  }

  /// The player is stopping or quitting; mpv may write a watch-later file with its timing.
  func stopPlayback(deferMPVWrites: Bool = false) {
    stoppingOrQuitting = true
    _ = routeAudioOwnershipNow()
    releaseFile(deferMPVWrites: deferMPVWrites)
    if bridgeEngaged { disengage() }
  }

  /// Runs after this bridge's submitted mpv commands have completed, without blocking AppKit.
  var hasUndrainedMPVCommands: Bool {
    activeMPVCommand != nil || !mpvCommandQueue.isEmpty || waitingForMPVEventOverflowRecovery ||
      hasDeferredAudioOutputResolution || synchronousTimingRestoreBarrier.blocksDrain
  }

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

  /// Hands mpv's speed and delay back to the user and drops the item. mpv keeps both options
  /// across files, so this only writes them while they still hold the bridge's values: by now mpv
  /// may already have applied the next file's saved settings.
  private func releaseFile(deferMPVWrites: Bool = false) {
    holdGeneration += 1
    holding = false
    stopHoldTimer()
    waitingForMPVAudio = false
    audioStartupClock.reset()
    pendingHoldReason = nil
    lastMPVAudioTime = nil
    resetAudioClockMotionTracking()
    let restoreSpeed = holdSpeedApplied || hasPendingMPVProperty(MPVOption.PlaybackControl.speed)
    let restoreDelay = audioDelayCorrection != 0 || hasPendingMPVProperty(MPVOption.Audio.audioDelay)
    if let mpv = player?.mpv, player?.info.state != .shutDown {
      // The bridge owns these values while the corresponding flag/correction is active.
      // A flag can clear before its async write receives a reply, so also restore any property
      // with a queued or in-flight bridge write. Stop/quit normally keeps the direct writes so
      // watch-later sees the user's timing values; while a pre-start hook is waiting on main, skip
      // those synchronous calls and let the queued writes drain after the hook continues.
      if restoreSpeed {
        holdSpeedApplied = false
        enqueueMPVProperty(.doubleProperty(MPVOption.PlaybackControl.speed, userSpeed),
                           coalescingKey: "airplay-speed")
        if !deferMPVWrites {
          speedWrites.record(userSpeed)
          mpv.setDouble(MPVOption.PlaybackControl.speed, userSpeed, level: .verbose)
        }
      }
      if restoreDelay {
        audioDelayCorrection = 0
        enqueueMPVProperty(.doubleProperty(MPVOption.Audio.audioDelay, userAudioDelay),
                           coalescingKey: "airplay-audio-delay")
        if !deferMPVWrites {
          delayWrites.record(userAudioDelay)
          mpv.setDouble(MPVOption.Audio.audioDelay, userAudioDelay, level: .verbose)
        }
      }
    }
    holdSpeedApplied = false
    audioDelayCorrection = 0
    guard itemSelection != nil else { return }
    replaceItem(with: nil)
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
    enqueueMPVRequest(MPVCommandRequest(operation: operation, requiredForOutput: false,
                                        coalescingKey: coalescingKey,
                                        restoreAudioOutput: nil,
                                        restoreAudioOutputToken: nil,
                                        expectedAudioOutputIntentGeneration: nil))
  }

  private func hasPendingMPVProperty(_ name: String) -> Bool {
    if activeMPVCommand?.operation.name == name { return true }
    return mpvCommandQueue.contains { $0.operation.name == name }
  }

  private func enqueueMPVRequest(_ request: MPVCommandRequest) {
    var request = request
    let coalescingKey = request.coalescingKey
    if let coalescingKey {
      if let queuedIndex = mpvCommandQueue.lastIndex(where: { $0.coalescingKey == coalescingKey }) {
        if !mpvCommandQueue[queuedIndex].operation.matches(request.operation) {
          cancelInternalTimingWrite(for: mpvCommandQueue[queuedIndex])
          request.timingWriteToken = recordInternalTimingWrite(for: request.operation)
          mpvCommandQueue[queuedIndex] = request
        }
      } else if activeMPVCommand?.coalescingKey != coalescingKey ||
                  activeMPVCommand.map({ !$0.operation.matches(request.operation) }) == true {
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
    mpv.submitAirPlayCommand(
      ifAudioOutputIntentGeneration: submissionIntentGeneration,
      ifRouteOwnershipGeneration: routeOwnershipGeneration,
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

  /// Retire a bridge AO write that became stale between main-thread preflight and queue submission.
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
      afterFailure: result, whileStoppingOrQuitting: stoppingOrQuitting,
      hasNewerWriteQueued: hasNewerTimingWriteQueued) {
      guard synchronousTimingRestoreBarrier.begin(replyUserdata: replyUserdata) else { return }
      if timingWriteMarkerWasCancelled || request.timingWriteToken == nil {
        var timingRequest = request
        timingRequest.timingWriteToken = recordInternalTimingWrite(
          for: .doubleProperty(timingRestore.property, timingRestore.value),
          commandPending: false)
        activeMPVCommand = timingRequest
      }
      log("async timing restore failed during stop; applying it synchronously off AppKit",
          level: .warning)
      guard let mpv = player?.mpv else {
        finishSynchronousTimingRestore(MPV_ERROR_UNINITIALIZED.rawValue,
                                       replyUserdata: replyUserdata)
        return
      }
      mpv.restoreAirPlayTimingValue(timingRestore.property, value: timingRestore.value) {
        [weak self] restoreResult in
        self?.finishSynchronousTimingRestore(restoreResult, replyUserdata: replyUserdata)
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

  /// Keeps Stop/quit pending until a final speed or delay write has been restored off AppKit.
  private func finishSynchronousTimingRestore(_ result: Int32, replyUserdata: UInt64) {
    guard synchronousTimingRestoreBarrier.finish(replyUserdata: replyUserdata) else { return }
    guard activeMPVCommand?.replyUserdata == replyUserdata else {
      runNextMPVCommand()
      return
    }
    if result < 0, player?.mpv?.hasObservedShutdownEvent != true {
      let error = String(cString: mpv_error_string(result))
      log("could not restore timing property after Stop/quit: \(error)", level: .error)
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
          player?.sendOSD(.custom(NSLocalizedString(
            "osc_toolbar.airplay_output.restore_failed",
            value: "AirPlay stopped, but Reel could not restore audio output on this Mac.",
            comment: "The native AirPlay bridge failed to restore mpv's audio output")))
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

  private static func seconds(_ time: CMTime) -> Double? {
    let value = CMTimeGetSeconds(time)
    return value.isFinite && value >= 0 ? value : nil
  }
}

extension AirPlayAudioBridge: AVRoutePickerViewDelegate {
  func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
    // The route can settle a moment after the list closes.
    routeMayHaveChanged()
    for delay in [0.5, 1.5] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.routeMayHaveChanged() }
    }
  }
}
