import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

final class WeakPlaylistItem {
  weak var value: MPVPlaylistItem?
  init(_ value: MPVPlaylistItem) { self.value = value }
}

let first = MPVPlaylistItem(filename: "/media/duplicate.m4a", isCurrent: true, isPlaying: true, title: "First")
let second = MPVPlaylistItem(filename: "/media/duplicate.m4a", isCurrent: false, isPlaying: false, title: "Second")
let third = MPVPlaylistItem(filename: "/media/third.m4a", isCurrent: false, isPlaying: false, title: nil)
var playlist = [first, second, third]

expect(MPVPlaylistItem.canReadFullPlaylistSnapshot(isLoaded: true, isIdle: false),
       "full snapshots are safe after FILE_LOADED")
expect(MPVPlaylistItem.canReadFullPlaylistSnapshot(isLoaded: false, isIdle: true),
       "full snapshots are safe after mpv enters idle")
expect(!MPVPlaylistItem.canReadFullPlaylistSnapshot(isLoaded: false, isIdle: false),
       "full snapshots defer while mpv may be waiting on a load hook")
expect(!MPVPlaylistItem.canReadFullPlaylistSnapshot(isLoaded: true, isIdle: false,
                                                     isLoadTransitioning: true),
       "START_FILE defers full snapshots before main-thread loading state catches up")
expect(!MPVPlaylistItem.canReadFullPlaylistSnapshot(isLoaded: false, isIdle: true,
                                                     isLoadTransitioning: true),
       "a load transition takes precedence over a stale idle snapshot")

expect(MPVPlaylistItem.canReusePlaybackSnapshot(snapshotGeneration: 4, currentGeneration: 4,
                                                 cachedCount: 3, currentCount: 3),
       "an unchanged playlist generation and count should allow the playback-only fast path")
expect(!MPVPlaylistItem.canReusePlaybackSnapshot(snapshotGeneration: 4, currentGeneration: 5,
                                                  cachedCount: 3, currentCount: 3),
       "same-count reorder such as startup shuffle must invalidate the cached row order")
expect(!MPVPlaylistItem.canReusePlaybackSnapshot(snapshotGeneration: 4, currentGeneration: 4,
                                                  cachedCount: 3, currentCount: 4),
       "playlist size changes must invalidate the cached row set")
expect(MPVPlaylistItem.canCommitPlaylistSnapshot(readRevision: 9, currentReadRevision: 9,
                                                  snapshotGeneration: 4, currentGeneration: 4),
       "the latest read at the current structure generation may commit")
expect(!MPVPlaylistItem.canCommitPlaylistSnapshot(readRevision: 8, currentReadRevision: 9,
                                                   snapshotGeneration: 4, currentGeneration: 4),
       "a full read started before a newer status refresh cannot overwrite it")
expect(!MPVPlaylistItem.canCommitPlaylistSnapshot(readRevision: 9, currentReadRevision: 9,
                                                   snapshotGeneration: 4, currentGeneration: 5),
       "a read started before playlist invalidation cannot commit afterward")
let partialSnapshot = MPVPlaylistItem.makeSnapshot(count: 3) { index in
  guard index < 2 else { return nil }
  return MPVPlaylistItem(filename: "/media/row-\(index).m4a", isCurrent: false,
                         isPlaying: false, title: nil)
}
expect(partialSnapshot == nil,
       "a row removed during a full read must discard the partial snapshot instead of crashing")
let emptySnapshot = MPVPlaylistItem.makeSnapshot(count: 0) { _ in nil }
expect(emptySnapshot?.isEmpty == true,
       "an empty playlist remains a valid complete snapshot")
expect(MPVPlaylistMutationPolicy.invalidatesSnapshot(for: "playlist-move") &&
       MPVPlaylistMutationPolicy.invalidatesSnapshot(for: "playlist-shuffle") &&
       MPVPlaylistMutationPolicy.invalidatesSnapshot(for: "loadfile"),
       "plugin commands that can reorder or replace playlist rows must invalidate the snapshot")
