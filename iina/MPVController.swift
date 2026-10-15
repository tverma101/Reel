//
//  MPVController.swift
//  iina
//
//  Created by lhc on 8/7/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa
import JavaScriptCore
import VideoToolbox

fileprivate let yes_str = "yes"
fileprivate let no_str = "no"

/// Change this variable to adjust mpv log level.
///
/// Available levels:
/// |  Level  | Output  |
/// | --- | --- |
/// | no  | complete silence |
/// | fatal | fatal messages only |
/// | error | error messages |
/// | warn  | warning messages |
/// | info | informational message |
/// | status | status messages (default) |
/// | v | verbose messages |
/// | debug | debug messages |
/// | trace | very noisy debug messages |
/// - Important: The mpv event system uses an event queue of limited size. If events are not read quickly enough the queue can
///     overflow resulting in events being dropped. Loss of events can trigger severe malfunctions. IINA's ability to include mpv log
///     messages in the IINA log file relies up the mpv `MPV_EVENT_LOG_MESSAGE` event. There is a danger that mpv will emit log
///     messages at a rate that exceeds IINA's ability to empty the event queue before it overflows. For this reason IINA intentionally
///     limits the mpv log level to `warn`. If you change the level to debug a problem be aware that the event queue could overflow
///     and drop events resulting in odd behavior.
fileprivate let MPVLogLevel = "warn"
fileprivate let logLevelMap: [String: Logger.Level] = ["fatal": .error,
                                                       "error": .error,
                                                       "warn": .warning,
                                                       "info": .debug,
                                                       "v": .verbose,
                                                       "debug": .debug,
                                                       "trace": .verbose]

// FIXME: should be moved to a separated file
struct MPVHookValue {
  typealias Block = (@escaping () -> Void) -> Void

  var id: String?
  var isJavascript: Bool
  var block: Block?
  var jsBlock: JSManagedValue!
  var context: JSContext!

  init(withIdentifier id: String, jsContext context: JSContext, jsBlock block: JSValue, owner: JavascriptAPIMpv) {
    self.id = id
    self.isJavascript = true
    self.jsBlock = JSManagedValue(value: block)
    self.context = context
    context.virtualMachine.addManagedReference(self.jsBlock, withOwner: owner)
  }

  init(withBlock block: @escaping Block) {
    self.isJavascript = false
    self.block = block
  }

  func call(withNextBlock next: @escaping () -> Void) {
    if isJavascript {
      let block: @convention(block) () -> Void = { next() }
      guard let callback = jsBlock.value else {
        next()
        return
      }
      callback.call(withArguments: [JSValue(object: block, in: context)!])
      if callback.forProperty("constructor")?.forProperty("name")?.toString() != "AsyncFunction" {
        next()
      }
    } else {
      block!(next)
    }
  }
}

// Global functions

/// A lock-protected view of the mpv values used by Reel's AirPlay bridge. The bridge samples this
/// snapshot on the main thread instead of calling synchronous libmpv getters from its timers.
struct MPVAirPlaySnapshot {
  var audioOutput: String?
  /// Raw async AO requests remain pending until mpv reports a matching output value.
  var pendingRawAudioOutputIntents: [MPVAirPlayPendingAudioOutputIntent] = []
  /// The newest confirmed direct AO intent, retained even if an older bridge restore runs later.
  var directAudioOutput: String?
  var directAudioOutputGeneration: UInt64 = 0
  /// Orders direct AO actions by invocation, independent of property event delivery order.
  var nextDirectAudioOutputIntentSequence: UInt64 = 0
  var directAudioOutputIntentSequence: UInt64 = 0
  /// Increments for each observed or direct `ao` update so overflow samples cannot overwrite it.
  var audioOutputGeneration: UInt64 = 0
  /// Prevents route reconciliation while a synchronous `ao` write has not settled yet.
  var audioOutputChangesInFlight = 0
  var rebaseStartTime: Bool?
  var isPaused: Bool?
  var pausedForCache: Bool?
  var timePosition: Double?
  var audioPTS: Double?
  var duration: Double?
  var demuxerStartTime: Double?
  var streamOpenFilename: String?
  var estimatedVideoFPS: Double?
  var containerFPS: Double?
  var speed: Double?

  mutating func resetMediaValues() {
    pausedForCache = nil
    timePosition = nil
    audioPTS = nil
    duration = nil
    demuxerStartTime = nil
    streamOpenFilename = nil
    estimatedVideoFPS = nil
    containerFPS = nil
  }
}

struct MPVAirPlayPendingAudioOutputIntent {
  /// `nil` means the command selects an output dynamically (for example, `cycle ao`).
  let output: String?
  let intentSequence: UInt64
  /// Dynamic commands must observe a changed value, not a delayed event for the prior state.
  let previousOutput: String?
}

private struct RawAudioOutputCommand {
  let output: String?
  let isAsynchronous: Bool
  var intentSequence: UInt64 = 0
}

private struct MPVAirPlayAudioOutputWriteToken {
  let generationBeforeWrite: UInt64
  let intentSequences: [UInt64]
  let initialAudioOutput: String?
}

private struct MPVAirPlaySnapshotRequestState {
  var generation: UInt64 = 0
  var pendingTokens = Set<UInt64>()
  var isDisabled = false
  var isRecoveringFromQueueOverflow = false
}

class MPVController: NSObject {
  struct UserData {
    static let screenshot: UInt64 = 1000000
    static let preferenceOptionCommand: UInt64 = 1000002
    static let airPlaySnapshotBase: UInt64 = 0xA17A_0000_0000_0000
    static let airPlayAudioCommandBase: UInt64 = 0xA17B_0000_0000_0000
    private static let airPlayAudioCommandMask: UInt64 = 0xFFFF_0000_0000_0000

    static func isAirPlayAudioCommand(_ token: UInt64) -> Bool {
      (token & airPlayAudioCommandMask) == airPlayAudioCommandBase
    }
  }

  // The mpv_handle
  var mpv: OpaquePointer!
  var mpvRenderContext: OpaquePointer?

  private var openGLContext: CGLContextObj! = nil

  /// [DispatchQueue](https://developer.apple.com/documentation/dispatch/dispatchqueue) for reading `mpv`
  /// events.
  /// - Important: The mpv event system uses an event queue of limited size. If events are not read quickly enough with
  ///     `mpv_wait_event` the queue can overflow resulting in events being dropped. IINA can recover from the loss of some
  ///     types of mpv events, but certain mpv events are critical. If a critical event is discarded IINA will experience severe
  ///     malfunctions. For this reason this queue _must only_ be used for reading events. This also means processing of events
  ///     _must not be performed_ using this queue unless the work required can _always_ be accomplished _quickly_. Otherwise
  ///     processing _must be_ queued to another dispatch queue.
  /// - Important: To avoid using locking to prevent data races the convention is that processing involving data used by the UI is
  ///     never performed while running on this queue's thread and instead is queued for processing by the main thread .
  private lazy var queue = DispatchQueue(label: "com.colliderli.iina.controller",
                                         qos: .userInitiated)
  /// Snapshot queries share libmpv's core lock and must not delay the AppKit event thread.
  private let airPlaySnapshotQueue = DispatchQueue(label: "com.colliderli.iina.airplay-snapshot",
                                                    qos: .userInitiated)
  /// Gates queued AirPlay/snapshot/quit calls against the terminal marker. The event reader never
  /// takes this lock while polling so it can always dispatch hooks that unblock libmpv calls.
  private let airPlaySnapshotCallLock = NSLock()
  /// Serializes synchronous `ao` setters so the retained local-output intent follows libmpv write order.
  private let airPlayAudioOutputWriteLock = NSLock()
  /// Accessed only by the serial mpv event queue; pairs START_FILE with FILE_LOADED or END_FILE.
  private var activePlaylistLoadTransition: UInt64?
  @Atomic private var pendingPlaylistLoadTransitions: [UInt64] = []

  // Once the shutdown event is received, the main-thread handler destroys the mpv handle. Wakeup
  // callbacks can already have queued additional event reads, so those reads must stop before they
  // can call mpv_wait_event with a destroyed handle.
  @Atomic private var hasReceivedShutdownEvent = false
  @Atomic private var airPlaySnapshot = MPVAirPlaySnapshot()
  @Atomic private var airPlaySnapshotRequests = MPVAirPlaySnapshotRequestState()

  var airPlayPlaybackSnapshot: MPVAirPlaySnapshot { airPlaySnapshot }
  var hasObservedShutdownEvent: Bool { hasReceivedShutdownEvent }

  unowned let player: PlayerCore

  var needRecordSeekTime: Bool = false
  var recordedSeekStartTime: CFTimeInterval = 0
  var recordedSeekTimeListener: ((Double) -> Void)?

  @Atomic private var hooks: [UInt64: MPVHookValue] = [:]
  private var hookCounter: UInt64 = 1

  let observeProperties: [String: mpv_format] = [
    MPVProperty.trackList: MPV_FORMAT_NODE,
    MPVProperty.playlistCount: MPV_FORMAT_INT64,
    MPVProperty.playlistCurrentPos: MPV_FORMAT_INT64,
    MPVProperty.playlistPlayingPos: MPV_FORMAT_INT64,
    MPVProperty.vf: MPV_FORMAT_NONE,
    MPVProperty.af: MPV_FORMAT_NONE,
    MPVProperty.audioDeviceList: MPV_FORMAT_NONE,
    MPVProperty.streamOpenFilename: MPV_FORMAT_STRING,
    MPVProperty.duration: MPV_FORMAT_DOUBLE,
    MPVProperty.demuxerStartTime: MPV_FORMAT_DOUBLE,
    MPVOption.TrackSelection.vid: MPV_FORMAT_INT64,
    MPVOption.TrackSelection.aid: MPV_FORMAT_INT64,
    MPVOption.TrackSelection.sid: MPV_FORMAT_INT64,
    MPVOption.Subtitles.secondarySid: MPV_FORMAT_INT64,
    MPVOption.PlaybackControl.pause: MPV_FORMAT_FLAG,
    MPVOption.PlaybackControl.rebaseStartTime: MPV_FORMAT_FLAG,
    MPVOption.PlaybackControl.loopPlaylist: MPV_FORMAT_STRING,
    MPVOption.PlaybackControl.loopFile: MPV_FORMAT_STRING,
    MPVProperty.chapter: MPV_FORMAT_INT64,
    MPVOption.Video.deinterlace: MPV_FORMAT_FLAG,
    MPVOption.Video.hwdec: MPV_FORMAT_STRING,
    MPVOption.Video.videoRotate: MPV_FORMAT_INT64,
    MPVOption.Audio.mute: MPV_FORMAT_FLAG,
    MPVOption.Audio.volume: MPV_FORMAT_DOUBLE,
    MPVOption.Audio.audioDelay: MPV_FORMAT_DOUBLE,
    MPVOption.Audio.ao: MPV_FORMAT_STRING,
    MPVOption.PlaybackControl.speed: MPV_FORMAT_DOUBLE,
    MPVOption.Subtitles.secondarySubDelay: MPV_FORMAT_DOUBLE,
    MPVOption.Subtitles.secondarySubPos: MPV_FORMAT_DOUBLE,
    MPVOption.Subtitles.secondarySubVisibility: MPV_FORMAT_FLAG,
    MPVOption.Subtitles.subDelay: MPV_FORMAT_DOUBLE,
    MPVOption.Subtitles.subPos: MPV_FORMAT_DOUBLE,
    MPVOption.Subtitles.subScale: MPV_FORMAT_DOUBLE,
    MPVOption.Subtitles.subVisibility: MPV_FORMAT_FLAG,
    MPVOption.Equalizer.contrast: MPV_FORMAT_INT64,
    MPVOption.Equalizer.brightness: MPV_FORMAT_INT64,
    MPVOption.Equalizer.gamma: MPV_FORMAT_INT64,
    MPVOption.Equalizer.hue: MPV_FORMAT_INT64,
    MPVOption.Equalizer.saturation: MPV_FORMAT_INT64,
    MPVOption.Window.fullscreen: MPV_FORMAT_FLAG,
    MPVOption.Window.ontop: MPV_FORMAT_FLAG,
    MPVOption.Window.windowScale: MPV_FORMAT_DOUBLE,
    MPVProperty.mediaTitle: MPV_FORMAT_STRING,
    MPVProperty.videoParamsRotate: MPV_FORMAT_INT64,
    MPVProperty.videoParamsPrimaries: MPV_FORMAT_STRING,
    MPVProperty.videoParamsGamma: MPV_FORMAT_STRING,
    MPVProperty.idleActive: MPV_FORMAT_FLAG,
    MPVProperty.currentAo: MPV_FORMAT_STRING
  ]

  /// Map from mpv codec name to core media video codec types.
  ///
  /// This map only contains the mpv codecs `adjustCodecWhiteList` can remove from the mpv `hwdec-codecs` option.
  /// If any codec types are added then `HardwareDecodeCapabilities` will need to be updated to support them.
  private let mpvCodecToCodecTypes: [String: [CMVideoCodecType]] = [
    "av1": [kCMVideoCodecType_AV1],
    "prores": [kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ,
               kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy,
               kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ,
               kCMVideoCodecType_AppleProResRAW, kCMVideoCodecType_AppleProResRAWHQ],
    "vp9": [kCMVideoCodecType_VP9]
  ]

  private let subsystem: Logger.Subsystem

  /// Creates a `MPVController` object.
  /// - Parameters:
  ///   - playerCore: The player this `MPVController` will be associated with.
  init(playerCore: PlayerCore) {
    self.player = playerCore
    subsystem = Logger.makeSubsystem("mpv\(player.playerNumber)", ["building.columns"])
    super.init()
  }

  deinit {
    removeOptionObservers()
  }

  /// Remove codecs from the hardware decoding white list that this Mac does not support.
  ///
  /// As explained in [HWAccelIntro](https://trac.ffmpeg.org/wiki/HWAccelIntro),  [FFmpeg](https://ffmpeg.org/)
  /// will automatically fall back to software decoding. _However_ when it does so `FFmpeg` emits an error level log message
  /// referring to "Failed setup". This has confused users debugging problems. To eliminate the overhead of setting up for hardware
  /// decoding only to have it fail, this method removes codecs from the mpv
  /// [hwdec-codecs](https://mpv.io/manual/stable/#options-hwdec-codecs) option that are known to not have
  /// hardware decoding support on this Mac. This is not comprehensive. This method only covers the recent codecs whose support
  /// for hardware decoding varies among Macs. This merely reduces the dependence upon the FFmpeg fallback to software decoding
  /// feature in some cases.
  private func adjustCodecWhiteList() {
    // Allow the user to override this behavior.
    guard !userOptionsContains(MPVOption.Video.hwdecCodecs) else {
      log("""
        Option \(MPVOption.Video.hwdecCodecs) has been set in advanced settings, \
        will not adjust white list
        """)
      return
    }
    guard let whitelist = getString(MPVOption.Video.hwdecCodecs) else {
      // Internal error. Make certain this method is called after mpv_initialize which sets the
      // default value.
      log("Failed to obtain the value of option \(MPVOption.Video.hwdecCodecs)", level: .error)
      return
    }
    log("Hardware decoding whitelist (\(MPVOption.Video.hwdecCodecs)) is set to \(whitelist)")
    var adjusted: [String] = []
    var needsAdjustment = false
    codecLoop: for codec in whitelist.components(separatedBy: ",") {
      guard let codecTypes = mpvCodecToCodecTypes[codec] else {
        // Not a codec this method supports removing. Retain it in the option value.
        adjusted.append(codec)
        continue
      }
      // The mpv codec name can map to multiple codec types. If hardware decoding is supported for
      // any of them retain the codec in the option value.
      for codecType in codecTypes {
        if HardwareDecodeCapabilities.shared.isSupported(codecType) {
          adjusted.append(codec)
          continue codecLoop
        }
      }
      needsAdjustment = true
      log("This Mac does not support \(codec) hardware decoding")
    }
    // Only set the option if a change is needed to avoid logging when nothing has changed.
    if needsAdjustment {
      chkErr(setOptionString(MPVOption.Video.hwdecCodecs, adjusted.joined(separator: ",")))
    }
  }

