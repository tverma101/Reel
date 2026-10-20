import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

var cache = PlaybackInfoCache()
let playlistPaths = (0..<1_000).map { "/media/playlist-\($0).m4a" }
cache.replacePlaylistPaths(playlistPaths, generation: 1)
for (index, path) in playlistPaths.enumerated() {
  cache.setDurationAndProgress((duration: Double(index + 1), progress: 0), for: path)
  cache.setMetadata((title: "title-\(index)", artist: "artist"), for: path)
}
expect(cache.entryCount == playlistPaths.count,
       "every entry in a large active playlist should stay cached")
expect(cache.durationAndProgress(for: playlistPaths[999])?.duration == 1_000 &&
       cache.metadata(for: playlistPaths[999])?.title == "title-999",
       "the last row in a large active playlist should retain both probe results")

let activePath = "/media/current-not-listed.m4a"
cache.setActiveFilePath(activePath)
cache.setDurationAndProgress((duration: 12, progress: 3), for: activePath)
cache.setMetadata((title: "active", artist: nil), for: activePath)
expect(cache.durationAndProgress(for: activePath)?.progress == 3 &&
       cache.metadata(for: activePath)?.title == "active",
       "the current file should remain cached even when mpv omits it from the playlist")

cache.replacePlaylistPaths(["/media/new-a.m4a", "/media/new-b.m4a"], generation: 2)
expect(cache.entryCount == 1,
       "replacing the playlist should prune all stale paths except the active file")
expect(cache.durationAndProgress(for: activePath) != nil && cache.metadata(for: activePath) != nil,
       "playlist replacement should preserve the current file's probe results")

cache.setDurationAndProgress((duration: 99, progress: 0), for: "/media/late-stale-probe.m4a")
cache.setMetadata((title: "stale", artist: nil), for: "/media/late-stale-probe.m4a")
expect(cache.durationAndProgress(for: "/media/late-stale-probe.m4a") == nil &&
       cache.metadata(for: "/media/late-stale-probe.m4a") == nil,
       "late probes for paths outside the active playlist should not repopulate stale cache entries")

let reusedPath = "/media/reused.m4a"
cache.resetScope(playlistPaths: [reusedPath], activeFilePath: nil)
cache.replacePlaylistPaths([reusedPath], generation: 10)
let staleRequest = cache.beginProbe(for: reusedPath)!
// An intermediate playlist mutation can be coalesced before rows are fetched, leaving the same
// path set at refresh time. The new generation must still invalidate the old request.
cache.replacePlaylistPaths([reusedPath], generation: 12)
cache.finishProbe(for: reusedPath, requestID: staleRequest,
                  durationAndProgress: (duration: 5, progress: 1),
                  metadata: (title: "stale-before-readd", artist: nil))
expect(cache.durationAndProgress(for: reusedPath) == nil &&
       cache.metadata(for: reusedPath) == nil,
       "a changed playlist generation invalidates probes when the refreshed path set is unchanged")
cache.replacePlaylistPaths(["/media/replacement.m4a"], generation: 13)
cache.replacePlaylistPaths([reusedPath], generation: 14)
let currentRequest = cache.beginProbe(for: reusedPath)!
cache.finishProbe(for: reusedPath, requestID: currentRequest,
                  durationAndProgress: (duration: 22, progress: 11),
                  metadata: (title: "new", artist: nil))
cache.finishProbe(for: reusedPath, requestID: staleRequest,
                  durationAndProgress: (duration: 10, progress: 5),
                  metadata: (title: "old", artist: nil))
expect(cache.durationAndProgress(for: reusedPath)?.duration == 22 &&
       cache.durationAndProgress(for: reusedPath)?.progress == 11 &&
       cache.metadata(for: reusedPath)?.title == "new",
       "a completed probe from before removal and re-addition must not overwrite the newer result")

cache.setDurationAndProgress((duration: 88, progress: 33), for: reusedPath)
let supersededRequest = cache.beginProbe(for: reusedPath)!
let latestRequest = cache.beginProbe(for: reusedPath)!
cache.finishProbe(for: reusedPath, requestID: latestRequest,
                  durationAndProgress: (duration: 33, progress: 12),
                  metadata: (title: "latest", artist: nil))