expect(!MPVPlaylistMutationPolicy.invalidatesSnapshot(for: "playlist-next") &&
       !MPVPlaylistMutationPolicy.invalidatesSnapshot(for: "seek"),
       "ordinary playback navigation should keep the structure-only snapshot valid")
expect(MPVPlaylistMutationPolicy.invalidatesSnapshot(in: "no-osd playlist-shuffle") &&
       MPVPlaylistMutationPolicy.invalidatesSnapshot(in: "async raw playlist-clear; sync seek 10") &&
       MPVPlaylistMutationPolicy.invalidatesSnapshot(in: "osd-msg playlist-shuffle"),
       "raw command prefixes are skipped before checking every command in the sequence")
expect(!MPVPlaylistMutationPolicy.invalidatesSnapshot(in: "osd-msg-bar seek 10; no-osd playlist-next"),
       "prefixed playback navigation does not trigger structural invalidation")

let queueRows = [
  MPVPlaylistItem(filename: "/media/duplicate.m4a", isCurrent: false, isPlaying: false, title: "old"),
  MPVPlaylistItem(filename: "/media/duplicate.m4a", isCurrent: true, isPlaying: true, title: "playing"),
]
expect(MPVPlaylistItem.nowPlayingQueueIndex(in: queueRows, currentPath: "/media/duplicate.m4a") == 1,
       "Now Playing uses the active row when duplicate playlist paths exist")

let unchangedReplacements = MPVPlaylistItem.refreshPlaybackFlags(
  in: &playlist, previousCurrentIndex: 0, previousPlayingIndex: 0, currentIndex: 0, playingIndex: 0)
expect(unchangedReplacements == 0 && playlist[0] === first && playlist[1] === second && playlist[2] === third,
       "an unchanged snapshot should preserve every row object")

let changedReplacements = MPVPlaylistItem.refreshPlaybackFlags(
  in: &playlist, previousCurrentIndex: 0, previousPlayingIndex: 0, currentIndex: 1, playingIndex: 2)
expect(changedReplacements == 3,
       "a playback transition should replace only the rows whose flags changed")
expect(playlist[0] !== first && !playlist[0].isCurrent && !playlist[0].isPlaying,
       "the previous current/playing row should clear both flags")
expect(playlist[1] !== second && playlist[1].isCurrent && !playlist[1].isPlaying && playlist[1].title == "Second",
       "duplicate filenames should retain their index-specific current state and title")
expect(playlist[2] !== third && !playlist[2].isCurrent && playlist[2].isPlaying,
       "the new playing row should update independently from the current row")

let titleRefreshed = MPVPlaylistItem.refreshPlaybackFlags(
  in: &playlist, previousCurrentIndex: 1, previousPlayingIndex: 2, currentIndex: 1, playingIndex: 2,
  titleUpdates: [MPVPlaylistTitleUpdate(index: 2, title: "Acquired after load")])
expect(titleRefreshed == 1 && playlist[2].title == "Acquired after load" &&
       playlist[2].filenameForDisplay == "Acquired after load",
       "FILE_LOADED should refresh a title mpv acquired after opening the playlist row")
let titleCleared = MPVPlaylistItem.refreshPlaybackFlags(
  in: &playlist, previousCurrentIndex: 1, previousPlayingIndex: 2, currentIndex: 1, playingIndex: 2,
  titleUpdates: [MPVPlaylistTitleUpdate(index: 2, title: nil)])
expect(titleCleared == 1 && playlist[2].title == nil && playlist[2].filenameForDisplay == "third.m4a",
       "an explicit nil title refresh should clear stale metadata and restore the filename")

let stableRow = playlist[0]
let movedReplacements = MPVPlaylistItem.refreshPlaybackFlags(
  in: &playlist, previousCurrentIndex: 1, previousPlayingIndex: 2, currentIndex: 2, playingIndex: 2)