  /// Determine if this Mac has an Apple Silicon chip.
  /// - Returns: `true` if running on a Mac with an Apple Silicon chip, `false` otherwise.
  private func runningOnAppleSilicon() -> Bool {
    var sysinfo = utsname()
    let result = uname(&sysinfo)
    guard result == EXIT_SUCCESS else {
      log("uname failed returning \(result)", level: .error)
      return false
    }
    let data = Data(bytes: &sysinfo.machine, count: Int(_SYS_NAMELEN))
    guard let machine = String(bytes: data, encoding: .ascii) else {
      log("Failed to construct string for sysinfo.machine", level: .error)
      return false
    }
    return machine.starts(with: "arm64")
  }

  /// Apply a workaround for issue [#4486](https://github.com/iina/iina/issues/4486), if needed.
  ///
  /// On Macs with an Intel chip VP9 hardware acceleration is causing a hang in
  ///[VTDecompressionSessionWaitForAsynchronousFrames](https://developer.apple.com/documentation/videotoolbox/1536066-vtdecompressionsessionwaitforasy).
  /// This has been reproduced with FFmpeg and has been reported in ticket [9599](https://trac.ffmpeg.org/ticket/9599).
  ///
  /// The workaround removes VP9 from the value of the mpv [hwdec-codecs](https://mpv.io/manual/master/#options-hwdec-codecs) option,
  /// the list of codecs eligible for hardware acceleration.
  private func applyHardwareAccelerationWorkaround() {
    // The problem is not reproducible under Apple Silicon.
    guard !runningOnAppleSilicon() else {
      log("Running on Apple Silicon, not applying FFmpeg 9599 workaround")
      return
    }
    // Allow the user to override this behavior.
    guard !userOptionsContains(MPVOption.Video.hwdecCodecs) else {
      log("""
        Option \(MPVOption.Video.hwdecCodecs) has been set in advanced settings, \
        not applying FFmpeg 9599 workaround
        """)
      return
    }
    guard let whitelist = getString(MPVOption.Video.hwdecCodecs) else {
      // Internal error. Make certain this method is called after mpv_initialize which sets the
      // default value.
      log("Failed to obtain the value of option \(MPVOption.Video.hwdecCodecs)", level: .error)
      return
    }
    var adjusted: [String] = []
    var needsWorkaround = false
    codecLoop: for codec in whitelist.components(separatedBy: ",") {
      guard codec == "vp9" else {
        adjusted.append(codec)
        continue
      }
      needsWorkaround = true
    }
    if needsWorkaround {
      log("Disabling hardware acceleration for VP9 encoded videos to workaround FFmpeg 9599")
      chkErr(setOptionString(MPVOption.Video.hwdecCodecs, adjusted.joined(separator: ",")))
    }
  }

  /**
   Init the mpv context, set options
   */
  func mpvInit() {
    // Create a new mpv instance and an associated client API handle to control the mpv instance.
    mpv = mpv_create()

    // User default settings

    if Preference.bool(for: .enableInitialVolume) {
      setUserOption(PK.initialVolume, type: .int, forName: MPVOption.Audio.volume, sync: false,
                    level: .verbose)
    } else {
      setUserOption(PK.softVolume, type: .int, forName: MPVOption.Audio.volume, sync: false,
                    level: .verbose)
    }

    // - Advanced

    // disable internal OSD
    let useMpvOsd = Preference.bool(for: .enableAdvancedSettings) && Preference.bool(for: .useMpvOsd)
    if !useMpvOsd {
      chkErr(setOptionString(MPVOption.OSD.osdLevel, "0", level: .verbose))
    } else {
      player.displayOSD = false
    }

    // log
    if Logger.enabled {
      let path = Logger.logDirectory.appendingPathComponent("mpv.log").path
      chkErr(setOptionString(MPVOption.ProgramBehavior.logFile, path, level: .verbose))
    }

    // - General

    let setScreenshotPath = { (key: Preference.Key) -> String in
      let screenshotPath = Preference.string(for: .screenshotFolder)!
      return Preference.bool(for: .screenshotSaveToFile) ?
        NSString(string: screenshotPath).expandingTildeInPath :
        Utility.screenshotCacheURL.path
    }

    setUserOption(PK.screenshotFolder, type: .other, forName: MPVOption.Screenshot.screenshotDir,
                  level: .verbose, transformer: setScreenshotPath)
    setUserOption(PK.screenshotSaveToFile, type: .other, forName: MPVOption.Screenshot.screenshotDir,
                  level: .verbose, transformer: setScreenshotPath)

    setUserOption(PK.screenshotFormat, type: .other, forName: MPVOption.Screenshot.screenshotFormat,
                  verboseIfDefault: true) { key in
      let format: Preference.ScreenshotFormat = Preference.enum(for: key)
      // Workaround for mpv issue  #15107, HDR screenshots are unimplemented (gpu/gpu-next).
      // If the screenshot format is set to JPEG XL then set the screenshot-sw option to yes. This
      // causes the screenshot to be rendered by software instead of the VO. If a HDR video is being
      // displayed in HDR then the resulting screenshot will be HDR.
      self.chkErr(self.setOptionFlag(MPVOption.Screenshot.screenshotSw, format == .jxl,
                                     verboseIfDefault: true))
      return String(describing: format)
    }

    setUserOption(PK.screenshotTemplate, type: .string,
                  forName: MPVOption.Screenshot.screenshotTemplate)

    // Disable mpv's media key system as it now uses the MediaPlayer Framework.
    // Dropped media key support in 10.11 and 10.12.
    chkErr(setOptionString(MPVOption.Input.inputMediaKeys, no_str, level: .verbose))

    setUserOption(PK.keepOpenOnFileEnd, type: .other, forName: MPVOption.Window.keepOpen,
                  level: .verbose) { key in
      let keepOpen = Preference.bool(for: PK.keepOpenOnFileEnd)
      let keepOpenPl = !Preference.bool(for: PK.playlistAutoPlayNext)
      return keepOpenPl ? "always" : (keepOpen ? "yes" : "no")
    }

    setUserOption(PK.playlistAutoPlayNext, type: .other, forName: MPVOption.Window.keepOpen,
                  level: .verbose) { key in
      let keepOpen = Preference.bool(for: PK.keepOpenOnFileEnd)
      let keepOpenPl = !Preference.bool(for: PK.playlistAutoPlayNext)
      return keepOpenPl ? "always" : (keepOpen ? "yes" : "no")
    }

    chkErr(setOptionString("watch-later-directory", Utility.watchLaterURL.path, level: .verbose))
    setUserOption(PK.resumeLastPosition, type: .bool, forName: MPVOption.WatchLater.savePositionOnQuit,
                  verboseIfDefault: true)
    setUserOption(PK.resumeLastPosition, type: .bool, forName: MPVOption.WatchLater.resumePlayback,
                  verboseIfDefault: true)

    setUserOption(.initialWindowSizePosition, type: .string, forName: MPVOption.Window.geometry,
                  level: .verbose)

    // - Codec

    setUserOption(PK.videoThreads, type: .int, forName: MPVOption.Video.vdLavcThreads,
                  verboseIfDefault: true)
    setUserOption(PK.audioThreads, type: .int, forName: MPVOption.Audio.adLavcThreads,
                  verboseIfDefault: true)

    setUserOption(PK.hardwareDecoder, type: .other, forName: MPVOption.Video.hwdec,
                  verboseIfDefault: true) { key in
      return String(describing: Preference.enum(for: key) as Preference.HardwareDecoderOption)
    }

    setUserOption(PK.audioLanguage, type: .asyncOther, forName: MPVOption.TrackSelection.alang,
                  level: .verbose) { [weak self] key in
      self?.preferredTrackLanguage(for: key)
    }
    setUserOption(.autoSelectPreferredTrackLanguages, type: .asyncOther,
                  forName: MPVOption.TrackSelection.alang, level: .verbose) { [weak self] _ in
      self?.preferredTrackLanguage(for: .audioLanguage)
    }
    setUserOption(PK.maxVolume, type: .int, forName: MPVOption.Audio.volumeMax, level: .verbose)

    let spdifValue = { (key: Preference.Key) -> String in
      var spdif: [String] = []
      if Preference.bool(for: PK.spdifAC3) { spdif.append("ac3") }
      if Preference.bool(for: PK.spdifDTS){ spdif.append("dts") }
      if Preference.bool(for: PK.spdifDTSHD) { spdif.append("dts-hd") }
      if Preference.bool(for: PK.spdifEAC3) { spdif.append("eac3") }
      if Preference.bool(for: PK.spdifTRUEHD) { spdif.append("truehd") }
      return spdif.joined(separator: ",")
    }
    setUserOption(PK.spdifAC3, type: .other, forName: MPVOption.Audio.audioSpdif,
                  verboseIfDefault: true, transformer: spdifValue)
    setUserOption(PK.spdifDTS, type: .other, forName: MPVOption.Audio.audioSpdif,
                  verboseIfDefault: true, transformer: spdifValue)
    setUserOption(PK.spdifDTSHD, type: .other, forName: MPVOption.Audio.audioSpdif,
                  verboseIfDefault: true, transformer: spdifValue)
    setUserOption(PK.spdifEAC3, type: .other, forName: MPVOption.Audio.audioSpdif,
                  verboseIfDefault: true, transformer: spdifValue)
    setUserOption(PK.spdifTRUEHD, type: .other, forName: MPVOption.Audio.audioSpdif,
                  verboseIfDefault: true, transformer: spdifValue)

    setUserOption(PK.audioDevice, type: .string, forName: MPVOption.Audio.audioDevice,
                  verboseIfDefault: true)

    setUserOption(PK.replayGain, type: .other, forName: MPVOption.Audio.replaygain,
                  verboseIfDefault: true) { key in
      return String(describing: Preference.enum(for: key) as Preference.ReplayGainOption)
    }
    setUserOption(PK.replayGainPreamp, type: .float, forName: MPVOption.Audio.replaygainPreamp,
                  verboseIfDefault: true)
    setUserOption(PK.replayGainClip, type: .bool, forName: MPVOption.Audio.replaygainClip,
                  verboseIfDefault: true)
    setUserOption(PK.replayGainFallback, type: .float, forName: MPVOption.Audio.replaygainFallback,
                  verboseIfDefault: true)

    setUserOption(PK.gaplessAudio, type: .other, forName: MPVOption.Audio.gaplessAudio,
                  verboseIfDefault: true) { key in
      return String(describing: Preference.enum(for: key) as Preference.GaplessAudioOption)
    }

    // IINA builds FFmpeg with support for the SVT-AV1 encoder. This encoder is preferred over
    // libaom for its better performance. Must set the mpv screenshot-avif-encoder option as it
    // defaults to "libaom-av1".
    chkErr(setOptionString(MPVOption.Screenshot.screenshotAvifEncoder, "libsvtav1",
                           level: .verbose))

    // The mpv screenshot-avif-opts option default value uses keys recognized by the libaom encoder.
    // As IINA is using the SVT-AV1 encoder the default value is inappropriate. Since the encoder is
    // only being used for screenshots, enable still-picture coding optimizations for improved
    // coding efficiency and reduced memory usage.
    chkErr(setOptionString(MPVOption.Screenshot.screenshotAvifOpts, "svtav1-params=avif=1",
                           level: .verbose))

    // - Sub

    chkErr(setOptionString(MPVOption.Subtitles.subAuto, "no", level: .verbose))
    setUserOption(.showSecondSubtitleTrack, type: .asyncOther,
                  forName: MPVOption.Subtitles.secondarySid, level: .verbose) { key in
      return Preference.bool(for: key) ? "auto" : "no"
    }
    chkErr(setOptionalOptionString(MPVOption.Subtitles.subCodepage,
                                   Preference.string(for: .defaultEncoding), verboseIfDefault: true))
    player.info.subEncoding = Preference.string(for: .defaultEncoding)

    let subOverrideHandler: OptionObserverInfo.Transformer = { key in
      String(describing: Preference.enum(for: key) as Preference.SubOverrideLevel)
    }
    setUserOption(PK.subOverrideLevel, type: .other, forName: MPVOption.Subtitles.subAssOverride,
                  verboseIfDefault: true, transformer: subOverrideHandler)
    setUserOption(PK.secondarySubOverrideLevel, type: .other,
                  forName: MPVOption.Subtitles.secondarySubAssOverride, verboseIfDefault: true,
                  transformer: subOverrideHandler)

    setUserOption(PK.subTextFont, type: .string, forName: MPVOption.Subtitles.subFont,
                  verboseIfDefault: true)
    setUserOption(PK.subTextSize, type: .float, forName: MPVOption.Subtitles.subFontSize,
                  verboseIfDefault: true)

    setUserOption(PK.subTextColorString, type: .color, forName: MPVOption.Subtitles.subColor,
                  verboseIfDefault: true)

    setUserOption(PK.subBold, type: .bool, forName: MPVOption.Subtitles.subBold,
                  verboseIfDefault: true)
    setUserOption(PK.subItalic, type: .bool, forName: MPVOption.Subtitles.subItalic,
                  verboseIfDefault: true)

    setUserOption(PK.subBlur, type: .float, forName: MPVOption.Subtitles.subBlur,
                  verboseIfDefault: true)
    setUserOption(PK.subSpacing, type: .float, forName: MPVOption.Subtitles.subSpacing,
                  verboseIfDefault: true)

    setUserOption(PK.subBorderSize, type: .float, forName: MPVOption.Subtitles.subOutlineSize,
                  verboseIfDefault: true)
    setUserOption(PK.subBorderColorString, type: .color, forName: MPVOption.Subtitles.subOutlineColor,
                  verboseIfDefault: true)

    setUserOption(PK.subShadowSize, type: .float, forName: MPVOption.Subtitles.subShadowOffset,
                  verboseIfDefault: true)
    setUserOption(PK.subShadowColorString, type: .color, forName: MPVOption.Subtitles.subBackColor,
                  verboseIfDefault: true)

    setUserOption(PK.subBorderStyle, type: .other, forName: MPVOption.Subtitles.subBorderStyle,
                  verboseIfDefault: true) { key in
      String(describing: Preference.enum(for: key) as Preference.SubBorderStyle)
    }

    setUserOption(PK.subAlignX, type: .other, forName: MPVOption.Subtitles.subAlignX,
                  verboseIfDefault: true) { key in
      return String(describing: Preference.enum(for: key) as Preference.SubAlignX)
    }

    setUserOption(PK.subAlignY, type: .other, forName: MPVOption.Subtitles.subAlignY,
                  verboseIfDefault: true) { key in
      return String(describing: Preference.enum(for: key) as Preference.SubAlignY)
    }

    setUserOption(PK.subMarginX, type: .int, forName: MPVOption.Subtitles.subMarginX,
                  verboseIfDefault: true)
    setUserOption(PK.subMarginY, type: .int, forName: MPVOption.Subtitles.subMarginY,
                  verboseIfDefault: true)

    setUserOption(PK.subPos, type: .float, forName: MPVOption.Subtitles.subPos, verboseIfDefault: true)

    setUserOption(PK.subLang, type: .asyncOther, forName: MPVOption.TrackSelection.slang,
                  level: .verbose) { [weak self] key in
      self?.preferredTrackLanguage(for: key)
    }
    setUserOption(.autoSelectPreferredTrackLanguages, type: .asyncOther,
                  forName: MPVOption.TrackSelection.slang, level: .verbose) { [weak self] _ in
      self?.preferredTrackLanguage(for: .subLang)
    }

    setUserOption(PK.displayInLetterBox, type: .bool, forName: MPVOption.Subtitles.subUseMargins,
                  verboseIfDefault: true)
    setUserOption(PK.displayInLetterBox, type: .bool, forName: MPVOption.Subtitles.subAssForceMargins,
                  verboseIfDefault: true)

    setUserOption(PK.subScaleWithWindow, type: .bool, forName: MPVOption.Subtitles.subScaleByWindow,
                  verboseIfDefault: true)

    // - Network / cache settings

    setUserOption(PK.enableCache, type: .other, forName: MPVOption.Cache.cache,
                  verboseIfDefault: true) { key in
      return Preference.bool(for: key) ? "yes" : "no"
    }

    setUserOption(PK.cachePauseInitial, type: .bool, forName: MPVOption.Cache.cachePauseInitial,
                  verboseIfDefault: true)
    setUserOption(PK.cachePauseWait, type: .float, forName: MPVOption.Cache.cachePauseWait,
                  verboseIfDefault: true)
    setUserOption(PK.defaultCacheSize, type: .other, forName: MPVOption.Demuxer.demuxerMaxBytes,
                  verboseIfDefault: true) { key in
      return "\(Preference.integer(for: key))KiB"
    }
    setUserOption(PK.secPrefech, type: .int, forName: MPVOption.Cache.cacheSecs, verboseIfDefault: true)

    setUserOption(PK.userAgent, type: .other, forName: MPVOption.Network.userAgent,
                  verboseIfDefault: true) { key in
      let ua = Preference.string(for: key)!
      return ua.isEmpty ? nil : ua
    }

    setUserOption(PK.transportRTSPThrough, type: .other, forName: MPVOption.Network.rtspTransport,
                  verboseIfDefault: true) { key in
      return String(describing: Preference.enum(for: .transportRTSPThrough) as
                    Preference.RTSPTransportation)
    }

    setUserOption(PK.ytdlEnabled, type: .other, forName: MPVOption.ProgramBehavior.ytdl,
                  verboseIfDefault: true) { key in
      let v = Preference.bool(for: .ytdlEnabled)
      if JavascriptPlugin.hasYTDL {
        return "no"
      }
      return v ? "yes" : "no"
    }
    setUserOption(PK.ytdlRawOptions, type: .string, forName: MPVOption.ProgramBehavior.ytdlRawOptions,
                  verboseIfDefault: true)
    chkErr(setOptionString(MPVOption.ProgramBehavior.resetOnNextFile,
            "\(MPVOption.PlaybackControl.abLoopA),\(MPVOption.PlaybackControl.abLoopB)", level: .verbose))

    setUserOption(PK.audioDriverEnableAVFoundation, type: .other, forName: MPVOption.Audio.ao,
                  verboseIfDefault: true) { key in
      Preference.bool(for: key) ? "avfoundation" : "coreaudio"
    }

    // Set user defined conf dir.
    if Preference.bool(for: .enableAdvancedSettings),
       Preference.bool(for: .useUserDefinedConfDir),
       var userConfDir = Preference.string(for: .userDefinedConfDir) {
      userConfDir = NSString(string: userConfDir).standardizingPath
      setOptionString("config", "yes")
      let status = setOptionString(MPVOption.ProgramBehavior.configDir, userConfDir)
      if status < 0 {
        Utility.showAlert("extra_option.config_folder", arguments: [userConfDir], disableMenus: true)
      }
    }

    // Set user defined options.
    if Preference.bool(for: .enableAdvancedSettings) {
      if let userOptions = Preference.value(for: .userOptions) as? [[String]] {
        if !userOptions.isEmpty {
          log("Setting \(userOptions.count) user configured mpv option values")
          userOptions.forEach { op in
            let status = setOptionString(op[0], op[1])
            if status < 0 {
              Utility.showAlert("extra_option.error", arguments:
                                  [op[0], op[1], status], disableMenus: true)
            }
          }
          log("Set \(userOptions.count) user configured mpv option values")
        }
      } else {
        Utility.showAlert("extra_option.cannot_read", disableMenus: true)
      }
    }

    // Load external scripts

    // Load keybindings. This is still required for mpv to handle media keys or apple remote.
    let userConfigs = PrefKeyBindingViewController.userConfigs
    var inputConfPath =  PrefKeyBindingViewController.defaultConfigs["IINA Default"]
    if let confFromUd = Preference.string(for: .currentInputConfigName) {
      if let currentConfigFilePath = Utility.getFilePath(Configs: userConfigs, forConfig: confFromUd, showAlert: false) {
        inputConfPath = currentConfigFilePath
      }
    }
    chkErr(setOptionalOptionString(MPVOption.Input.inputConf, inputConfPath, level: .verbose))

    // Receive log messages at warn level.
    chkErr(mpv_request_log_messages(mpv, MPVLogLevel))

    // Request tick event.
    // chkErr(mpv_request_event(mpv, MPV_EVENT_TICK, 1))

    // Set a custom function that should be called when there are new events.
    mpv_set_wakeup_callback(self.mpv, { (ctx) in
      let mpvController = unsafeBitCast(ctx, to: MPVController.self)
      mpvController.readEvents()
      }, mutableRawPointerOf(obj: self))

    // Observe properties.
    observeProperties.forEach { (k, v) in
      mpv_observe_property(mpv, 0, k, v)
    }

    // Initialize an uninitialized mpv instance. If the mpv instance is already running, an error is returned.
    chkErr(mpv_initialize(mpv))

    applyPreferredTrackOptions()

    // The option watch-later-options is not available until after the mpv instance is initialized.
    // Useful to log the value of this option as users often ask about what the Watch Later feature
    // remembers.
    if let watchLaterOptions = getString(MPVOption.WatchLater.watchLaterOptions) {
      let sorted = watchLaterOptions.components(separatedBy: ",").sorted().joined(separator: ",")
      log("Options mpv is configured to save in watch later files: \(sorted)")
    }

    // Must be called after mpv_initialize which sets the default value for hwdec-codecs.
    adjustCodecWhiteList()
    applyHardwareAccelerationWorkaround()

    // Set options that can be override by user's config. mpv will log user config when initialize,
    // so we put them here.
    chkErr(setOptionString(MPVOption.Video.vo, "libmpv", level: .verbose))
    chkErr(setOptionString(MPVOption.Window.keepaspect, "yes", level: .verbose))
    chkErr(setOptionString(MPVOption.Video.gpuHwdecInterop, "auto", level: .verbose))
  }

