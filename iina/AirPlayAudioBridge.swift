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

/// Serves the decoded audio to AVFoundation as a WAV file. AVFoundation asks for byte ranges on
/// `queue`, and decoding happens there too, a quarter second at a time, staying about a minute
/// ahead of what the speaker is playing.
final class AirPlayPCMResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
  static let scheme = "reel-airplay"
  static let sampleRate = Double(FFmpegPCMStreamReader.sampleRate)
  private static let bytesPerFrame = Int64(FFmpegPCMStreamReader.channelCount * 2)
  private static let headerLength: Int64 = 44
  /// A WAV header stores sizes in 32 bits, which limits one stream to about six hours.
  static let maximumFrames = (Int64(UInt32.max) - 64) / bytesPerFrame
  private static let chunkFrames = Int64(sampleRate / 4)
  /// How far ahead of the speaker the stream is kept. AVFoundation pulls this much decoded audio
  /// into its own buffer: 60 s measured 16.6 MB streamed per 30 s of playback, 20 s measured 9.6 MB.
  /// A 20 s lead still refills in well under a second (decoding runs far faster than playback).
  private static let leadFrames = Int64(sampleRate * 20)
  /// A new range is always served this far, so a seek never waits for the playhead to be updated.
  private static let burstFrames = Int64(sampleRate * 10)

  /// Thread-safe state shared with the main thread.
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
  let frameCount: Int64
  private let source: String
  private let streamIndex: Int
  private let mediaOrigin: Double?
  private let onFailure: () -> Void
  private let shared = SharedState()

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

  /// Called from the main thread with the time the speaker is playing.
  func setPlayhead(seconds: Double) {
    guard seconds.isFinite else { return }
    shared.playhead = Int64(max(0, seconds) * Self.sampleRate)
    queue.async { [weak self] in self?.schedulePump() }
  }

  func invalidate() {
    shared.invalidate()
    queue.async { [self] in
      let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
      for request in requests where !request.loading.isFinished && !request.loading.isCancelled {
        request.loading.finishLoading(with: error)
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
    requests.append(Request(loading: loadingRequest, start: start, end: end))
    schedulePump()
    return true
  }

  func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                      didCancel loadingRequest: AVAssetResourceLoadingRequest) {
    requests.removeAll { $0.loading === loadingRequest }
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
    requests.removeAll { $0.loading.isCancelled || $0.loading.isFinished }
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
    guard let dataRequest = request.loading.dataRequest else {
      request.loading.finishLoading()
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
      guard let data = readFrames(at: firstFrame, count: Int(endFrame - firstFrame)) else { return false }
      let length = Int(upper - request.offset)
      dataRequest.respond(with: data[skip..<(skip + length)])
      request.offset = upper
    }
    if request.offset >= request.end {
      request.loading.finishLoading()
    }
    return true
  }

  private func readFrames(at frame: Int64, count: Int) -> Data? {
    let shared = shared
    let cancelled: () -> Bool = { shared.isInvalidated }
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

  private func fail() {
    let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotDecodeContentData)
    for request in requests where !request.loading.isFinished && !request.loading.isCancelled {
      request.loading.finishLoading(with: error)
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

// MARK: - Bridge

/// Values the bridge wrote to an mpv property, so their change events are not taken for the user's.
private struct InternalWrites {
  private var writes: [(value: Double, time: Date)] = []

  mutating func record(_ value: Double) {
    writes.append((value, Date()))
  }

  /// True when `value` is one the bridge wrote; drops it and anything older.
  mutating func consume(_ value: Double) -> Bool {
    let now = Date()
    writes.removeAll { now.timeIntervalSince($0.time) > 2 }
    guard let index = writes.lastIndex(where: { abs($0.value - value) < 1e-9 }) else { return false }
    writes.removeFirst(index + 1)
    return true
  }
}

final class AirPlayAudioBridge: NSObject {
  /// Runs the bridge on the Mac's own output, so sync can be checked without a speaker.
  private static let localTestKey = "ReelAirPlayBridgeLocalTest"
  /// Seconds to subtract from AVPlayer's clock, for a receiver whose latency it does not include.
  private static let latencyKey = "ReelAirPlayBridgeLatencyCompensation"
  /// mpv's slowest speed. The picture waits at it, without pausing, while the speaker starts.
  private static let holdSpeed = 0.01
  private static let holdTimeout: TimeInterval = 10
  private static let correctionThreshold = 0.045
  private static let resyncThreshold = 1.0
  /// How long the picture may stay still before the bridge stops trusting its clock.
  private static let pictureStallTimeout: TimeInterval = 0.6
  /// A picture that moved less than this between ticks is not moving.
  private static let pictureMotionEpsilon = 0.001

  private enum AudioSelection {
    case noAudio
    case unsupported(String)
    case supported(Selection)
  }

  private struct Selection: Equatable {
    let source: String
    let streamIndex: Int
    /// The container time of mpv's 0, or nil for the file's own start time.
    let origin: Double?
  }

  private weak var player: PlayerCore?
  private var avPlayer: AVPlayer?
  private var routePicker: AVRoutePickerView?
  private var observedContext: NSObject?
  private var routeObservers: [NSObjectProtocol] = []
  private var timeControlObservation: NSKeyValueObservation?
  private var itemStatusObservation: NSKeyValueObservation?
  private var loader: AirPlayPCMResourceLoader?
  private var itemSelection: Selection?
  private var itemGeneration = 0
  private var syncTimer: Timer?
  private var holdTimer: Timer?

  /// The picker sends this player to a speaker other than the Mac's (or the local test is on).
  private var routeActive = false
  private var routeNames: [String] = []
  private var routeDescription = ""
  /// This file's audio could not be bridged, so mpv plays it on the Mac until the next file.
  private var bridgeFailedForFile = false
  /// mpv's `ao` from before the bridge switched it to `null`.
  private var savedAudioOutput: String?
  private var latencyCompensation = 0.0

  private var speedWrites = InternalWrites()
  private var delayWrites = InternalWrites()
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
  private var waitingForMPVAudioSince: Date?
  private var pendingHoldReason: String?
  private var lastMPVAudioTime: Double?
  /// The picture's clock stopped advancing; the speaker is paused until mpv runs again.
  private var lastPicturePosition: Double?
  private var pictureMovedAt: Date?
  private var waitingForPicture = false

  /// mpv's own audio output is off; the hidden AVPlayer is what can be heard.
  var isEngaged: Bool { savedAudioOutput != nil }

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
    super.init()
  }

  deinit {
    // A repeating timer stays on the run loop until it is invalidated, and a block observer stays
    // registered until it is removed; both would outlive the player if left alone.
    syncTimer?.invalidate()
    holdTimer?.invalidate()
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
    let wasActive = routeActive
    routeActive = active
    if active && !wasActive {
      // A new choice deserves a new attempt.
      bridgeFailedForFile = false
    }
    reconcile()
    guard let player, player.info.state.loaded else { return }
    if active && isEngaged {
      let name = routeNames.isEmpty ? NSLocalizedString("osc_toolbar.airplay_output.speaker", value: "the AirPlay speaker",
                                                        comment: "Unnamed AirPlay speaker")
                                    : ListFormatter.localizedString(byJoining: routeNames)
      player.sendOSD(.custom(String(format: NSLocalizedString("osc_toolbar.airplay_output.connected",
                                                              value: "Reel audio: %@",
                                                              comment: "Reel's audio now plays on the named speaker"), name)))
    } else if !active && wasActive {
      player.sendOSD(.custom(NSLocalizedString("osc_toolbar.airplay_output.disconnected", value: "Reel audio: this Mac",
                                               comment: "Reel's audio plays on the Mac again")))
    }
  }

  // MARK: Engaging

  /// Brings the bridge in line with the route, the file and its audio track.
  private func reconcile() {
    guard let player, player.info.state.active, player.mpv != nil else { return }
    guard routeActive && !bridgeFailedForFile else {
      if isEngaged { disengage() }
      return
    }
    let selection = player.info.state.loaded ? audioSelection() : nil
    if case .unsupported(let reason)? = selection {
      // Leaves mpv's own output on, without switching it off first.
      failForFile(reason, message: NSLocalizedString(
        "osc_toolbar.airplay_output.unsupported",
        value: "This file's audio can't be sent over AirPlay, so it plays on this Mac.",
        comment: "The bridge cannot read the current audio track"))
      return
    }
    if !isEngaged { engage() }
    switch selection {
    case .supported(let selection)?:
      if selection != itemSelection { replaceItem(with: selection) }
    case .noAudio?:
      if itemSelection != nil { replaceItem(with: nil) }
    case .unsupported?, nil:
      break
    }
  }

  private func engage() {
    guard let mpv = player?.mpv else { return }
    savedAudioOutput = mpv.getString(MPVOption.Audio.ao) ?? ""
    latencyCompensation = UserDefaults.standard.double(forKey: Self.latencyKey)
    mpv.setString(MPVOption.Audio.ao, "null", level: .verbose)
    _ = mpv.command(rawString: "ao-reload", level: .verbose)
    makePlayerIfNeeded()
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    RunLoop.main.add(timer, forMode: .common)
    syncTimer = timer
    log("engaged; mpv audio output \(savedAudioOutput ?? "") switched to null, latency compensation \(latencyCompensation)s")
  }

  private func disengage() {
    replaceItem(with: nil)
    waitingForMPVAudio = false
    waitingForMPVAudioSince = nil
    pendingHoldReason = nil
    lastMPVAudioTime = nil
    syncTimer?.invalidate()
    syncTimer = nil
    guard let mpv = player?.mpv, let saved = savedAudioOutput else { return }
    savedAudioOutput = nil
    let output = saved.isEmpty ? (Preference.bool(for: .audioDriverEnableAVFoundation) ? "avfoundation" : "coreaudio") : saved
    mpv.setString(MPVOption.Audio.ao, output, level: .verbose)
    _ = mpv.command(rawString: "ao-reload", level: .verbose)
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
    let rebased = player.mpv.getFlag(MPVOption.PlaybackControl.rebaseStartTime)
    if track.isExternal {
      guard let file = track.externalFilename, !file.isEmpty else {
        return .unsupported("the external audio track has no file name")
      }
      return .supported(Selection(source: file, streamIndex: streamIndex, origin: rebased ? nil : 0))
    }
    let origin = rebased ? player.mpv.getDoubleIfAvailable(MPVProperty.demuxerStartTime) ?? 0 : 0
    guard let url = player.info.currentURL else { return .unsupported("there is no media URL") }
    if url.isFileURL {
      return .supported(Selection(source: url.path, streamIndex: streamIndex, origin: origin))
    }
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
      return .unsupported("\(url.scheme ?? "unknown") sources are not supported")
    }
    // A hook such as ytdl can hand mpv a different stream from the page that was opened.
    let opened = player.mpv.getString(MPVProperty.streamOpenFilename) ?? url.absoluteString
    guard opened.hasPrefix("http://") || opened.hasPrefix("https://") else {
      return .unsupported("mpv opened the stream as \(opened.prefix(16))…")
    }
    return .supported(Selection(source: opened, streamIndex: streamIndex, origin: origin))
  }

  private func replaceItem(with selection: Selection?) {
    let hadItem = itemSelection != nil
    cancelHold()
    waitingForMPVAudio = false
    waitingForMPVAudioSince = nil
    pendingHoldReason = nil
    lastMPVAudioTime = nil
    resetPictureMotionTracking()
    setCorrection(0)
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
    let duration = player.mpv.getDoubleIfAvailable(MPVProperty.duration) ?? 0
    // Unknown lengths (live streams) get the longest stream a WAV header can describe.
    let frames = duration > 0 ? Int64((duration + 2) * AirPlayPCMResourceLoader.sampleRate)
                              : AirPlayPCMResourceLoader.maximumFrames
    let loader = AirPlayPCMResourceLoader(source: selection.source, streamIndex: selection.streamIndex,
                                          mediaOrigin: selection.origin, frameCount: frames) { [weak self] in
      guard let self, self.itemGeneration == generation else { return }
      self.failForFile("the audio could not be decoded")
    }
    self.loader = loader
    // Do not hold or start the speaker yet: the next tick waits until mpv's own audio output is
    // running, so this file's start cannot be postponed by a hold (see `waitingForMPVAudio`).
    waitingForMPVAudio = true
    waitingForMPVAudioSince = Date()
    pendingHoldReason = nil
    lastMPVAudioTime = nil
    resetPictureMotionTracking()
    let asset = AVURLAsset(url: URL(string: "\(AirPlayPCMResourceLoader.scheme)://audio/\(generation).wav")!)
    // The resource loader holds its delegate weakly; `self.loader` keeps it alive.
    asset.resourceLoader.setDelegate(loader, queue: loader.queue)
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
    waitingForMPVAudioSince = nil
    pendingHoldReason = nil
    lastMPVAudioTime = nil
    resetPictureMotionTracking()
    holdGeneration += 1
    let generation = holdGeneration
    stopHoldTimer()
    stalledSince = nil
    waitingForMPVCache = false
    driftSamples.removeAll()
    setCorrection(0)
    holdReason = reason
    holdRealign = realign
    if mpv.getFlag(MPVOption.PlaybackControl.pause) {
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
    let videoTime = mpv.getDoubleIfAvailable(MPVProperty.timePos) ?? 0
    let target = max(0, videoTime - userAudioDelay)
    loader?.setPlayhead(seconds: target)
    let heard = Self.seconds(avPlayer.currentTime())
    let gap = heard.map { abs($0 - target) } ?? .infinity
    let play: () -> Void = { [weak self] in
      guard let self, generation == self.holdGeneration, self.holding else { return }
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
    let videoTime = mpv.getDoubleIfAvailable(MPVProperty.timePos) ?? 0
    if avPlayer.timeControlStatus == .playing, let heard = audiblePosition,
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
    resetPictureMotionTracking()
  }

  /// Clears the picture-motion samples used to detect a stalled mpv clock.
  private func resetPictureMotionTracking() {
    lastPicturePosition = nil
    pictureMovedAt = nil
    waitingForPicture = false
  }

  private func stopHoldTimer() {
    holdTimer?.invalidate()
    holdTimer = nil
  }

  private func setHoldSpeed(_ hold: Bool) {
    guard hold != holdSpeedApplied, let mpv = player?.mpv else { return }
    holdSpeedApplied = hold
    let speed = hold ? Self.holdSpeed : userSpeed
    if let current = mpv.getDoubleIfAvailable(MPVOption.PlaybackControl.speed), abs(current - speed) < 1e-9 { return }
    speedWrites.record(speed)
    mpv.setDouble(MPVOption.PlaybackControl.speed, speed, level: .verbose)
  }

  private func setCorrection(_ correction: Double) {
    guard correction != audioDelayCorrection, let mpv = player?.mpv else { return }
    audioDelayCorrection = correction
    let delay = userAudioDelay + correction
    delayWrites.record(delay)
    mpv.setDouble(MPVOption.Audio.audioDelay, delay, level: .verbose)
  }

  // MARK: Keeping sync

  private func tick() {
    guard isCarrying, let player, player.info.state.loaded, let mpv = player.mpv, let avPlayer else { return }
    if let heard = Self.seconds(avPlayer.currentTime()) { loader?.setPlayhead(seconds: heard) }
    guard !holding, !mpv.getFlag(MPVOption.PlaybackControl.pause) else {
      driftSamples.removeAll()
      return
    }
    if mpv.getFlag(MPVProperty.pausedForCache) {
      // mpv is buffering its own copy of a stream; the speaker waits with the picture.
      if !waitingForMPVCache {
        waitingForMPVCache = true
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
      // audio delay is being written. The picture moving again means the new output is running, so
      // only then may the bridge hold it and start the speaker.
      if let since = waitingForMPVAudioSince, Date().timeIntervalSince(since) > Self.holdTimeout {
        failForFile("mpv's audio output did not start within \(Int(Self.holdTimeout))s")
        return
      }
      guard let pictureTime = mpv.getDoubleIfAvailable(MPVProperty.timePos) else { return }
      if let previous = lastMPVAudioTime, pictureTime > previous + Self.pictureMotionEpsilon {
        log("mpv audio output running at \(String(format: "%.3f", pictureTime))")
        let reason = pendingHoldReason ?? "mpv audio output running"
        pendingHoldReason = nil
        beginHold(reason, realign: true)
      } else {
        lastMPVAudioTime = pictureTime
      }
      return
    }
    if let pictureTime = mpv.getDoubleIfAvailable(MPVProperty.timePos) {
      // A frozen picture means a frozen master clock; measuring the speaker against it would push
      // the correction to a wrong value, and seeking the speaker back mid-stall would repeat audio.
      let now = Date()
      if let previous = lastPicturePosition, abs(pictureTime - previous) > Self.pictureMotionEpsilon {
        pictureMovedAt = now
      } else if pictureMovedAt == nil {
        pictureMovedAt = now
      }
      lastPicturePosition = pictureTime
      if let movedAt = pictureMovedAt, now.timeIntervalSince(movedAt) > Self.pictureStallTimeout {
        if !waitingForPicture {
          waitingForPicture = true
          driftSamples.removeAll()
          avPlayer.pause()
          log("picture stopped moving; holding the speaker until it resumes", level: .verbose)
        }
        return
      }
      if waitingForPicture {
        waitingForPicture = false
        requestHold("picture resumed", realign: true)
        return
      }
    }
    guard avPlayer.timeControlStatus == .playing, let heard = audiblePosition else {
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
    guard let videoTime = mpv.getDoubleIfAvailable(MPVProperty.timePos) else { return }
    if halfFrameDuration == nil {
      // time-pos is the displayed frame's start; on average the picture is half a frame later.
      let fps = mpv.getDoubleIfAvailable(MPVProperty.estimatedVfFps) ?? mpv.getDoubleIfAvailable(MPVProperty.containerFps)
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
    guard isEngaged, player?.info.state.loaded == true else { return }
    reconcile()
  }

  func pauseChanged(_ paused: Bool) {
    guard isCarrying else { return }
    if paused {
      cancelHold()
      avPlayer?.pause()
    } else {
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
    bridgeFailedForFile = false
  }

  func fileEnded() {
    releaseFile()
  }

  /// The player is stopping or quitting; mpv may write a watch-later file with its timing.
  func stopPlayback() {
    releaseFile()
  }

  /// Hands mpv's speed and delay back to the user and drops the item. mpv keeps both options
  /// across files, so this only writes them while they still hold the bridge's values: by now mpv
  /// may already have applied the next file's saved settings.
  private func releaseFile() {
    holdGeneration += 1
    holding = false
    stopHoldTimer()
    waitingForMPVAudio = false
    waitingForMPVAudioSince = nil
    pendingHoldReason = nil
    lastMPVAudioTime = nil
    resetPictureMotionTracking()
    if let mpv = player?.mpv, player?.info.state != .shutDown {
      if holdSpeedApplied,
         let speed = mpv.getDoubleIfAvailable(MPVOption.PlaybackControl.speed), abs(speed - Self.holdSpeed) < 1e-9 {
        speedWrites.record(userSpeed)
        mpv.setDouble(MPVOption.PlaybackControl.speed, userSpeed, level: .verbose)
      }
      if audioDelayCorrection != 0,
         let delay = mpv.getDoubleIfAvailable(MPVOption.Audio.audioDelay),
         abs(delay - (userAudioDelay + audioDelayCorrection)) < 1e-9 {
        delayWrites.record(userAudioDelay)
        mpv.setDouble(MPVOption.Audio.audioDelay, userAudioDelay, level: .verbose)
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
