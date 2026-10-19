//
//  CacheManager.swift
//  iina
//
//  Created by lhc on 28/9/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

final class CacheManager {
  static let shared = CacheManager()

  // Multiple player queues can write to and evict from the cache concurrently.
  private let lock = NSLock()
  private var needsRefresh = true
  private var cachedContents: [URL]?

  func invalidate() {
    lock.lock()
    defer { lock.unlock() }
    needsRefresh = true
  }

  // Called while holding `lock`.
  private func cacheFolderContents() -> [URL]? {
    if needsRefresh || cachedContents == nil {
      guard let contents = try? FileManager.default.contentsOfDirectory(
        at: Utility.thumbnailCacheURL,
        includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey],
        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
      ) else { return nil }
      cachedContents = contents
      needsRefresh = false
    }
    return cachedContents
  }

  private func fileSize(_ url: URL) -> Int {
    (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
  }

  func getCacheSize() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return (cacheFolderContents() ?? []).reduce(0) { $0 + fileSize($1) }
  }

  // Evict only if over budget, then reclaim to half the budget to avoid churn.
  func clearOldCache() {
    lock.lock()
    defer { lock.unlock() }

    let maxBytes = max(0, Preference.integer(for: .maxThumbnailPreviewCacheSize)) *
      FloatingPointByteCountFormatter.PrefixFactor.mi.rawValue
    guard let contents = cacheFolderContents() else { return }
    var totalBytes = contents.reduce(0) { $0 + fileSize($1) }
    guard totalBytes > maxBytes else { return }
    let targetBytes = maxBytes / 2

    let oldestFirst = contents.sorted {
      let first = (try? $0.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate ?? .distantPast
      let second = (try? $1.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate ?? .distantPast
      return first < second
    }
    for url in oldestFirst {
      guard totalBytes > targetBytes else { break }
      let size = fileSize(url)
      do {
        try FileManager.default.removeItem(at: url)
        totalBytes -= size
      } catch {
        // Do not count failed deletions as reclaimed bytes.
        continue
      }
    }
    needsRefresh = true
  }
}
