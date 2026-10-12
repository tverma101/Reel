//
//  AirPlayAudioRoutePicker.swift
//  iina
//
//  The native picker is bound to Reel's AVPlayer. For eligible files, that same AVPlayer
//  supplies both audio and local video; mpv stays paused underneath as the full-featured fallback.
//

import AVFoundation
import AVKit
import Cocoa

final class AirPlayAudioRoutePicker: NSObject {
  private weak var playerCore: PlayerCore?
  private let avPlayer = AVPlayer()
  private let routePicker = AVRoutePickerView()
  private var playerStatusObservation: NSKeyValueObservation?
  private var itemStatusObservation: NSKeyValueObservation?
  private var endObserver: NSObjectProtocol?
  private var failureObserver: NSObjectProtocol?
  private var timeControlObservation: NSKeyValueObservation?
  private var generation = 0
  private var seekGeneration = 0
  private var playbackIntentGeneration = 0
  private var activationTransportGeneration = 0
  private var activationInitiallyPaused = false
  private var isActivating = false
  private var expectedURL: URL?
  private var fellBackForCurrentFile = false
  private var playbackStallWorkItem: DispatchWorkItem?

  private(set) var isActive = false
  private(set) var isPreparing = false

  init(player: PlayerCore) {
    playerCore = player
    super.init()
    avPlayer.actionAtItemEnd = .pause
    // Reel's picture stays in its own window. The route picker is used for this player's audio.
    avPlayer.allowsExternalPlayback = false
    playerStatusObservation = avPlayer.observe(\.status, options: [.new]) { [weak self] player, _ in
      guard player.status == .failed else { return }
      DispatchQueue.main.async {
        guard let self, self.isActive else { return }
        self.fallbackToMPV(reason: player.error?.localizedDescription ?? "Apple playback failed")
      }
    }
    timeControlObservation = avPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
      DispatchQueue.main.async {
        guard let self, self.isActive else { return }
        guard player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
              self.playerCore?.info.state == .playing else {
          self.cancelPlaybackStallCheck()
          return
        }
        self.schedulePlaybackStallCheck()
      }
    }
    routePicker.isRoutePickerButtonBordered = false
    routePicker.player = nil
    routePicker.isHidden = true
    routePicker.toolTip = NSLocalizedString("osc_toolbar.airplay", comment: "Route Reel audio to an AirPlay speaker")
  }

  func makePickerView() -> AVRoutePickerView {
    routePicker
  }

  /// Prepare Apple playback in the background. mpv remains authoritative until the AVPlayer item
  /// is ready and seekable; a failed preparation simply leaves the existing mpv session running.
  func prepare(url: URL) {
    guard let playerCore, playerCore.canStartNativeAirPlay(for: url),
          !isActive, !isPreparing, !fellBackForCurrentFile else { return }

    generation += 1
    let requestGeneration = generation
    expectedURL = url
    isPreparing = true

    let asset = AVURLAsset(url: url)
    asset.loadValuesAsynchronously(forKeys: ["playable", "tracks"]) { [weak self] in
      DispatchQueue.main.async {
        guard let self, requestGeneration == self.generation else { return }
        guard self.expectedURL == url,
              self.playerCore?.canStartNativeAirPlay(for: url) == true else {
          self.cancelPreparation("The file stopped meeting Reel AirPlay requirements",
                                 suppressForCurrentFile: false)
          return
        }

        var error: NSError?
        guard asset.statusOfValue(forKey: "playable", error: &error) == .loaded,
              asset.statusOfValue(forKey: "tracks", error: &error) == .loaded,
              asset.isPlayable,
              asset.tracks(withMediaType: .video).count == 1,
              asset.tracks(withMediaType: .audio).count == 1 else {
          self.cancelPreparation("Apple playback does not support this file")
          return
        }

        let item = AVPlayerItem(asset: asset)
        self.itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
          DispatchQueue.main.async {
            guard let self, let item, requestGeneration == self.generation,
                  item === self.avPlayer.currentItem else { return }
            switch item.status {
            case .readyToPlay:
              self.activate(item: item, url: url, generation: requestGeneration)
            case .failed:
              if self.isActive {
                self.fallbackToMPV(reason: item.error?.localizedDescription ?? "Apple playback failed")
              } else {
                self.cancelPreparation(item.error?.localizedDescription ?? "Apple playback could not start")
              }
            case .unknown:
              break
            @unknown default:
              self.cancelPreparation("Apple playback returned an unknown file status")
            }
          }
        }
        self.avPlayer.replaceCurrentItem(with: item)
      }
    }
  }

  private func activate(item: AVPlayerItem, url: URL, generation requestGeneration: Int) {
    guard let playerCore, requestGeneration == generation, !isActive,
          playerCore.canStartNativeAirPlay(for: url),
          let duration = finiteSeconds(item.duration), duration > 0 else {
      cancelPreparation("Apple playback could not read the file duration")
      return
    }

    guard let mpv = playerCore.mpv else {
      cancelPreparation("The Reel player is no longer available")
      return
    }
    let wasPaused = playerCore.info.state == .paused || mpv.getFlag(MPVOption.PlaybackControl.pause)
    let mpvPosition = mpv.getDouble(MPVProperty.timePos)
    let startPosition = mpvPosition.isFinite ? mpvPosition.clamped(to: 0...duration) : 0
    playerCore.info.videoDuration = VideoTime(duration)
    playerCore.info.videoPosition = VideoTime(startPosition)

    // Mark the backend active before pausing mpv so its asynchronous pause notification cannot
    // overwrite the state now owned by AVPlayer.
    isActive = true
    isPreparing = false
    isActivating = true
    activationTransportGeneration = playbackIntentGeneration
    activationInitiallyPaused = wasPaused
    mpv.setFlag(MPVOption.PlaybackControl.pause, true, level: .verbose)
    playerCore.mainWindow.videoView.displayIdle()
    avPlayer.volume = Float((playerCore.info.volume / 100).clamped(to: 0...1))
    avPlayer.isMuted = playerCore.info.isMuted

    seekGeneration += 1
    let activationSeekGeneration = seekGeneration
    avPlayer.seek(to: CMTime(seconds: startPosition, preferredTimescale: 600),
                  toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
      DispatchQueue.main.async {
        guard let self, requestGeneration == self.generation, self.isActive,
              item === self.avPlayer.currentItem else { return }
        if !finished {
          guard self.seekGeneration == activationSeekGeneration else { return }
          self.fallbackToMPV(reason: "Apple could not seek to Reel's saved position")
          return
        }
        self.finishActivation(item: item, url: url, generation: requestGeneration,
                              seekGeneration: activationSeekGeneration, duration: duration)
      }
    }
  }

  private func finishActivation(item: AVPlayerItem, url: URL, generation requestGeneration: Int,
                                seekGeneration requestSeekGeneration: Int, duration: Double) {
    guard let playerCore, requestGeneration == generation, isActive, isActivating,
          requestSeekGeneration == seekGeneration, item === avPlayer.currentItem else { return }

    isActivating = false
    playerCore.mainWindow.showAirPlayPlayback(player: avPlayer)
    routePicker.player = avPlayer
    routePicker.isHidden = false
    observeEndOfItem(item)
    playerCore.info.videoDuration = VideoTime(duration)
    syncPosition()

    let paused = playbackIntentGeneration == activationTransportGeneration ?
      activationInitiallyPaused : playerCore.info.state == .paused
    if paused {
      avPlayer.pause()
      playerCore.info.state = .paused
    } else {
      avPlayer.playImmediately(atRate: Float(playerCore.info.playSpeed))
      playerCore.info.state = .playing
    }
    playerCore.refreshSyncUITimer()
    playerCore.syncUI([.time, .playButton, .volume])
    NowPlayingInfoManager.shared.updateInfo()
    playerCore.log("Using Apple's player for eligible Reel playback: \(url.lastPathComponent)")
  }

  private func observeEndOfItem(_ item: AVPlayerItem) {
    removeItemObservers()
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
    ) { [weak self] _ in
      guard let self, self.isActive, let playerCore = self.playerCore else { return }
      self.syncPosition()
      playerCore.info.videoPosition?.second = playerCore.info.videoDuration?.second ?? self.currentTime
      playerCore.info.state = .paused
      playerCore.refreshSyncUITimer()
      playerCore.syncUI([.time, .playButton])
      NowPlayingInfoManager.shared.updateInfo()
    }
    failureObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
    ) { [weak self] notification in
      guard let self, self.isActive else { return }
      let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
      self.fallbackToMPV(reason: error?.localizedDescription ?? "Apple playback stopped unexpectedly")
    }
  }

  private func removeItemObservers() {
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
    endObserver = nil
    failureObserver = nil
  }

  private func cancelPreparation(_ reason: String, suppressForCurrentFile: Bool = true) {
    guard let playerCore else { return }
    generation += 1
    isPreparing = false
    isActive = false
    if suppressForCurrentFile { fellBackForCurrentFile = true }
    expectedURL = nil
    itemStatusObservation = nil
    routePicker.player = nil
    routePicker.isHidden = true
    avPlayer.pause()
    avPlayer.replaceCurrentItem(with: nil)
    playerCore.log("Keeping mpv playback: \(reason)", level: .verbose)
  }

  /// Transfer playback back to mpv before a Reel-only feature or control uses mpv directly.
  func fallbackToMPV(reason: String) {
    guard isActive || isPreparing else { return }
    let wasActive = isActive
    fellBackForCurrentFile = true
    if isActive, !isActivating { syncPosition() }
    stopPlayback(resumeMPV: true)
    if wasActive {
      playerCore?.sendOSD(.custom(NSLocalizedString("osc_toolbar.airplay_output.fallback",
                                                   comment: "Message shown when a file leaves native AirPlay playback")))
    }
    playerCore?.log("Returning to mpv playback: \(reason)")
  }

  /// Detach the native player and picker. Callers save progress before using this when the file is
  /// being stopped or replaced. When resuming mpv, its time and user-facing audio controls are
  /// restored before it is unpaused.
  func stopPlayback(resumeMPV: Bool) {
    generation += 1
    seekGeneration += 1
    let wasActive = isActive
    isActive = false
    isPreparing = false
    isActivating = false
    expectedURL = nil
    cancelPlaybackStallCheck()
    itemStatusObservation = nil
    removeItemObservers()
    routePicker.player = nil
    routePicker.isHidden = true
    avPlayer.pause()
    avPlayer.replaceCurrentItem(with: nil)

    guard let playerCore else { return }
    playerCore.mainWindow.hideAirPlayPlayback()

    guard wasActive, resumeMPV, playerCore.info.state.active else { return }
    let position = playerCore.info.videoPosition?.second ?? 0
    playerCore.mpv.setDouble(MPVProperty.timePos, position, level: .verbose)
    playerCore.mpv.setDouble(MPVOption.Audio.volume, playerCore.info.volume, level: .verbose)
    playerCore.mpv.setFlag(MPVOption.Audio.mute, playerCore.info.isMuted, level: .verbose)
    playerCore.mpv.setDouble(MPVOption.PlaybackControl.speed, playerCore.info.playSpeed, level: .verbose)
    let paused = playerCore.info.state == .paused
    playerCore.mpv.setFlag(MPVOption.PlaybackControl.pause, paused, level: .verbose)
    if paused {
      playerCore.mainWindow.videoView.displayIdle()
    } else {
      playerCore.mainWindow.videoView.displayActive()
    }
    playerCore.syncUI([.time, .playButton, .volume])
    NowPlayingInfoManager.shared.updateInfo()
  }

  var currentTime: Double {
    guard isActive else { return 0 }
    return finiteSeconds(avPlayer.currentTime()) ?? 0
  }

  func syncPosition() {
    guard isActive, !isActivating, let playerCore else { return }
    if let item = avPlayer.currentItem,
       let duration = finiteSeconds(item.duration), duration > 0 {
      playerCore.info.videoDuration = VideoTime(duration)
    }
    guard let duration = playerCore.info.videoDuration?.second,
          duration.isFinite, duration > 0 else { return }
    let time = finiteSeconds(avPlayer.currentTime()) ?? playerCore.info.videoPosition?.second ?? 0
    let position = VideoTime(time.clamped(to: 0...duration))
    playerCore.info.videoPosition = position
    playerCore.chapterChanged(atVideoTime: position)
    let remaining = max(duration - playerCore.info.videoPosition!.second, 0)
    let displayedRemaining = Preference.bool(for: .scaleRemainingTime) ? remaining / max(playerCore.info.playSpeed, 0.01) : remaining
    playerCore.info.videoRemaining = VideoTime(displayedRemaining)
  }

  func pause() {
    guard isActive, let playerCore else { return }
    playbackIntentGeneration += 1
    avPlayer.pause()
    syncPosition()
    playerCore.info.state = .paused
    playerCore.refreshSyncUITimer()
    playerCore.syncUI([.time, .playButton])
    NowPlayingInfoManager.shared.updateInfo()
  }

  func resume() {
    guard isActive, let playerCore else { return }
    playbackIntentGeneration += 1
    let duration = playerCore.info.videoDuration?.second ?? 0
    if duration > 0, currentTime >= duration - 0.05 {
      seek(to: 0) { [weak self] in self?.startPlaying() }
    } else {
      startPlaying()
    }
  }

  private func startPlaying() {
    guard isActive, let playerCore else { return }
    avPlayer.playImmediately(atRate: Float(playerCore.info.playSpeed))
    playerCore.info.state = .playing
    playerCore.refreshSyncUITimer()
    playerCore.syncUI(.playButton)
    NowPlayingInfoManager.shared.updateInfo()
  }

  func seek(to seconds: Double, completion: (() -> Void)? = nil) {
    guard isActive, let playerCore else { return }
    seekGeneration += 1
    let request = seekGeneration
    let duration = playerCore.info.videoDuration?.second ?? 0
    let limit = duration > 0 ? max(duration - 0.05, 0) : max(seconds, 0)
    let target = seconds.isFinite ? seconds.clamped(to: 0...limit) : 0
    playerCore.info.videoPosition = VideoTime(target)
    avPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                  toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
      DispatchQueue.main.async {
        guard let self, self.isActive, self.seekGeneration == request else { return }
        guard finished else {
          self.fallbackToMPV(reason: "Apple could not seek within this file")
          return
        }
        self.syncPosition()
        if self.isActivating, let item = self.avPlayer.currentItem,
           let url = self.expectedURL,
           let duration = playerCore.info.videoDuration?.second {
          self.finishActivation(item: item, url: url, generation: self.generation,
                                seekGeneration: request, duration: duration)
        }
        playerCore.syncUI(.time)
        NowPlayingInfoManager.shared.updateInfo()
        completion?()
      }
    }
  }

  func toggleMute(_ muted: Bool) {
    guard isActive else { return }
    avPlayer.isMuted = muted
  }

  func setVolume(_ volume: Double) {
    guard isActive else { return }
    avPlayer.volume = Float((volume / 100).clamped(to: 0...1))
  }

  func setPlaybackSpeed(_ speed: Double) {
    guard isActive, let playerCore, playerCore.info.state == .playing else { return }
    avPlayer.playImmediately(atRate: Float(speed))
  }

  func resetFallbackForNewFile() {
    fellBackForCurrentFile = false
  }

  private func schedulePlaybackStallCheck() {
    guard playbackStallWorkItem == nil else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.playbackStallWorkItem = nil
      guard self.isActive, self.playerCore?.info.state == .playing,
            self.avPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
      self.fallbackToMPV(reason: "Apple playback remained stalled")
    }
    playbackStallWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
  }

  private func cancelPlaybackStallCheck() {
    playbackStallWorkItem?.cancel()
    playbackStallWorkItem = nil
  }

  private func finiteSeconds(_ time: CMTime) -> Double? {
    let value = CMTimeGetSeconds(time)
    return value.isFinite && value >= 0 ? value : nil
  }
}