  /// Initialize the `mpv` renderer.
  ///
  /// This method creates and initializes the `mpv` renderer and sets the callback that `mpv` calls when a new video frame is available.
  ///
  /// - Note: Advanced control must be enabled for the screenshot command to work when the window flag is used. See issue
  ///         [#4822](https://github.com/iina/iina/issues/4822) for details.
  func mpvInitRendering() {
    guard let mpv else {
      fatalError("mpvInitRendering() should be called after mpv handle being initialized!")
    }
    let apiType = UnsafeMutableRawPointer(mutating: (MPV_RENDER_API_TYPE_OPENGL as NSString).utf8String)
    var openGLInitParams = mpv_opengl_init_params(get_proc_address: mpvGetOpenGLFunc,
                                                  get_proc_address_ctx: nil)
    withUnsafeMutablePointer(to: &openGLInitParams) { openGLInitParams in
      var advanced: CInt = 1
      withUnsafeMutablePointer(to: &advanced) { advanced in
        var params = [
          mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: apiType),
          mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: openGLInitParams),
          mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL, data: advanced),
          mpv_render_param()
        ]
        chkErr(mpv_render_context_create(&mpvRenderContext, mpv, &params))
      }
      openGLContext = CGLGetCurrentContext()
      mpv_render_context_set_update_callback(mpvRenderContext!, mpvUpdateCallback, mutableRawPointerOf(obj: player.mainWindow.videoView.videoLayer))
    }
  }

  /// Lock the OpenGL context associated with the mpv renderer and set it to be the current context for this thread.
  ///
  /// This method is needed to meet this requirement from `mpv/render.h`:
  ///
  /// If the OpenGL backend is used, for all functions the OpenGL context must be "current" in the calling thread, and it must be the
  /// same OpenGL context as the `mpv_render_context` was created with. Otherwise, undefined behavior will occur.
  ///
  /// - Reference: [mpv render.h](https://github.com/mpv-player/mpv/blob/master/libmpv/render.h)
  /// - Reference: [Concurrency and OpenGL](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/OpenGL-MacProgGuide/opengl_threading/opengl_threading.html)
  /// - Reference: [OpenGL Context](https://www.khronos.org/opengl/wiki/OpenGL_Context)
  /// - Attention: Do not forget to unlock the OpenGL context by calling `unlockOpenGLContext`
  func lockAndSetOpenGLContext() {
    CGLLockContext(openGLContext)
    CGLSetCurrentContext(openGLContext)
  }

  /// Unlock the OpenGL context associated with the mpv renderer.
  func unlockOpenGLContext() {
    CGLUnlockContext(openGLContext)
  }

  func mpvUninitRendering() {
    stopAirPlaySnapshotRequests()
    guard let mpvRenderContext else { return }
    mpv_render_context_set_update_callback(mpvRenderContext, nil, nil)
    mpv_render_context_free(mpvRenderContext)
    self.mpvRenderContext = nil
    mpv_destroy(mpv)
    mpv = nil
  }

  func mpvReportSwap() {
    guard let mpvRenderContext else { return }
    mpv_render_context_report_swap(mpvRenderContext)
  }

  func shouldRenderUpdateFrame() -> Bool {
    guard let mpvRenderContext else { return false }
    let flags: UInt64 = mpv_render_context_update(mpvRenderContext)
    return flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) > 0
  }

  /// Remove observers for IINA preferences and mpv properties.
  /// - Important: Observers **must** be removed before sending a `quit` command to mpv. Accessing a mpv core after it
  ///     has shutdown is not permitted by mpv and can trigger a crash. During shutdown mpv will emit property change events,
  ///     thus it is critical that observers be removed, otherwise they may access the core and trigger a crash.
  func removeObservers() {
    // Remove observers for IINA preferences. Must not attempt to change a mpv setting in response
    // to an IINA preference change while mpv is shutting down.
    removeOptionObservers()
    // Remove observers for mpv properties. Because 0 was passed for reply_userdata when registering
    // mpv property observers all observers can be removed in one call.
    mpv_unobserve_property(mpv, 0)
  }

  /// Remove observers for IINA preferences.
  private func removeOptionObservers() {
    ObjcUtils.silenced {
      self.optionObservers.forEach { (k, _) in
        UserDefaults.standard.removeObserver(self, forKeyPath: k)
      }
    }
  }

  /// Shutdown this mpv controller.
  func mpvQuit() {
    // Stop new snapshots now, then remove observers and quit after any active snapshot call. Keep
    // this barrier off the AppKit thread: libmpv client calls serialize through the core lock.
    disableAirPlaySnapshotRequests()
    // Remove observers for IINA preference. Must not attempt to change a mpv setting
    // in response to an IINA preference change while mpv is shutting down.
    removeOptionObservers()
    airPlaySnapshotQueue.async { [self] in
      self.airPlaySnapshotCallLock.lock()
      defer { self.airPlaySnapshotCallLock.unlock() }
      guard !self.hasReceivedShutdownEvent, self.mpv != nil else {
        return
      }
      // Remove all mpv property observers before quit. Because 0 was passed for reply_userdata
      // when registering mpv property observers, they can all be removed in one call.
      mpv_unobserve_property(self.mpv, 0)
      // The quit command is special and mpv executes it asynchronously. Do not hold the gate while
      // polling events; the sole reader does not take the gate in its poll or hook path.
      self.command(.quit, level: .verbose)
    }
  }

  // MARK: - Command & property

  private func makeCArgs(_ command: MPVCommand, _ args: [String?]) -> [String?] {
    if args.count > 0 && args.last == nil {
      Logger.fatal("Command do not need a nil suffix")
    }
    var strArgs = args
    strArgs.insert(command.rawValue, at: 0)
    strArgs.append(nil)
    return strArgs
  }

  // Send arbitrary mpv command.
  func command(_ command: MPVCommand, args: [String?] = [], checkError: Bool = true,
               level: Logger.Level = .debug, returnValueCallback: ((Int32) -> Void)? = nil) {
    guard mpv != nil else { return }
    log("Run command: \(command.rawValue) \(args.compactMap{$0}.joined(separator: " "))", level: level)
    let directAudioOutput: String?
    if command.rawValue == "set", args.count >= 2, args[0] == MPVOption.Audio.ao {
      directAudioOutput = args[1]
    } else {
      directAudioOutput = nil
    }
    let audioOutputWrite = directAudioOutput.map { _ in
      beginSynchronousAudioOutputWrite()
    }
    var cargs = makeCArgs(command, args).map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
    defer {
      for ptr in cargs {
        if (ptr != nil) {
          free(UnsafeMutablePointer(mutating: ptr!))
        }
      }
    }
    let changesPlaylist = MPVPlaylistMutationPolicy.invalidatesSnapshot(for: command.rawValue)
    if changesPlaylist { player.playlistStructureWillChange() }
    let loadTransitionToken = MPVPlaylistMutationPolicy.beginsFileLoadTransition(
      for: command.rawValue, arguments: args) ? reservePlaylistLoadTransition() : nil
    let returnValue = mpv_command(self.mpv, &cargs)
    if changesPlaylist { player.playlistStructureDidChange() }
    if returnValue < 0, let loadTransitionToken {
      cancelPendingPlaylistLoadTransition(loadTransitionToken)
    }
    if let directAudioOutput, let audioOutputWrite {
      finishSynchronousAudioOutputWrite(directAudioOutput, result: returnValue,
                                        writeToken: audioOutputWrite,
                                        intentSequence: audioOutputWrite.intentSequences.first)
    }
    if checkError {
      chkErr(returnValue)
    } else if let cb = returnValueCallback {
      cb(returnValue)
    }
  }

  /// Runs a shutdown-sensitive state save under the client-call gate if shutdown is not observed.
  /// The event reader waits for this transaction before it proceeds to shutdown cleanup.
  @discardableResult
  func performIfNotShutdown(_ body: () -> Void) -> Bool {
    airPlaySnapshotCallLock.lock()
    defer { airPlaySnapshotCallLock.unlock() }
    guard !hasReceivedShutdownEvent, mpv != nil else { return false }
    body()
    return true
  }

  /// Submits a lifecycle command only if shutdown has not already been observed. The event reader
  /// does not hold the client-call gate while polling, so synchronous stop can service unload hooks.
  @discardableResult
  func commandIfNotShutdown(_ command: MPVCommand, level: Logger.Level = .debug) -> Bool {
    airPlaySnapshotCallLock.lock()
    defer { airPlaySnapshotCallLock.unlock() }
    guard !hasReceivedShutdownEvent, mpv != nil else { return false }
    self.command(command, level: level)
    return true
  }

  private func reservePlaylistLoadTransition() -> UInt64 {
    let token = player.playlistLoadDidStart()
    $pendingPlaylistLoadTransitions.withLock { $0.append(token) }
    return token
  }

  private func consumeOrStartPlaylistLoadTransition() -> UInt64 {
    if let token = $pendingPlaylistLoadTransitions.withLock({ pending -> UInt64? in
      guard !pending.isEmpty else { return nil }
      return pending.removeFirst()
    }) {
      return token
    }
    return player.playlistLoadDidStart()
  }

  private func cancelPendingPlaylistLoadTransition(_ token: UInt64) {
    let removed = $pendingPlaylistLoadTransitions.withLock { pending -> Bool in
      guard let index = pending.firstIndex(of: token) else { return false }
      pending.remove(at: index)
      return true
    }
    if removed { player.playlistLoadDidFinish(token) }
  }

  func command(rawString: String, level: Logger.Level = .debug) -> Int32 {
    log("Run command: \(rawString)", level: level)
    // Key-binding actions enter through mpv_command_string instead of command(_:args:). Track
    // direct AO changes in single or semicolon-separated raw actions, including `async` prefixes.
    let parsedAudioOutputCommands = Self.rawCommandAudioOutputs(rawString)
    let audioOutputWrite: MPVAirPlayAudioOutputWriteToken?
    if parsedAudioOutputCommands.isEmpty {
      audioOutputWrite = nil
    } else {
      audioOutputWrite = beginSynchronousAudioOutputWrite(intentCount: parsedAudioOutputCommands.count)
    }
    let audioOutputCommands: [RawAudioOutputCommand]
    if let audioOutputWrite {
      audioOutputCommands = zip(parsedAudioOutputCommands, audioOutputWrite.intentSequences).map {
        pair in
        var command = pair.0
        command.intentSequence = pair.1
        return command
      }
    } else {
      audioOutputCommands = []
    }
    let lastSynchronousAudioOutputCommand = audioOutputCommands.last { !$0.isAsynchronous }
    let changesPlaylist = MPVPlaylistMutationPolicy.invalidatesSnapshot(in: rawString)
    if changesPlaylist { player.playlistStructureWillChange() }
    let result = mpv_command_string(mpv, rawString)
    if let audioOutputWrite {
      // mpv_command_string only confirms that an `async` command was accepted. Never publish its
      // source text as current AO state. Literal synchronous setters retain their exact target;
      // selectors and expanded values are read back after execution.
      let output: String?
      if result >= 0, let command = lastSynchronousAudioOutputCommand {
        output = command.output ?? getString(MPVOption.Audio.ao)
      } else {
        output = nil
      }
      finishSynchronousAudioOutputWrite(output, result: result,
                                        writeToken: audioOutputWrite,
                                        intentSequence: lastSynchronousAudioOutputCommand?.intentSequence,
                                        recordsDirectAudioOutputIntent:
                                          lastSynchronousAudioOutputCommand != nil)
    }
    if let audioOutputWrite {
      for command in audioOutputCommands where command.isAsynchronous {
        recordAcceptedRawAsyncAudioOutputIntent(command.output,
                                                intentSequence: command.intentSequence,
                                                writeToken: audioOutputWrite)
      }
    }
    if changesPlaylist { player.playlistStructureDidChange() }
    return result
  }

  /// Splits key-binding commands only at unquoted semicolons. mpv accepts single, double and
  /// custom-quoted arguments; escaped characters cannot terminate a quoted value.
  private static func rawCommandSegments(_ rawString: String) -> [String] {
    let characters = Array(rawString)
    var segments: [String] = []
    var segment = ""
    var quote: Character?
    var customQuoteDelimiter: Character?
    var index = 0

    while index < characters.count {
      let character = characters[index]
      if let delimiter = customQuoteDelimiter {
        if character == delimiter, index + 1 < characters.count, characters[index + 1] == "`" {
          segment.append(character)
          segment.append("`")
          customQuoteDelimiter = nil
          index += 2
        } else {
          segment.append(character)
          index += 1
        }
        continue
      }

      if let currentQuote = quote {
        segment.append(character)
        if currentQuote == "\"", character == "\\", index + 1 < characters.count {
          segment.append(characters[index + 1])
          index += 2
        } else {
          if character == currentQuote { quote = nil }
          index += 1
        }
        continue
      }

      if character == "\\", index + 1 < characters.count {
        segment.append(character)
        segment.append(characters[index + 1])
        index += 2
      } else if character == "\"" || character == "'" {
        quote = character
        segment.append(character)
        index += 1
      } else if character == "`", index + 1 < characters.count {
        segment.append(character)
        segment.append(characters[index + 1])
        customQuoteDelimiter = characters[index + 1]
        index += 2
      } else if character == ";" {
        segments.append(segment)
        segment = ""
        index += 1
      } else {
        segment.append(character)
        index += 1
      }
    }
    segments.append(segment)
    return segments
  }

  /// Preserves quoted whitespace while splitting one already-delimited mpv command into tokens.
  private static func rawCommandTokens(_ command: String) -> [String] {
    let characters = Array(command)
    var tokens: [String] = []
    var token = ""
    var quote: Character?
    var customQuoteDelimiter: Character?
    var index = 0

    func finishToken() {
      if !token.isEmpty {
        tokens.append(token)
        token = ""
      }
    }

    while index < characters.count {
      let character = characters[index]
      if let delimiter = customQuoteDelimiter {
        token.append(character)
        if character == delimiter, index + 1 < characters.count, characters[index + 1] == "`" {
          token.append("`")
          customQuoteDelimiter = nil
          index += 2
        } else {
          index += 1
        }
        continue
      }

      if let currentQuote = quote {
        token.append(character)
        if currentQuote == "\"", character == "\\", index + 1 < characters.count {
          token.append(characters[index + 1])
          index += 2
        } else {
          if character == currentQuote { quote = nil }
          index += 1
        }
        continue
      }

      if character == "\\", index + 1 < characters.count {
        token.append(character)
        token.append(characters[index + 1])
        index += 2
      } else if character == "\"" || character == "'" {
        quote = character
        token.append(character)
        index += 1
      } else if character == "`", index + 1 < characters.count {
        customQuoteDelimiter = characters[index + 1]
        token.append(character)
        token.append(characters[index + 1])
        index += 2
      } else if character.isWhitespace {
        finishToken()
        index += 1
      } else {
        token.append(character)
        index += 1
      }
    }
    finishToken()
    return tokens
  }

  /// Decodes only literal tokens we can restore exactly. Expansion and escape syntax is deferred
  /// to mpv and therefore cannot safely be recorded as the requested AO string.
  private static func literalRawCommandToken(_ token: String) -> String? {
    guard !token.contains("\\"), !token.contains("$") else { return nil }
    if token.count >= 2, let first = token.first, (first == "\"" || first == "'"), token.last == first {
      let value = String(token.dropFirst().dropLast())
      guard !value.contains(first) else { return nil }
      return value
    }
    guard !token.contains("\""), !token.contains("'"), !token.contains("`") else { return nil }
    return token
  }

  private static func rawCommandAudioOutputs(_ rawString: String) -> [RawAudioOutputCommand] {
    var commands: [RawAudioOutputCommand] = []
    for segment in rawCommandSegments(rawString) {
      let tokens = rawCommandTokens(segment)
      var commandIndex = 0
      var isAsynchronous = false
      while commandIndex < tokens.count,
            MPVPlaylistMutationPolicy.commandPrefixes.contains(String(tokens[commandIndex])) {
        if tokens[commandIndex] == "async" { isAsynchronous = true }
        commandIndex += 1
      }
      guard commandIndex < tokens.count else { continue }
      let command = tokens[commandIndex]
      var propertyIndex = commandIndex + 1
      if command == "cycle-values",
         propertyIndex < tokens.count,
         literalRawCommandToken(tokens[propertyIndex]) == "!reverse" {
        propertyIndex += 1
      }
      guard propertyIndex < tokens.count,
            literalRawCommandToken(tokens[propertyIndex]) == MPVOption.Audio.ao else { continue }
      let output: String?
      switch command {
      case "set":
        guard propertyIndex + 1 < tokens.count else { continue }
        output = literalRawCommandToken(tokens[propertyIndex + 1])
      case "cycle":
        output = nil
      case "cycle-values":
        guard propertyIndex + 1 < tokens.count else { continue }
        output = nil
      default:
        continue
      }
      commands.append(RawAudioOutputCommand(output: output, isAsynchronous: isAsynchronous))
    }
    return commands
  }

  private func recordDirectAudioOutputIntent(_ output: String, intentSequence: UInt64,
                                            in snapshot: inout MPVAirPlaySnapshot) {
    guard intentSequence > snapshot.directAudioOutputIntentSequence else { return }
    snapshot.directAudioOutput = output
    snapshot.directAudioOutputIntentSequence = intentSequence
    snapshot.directAudioOutputGeneration &+= 1
    snapshot.pendingRawAudioOutputIntents.removeAll { $0.intentSequence <= intentSequence }
  }

  /// Applies an observed AO value and consumes only the newest matching raw async request.
  private func observeAudioOutput(_ output: String?, in snapshot: inout MPVAirPlaySnapshot) {
    snapshot.audioOutput = output
    snapshot.audioOutputGeneration &+= 1
    guard let output,
          let matchingIndex = snapshot.pendingRawAudioOutputIntents.indices
            .filter({
              let intent = snapshot.pendingRawAudioOutputIntents[$0]
              if let intentOutput = intent.output { return intentOutput == output }
              return intent.previousOutput != output
            })
            .max(by: {
              snapshot.pendingRawAudioOutputIntents[$0].intentSequence
                < snapshot.pendingRawAudioOutputIntents[$1].intentSequence
            }) else { return }
    let intent = snapshot.pendingRawAudioOutputIntents[matchingIndex]
    if intent.intentSequence > snapshot.directAudioOutputIntentSequence {
      recordDirectAudioOutputIntent(output, intentSequence: intent.intentSequence, in: &snapshot)
    } else {
      snapshot.pendingRawAudioOutputIntents.removeAll { $0.intentSequence <= intent.intentSequence }
    }
  }

  private func recordAcceptedRawAsyncAudioOutputIntent(_ output: String?, intentSequence: UInt64,
                                                       writeToken: MPVAirPlayAudioOutputWriteToken) {
    $airPlaySnapshot.withLock { snapshot in
      guard intentSequence > snapshot.directAudioOutputIntentSequence else { return }
      if let output, snapshot.audioOutput == output {
        // The current property already confirms this literal target, including an explicit null.
        recordDirectAudioOutputIntent(output, intentSequence: intentSequence, in: &snapshot)
        return
      }
      if output == nil, let observedOutput = snapshot.audioOutput,
         observedOutput != writeToken.initialAudioOutput,
         observedOutput != snapshot.directAudioOutput,
         snapshot.audioOutputGeneration > writeToken.generationBeforeWrite + 1 {
        // An asynchronous selector may finish before this call returns and its property event
        // may already have been consumed. The changed snapshot is the best available confirmation.
        recordDirectAudioOutputIntent(observedOutput, intentSequence: intentSequence, in: &snapshot)
        return
      }
      snapshot.pendingRawAudioOutputIntents.append(MPVAirPlayPendingAudioOutputIntent(
        output: output, intentSequence: intentSequence, previousOutput: snapshot.audioOutput))
      snapshot.pendingRawAudioOutputIntents.sort { $0.intentSequence < $1.intentSequence }
      if snapshot.pendingRawAudioOutputIntents.count > 16 {
        snapshot.pendingRawAudioOutputIntents.removeFirst(
          snapshot.pendingRawAudioOutputIntents.count - 16)
      }
    }
    DispatchQueue.main.async { [weak self] in
      self?.player.airPlayAudio.playbackSnapshotChanged()
    }
  }

  @discardableResult
  func asyncCommand(_ command: MPVCommand, args: [String?] = [], checkError: Bool = true,
                    replyUserdata: UInt64, level: Logger.Level = .debug) -> Int32 {
    guard mpv != nil else { return MPV_ERROR_UNINITIALIZED.rawValue }
    log("Asynchronously run command: \(command.rawValue) \(args.compactMap{$0}.joined(separator: " "))",
        level: level)
    var cargs = makeCArgs(command, args).map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
    defer {
      for ptr in cargs {
        if (ptr != nil) {
          free(UnsafeMutablePointer(mutating: ptr!))
        }
      }
    }
    let returnValue = mpv_command_async(self.mpv, replyUserdata, &cargs)
    if checkError {
      chkErr(returnValue)
    }
    return returnValue
  }

  /// Submit an AirPlay request away from AppKit and report immediate errors on the main queue.
  /// Snapshot batches, AirPlay requests, and quit share this serial queue and shutdown gate.
  func submitAirPlayCommand(_ submission: @escaping () -> Int32,
                            completion: @escaping (Int32) -> Void) {
    airPlaySnapshotQueue.async { [weak self] in
      guard let self else { return }
      self.airPlaySnapshotCallLock.lock()
      guard !self.hasReceivedShutdownEvent, self.mpv != nil else {
        self.airPlaySnapshotCallLock.unlock()
        return
      }
      let result = submission()
      self.airPlaySnapshotCallLock.unlock()
      guard !self.hasReceivedShutdownEvent else { return }
      let completionResult: Int32
      if result == MPV_ERROR_EVENT_QUEUE_FULL.rawValue {
        completionResult = self.beginAirPlayEventQueueOverflowRecovery()
          ? result : MPV_ERROR_UNINITIALIZED.rawValue
      } else {
        completionResult = result
      }
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.hasReceivedShutdownEvent else { return }
        completion(completionResult)
      }
    }
  }

  /// Restore Reel's saved local output after async AirPlay restoration hits sustained queue
  /// pressure. This bypasses the bounded async retry queue, runs away from AppKit, and stays
  /// serialized with snapshot calls and shutdown. The event reader remains free to drain events.
  func restoreAirPlayAudioOutput(_ output: String, completion: @escaping (Int32) -> Void) {
    airPlaySnapshotQueue.async { [weak self] in
      guard let self else { return }
      if !self.hasReceivedShutdownEvent, let mpv = self.mpv {
        // Make sure previous accepted async requests have finished before using the synchronous
        // client API. The event reader is a separate queue and continues to service their replies.
        mpv_wait_async_requests(mpv)
      }

      self.airPlaySnapshotCallLock.lock()
      let result: Int32
      if self.hasReceivedShutdownEvent || self.mpv == nil {
        result = MPV_ERROR_UNINITIALIZED.rawValue
      } else {
        let setResult = self.setString(MPVOption.Audio.ao, output, level: .warning,
                                       recordsDirectAudioOutputIntent: false)
        result = setResult < 0 ? setResult : self.command(rawString: "ao-reload", level: .warning)
      }
      self.airPlaySnapshotCallLock.unlock()

      DispatchQueue.main.async { [weak self] in
        guard let self, !self.hasReceivedShutdownEvent else { return }
        completion(result)
      }
    }
  }

  /// Starts one recovery for either an overflow event or a rejected async submission.
  /// Returns false only if shutdown already disabled AirPlay polling.
  @discardableResult
  private func beginAirPlayEventQueueOverflowRecovery() -> Bool {
    guard !hasReceivedShutdownEvent else { return false }
    let recovery = $airPlaySnapshotRequests.withLock { state -> (available: Bool, start: Bool) in
      state.generation &+= 1
      state.pendingTokens.removeAll()
      guard !state.isDisabled else { return (false, false) }
      guard !state.isRecoveringFromQueueOverflow else { return (true, false) }
      state.isRecoveringFromQueueOverflow = true
      return (true, true)
    }
    if recovery.start { recoverAirPlayAsyncRequestsAfterQueueOverflow() }
    return recovery.available
  }

  func observe(property: String, format: mpv_format = MPV_FORMAT_DOUBLE) {
    mpv_observe_property(mpv, 0, property, format)
  }

  /// Request a compact playback clock sample without blocking the caller. The replies are handled
  /// on mpv's event queue and never forwarded to the main queue as plugin events.
  func requestAirPlayPlaybackSnapshot() {
    let properties: [(String, mpv_format)] = [
      (MPVProperty.timePos, MPV_FORMAT_DOUBLE),
      (MPVProperty.audioPts, MPV_FORMAT_DOUBLE),
      (MPVProperty.pausedForCache, MPV_FORMAT_FLAG),
      (MPVProperty.estimatedVfFps, MPV_FORMAT_DOUBLE),
      (MPVProperty.containerFps, MPV_FORMAT_DOUBLE)
    ]
    $airPlaySnapshotRequests.withLock { state in
      guard !state.isDisabled, !state.isRecoveringFromQueueOverflow,
            !hasReceivedShutdownEvent, state.pendingTokens.isEmpty else { return }
      state.generation &+= 1
      for index in properties.indices {
        state.pendingTokens.insert(Self.airPlaySnapshotToken(state.generation, propertyIndex: index))
      }
      let generation = state.generation
      airPlaySnapshotQueue.async { [weak self] in
        guard let self else { return }
        self.airPlaySnapshotCallLock.lock()
        defer { self.airPlaySnapshotCallLock.unlock() }
        let mpv = self.$airPlaySnapshotRequests.withLock { state -> OpaquePointer? in
          guard state.generation == generation, !state.isDisabled,
                !state.isRecoveringFromQueueOverflow,
                !self.hasReceivedShutdownEvent, let mpv = self.mpv else {
            if state.generation == generation { state.pendingTokens.removeAll() }
            return nil
          }
          return mpv
        }
        guard let mpv else { return }
        for (index, property) in properties.enumerated() {
          let token = Self.airPlaySnapshotToken(generation, propertyIndex: index)
          if mpv_get_property_async(mpv, token, property.0, property.1) < 0 {
            self.$airPlaySnapshotRequests.withLock { state in
              if state.generation == generation { state.pendingTokens.remove(token) }
            }
          }
        }
      }
    }
  }

  /// Stop new snapshots and let an in-flight client call finish before destroying its mpv handle.
  private func stopAirPlaySnapshotRequests() {
    disableAirPlaySnapshotRequests()
    airPlaySnapshotQueue.sync {}
  }

  /// Prevent any additional snapshot batches from being submitted.
  private func disableAirPlaySnapshotRequests() {
    $airPlaySnapshotRequests.withLock { state in
      state.isDisabled = true
      state.pendingTokens.removeAll()
    }
  }

  // Set property
  func setFlag(_ name: String, _ flag: Bool, level: Logger.Level = .debug) {
    log("Set property: \(name)=\(flag)", level: level)
    var data: Int32 = flag ? 1 : 0
    mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &data)
  }

  func setInt(_ name: String, _ value: Int, level: Logger.Level = .debug) {
    log("Set property: \(name)=\(value)", level: level)
    var data = Int64(value)
    mpv_set_property(mpv, name, MPV_FORMAT_INT64, &data)
  }

  func setDouble(_ name: String, _ value: Double, level: Logger.Level = .debug) {
    log("Set property: \(name)=\(value)", level: level)
    var data = value
    mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
  }

  @discardableResult
  func setDoubleAsync(_ name: String, _ value: Double, replyUserdata: UInt64,
                      level: Logger.Level = .debug) -> Int32 {
    log("Set property asynchronously: \(name)=\(value)", level: level)
    var data = value
    return withUnsafeMutablePointer(to: &data) { pointer in
      mpv_set_property_async(mpv, replyUserdata, name, MPV_FORMAT_DOUBLE, pointer)
    }
  }

  @discardableResult
  func setStringAsync(_ name: String, _ value: String, replyUserdata: UInt64,
                      level: Logger.Level = .debug) -> Int32 {
    log("Set property asynchronously: \(name)=\(value)", level: level)
    return name.withCString { namePointer in
      value.withCString { valuePointer in
        mpv_set_property_async(mpv, replyUserdata, namePointer, MPV_FORMAT_STRING,
                               UnsafeMutableRawPointer(mutating: valuePointer))
      }
    }
  }

  @discardableResult
  func setString(_ name: String, _ value: String, level: Logger.Level = .debug) -> Int32 {
    setString(name, value, level: level, recordsDirectAudioOutputIntent: true)
  }

  @discardableResult
  private func setString(_ name: String, _ value: String, level: Logger.Level,
                         recordsDirectAudioOutputIntent: Bool) -> Int32 {
    log("Set property: \(name)=\(value)", level: level)
    let isAudioOutput = name == MPVOption.Audio.ao
    let audioOutputWrite = isAudioOutput
      ? beginSynchronousAudioOutputWrite(recordsDirectAudioOutputIntent: recordsDirectAudioOutputIntent)
      : nil
    let result = mpv_set_property_string(mpv, name, value)
    if let audioOutputWrite {
      finishSynchronousAudioOutputWrite(value, result: result,
                                        writeToken: audioOutputWrite,
                                        intentSequence: audioOutputWrite.intentSequences.first,
                                        recordsDirectAudioOutputIntent: recordsDirectAudioOutputIntent)
    }
    return result
  }

  /// Marks a synchronous AO change before libmpv runs and serializes direct setters with one another.
  private func beginSynchronousAudioOutputWrite(
    intentCount: Int = 1,
    recordsDirectAudioOutputIntent: Bool = true
  ) -> MPVAirPlayAudioOutputWriteToken {
    airPlayAudioOutputWriteLock.lock()
    return $airPlaySnapshot.withLock { snapshot in
      let initialAudioOutput = snapshot.audioOutput
      snapshot.audioOutputChangesInFlight += 1
      snapshot.audioOutputGeneration &+= 1
      var intentSequences: [UInt64] = []
      if recordsDirectAudioOutputIntent {
        for _ in 0..<max(0, intentCount) {
          snapshot.nextDirectAudioOutputIntentSequence &+= 1
          intentSequences.append(snapshot.nextDirectAudioOutputIntentSequence)
        }
      }
      return MPVAirPlayAudioOutputWriteToken(
        generationBeforeWrite: snapshot.audioOutputGeneration,
        intentSequences: intentSequences,
        initialAudioOutput: initialAudioOutput)
    }
  }

  /// Publishes the newest successful direct AO intent and then releases the setter lock.
  private func finishSynchronousAudioOutputWrite(_ value: String?, result: Int32,
                                                 writeToken: MPVAirPlayAudioOutputWriteToken,
                                                 intentSequence: UInt64?,
                                                 recordsDirectAudioOutputIntent: Bool = true) {
    $airPlaySnapshot.withLock { snapshot in
      if result >= 0 {
        if let value {
          // A newer observed property event may have completed while this caller was in libmpv.
          if snapshot.audioOutputGeneration == writeToken.generationBeforeWrite {
            snapshot.audioOutput = value
          }
          if recordsDirectAudioOutputIntent, let intentSequence {
            recordDirectAudioOutputIntent(value, intentSequence: intentSequence, in: &snapshot)
          }
        }
      }
      snapshot.audioOutputChangesInFlight = max(0, snapshot.audioOutputChangesInFlight - 1)
      snapshot.audioOutputGeneration &+= 1
    }
    airPlayAudioOutputWriteLock.unlock()
    DispatchQueue.main.async { [weak self] in
      self?.player.airPlayAudio.playbackSnapshotChanged()
    }
  }

  @discardableResult
  func setStringToDefault(_ name: String, level: Logger.Level = .debug) -> Int32 {
    guard let value = MPVOptionDefaults.shared.getString(name) else {
      log("Failed to obtain default for option: \(name)", level: .error)
      return MPV_ERROR_OPTION_NOT_FOUND.rawValue
    }
    log("Set property to default: \(name)=\(value)", level: level)
    return mpv_set_property_string(mpv, name, value)
  }

  func getEnum<T: MPVOptionValue>(_ name: String) -> T {
    guard let value = getString(name) else {
      return T.defaultValue
    }
    return T.init(rawValue: value) ?? T.defaultValue
  }

  func getInt(_ name: String) -> Int {
    var data = Int64()
    mpv_get_property(mpv, name, MPV_FORMAT_INT64, &data)
    return Int(data)
  }

  /// Like `getInt`, but `nil` when mpv cannot provide the property right now.
  func getIntIfAvailable(_ name: String) -> Int? {
    var data = Int64()
    guard mpv_get_property(mpv, name, MPV_FORMAT_INT64, &data) >= 0 else { return nil }
    return Int(data)
  }

  func getDouble(_ name: String) -> Double {
    var data = Double()
    mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
    return data
  }

  /// Like `getDouble`, but `nil` when mpv cannot provide the property right now.
  func getDoubleIfAvailable(_ name: String) -> Double? {
    var data = Double()
    guard mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &data) >= 0, data.isFinite else { return nil }
    return data
  }

  func getFlag(_ name: String) -> Bool {
    var data = Int32()
    mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &data)
    return data > 0
  }

  func getString(_ name: String) -> String? {
    let cstr = mpv_get_property_string(mpv, name)
    let str: String? = cstr == nil ? nil : String(cString: cstr!)
    mpv_free(cstr)
    return str
  }

  /** Get filter. only "af" or "vf" is supported for name */
  func getFilters(_ name: String) -> [MPVFilter] {
    Logger.ensure(name == MPVProperty.vf || name == MPVProperty.af, "getFilters() do not support \(name)!")

    var result: [MPVFilter] = []
    var node = mpv_node()
    mpv_get_property(mpv, name, MPV_FORMAT_NODE, &node)
    guard let filters = (try? MPVNode.parse(node)!) as? [[String: Any?]] else { return result }
    filters.forEach { f in
      let filter = MPVFilter(name: f["name"] as! String,
                             label: f["label"] as? String,
                             params: f["params"] as? [String: String])
      result.append(filter)
    }
    mpv_free_node_contents(&node)
    return result
  }

  /// Remove the audio or video filter at the given index in the list of filters.
  ///
  /// Previously IINA removed filters using the mpv `af remove` and `vf remove` commands described in the
  /// [Input Commands that are Possibly Subject to Change](https://mpv.io/manual/stable/#input-commands-that-are-possibly-subject-to-change)
  /// section of the mpv manual. The behavior of the remove command is described in the [video-filters](https://mpv.io/manual/stable/#video-filters)
  /// section of the manual under the entry for `--vf-remove-filter`.
  ///
  /// When searching for the filter to be deleted the remove command takes into consideration the order of filter parameters. The
  /// expectation is that the application using the mpv client will provide the filter to the remove command in the same way it was
  /// added. However IINA doe not always know how a filter was added. Filters can be added to mpv outside of IINA therefore it is not
  /// possible for IINA to know how filters were added. IINA obtains the filter list from mpv using `mpv_get_property`. The
  /// `mpv_node` tree returned for a filter list stores the filter parameters in a `MPV_FORMAT_NODE_MAP`. The key value pairs in a
  /// `MPV_FORMAT_NODE_MAP` are in **random** order. As a result sometimes the order of filter parameters in the filter string
  /// representation given by IINA to the mpv remove command would not match the order of parameters given when the filter was
  /// added to mpv and the remove command would fail to remove the filter. This was reported in
  /// [IINA issue #3620 Audio filters with same name cannot be removed](https://github.com/iina/iina/issues/3620).
  ///
  /// The issue of `mpv_get_property` returning filter parameters in random order even though the remove command is sensitive to
  /// filter parameter order was raised with the mpv project in
  /// [mpv issue #9841 mpv_get_property returns filter params in unordered map breaking remove](https://github.com/mpv-player/mpv/issues/9841)
  /// The response from the mpv project confirmed that the parameters in a `MPV_FORMAT_NODE_MAP` **must** be considered to
  /// be in random order even if they appear to be ordered. The recommended methods for removing filters is to use labels, which
  /// IINA does for filters it creates or removing based on position in the filter list. This method supports removal based on the
  /// position within the list of filters.
  ///
  /// The recommended implementation is to get the entire list of filters using `mpv_get_property`, remove the filter from the
  /// `mpv_node` tree returned by that method and then set the list of filters using `mpv_set_property`. This is the approach
  /// used by this method.
  /// - Parameter name: The kind of filter identified by the mpv property name, `MPVProperty.af` or `MPVProperty.vf`.
  /// - Parameter index: Index of the filter to be removed.
  /// - Returns: `true` if the filter was successfully removed, `false` if the filter was not removed.
  func removeFilter(_ name: String, _ index: Int) -> Bool {
    Logger.ensure(name == MPVProperty.vf || name == MPVProperty.af, "removeFilter() does not support \(name)!")

    // Get the current list of filters from mpv as a mpv_node tree.
    var oldNode = mpv_node()
    defer { mpv_free_node_contents(&oldNode) }
    mpv_get_property(mpv, name, MPV_FORMAT_NODE, &oldNode)

    let oldList = oldNode.u.list!.pointee

    // If the user uses mpv's JSON-based IPC protocol to make changes to mpv's filters behind IINA's
    // back then there is a very small window of vulnerability where the list of filters displayed
    // by IINA may be stale and therefore the index to remove may be invalid. IINA listens for
    // changes to mpv's filter properties and updates the filters displayed when changes occur, so
    // it is unlikely in practice that this method will be called with an invalid index, but we will
    // validate the index nonetheless to insure this code does not trigger a crash.
    guard index < oldList.num else {
      log("Found \(oldList.num) \(name) filters, index of filter to remove (\(index)) is invalid",
          level: .error)
      return false
    }

    // The documentation for mpv_node states:
    // "If mpv writes this struct (e.g. via mpv_get_property()), you must not change the data."
    // So the approach taken is to create new top level node objects as those need to be modified in
    // order to remove the filter, and reuse the lower level node objects representing the filters.
    // First we create a new node list that is one entry smaller than the current list of filters.
    let newNum = oldList.num - 1
    let newValues = UnsafeMutablePointer<mpv_node>.allocate(capacity: Int(newNum))
    defer {
      newValues.deinitialize(count: Int(newNum))
      newValues.deallocate()
    }
    var newList = mpv_node_list()
    newList.num = newNum
    newList.values = newValues

    // Make the new list of values point to the same values in the old list, skipping the entry to
    // be removed.
    var newValuesPtr = newValues
    var oldValuesPtr = oldList.values!
    for i in 0 ..< oldList.num {
      if i != index {
        newValuesPtr.pointee = oldValuesPtr.pointee
        newValuesPtr = newValuesPtr.successor()
      }
      oldValuesPtr = oldValuesPtr.successor()
    }

    // Add the new list to a new node.
    let newListPtr = UnsafeMutablePointer<mpv_node_list>.allocate(capacity: 1)
    defer {
      newListPtr.deinitialize(count: 1)
      newListPtr.deallocate()
    }
    newListPtr.pointee = newList
    var newNode = mpv_node()
    newNode.format = MPV_FORMAT_NODE_ARRAY
    newNode.u.list = newListPtr

    // Set the list of filters using the new node that leaves out the filter to be removed.
    log("Set property: \(name)=<a mpv node>")
    mpv_set_property(mpv, name, MPV_FORMAT_NODE, &newNode)
    return true
  }

  /** Set filter. only "af" or "vf" is supported for name */
  func setFilters(_ name: String, filters: [MPVFilter]) {
    Logger.ensure(name == MPVProperty.vf || name == MPVProperty.af, "setFilters() do not support \(name)!")
    let cmd = name == MPVProperty.vf ? MPVCommand.vf : MPVCommand.af

    let str = filters.map { $0.stringFormat }.joined(separator: ",")
    command(cmd, args: ["set", str], checkError: false) { returnValue in
      if returnValue < 0 {
        Utility.showAlert("filter.incorrect")
        // reload data in filter setting window
        self.player.postNotification(.iinaVFChanged)
      }
    }
  }

  func getNode(_ name: String) -> Any? {
    var node = mpv_node()
    mpv_get_property(mpv, name, MPV_FORMAT_NODE, &node)
    let parsed = try? MPVNode.parse(node)
    mpv_free_node_contents(&node)
    return parsed
  }

  func setNode(_ name: String, _ value: Any) {
    guard var node = try? MPVNode.create(value) else {
      log("setNode: cannot encode value for \(name)", level: .error)
      return
    }
    log("Set property: \(name)=<a mpv node>")
    mpv_set_property(mpv, name, MPV_FORMAT_NODE, &node)
    MPVNode.free(node)
  }

  /// Returns the given node map value as an `Int`.
  ///
  /// This method is intended to be used when extracting values from a `MPV_FORMAT_NODE_MAP` `mpv_node` that contains
  /// mixed types.
  /// - Note: Zero is returned for `nil` values to match the behavior of `getInt`.
  /// - Parameter value:Value from a mpv node map.
  /// - Returns: The given value converted to an `Int`.
  static func nodeValueAsInt(_ value: Any?) -> Int {
    guard let asInt64 = value as? Int64 else { return 0 }
    return Int(asInt64)
  }

  // MARK: - Hooks

  func addHook(_ name: MPVHook, priority: Int32 = 0, hook: MPVHookValue) {
    $hooks.withLock {
      mpv_hook_add(mpv, hookCounter, name.rawValue, priority)
      $0[hookCounter] = hook
      hookCounter += 1
    }
  }

  func removeHooks(withIdentifier id: String) {
    $hooks.withLock { hooks in
      hooks.filter { (k, v) in v.isJavascript && v.id == id }.keys.forEach { hooks.removeValue(forKey: $0) }
    }
  }

  // MARK: - Events

  // Read event and handle it async
  private func readEvents() {
    guard !hasReceivedShutdownEvent else { return }
    queue.async { self.readEventsOnQueue() }
  }

  /// The sole event-queue reader. An optional completion runs after draining through MPV_EVENT_NONE.
  private func readEventsOnQueue(afterDraining completion: (() -> Void)? = nil) {
    guard !hasReceivedShutdownEvent, let mpv else {
      completion?()
      return
    }
    while !hasReceivedShutdownEvent {
      // Keep polling independent of client-call submission: libmpv may be waiting for an event
      // hook while a queued API call is in progress.
      let event = mpv_wait_event(mpv, 0)!
      let eventId = event.pointee.event_id
      if eventId == MPV_EVENT_SHUTDOWN {
        // Publish terminal state immediately so work queued behind the call gate cannot begin.
        hasReceivedShutdownEvent = true
        airPlaySnapshotCallLock.lock()
        $airPlaySnapshotRequests.withLock { state in
          state.isDisabled = true
          state.pendingTokens.removeAll()
        }
        airPlaySnapshotCallLock.unlock()
      }
      // Do not deal with mpv-event-none
      if eventId == MPV_EVENT_NONE {
        break
      }
      if eventId == MPV_EVENT_SHUTDOWN {
        // Snapshot calls use a separate queue. Close that path and drain it before notifying the
        // main thread, which may destroy the mpv handle as soon as it handles this event.
        airPlaySnapshotQueue.sync {}
      }
      handleEvent(event)
      // Must stop reading events once the mpv core is shutdown.
      if eventId == MPV_EVENT_SHUTDOWN {
        break
      }
    }
    completion?()
  }

  // Handle the event
  private func handleEvent(_ event: UnsafePointer<mpv_event>) {
    let eventId = event.pointee.event_id

    switch eventId {
    case MPV_EVENT_SHUTDOWN:
      DispatchQueue.main.async {
        self.player.mpvHasShutdown()
      }

    case MPV_EVENT_LOG_MESSAGE:
      let dataOpaquePtr = OpaquePointer(event.pointee.data)
      let msg = UnsafeMutablePointer<mpv_event_log_message>(dataOpaquePtr)
      let prefix = String(cString: (msg?.pointee.prefix)!)
      let level = String(cString: (msg?.pointee.level)!)
      let text = String(cString: (msg?.pointee.text)!).trimmingCharacters(in: .newlines)
      log("[\(prefix)] \(level): \(text)", level: logLevelMap[level] ?? .verbose)

    case MPV_EVENT_HOOK:
      let userData = event.pointee.reply_userdata
      let hookEvent = event.pointee.data.bindMemory(to: mpv_event_hook.self, capacity: 1).pointee
      let hookID = hookEvent.id
      guard let hook = $hooks.withLock({ $0[userData] }) else {
        // Hook not found, probably because it's from an unloaded plugin.
        // Still need to call hook_continue otherwise it will stuck.
        log("Hook \(hookID) not found", level: .warning)
        mpv_hook_continue(self.mpv, hookID)
        break
      }
      hook.call {
        mpv_hook_continue(self.mpv, hookID)
      }

    case MPV_EVENT_PROPERTY_CHANGE:
      let dataOpaquePtr = OpaquePointer(event.pointee.data)
      if let property = UnsafePointer<mpv_event_property>(dataOpaquePtr)?.pointee {
        let propertyName = String(cString: property.name)
        handlePropertyChange(propertyName, property)
      }

    case MPV_EVENT_GET_PROPERTY_REPLY:
      if handleAirPlaySnapshotReply(event) { return }

    case MPV_EVENT_AUDIO_RECONFIG: break

    case MPV_EVENT_VIDEO_RECONFIG:
      DispatchQueue.main.async { self.player.onVideoReconfig() }

    case MPV_EVENT_START_FILE:
      let abandonedTransition = activePlaylistLoadTransition
      activePlaylistLoadTransition = consumeOrStartPlaylistLoadTransition()
      if let abandonedTransition {
        DispatchQueue.main.async { self.player.playlistLoadDidFinish(abandonedTransition) }
      }
      $airPlaySnapshot.withLock { $0.resetMediaValues() }
      $airPlaySnapshotRequests.withLock {
        $0.generation &+= 1
        $0.pendingTokens.removeAll()
      }
      guard let path = getString(MPVProperty.path) else { break }
      DispatchQueue.main.async { [self] in
        player.info.state = .starting
        player.fileStarted(path: path)
      }

    case MPV_EVENT_FILE_LOADED:
      let transition = activePlaylistLoadTransition
      activePlaylistLoadTransition = nil
      DispatchQueue.main.async {
        self.player.fileLoaded()
        self.player.playlistLoadDidFinish(transition)
      }

    case MPV_EVENT_SEEK:
      DispatchQueue.main.async { [self] in
        player.info.isSeeking = true
        // When playback is paused the display link may be shutdown in order to not waste energy.
        // It must be running when seeking to avoid slowdowns caused by mpv waiting for IINA to call
        // mpv_render_report_swap.
        player.mainWindow.videoView.displayActive()
        if needRecordSeekTime {
          recordedSeekStartTime = CACurrentMediaTime()
        }
        player.syncUI(.time)
        let current = player.info.videoPosition?.stringRepresentation ?? Constants.String.videoTimePlaceholder
        let total = player.info.videoDuration?.stringRepresentation ?? Constants.String.videoTimePlaceholder
        let percentage = (player.info.videoPosition / player.info.videoDuration) ?? 1
        player.sendOSD(.seek(current, total, percentage))
      }

    case MPV_EVENT_PLAYBACK_RESTART:
      DispatchQueue.main.async { [self] in
        player.info.isSeeking = false
        // When playback is paused the display link may be shutdown in order to not waste energy.
        // The display link will be restarted while seeking. If playback is paused shut it down
        // again.
        if player.info.state == .paused {
          player.mainWindow.videoView.displayIdle()
        }
        if needRecordSeekTime {
          recordedSeekTimeListener?(CACurrentMediaTime() - recordedSeekStartTime)
          recordedSeekTimeListener = nil
        }
        player.playbackRestarted()
        player.syncUI(.time)
      }

    case MPV_EVENT_END_FILE:
      let transition = activePlaylistLoadTransition
      activePlaylistLoadTransition = nil
      let reason = event.pointee.data.load(as: mpv_end_file_reason.self)
      let dueToStopCommand = reason == MPV_END_FILE_REASON_STOP
      // When the IINA "Pause" setting is enabled under "When media is opened" IINA must tell mpv to
      // pause playback ASAP. Events are delivered asynchronously. If the IINA
      // "Play next item automatically" setting is enabled mpv will currently be loading the next
      // item in the playlist and will immediately start playing it as soon as loading completes.
      // Thus there is a race condition as to whether IINA can pause playback before mpv starts
      // playing the media. This is more likely to happen with audio files that can be quickly
      // loaded. As handling this does not require accessing IINA state not protected by locks and
      // only available to the main thread along with the requirement to pause playback ASAP we will
      // not leave this to the PlayerCore function and handle this now before calling fileEnded.
      if !dueToStopCommand, Preference.bool(for: .pauseWhenOpen) {
        setFlag(MPVOption.PlaybackControl.pause, true, level: .verbose)
        // Normally a log message is emitted before calling mpv, but in this case, due to the race
        // condition, playback must be paused as soon as possible, so logging is done afterward.
        log("Pausing playback because \"pause when media is opened\" is enabled")
      }
      DispatchQueue.main.async {
        self.player.fileEnded(dueToStopCommand)
        self.player.playlistLoadDidFinish(transition)
      }

    case MPV_EVENT_COMMAND_REPLY:
      let reply = event.pointee.reply_userdata
      if reply == MPVController.UserData.screenshot {
        let code = event.pointee.error
        guard code >= 0 else {
          let error = String(cString: mpv_error_string(code))
          log("Cannot take a screenshot, mpv API error: \(error), Return value: \(code)", level: .error)
          // Unfortunately the mpv API does not provide any details on the failure. The error
          // code returned maps to "error running command", so all the alert can report is
          // that we cannot take a screenshot.
          DispatchQueue.main.async {
            Utility.showAlert("screenshot.error_taking")
          }
          break
        }
        DispatchQueue.main.async { self.player.screenshotCallback() }
      } else if MPVController.UserData.isAirPlayAudioCommand(reply) {
        let code = event.pointee.error
        DispatchQueue.main.async {
          self.player.airPlayAudio.mpvCommandCompleted(code, replyUserdata: reply)
        }
      }

    case MPV_EVENT_SET_PROPERTY_REPLY:
      let reply = event.pointee.reply_userdata
      if MPVController.UserData.isAirPlayAudioCommand(reply) {
        let code = event.pointee.error
        DispatchQueue.main.async {
          self.player.airPlayAudio.mpvCommandCompleted(code, replyUserdata: reply)
        }
      } else if reply == MPVController.UserData.preferenceOptionCommand, event.pointee.error < 0 {
        let error = String(cString: mpv_error_string(event.pointee.error))
        log("Asynchronous preference update failed: \(error)", level: .warning)
      }

    case MPV_EVENT_QUEUE_OVERFLOW:
      // The mpv event system uses an event queue of limited size. If events are not read quickly
      // enough the queue can overflow resulting in events being dropped. This event indicates the
      // ringbuffer overflowed and at least one event was dropped. IINA can recover from the loss of
      // some types of mpv events, but certain mpv events are critical. If a critical event is
      // discarded IINA will experience severe malfunctions. For this reason most of the work of
      // processing an event is dispatched to other queues so that MPVController can move on to
      // reading the next event. Snapshot polling and serialized AirPlay command replies both need
      // explicit recovery because either kind of response may have been dropped.
      log("Critical failure, mpv events lost, queue overflowed; recovering AirPlay requests",
          level: .error)
      beginAirPlayEventQueueOverflowRecovery()

    default: break
      // let eventName = String(cString: mpv_event_name(eventId))
      // Utility.log("mpv event (unhandled): \(eventName)")
    }

    // This code is running in the com.colliderli.iina.controller dispatch queue. We must not run
    // plugins from a task in this queue. Accessing EventController data from a thread in this queue
    // results in data races that can cause a crash. See issue 3986.
    DispatchQueue.main.async { [self] in
      let eventName = "mpv.\(String(cString: mpv_event_name(eventId)))"
      player.events.emit(.init(eventName))
    }
  }

  private func handleAirPlaySnapshotReply(_ event: UnsafePointer<mpv_event>) -> Bool {
    let token = event.pointee.reply_userdata
    guard let (generation, propertyIndex) = Self.airPlaySnapshotTokenParts(token) else { return false }
    let isCurrentSample = $airPlaySnapshotRequests.withLock { state -> Bool in
      guard state.pendingTokens.remove(token) != nil else { return false }
      return state.generation == generation
    }
    // Consume stale private replies too, so they never fall through to generic/plugin dispatch.
    guard isCurrentSample else { return true }

    let property: mpv_event_property? = {
      guard event.pointee.error >= 0 else { return nil }
      let dataOpaquePtr = OpaquePointer(event.pointee.data)
      return UnsafePointer<mpv_event_property>(dataOpaquePtr)?.pointee
    }()
    $airPlaySnapshot.withLock { snapshot in
      switch propertyIndex {
      case 0:
        snapshot.timePosition = property.flatMap(doubleValue(from:))
      case 1:
        snapshot.audioPTS = property.flatMap(doubleValue(from:))
      case 2:
        snapshot.pausedForCache = property.flatMap(flagValue(from:))
      case 3:
        snapshot.estimatedVideoFPS = property.flatMap(doubleValue(from:))
      case 4:
        snapshot.containerFPS = property.flatMap(doubleValue(from:))
      default:
        break
      }
    }
    return true
  }

  /// Recovers accepted asynchronous AirPlay commands whose reply events may have been dropped.
  /// Keep this wait off AppKit and the event-reader queue; the latter must continue draining events.
  private func recoverAirPlayAsyncRequestsAfterQueueOverflow() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let activeReplyToken = self.player.airPlayAudio.beginMPVEventQueueOverflowRecovery()
      self.airPlaySnapshotQueue.async { [weak self] in
        guard let self else { return }
        if !self.hasReceivedShutdownEvent, let mpv = self.mpv {
          // This API waits off-main until every accepted asynchronous request has produced its
          // reply event. Do not hold the call gate: the event reader must keep draining the queue.
          mpv_wait_async_requests(mpv)
        }
        self.queue.async { [weak self] in
          guard let self else { return }
          // The async barrier guarantees replies were emitted, not that the event reader has
          // delivered them to the bridge yet. Drain the event queue before treating one as lost.
          self.readEventsOnQueue {
            // The overflow may have discarded the ao property-change event. Re-read the actual
            // value after the accepted async requests and their replies have drained, before the
            // bridge resumes and makes another route decision.
            self.airPlaySnapshotQueue.async { [weak self] in
              guard let self else { return }
              self.airPlaySnapshotCallLock.lock()
              let sampleState = self.$airPlaySnapshot.withLock { snapshot in
                (generation: snapshot.audioOutputGeneration,
                 canPublish: snapshot.audioOutputChangesInFlight == 0)
              }
              let audioOutput: String?
              if !self.hasReceivedShutdownEvent, self.mpv != nil {
                audioOutput = self.getString(MPVOption.Audio.ao)
              } else {
                audioOutput = nil
              }
              self.airPlaySnapshotCallLock.unlock()

              DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.hasReceivedShutdownEvent {
                  self.$airPlaySnapshot.withLock { snapshot in
                    // An observed ao event after this sample is newer than the queried value.
                    if sampleState.canPublish,
                       snapshot.audioOutputGeneration == sampleState.generation,
                       snapshot.audioOutputChangesInFlight == 0,
                       let audioOutput {
                      // Reconcile raw async AO intent here too: MPV may have dropped the property
                      // event that would otherwise confirm the pending request.
                      self.observeAudioOutput(audioOutput, in: &snapshot)
                    }
                  }
                }
                self.$airPlaySnapshotRequests.withLock { $0.isRecoveringFromQueueOverflow = false }
                // The shutdown path clears the bridge command queue after draining this reader.
                guard !self.hasReceivedShutdownEvent else { return }
                self.player.airPlayAudio.finishMPVEventQueueOverflowRecovery(
                  for: activeReplyToken
                )
                self.player.airPlayAudio.playbackSnapshotChanged()
                self.requestAirPlayPlaybackSnapshot()
              }
            }
          }
        }
      }
    }
  }

  private static func airPlaySnapshotToken(_ generation: UInt64, propertyIndex: Int) -> UInt64 {
    UserData.airPlaySnapshotBase &+ (generation << 3) &+ UInt64(propertyIndex)
  }

  private static func airPlaySnapshotTokenParts(_ token: UInt64) -> (UInt64, Int)? {
    guard token >= UserData.airPlaySnapshotBase else { return nil }
    let offset = token - UserData.airPlaySnapshotBase
    let propertyIndex = Int(offset & 0b111)
    guard propertyIndex < 5 else { return nil }
    return (offset >> 3, propertyIndex)
  }

  // MARK: - Property listeners

  private func handlePropertyChange(_ name: String, _ property: mpv_event_property) {

    $airPlaySnapshot.withLock { snapshot in
      switch name {
      case MPVOption.Audio.ao:
        self.observeAudioOutput(stringValue(from: property), in: &snapshot)
      case MPVOption.PlaybackControl.rebaseStartTime:
        snapshot.rebaseStartTime = flagValue(from: property)
      case MPVOption.PlaybackControl.pause:
        snapshot.isPaused = flagValue(from: property)
      case MPVProperty.pausedForCache:
        snapshot.pausedForCache = flagValue(from: property)
      case MPVProperty.timePos:
        snapshot.timePosition = doubleValue(from: property)
      case MPVProperty.audioPts:
        snapshot.audioPTS = doubleValue(from: property)
      case MPVProperty.duration:
        snapshot.duration = doubleValue(from: property)
      case MPVProperty.demuxerStartTime:
        snapshot.demuxerStartTime = doubleValue(from: property)
      case MPVProperty.streamOpenFilename:
        snapshot.streamOpenFilename = stringValue(from: property)
      case MPVProperty.estimatedVfFps:
        snapshot.estimatedVideoFPS = doubleValue(from: property)
      case MPVProperty.containerFps:
        snapshot.containerFPS = doubleValue(from: property)
      case MPVOption.PlaybackControl.speed:
        snapshot.speed = doubleValue(from: property)
      default:
        break
      }
    }

    switch name {
    case MPVOption.Audio.ao, MPVOption.PlaybackControl.rebaseStartTime,
         MPVProperty.duration, MPVProperty.demuxerStartTime, MPVProperty.streamOpenFilename:
      DispatchQueue.main.async { self.player.airPlayAudio.playbackSnapshotChanged() }
    default:
      break
    }

    switch name {

    case MPVProperty.audioDeviceList:
      DispatchQueue.main.async { self.player.audioDeviceListChanged() }

    case MPVProperty.videoParams:
      DispatchQueue.main.async { self.player.postNotification(.iinaVideoParamsChanged) }

    case MPVProperty.videoParamsRotate:
      guard let rotation = UnsafePointer<Int>(OpaquePointer(property.data))?.pointee else {
        logPropertyValueError(MPVProperty.videoParamsRotate, property.format)
        break
      }
      DispatchQueue.main.async { self.player.mainWindow.rotation = rotation }

    case MPVProperty.videoParamsPrimaries:
      fallthrough;

    case MPVProperty.videoParamsGamma:
      DispatchQueue.main.async { self.player.refreshEdrMode() }

    case MPVOption.TrackSelection.vid:
      guard let id = UnsafePointer<Int64>(OpaquePointer(property.data))?.pointee else { break }
      DispatchQueue.main.async { self.player.vidChanged(Int(id)) }

    case MPVOption.TrackSelection.aid:
      guard let id = UnsafePointer<Int64>(OpaquePointer(property.data))?.pointee else { break }
      DispatchQueue.main.async { self.player.aidChanged(Int(id)) }

    case MPVOption.TrackSelection.sid:
      guard let id = UnsafePointer<Int64>(OpaquePointer(property.data))?.pointee else { break }
      DispatchQueue.main.async { self.player.sidChanged(Int(id)) }

    case MPVOption.Subtitles.secondarySid:
      guard let id = UnsafePointer<Int64>(OpaquePointer(property.data))?.pointee else { break }
      DispatchQueue.main.async { self.player.secondarySidChanged(Int(id)) }

    case MPVOption.PlaybackControl.pause:
      guard let paused = flagValue(from: property) else {
        logPropertyValueError(MPVOption.PlaybackControl.pause, property.format)
        break
      }
      DispatchQueue.main.async { self.player.pauseChanged(paused) }

    case MPVProperty.chapter:
      DispatchQueue.main.async { self.player.chapterChanged() }

    case MPVOption.PlaybackControl.speed:
      guard let speed = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee else {
        logPropertyValueError(MPVOption.PlaybackControl.speed, property.format)
        break
      }
      DispatchQueue.main.async {
        // The AirPlay bridge holds the picture with a near-zero speed while the speaker starts.
        guard !self.player.airPlayAudio.consumeInternalSpeed(speed) else { return }
        self.player.speedChanged(speed)
        self.player.airPlayAudio.userSpeedChanged()
      }

    case MPVOption.PlaybackControl.loopPlaylist, MPVOption.PlaybackControl.loopFile:
      DispatchQueue.main.async { [self] in
        guard player.info.state.loaded else { return }
        let loopMode = player.getLoopMode()
        switch loopMode {
        case .file:
          player.sendOSD(.fileLoop)
        case .playlist:
          player.sendOSD(.playlistLoop)
        default:
          player.sendOSD(.noLoop)
        }
        player.postNotification(.iinaLoopStatusChanged)
      }

    case MPVOption.Video.deinterlace:
      guard let data = flagValue(from: property) else {
        logPropertyValueError(MPVOption.Video.deinterlace, property.format)
        break
      }
      DispatchQueue.main.async { [self] in
        // this property will fire a change event at file start
        if player.info.deinterlace != data {
          player.info.deinterlace = data
          player.sendOSD(.deinterlace(data))
        }
        player.postNotification(.iinaDeinterlaceChanged)
      }

    case MPVOption.Video.hwdec:
      guard let data = stringValue(from: property) else {
        logPropertyValueError(MPVOption.Video.hwdec, property.format)
        break
      }
      DispatchQueue.main.async { [self] in
        if player.info.hwdec != data {
          player.info.hwdec = data
          player.sendOSD(.hwdec(player.info.hwdecEnabled))
        }
        player.postNotification(.iinaHwdecChanged)
      }

    case MPVOption.Video.videoRotate:
      guard let data = UnsafePointer<Int64>(OpaquePointer(property.data))?.pointee else {
        logPropertyValueError(MPVOption.Video.videoRotate, property.format)
        break
      }
      let intData = Int(data)
      DispatchQueue.main.async { self.player.info.rotation = intData }

    case MPVOption.Audio.mute:
      guard let data = flagValue(from: property) else {
        logPropertyValueError(MPVOption.Audio.mute, property.format)
        break
      }
      DispatchQueue.main.async { [self] in
        player.info.isMuted = data
        player.airPlayAudio.volumeChanged()
        player.syncUI(.volume)
        player.sendOSD(data ? OSDMessage.mute : OSDMessage.unMute)
      }

    case MPVOption.Audio.volume:
      guard let data = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee else {
        logPropertyValueError(MPVOption.Audio.volume, property.format)
        break
      }
      DispatchQueue.main.async { [self] in
        player.info.volume = data
        player.airPlayAudio.volumeChanged()
        player.syncUI(.volume)
        player.sendOSD(.volume(data))
      }

    case MPVOption.Audio.audioDelay:
      guard let data = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee else {
        logPropertyValueError(MPVOption.Audio.audioDelay, property.format)
        break
      }
      DispatchQueue.main.async { [self] in
        // While the AirPlay bridge carries the audio, part of mpv's delay is its sync correction.
        guard let delay = player.airPlayAudio.userAudioDelay(fromMPV: data) else { return }
        player.info.audioDelay = delay
        player.sendOSD(.audioDelay(delay))
        player.postNotification(.iinaAudioDelayChanged)
      }

    case MPVOption.Subtitles.subVisibility:
      if let visible = flagValue(from: property) {
        DispatchQueue.main.async {
          self.player.subVisibilityChanged(visible)
        }
      }

    case MPVOption.Subtitles.secondarySubVisibility:
      if let visible = flagValue(from: property) {
        DispatchQueue.main.async {
          self.player.secondSubVisibilityChanged(visible)
        }
      }

    case MPVOption.Subtitles.secondarySubDelay:
      fallthrough
    case MPVOption.Subtitles.subDelay:
      guard let data = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee else {
        logPropertyValueError(name, property.format)
        break
      }
      guard name == MPVOption.Subtitles.subDelay else {
        DispatchQueue.main.async { self.player.secondarySubDelayChanged(data) }
        break
      }
      DispatchQueue.main.async { self.player.subDelayChanged(data) }

    case MPVOption.Subtitles.subScale:
      guard let data = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee else {
        logPropertyValueError(MPVOption.Subtitles.subScale, property.format)
        break
      }
      DispatchQueue.main.async { self.player.subScaleChanged(data) }

    case MPVOption.Subtitles.secondarySubPos:
      fallthrough
    case MPVOption.Subtitles.subPos:
      guard let data = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee else {
        logPropertyValueError(name, property.format)
        break
      }
      if name == MPVOption.Subtitles.subPos {
        DispatchQueue.main.async { self.player.subPosChanged(data) }
      } else {
        DispatchQueue.main.async { self.player.secondarySubPosChanged(data) }
      }

    case MPVOption.Equalizer.contrast:
      guard let data = UnsafePointer<Int64>(OpaquePointer(property.data))?.pointee else {
        logPropertyValueError(MPVOption.Equalizer.contrast, property.format)
        break
      }
      let intData = Int(data)
      DispatchQueue.main.async { [self] in
        player.info.contrast = intData
        player.sendOSD(.contrast(intData))
        player.postNotification(.iinaVideoEqualizerChanged)
      }

    case MPVOption.Equalizer.hue:
      guard let data = UnsafePointer<Int64>(OpaquePointer(property.data))?.pointee else {
        logPropertyValueError(MPVOption.Equalizer.hue, property.format)
        break
      }
      let intData = Int(data)
      DispatchQueue.main.async { [self] in
        player.info.hue = intData
        player.sendOSD(.hue(intData))
        player.postNotification(.iinaVideoEqualizerChanged)
      }

    case MPVOption.Equalizer.brightness:
      guard let data = UnsafePointer<Int64>(OpaquePointer(property.data))?.pointee else {
        logPropertyValueError(MPVOption.Equalizer.brightness, property.format)
        break
      }
      let intData = Int(data)
      DispatchQueue.main.async { [self] in
        player.info.brightness = intData
        player.sendOSD(.brightness(intData))
        player.postNotification(.iinaVideoEqualizerChanged)
      }

    case MPVOption.Equalizer.gamma:
      guard let data = UnsafePointer<Int64>(OpaquePointer(property.data))?.pointee else {
        logPropertyValueError(MPVOption.Equalizer.gamma, property.format)
        break
      }
      let intData = Int(data)
      DispatchQueue.main.async { [self] in
        player.info.gamma = intData
        player.sendOSD(.gamma(intData))
        player.postNotification(.iinaVideoEqualizerChanged)
      }

    case MPVOption.Equalizer.saturation:
      guard let data = UnsafePointer<Int64>(OpaquePointer(property.data))?.pointee else {
        logPropertyValueError(MPVOption.Equalizer.saturation, property.format)
        break
      }
      let intData = Int(data)
      DispatchQueue.main.async { [self] in
        player.info.saturation = intData
        player.sendOSD(.saturation(intData))
        player.postNotification(.iinaVideoEqualizerChanged)
      }

    // following properties may change before file loaded

    case MPVProperty.playlistCount:
      DispatchQueue.main.async { self.player.postNotification(.iinaPlaylistChanged) }

    case MPVProperty.playlistCurrentPos, MPVProperty.playlistPlayingPos:
      DispatchQueue.main.async { self.player.playlistPlaybackStatusMayHaveChanged() }

    case MPVProperty.trackList:
      // Parse while mpv's event data is alive. Querying track-list again on the main thread can
      // deadlock with mpv's file-loading hooks and leave the player window unresponsive.
      guard property.format == MPV_FORMAT_NODE, let data = property.data,
            let tracks = (try? MPVNode.parse(data.assumingMemoryBound(to: mpv_node.self).pointee))
              as? [[String: Any]] else { break }
      DispatchQueue.main.async { self.player.trackListChanged(tracks) }

    case MPVProperty.vf:
      DispatchQueue.main.async { [self] in
        player.vfChanged()
      }

    case MPVProperty.af:
      DispatchQueue.main.async { self.player.afChanged() }

    case MPVOption.Window.fullscreen:
      DispatchQueue.main.async { self.player.fullscreenChanged() }

    case MPVOption.Window.ontop:
      DispatchQueue.main.async { self.player.ontopChanged() }

    case MPVOption.Window.windowScale:
      DispatchQueue.main.async { self.player.windowScaleChanged() }

    case MPVProperty.mediaTitle:
      DispatchQueue.main.async { self.player.mediaTitleChanged() }

    case MPVProperty.idleActive:
      guard let idleActive = flagValue(from: property) else {
        logPropertyValueError(MPVProperty.idleActive, property.format)
        break
      }
      guard idleActive else { break }
      DispatchQueue.main.async { self.player.idleActiveChanged() }

    case MPVProperty.currentAo:
      DispatchQueue.main.async { self.player.currentAoChanged() }

    default:
      // Utility.log("MPV property changed (unhandled): \(name)")
      break
    }

    // mpv owns property.data only until the next call to mpv_wait_event. Copy the primitive value
    // while still on the event queue; the main-queue plugin callback must not capture the C pointer.
    let eventData = copyPropertyValue(property)

    // This code is running in the com.colliderli.iina.controller dispatch queue. We must not run
    // plugins from a task in this queue. Accessing EventController data from a thread in this queue
    // results in data races that can cause a crash. See issue 3986.
    DispatchQueue.main.async { [self] in
      let eventName = EventController.Name("mpv.\(name).changed")
      if player.events.hasListener(for: eventName) {
        // FIXME: better convert to JSValue before passing to call()
        player.events.emit(eventName, data: eventData)
      }
    }
  }

  /// mpv represents `MPV_FORMAT_FLAG` as a C `int`, not a Swift `Bool`.
  private func flagValue(from property: mpv_event_property) -> Bool? {
    guard property.format == MPV_FORMAT_FLAG,
          let data = property.data else { return nil }
    return data.assumingMemoryBound(to: Int32.self).pointee != 0
  }

  private func doubleValue(from property: mpv_event_property) -> Double? {
    guard property.format == MPV_FORMAT_DOUBLE,
          let data = property.data else { return nil }
    let value = data.assumingMemoryBound(to: Double.self).pointee
    return value.isFinite ? value : nil
  }

  /// `MPV_FORMAT_STRING` stores a `char *` at `property.data` (so the event field is `char **`).
  private func stringValue(from property: mpv_event_property) -> String? {
    guard property.format == MPV_FORMAT_STRING,
          let data = property.data,
          let value = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee else { return nil }
    return String(cString: value)
  }

  /// Copy a supported property into Swift-owned storage before mpv advances its event queue.
  private func copyPropertyValue(_ property: mpv_event_property) -> Any {
    guard let data = property.data else { return 0 }
    switch property.format {
    case MPV_FORMAT_FLAG:
      return data.assumingMemoryBound(to: Int32.self).pointee != 0
    case MPV_FORMAT_INT64:
      return data.assumingMemoryBound(to: Int64.self).pointee
    case MPV_FORMAT_DOUBLE:
      return data.assumingMemoryBound(to: Double.self).pointee
    case MPV_FORMAT_STRING:
      guard let value = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee else { return 0 }
      return String(cString: value)
    default:
      return 0
    }
  }

  // MARK: - User Options

  private enum UserOptionType {
    case bool, int, float, string, color, other, asyncOther
  }

  private struct OptionObserverInfo {
    typealias Transformer = (Preference.Key) -> String?

    var prefKey: Preference.Key
    var optionName: String
    var valueType: UserOptionType
    /** input a pref key and return the option value (as string) */
    var transformer: Transformer?

    init(_ prefKey: Preference.Key, _ optionName: String, _ valueType: UserOptionType, _ transformer: Transformer?) {
      self.prefKey = prefKey
      self.optionName = optionName
      self.valueType = valueType
      self.transformer = transformer
    }
  }

  private var optionObservers: [String: [OptionObserverInfo]] = [:]

  private func setOptionFlag(_ name: String, _ flag: Bool, level: Logger.Level = .debug,
                             verboseIfDefault: Bool = false) -> Int32 {
    let value = flag ? yes_str : no_str
    return setOptionString(name, value, level: level, verboseIfDefault: verboseIfDefault)
  }

  private func setOptionFloat(_ name: String, _ value: Float, level: Logger.Level = .debug,
                              verboseIfDefault: Bool = false) -> Int32 {
    let levelToUse: Logger.Level = {
      guard verboseIfDefault, let defaultValue = MPVOptionDefaults.shared.getDouble(name),
            abs(Double(value).distance(to: defaultValue)) <= Double.leastNonzeroMagnitude else {
        return level
      }
      return .verbose
    }()
    log("Set option: \(name)=\(value)", level: levelToUse)
    var data = Double(value)
    return mpv_set_option(mpv, name, MPV_FORMAT_DOUBLE, &data)
  }

  private func setOptionInt(_ name: String, _ value: Int, level: Logger.Level = .debug,
                            verboseIfDefault: Bool = false) -> Int32 {
    let levelToUse: Logger.Level = verboseIfDefault &&
      MPVOptionDefaults.shared.getInt(name) == value ? .verbose  : level
    log("Set option: \(name)=\(value)", level: levelToUse)
    var data = Int64(value)
    return mpv_set_option(mpv, name, MPV_FORMAT_INT64, &data)
  }

  @discardableResult
  private func setOptionString(_ name: String, _ value: String, level: Logger.Level = .debug,
                               verboseIfDefault: Bool = false) -> Int32 {
    let levelToUse: Logger.Level = verboseIfDefault &&
      MPVOptionDefaults.shared.getString(name) == value ? .verbose  : level
    log("Set option: \(name)=\(value)", level: levelToUse)
    return mpv_set_option_string(mpv, name, value)
  }

  private func setOptionalOptionColor(_ name: String, _ value: String?,
                                       level: Logger.Level = .debug,
                                       verboseIfDefault: Bool = false) -> Int32 {
    guard let value else { return 0 }
    let levelToUse: Logger.Level = {
      // The default value for options of type color is currently returned by mpv in the alternative
      // string format that specifies component values in hex. Must convert to the form that uses
      // floating point to be able to compare the strings.
      guard verboseIfDefault, let defaultValue = MPVOptionDefaults.shared.getString(name),
            hexColorToFloat(defaultValue) == value else {
        return level
      }
      return .verbose
    }()
    return setOptionString(name, value, level: levelToUse)
  }

  private func setOptionalOptionString(_ name: String, _ value: String?, level: Logger.Level = .debug,
                                       verboseIfDefault: Bool = false) -> Int32 {
    guard let value else { return 0 }
    return setOptionString(name, value, level: level, verboseIfDefault: verboseIfDefault)
  }

  /// Apply language and subtitle-count preferences after mpv has loaded its config files.
  private func applyPreferredTrackOptions() {
    let options: [(String, String)] = [
      (MPVOption.TrackSelection.alang, preferredTrackLanguage(for: .audioLanguage)),
      (MPVOption.TrackSelection.slang, preferredTrackLanguage(for: .subLang)),
      (MPVOption.Subtitles.secondarySid,
       Preference.bool(for: .showSecondSubtitleTrack) ? "auto" : "no"),
    ]
    for (name, value) in options where !userOptionsContains(name) {
      chkErr(setString(name, value, level: .verbose))
    }
  }

  private func preferredTrackLanguage(for key: Preference.Key) -> String {
    guard Preference.bool(for: .autoSelectPreferredTrackLanguages) else { return "" }
    return SubtitleLanguagePreference.preferredTrackTags(from: Preference.string(for: key))
      .joined(separator: ",")
  }

  /// Set the given mpv option to the value of the given IINA setting.
  ///
  /// To reduce the amount of logging that occurs when `MPVController` initializes a mpv core this method provides a
  /// `verboseIfDefault` parameter. If this parameter is set to `true` then the value to set the mpv option to is compared to the
  /// default value for the mpv option and if the values match then the value of the `level` parameter will be ignored and the
  /// message will be logged using the `verbose` level.
  /// - Parameters:
  ///   - key: Key for the IINA setting.
  ///   - type: Type of the value of the mpv option.
  ///   - name: Name of the mpv option.
  ///   - sync: Whether to add an observer for the IINA setting that updates the mpv option when the IINA setting changes.
  ///   - level: Log level to use when logging the setting of the option.
  ///   - verboseIfDefault: Whether to use log level `verbose` if the value matches the default for the mpv option.
  ///   - transformer: Optional transformer that changes the IINA setting value to be usable as the mpv option value.
  private func setUserOption(_ key: Preference.Key, type: UserOptionType, forName name: String,
                             sync: Bool = true, level: Logger.Level = .debug,
                             verboseIfDefault: Bool = false,
                             transformer: OptionObserverInfo.Transformer? = nil) {
    var code: Int32 = 0

    let keyRawValue = key.rawValue

    switch type {
    case .int:
      code = setOptionInt(name, Preference.integer(for: key), level: level,
                          verboseIfDefault: verboseIfDefault)

    case .float:
      code = setOptionFloat(name, Preference.float(for: key), level: level,
                            verboseIfDefault: verboseIfDefault)

    case .bool:
      code = setOptionFlag(name, Preference.bool(for: key), level: level,
                           verboseIfDefault: verboseIfDefault)

    case .string:
      code = setOptionalOptionString(name, Preference.string(for: key), level: level,
                                     verboseIfDefault: verboseIfDefault)

    case .color:
      let value = Preference.string(for: key)
      code = setOptionalOptionColor(name, value, level: level, verboseIfDefault: verboseIfDefault)
      // Random error here (perhaps a Swift or mpv one), so set it twice
      // 「没有什么是 set 不了的；如果有，那就 set 两次」
      if code < 0 {
        code = setOptionalOptionColor(name, value, level: level, verboseIfDefault: verboseIfDefault)
      }

    case .other, .asyncOther:
      guard let tr = transformer else {
        log("setUserOption: no transformer!", level: .error)
        return
      }
      if let value = tr(key) {
        code = setOptionString(name, value, level: level, verboseIfDefault: verboseIfDefault)
      } else {
        code = 0
      }
    }

    if code < 0 {
      Utility.showAlert("mpv_error", arguments: [String(cString: mpv_error_string(code)), "\(code)", name],
                        disableMenus: true)
    }

    if sync {
      UserDefaults.standard.addObserver(self, forKeyPath: keyRawValue, options: [.new, .old], context: nil)
      if optionObservers[keyRawValue] == nil {
        optionObservers[keyRawValue] = []
      }
      optionObservers[keyRawValue]!.append(OptionObserverInfo(key, name, type, transformer))
    }
  }

  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
    guard !(change?[NSKeyValueChangeKey.oldKey] is NSNull) else { return }

    guard let keyPath else { return }
    guard let infos = optionObservers[keyPath] else { return }

    for info in infos {
      switch info.valueType {
      case .int:
        let value = Preference.integer(for: info.prefKey)
        setInt(info.optionName, value)

      case .float:
        let value = Preference.float(for: info.prefKey)
        setDouble(info.optionName, Double(value))

      case .bool:
        let value = Preference.bool(for: info.prefKey)
        setFlag(info.optionName, value)

      case .string:
        if let value = Preference.string(for: info.prefKey) {
          setString(info.optionName, value)
        }

      case .color:
        if let value = Preference.string(for: info.prefKey) {
          setString(info.optionName, value)
        }

      case .other:
        guard let tr = info.transformer else {
          log("setUserOption: no transformer!", level: .error)
          return
        }
        if let value = tr(info.prefKey) {
          setString(info.optionName, value)
        }

      case .asyncOther:
        guard let tr = info.transformer else {
          log("setUserOption: no transformer!", level: .error)
          return
        }
        if let value = tr(info.prefKey) {
          let result = setStringAsync(info.optionName, value,
                                      replyUserdata: UserData.preferenceOptionCommand,
                                      level: .verbose)
          if result < 0 {
            log("Could not queue asynchronous preference update for \(info.optionName): \(result)",
                level: .warning)
          }
        }
      }
    }
  }

  // MARK: - Utils

  /**
   Utility function for checking mpv api error
   */
  private func chkErr(_ status: Int32!) {
    guard status < 0 else { return }
    DispatchQueue.main.async {
      Logger.fatal("mpv API error: \"\(String(cString: mpv_error_string(status)))\", Return value: \(status!).")
    }
  }

  private func log(_ message: @autoclosure () -> String, level: Logger.Level = .debug) {
    Logger.log(message, level: level, subsystem: subsystem)
  }

  /// Log an error when a `mpv` property change event can't be processed because a property value could not be converted to the
  /// expected type.
  ///
  /// A [MPV_EVENT_PROPERTY_CHANGE](https://mpv.io/manual/stable/#command-interface-mpv-event-property-change)
  /// event contains the new value of the property. If that value could not be converted to the expected type then this method is called
  /// to log the problem.
  ///
  /// _However_ the situation is not that simple. The documentation for [mpv_observe_property](https://github.com/mpv-player/mpv/blob/023d02c9504e308ba5a295cd1846f2508b3dd9c2/libmpv/client.h#L1192-L1195)
  /// contains the following warning:
  ///
  /// "if a property is unavailable or retrieving it caused an error, `MPV_FORMAT_NONE` will be set in `mpv_event_property`, even
  /// if the format parameter was set to a different value. In this case, the `mpv_event_property.data` field is invalid"
  ///
  /// With mpv 0.35.0 we are receiving some property change events for the video-params/rotate property that do not contain the
  /// property value. This happens when the core starts before a file is loaded and when the core is stopping. At some point this needs
  /// to be investigated. For now we suppress logging an error for this known case.
  /// - Parameter property: Name of the property whose value changed.
  /// - Parameter format: Format of the value contained in the property change event.
  private func logPropertyValueError(_ property: String, _ format: mpv_format) {
    guard property != MPVProperty.videoParamsRotate || format != MPV_FORMAT_NONE else { return }
    log("""
      Value of property \(property) in the property change event could not be converted from
      \(format) to the expected type
      """, level: .error)
  }

  /// Convert the given mpv color string containing color components specified in hex to floating point.
  ///
  /// Normally color is specified in the form r/g/b, where each color component is specified as number in the range 0.0 to 1.0. It's also
  /// possible to specify the transparency by using r/g/b/a, where the alpha value 0 means fully transparent, and 1.0 means opaque.
  /// If the alpha component is not given, the color is 100% opaque. Alternatively, the color can be specified as a RGB hex triplet in the
  /// form #RRGGBB, where each 2-digit group expresses a color value in the range 0 (00) to 255 (FF). Alpha is given with #AARRGGBB.
  /// This method converts from the hex based alternative form to the floating point form.
  /// - Parameter color: Color with components specified in hex.
  /// - Returns: Color with components specified in floating point.
  private func hexColorToFloat(_ color: String) -> String {
    guard color.starts(with: "#"), color.count == 7 || color.count == 9 else {
      log("Invalid mpv hex color string: \(color)", level: .error)
      return color
    }
    var components: [String] = []
    for offset in stride(from: 1, to: color.count, by: 2) {
      let range = color.index(color.startIndex, offsetBy: offset)...color.index(color.startIndex, offsetBy: offset + 1)
      let value = Double(Int(color[range], radix: 16)!)
      components.append(String(value / 255))
    }
    guard components.count == 4 else {
      return components.joined(separator: "/")
    }
    // The alpha component comes first in the hex based form, last in the floating point form.
    let alpha = components[0]
    components.remove(at: 0)
    return "\(components.joined(separator: "/"))/\(alpha)"
  }

  /// Searches the list of user configured `mpv` options and returns `true` if the given option is present.
  /// - Parameter option: Option to look for.
  /// - Returns: `true` if the `mpv` option is found, `false` otherwise.
  private func userOptionsContains(_ option: String) -> Bool {
    guard Preference.bool(for: .enableAdvancedSettings),
          let userOptions = Preference.value(for: .userOptions) as? [[String]] else { return false }
    return userOptions.contains { $0[0] == option }
  }
}

fileprivate func mpvGetOpenGLFunc(_ ctx: UnsafeMutableRawPointer?, _ name: UnsafePointer<Int8>?) -> UnsafeMutableRawPointer? {
  let symbolName: CFString = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingASCII);
  guard let addr = CFBundleGetFunctionPointerForName(CFBundleGetBundleWithIdentifier(CFStringCreateCopy(kCFAllocatorDefault, "com.apple.opengl" as CFString)), symbolName) else {
    Logger.fatal("Cannot get OpenGL function pointer!")
  }
  return addr
}

fileprivate func mpvUpdateCallback(_ ctx: UnsafeMutableRawPointer?) {
  let layer = bridge(ptr: ctx!) as ViewLayer
  layer.update()
}
