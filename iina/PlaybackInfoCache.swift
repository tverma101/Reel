import Foundation

/// Short-lived metadata for the current playlist and playing file.
/// Callers serialize access with PlaybackInfo's playlist lock.
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
  private var playlistSnapshotIsValid = false
  private var probeIDs: [String: UInt64] = [:]
  private var nextProbeID: UInt64 = 0
  private(set) var activeFilePath: String?

  func durationAndProgress(for path: String) -> DurationAndProgress? {
    guard let entry = entries[path], entry.hasDurationAndProgress else { return nil }
    return (duration: entry.duration, progress: entry.progress)
  }

  func metadata(for path: String) -> Metadata? {
    guard let entry = entries[path], entry.hasMetadata else { return nil }
    return (title: entry.title, artist: entry.artist)
  }

  mutating func replacePlaylistPaths(_ paths: [String]) {
    let newPaths = Set(paths)
    playlistSnapshotIsValid = true
    guard newPaths != playlistPaths else { return }
    for removedPath in playlistPaths.subtracting(newPaths) {
      probeIDs.removeValue(forKey: removedPath)
    }
    playlistPaths = newPaths
    pruneOutsideCurrentScope()
  }

  mutating func resetScope(activeFilePath: String?) {
    playlistPaths = []
    playlistSnapshotIsValid = false
    self.activeFilePath = activeFilePath
    probeIDs.removeAll(keepingCapacity: true)
    pruneOutsideCurrentScope()
  }

  mutating func setActiveFilePath(_ path: String?) {
    guard activeFilePath != path else { return }
    let previousPath = activeFilePath
    activeFilePath = path
    if let previousPath, !playlistPaths.contains(previousPath) {
      entries.removeValue(forKey: previousPath)
      probeIDs.removeValue(forKey: previousPath)
    }
  }

  mutating func beginProbe(for path: String) -> UInt64? {
    guard playlistSnapshotIsValid, isInCurrentScope(path) else { return nil }
    nextProbeID &+= 1
    probeIDs[path] = nextProbeID
    return nextProbeID
  }

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