expect(movedReplacements == 2 && playlist[0] === stableRow,
       "rows unaffected by a current-position move should keep their object identity")

let beforeInvalidRefresh = playlist
let invalidReplacements = MPVPlaylistItem.refreshPlaybackFlags(
  in: &playlist, previousCurrentIndex: 2, previousPlayingIndex: 2, currentIndex: 99, playingIndex: 2)
expect(invalidReplacements == nil && playlist[0] === beforeInvalidRefresh[0] &&
       playlist[1] === beforeInvalidRefresh[1] && playlist[2] === beforeInvalidRefresh[2],
       "an index outside the cached playlist should request a full refresh without partial edits")

let stressCount = 101
var stressPlaylist = (0..<stressCount).map {
  MPVPlaylistItem(filename: "/media/stress-\($0).m4a", isCurrent: $0 == 0,
                  isPlaying: $0 == 0, title: nil)
}
var retiredRows: [WeakPlaylistItem] = []
var previousIndex = 0
for iteration in 0..<1_000 {
  let nextIndex = (iteration + 1) % stressCount
  retiredRows.append(WeakPlaylistItem(stressPlaylist[previousIndex]))
  let replacements = MPVPlaylistItem.refreshPlaybackFlags(
    in: &stressPlaylist,
    previousCurrentIndex: previousIndex,
    previousPlayingIndex: previousIndex,
    currentIndex: nextIndex,
    playingIndex: nextIndex)
  expect(replacements != nil && replacements! <= 2,
         "a playlist playback transition should replace at most the old and new rows")
  previousIndex = nextIndex
}
expect(stressPlaylist.count == stressCount,
       "one thousand FILE_LOADED-style transitions should keep the playlist snapshot size fixed")
expect(retiredRows.allSatisfy({ $0.value == nil }),
       "replaced playlist rows should be released instead of accumulating across transitions")

var splitPlaybackPlaylist = (0..<stressCount).map {
  MPVPlaylistItem(filename: "/media/split-\($0).m4a", isCurrent: $0 == 0,
                  isPlaying: $0 == 0, title: nil)
}
var retiredSplitRows: [WeakPlaylistItem] = []
var previousCurrentIndex = 0
var previousPlayingIndex = 0
for iteration in 0..<1_000 {
  let currentIndex = (iteration + 1) % stressCount
  let playingIndex = (iteration + 37) % stressCount
  let affected = Set([previousCurrentIndex, previousPlayingIndex, currentIndex, playingIndex])
  retiredSplitRows.append(contentsOf: affected.map { WeakPlaylistItem(splitPlaybackPlaylist[$0]) })
  let replacements = MPVPlaylistItem.refreshPlaybackFlags(
    in: &splitPlaybackPlaylist,
    previousCurrentIndex: previousCurrentIndex,
    previousPlayingIndex: previousPlayingIndex,
    currentIndex: currentIndex,
    playingIndex: playingIndex,
    titleUpdates: [
      MPVPlaylistTitleUpdate(index: currentIndex, title: "current-\(iteration)"),
      MPVPlaylistTitleUpdate(index: playingIndex,
                             title: iteration.isMultiple(of: 2) ? "playing-\(iteration)" : nil)
    ])
  expect(replacements != nil && replacements! <= 4,
         "distinct current and playing rows should keep each transition bounded to four rows")
  expect(retiredSplitRows.suffix(affected.count).allSatisfy({ $0.value == nil }),
         "each distinct-index transition should release its replaced row objects immediately")
  previousCurrentIndex = currentIndex
  previousPlayingIndex = playingIndex
}
expect(splitPlaybackPlaylist.count == stressCount &&
       splitPlaybackPlaylist[previousCurrentIndex].title == "current-999",
       "one thousand distinct current/playing transitions should keep a stable row count and fresh title")
expect(retiredSplitRows.allSatisfy({ $0.value == nil }),
       "distinct playback and title refreshes should not retain retired row objects")

print("PASS: playlist playback refresh reuses stable rows and rejects stale indexes")