cache.finishProbe(for: reusedPath, requestID: supersededRequest,
                  durationAndProgress: (duration: 44, progress: 13),
                  metadata: (title: "superseded", artist: nil))
expect(cache.durationAndProgress(for: reusedPath)?.duration == 88 &&
       cache.durationAndProgress(for: reusedPath)?.progress == 33 &&
       cache.metadata(for: reusedPath)?.title == "latest",
       "a probe must preserve newer playback duration/progress and accept only latest metadata")

cache.resetScope(playlistPaths: [reusedPath], activeFilePath: reusedPath)
cache.replacePlaylistPaths([reusedPath], generation: 20)
let activeStaleRequest = cache.beginProbe(for: reusedPath)!
cache.replacePlaylistPaths(["/media/other-active.m4a"], generation: 21)
expect(cache.durationAndProgress(for: reusedPath) != nil,
       "removing the playing file from the playlist should keep its active cache entry")
cache.replacePlaylistPaths([reusedPath], generation: 22)
let activeCurrentRequest = cache.beginProbe(for: reusedPath)!
cache.finishProbe(for: reusedPath, requestID: activeCurrentRequest,
                  durationAndProgress: (duration: 55, progress: 15),
                  metadata: (title: "active-new", artist: nil))
cache.finishProbe(for: reusedPath, requestID: activeStaleRequest,
                  durationAndProgress: (duration: 66, progress: 16),
                  metadata: (title: "active-old", artist: nil))
expect(cache.durationAndProgress(for: reusedPath)?.duration == 88 &&
       cache.metadata(for: reusedPath)?.title == "active-new",
       "playlist removal invalidates probes even when the removed path remains active")

let mutationGapPath = "/media/mutation-gap.m4a"
cache.resetScope(playlistPaths: [mutationGapPath], activeFilePath: nil)
cache.replacePlaylistPaths([mutationGapPath], generation: 30)
let mutationGapRequest = cache.beginProbe(for: mutationGapPath)!
cache.invalidatePlaylistSnapshot()
expect(cache.beginProbe(for: mutationGapPath) == nil,
       "a mutation gap cannot admit probes before the next playlist snapshot")
cache.finishProbe(for: mutationGapPath, requestID: mutationGapRequest,
                  durationAndProgress: (duration: 77, progress: 7),
                  metadata: (title: "stale-during-refresh", artist: nil))
expect(cache.durationAndProgress(for: mutationGapPath) == nil && cache.metadata(for: mutationGapPath) == nil,
       "a probe finishing before snapshot refresh cannot repopulate invalidated cache state")
cache.replacePlaylistPaths([mutationGapPath], generation: 31)
let refreshedRequest = cache.beginProbe(for: mutationGapPath)!
cache.finishProbe(for: mutationGapPath, requestID: refreshedRequest,
                  durationAndProgress: (duration: 31, progress: 3),
                  metadata: (title: "fresh-after-refresh", artist: nil))
expect(cache.durationAndProgress(for: mutationGapPath)?.duration == 31 &&
       cache.metadata(for: mutationGapPath)?.title == "fresh-after-refresh",
       "a refreshed snapshot reopens cache probes")

for index in 0..<1_000 {
  let path = "/media/transient-\(index).m4a"
  cache.resetScope(playlistPaths: [], activeFilePath: path)
  cache.setDurationAndProgress((duration: Double(index), progress: 0), for: path)
  cache.setMetadata((title: "transient-\(index)", artist: nil), for: path)
  expect(cache.entryCount == 1,
         "unique sequential files should keep cache size bounded to the current file")
}
expect(cache.durationAndProgress(for: "/media/transient-999.m4a")?.duration == 999 &&
       cache.durationAndProgress(for: "/media/transient-0.m4a") == nil &&
       cache.metadata(for: "/media/transient-0.m4a") == nil,
       "sequential unique paths should retain only the latest active file")

print("PASS: playlist metadata caches retain the active working set and release stale paths")
