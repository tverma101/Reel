//
//  MPVPlaylistItem.swift
//  iina
//
//  Created by lhc on 23/8/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

class MPVPlaylistItem: NSObject, Identifiable {

  /** Actually this is the path. Use `filename` to conform mpv API's naming. */
  var filename: String

  /** Title or the real filename */
  var filenameForDisplay: String {
    return title ?? (isNetworkResource ? filename : NSString(string: filename).lastPathComponent)
  }

  var isCurrent: Bool
  var isPlaying: Bool
  var isNetworkResource: Bool

  var title: String?

  init(filename: String, isCurrent: Bool, isPlaying: Bool, title: String?) {
    self.filename = filename
    self.isCurrent = isCurrent
    self.isPlaying = isPlaying
    self.title = title
    self.isNetworkResource = Regex.url.matches(filename)
  }

  /// A playlist may change while mpv properties are being read. Discard a partial snapshot when
  /// any indexed row disappears so callers can retry after the mutation settles.
  static func makeSnapshot(count: Int, readRow: (Int) -> MPVPlaylistItem?) -> [MPVPlaylistItem]? {
    guard count >= 0 else { return nil }
    var items: [MPVPlaylistItem] = []
    items.reserveCapacity(count)
    for index in 0..<count {
      guard let item = readRow(index) else { return nil }
      items.append(item)
    }
    return items
  }

  static func canReusePlaybackSnapshot(snapshotGeneration: UInt64,
                                       currentGeneration: UInt64,
                                       cachedCount: Int,
                                       currentCount: Int) -> Bool {
    snapshotGeneration == currentGeneration && cachedCount == currentCount
  }

  static func canReadFullPlaylistSnapshot(isLoaded: Bool, isIdle: Bool,
                                          isLoadTransitioning: Bool = false) -> Bool {
    !isLoadTransitioning && (isLoaded || isIdle)
  }

  static func canCommitPlaylistSnapshot(readRevision: UInt64,
                                        currentReadRevision: UInt64,
                                        snapshotGeneration: UInt64,
                                        currentGeneration: UInt64) -> Bool {
    readRevision == currentReadRevision && snapshotGeneration == currentGeneration
  }

  static func nowPlayingQueueIndex(in playlist: [MPVPlaylistItem], currentPath: String) -> Int? {
    playlist.firstIndex(where: { $0.isPlaying })
      ?? playlist.firstIndex(where: { $0.isCurrent })
      ?? playlist.firstIndex(where: { $0.filename == currentPath })
  }

  /// Refresh only the rows whose current/playing state changed. `nil` means the mpv indexes do not
  /// match this cached playlist and the caller should rebuild the full snapshot. mpv can learn a
  /// row's display title only after opening it, so callers can also refresh titles for the small
  /// set of rows whose metadata may have changed.
  @discardableResult
  static func refreshPlaybackFlags(in playlist: inout [MPVPlaylistItem],
                                   previousCurrentIndex: Int,
                                   previousPlayingIndex: Int,
                                   currentIndex: Int,
                                   playingIndex: Int,
                                   titleUpdates: [MPVPlaylistTitleUpdate] = []) -> Int? {
    func isValid(_ index: Int) -> Bool {
      index == -1 || playlist.indices.contains(index)
    }
    guard isValid(previousCurrentIndex), isValid(previousPlayingIndex),
          isValid(currentIndex), isValid(playingIndex),
          titleUpdates.allSatisfy({ playlist.indices.contains($0.index) }) else { return nil }

    var titleByIndex: [Int: String?] = [:]
    for update in titleUpdates {
      // `.some(nil)` records an explicit nil title rather than removing the dictionary entry.
      titleByIndex[update.index] = .some(update.title)
    }

    var affectedIndices: [Int] = []
    for index in [previousCurrentIndex, previousPlayingIndex, currentIndex, playingIndex]
    where index >= 0 && !affectedIndices.contains(index) {
      affectedIndices.append(index)
    }
    for index in titleByIndex.keys where !affectedIndices.contains(index) {
      affectedIndices.append(index)
    }

    var replacements = 0
    for index in affectedIndices {
      let item = playlist[index]
      let isCurrent = index == currentIndex
      let isPlaying = index == playingIndex
      let title = titleByIndex[index] ?? item.title
      guard item.isCurrent != isCurrent || item.isPlaying != isPlaying || item.title != title else { continue }
      playlist[index] = MPVPlaylistItem(filename: item.filename,
                                        isCurrent: isCurrent,
                                        isPlaying: isPlaying,
                                        title: title)
      replacements += 1
    }
    return replacements
  }
}

struct MPVPlaylistTitleUpdate {
  let index: Int
  let title: String?
}

/// Playlist commands exposed to plugins can bypass PlayerCore's typed mutation methods. Keep the
/// incremental playback snapshot safe when one of those commands can change row order/content.
enum MPVPlaylistMutationPolicy {
  private static let commandPrefixes: Set<String> = [
    "osd-auto", "no-osd", "osd-bar", "osd-msg", "osd-msg-bar", "raw", "expand-properties",
    "repeatable", "nonrepeatable", "nonscalable", "async", "sync"
  ]

  static func invalidatesSnapshot(for commandName: String) -> Bool {
    switch commandName {
    case "stop", "loadfile", "loadlist", "playlist-clear", "playlist-remove", "playlist-move",
         "playlist-shuffle", "playlist-unshuffle":
      return true
    default:
      return false
    }
  }

  /// A default or replace loadfile/loadlist immediately begins loading media. Reserve its
  /// transition before sending the command so a queued playlist snapshot cannot read mpv while a
  /// plugin load hook is running ahead of START_FILE delivery.
  static func beginsFileLoadTransition(for commandName: String, arguments: [String?]) -> Bool {
    guard commandName == "loadfile" || commandName == "loadlist" else { return false }
    let mode = arguments.count > 1 ? arguments[1] : nil
    return mode == nil || mode == "replace"
  }

  static func invalidatesSnapshot(in rawCommandString: String) -> Bool {
    rawCommandString.split(separator: ";", omittingEmptySubsequences: true).contains { command in
      let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
      let name = tokens.first(where: { !commandPrefixes.contains($0) }) ?? ""
      return invalidatesSnapshot(for: name)
    }
  }
}
