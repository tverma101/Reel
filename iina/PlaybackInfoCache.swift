import Foundation

/// Short-lived playlist probe results. Callers serialize access with PlaybackInfo's playlist lock.
struct PlaybackInfoCache {
  typealias DurationAndProgress = (duration: Double?, progress: Double?)
  typealias Metadata = (title: String?, artist: String?)

  private struct Entry {
    var hasDurationAndProgress = false
    var duration: Double?
    var progress: Double?
    var hasMetadata = false
    var title: String?
    var artist: String?
  }

  private var entries: [String: Entry] = [:]
  private var playlistPaths: Set<String> = []
  private var playlistGeneration: UInt64?
  private var playlistSnapshotIsValid = false
  /// Contains only active asynchronous probes, so request tracking stays bounded by concurrent work.
  private var probeIDs: [String: UInt64] = [:]
  private var nextProbeID: UInt64 = 0
  private(set) var activeFilePath: String?

  var entryCount: Int { entries.count }

  func durationAndProgress(for path: String) -> DurationAndProgress? {
    guard let entry = entries[path], entry.hasDurationAndProgress else { return nil }
    return (duration: entry.duration, progress: entry.progress)
  }

  func metadata(for path: String) -> Metadata? {
    guard let entry = entries[path], entry.hasMetadata else { return nil }
    return (title: entry.title, artist: entry.artist)
  }

  /// Replace the playlist working set after a structural playlist refresh.
  /// The current file stays cached even when mpv temporarily omits it from the playlist.
  mutating func replacePlaylistPaths(_ paths: [String], generation: UInt64) {
    let newPaths = Set(paths)
    if let playlistGeneration, playlistGeneration != generation {
      // A path can be removed and re-added between two coalesced refreshes. The new generation
      // still invalidates requests started against the earlier playlist instance.
      probeIDs.removeAll(keepingCapacity: true)
    }
    playlistGeneration = generation
    playlistSnapshotIsValid = true
    guard newPaths != playlistPaths else { return }
    for removedPath in playlistPaths.subtracting(newPaths) {
      probeIDs.removeValue(forKey: removedPath)
    }
    playlistPaths = newPaths
    pruneOutsideCurrentScope()
  }

  /// Reset on a new open request. This is atomic with respect to cache readers and writers.
  mutating func resetScope(playlistPaths: [String], activeFilePath: String?) {
    self.playlistPaths = Set(playlistPaths)
    playlistGeneration = nil
    playlistSnapshotIsValid = false
    self.activeFilePath = activeFilePath
    probeIDs.removeAll(keepingCapacity: true)
    pruneOutsideCurrentScope()
  }

  /// Block in-flight playlist probes as soon as mpv reports a structural mutation, before rows
  /// can safely be queried and committed on the main thread.
  mutating func invalidatePlaylistSnapshot() {
    playlistSnapshotIsValid = false
    probeIDs.removeAll(keepingCapacity: true)
  }

  /// Update on FILE_STARTED. Normal playlist transitions only remove at most the previous
  /// active path, so they don't scan the full cache on every file load.
  mutating func setActiveFilePath(_ path: String?) {
    guard activeFilePath != path else { return }
    let previousPath = activeFilePath
    activeFilePath = path
    if let previousPath, !playlistPaths.contains(previousPath) {
      entries.removeValue(forKey: previousPath)
      probeIDs.removeValue(forKey: previousPath)
    }
  }

  /// Begin an asynchronous probe. A newer probe for the same path supersedes the older one.
  mutating func beginProbe(for path: String) -> UInt64? {
    guard playlistSnapshotIsValid, isInCurrentScope(path) else { return nil }
    nextProbeID &+= 1
    probeIDs[path] = nextProbeID
    return nextProbeID
  }

  /// Commit a probe only if it is still the latest request for a path in the active working set.
  /// Existing playback progress/duration wins over a slower sidebar probe.
  mutating func finishProbe(
    for path: String,
    requestID: UInt64,
    durationAndProgress: DurationAndProgress?,
    metadata: Metadata?
  ) {
    guard playlistSnapshotIsValid, isInCurrentScope(path), probeIDs[path] == requestID else { return }
    probeIDs.removeValue(forKey: path)
    guard durationAndProgress != nil || metadata != nil else { return }

    var entry = entries[path] ?? Entry()
    if !entry.hasDurationAndProgress, let durationAndProgress {
      entry.hasDurationAndProgress = true
      entry.duration = durationAndProgress.duration
      entry.progress = durationAndProgress.progress
    }
    if let metadata {
      entry.hasMetadata = true
      entry.title = metadata.title
      entry.artist = metadata.artist
    }
    entries[path] = entry
  }

  /// Update only an existing duration result, matching the original playback-progress path.
  mutating func setDuration(_ duration: Double, for path: String) {
    guard isInCurrentScope(path), var entry = entries[path], entry.hasDurationAndProgress else { return }
    entry.duration = duration
    entries[path] = entry
  }

  mutating func setDurationAndProgress(_ value: DurationAndProgress, for path: String) {
    guard isInCurrentScope(path) else { return }
    var entry = entries[path] ?? Entry()
    entry.hasDurationAndProgress = true
    entry.duration = value.duration
    entry.progress = value.progress
    entries[path] = entry
  }

  mutating func setMetadata(_ value: Metadata, for path: String) {
    guard isInCurrentScope(path) else { return }
    var entry = entries[path] ?? Entry()
    entry.hasMetadata = true
    entry.title = value.title
    entry.artist = value.artist
    entries[path] = entry
  }

  private func isInCurrentScope(_ path: String) -> Bool {
    path == activeFilePath || playlistPaths.contains(path)
  }

  private mutating func pruneOutsideCurrentScope() {
    var retainedPaths = playlistPaths
    if let activeFilePath { retainedPaths.insert(activeFilePath) }
    entries = entries.filter { retainedPaths.contains($0.key) }
    probeIDs = probeIDs.filter { retainedPaths.contains($0.key) }
  }
}
