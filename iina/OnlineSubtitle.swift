//
//  OnlineSubtitle.swift
//  iina
//
//  Created by lhc on 10/1/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Foundation
import PromiseKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum BuiltinSubtitleResponseLimit {
  static let searchBytes = 2 * 1024 * 1024
  static let detailBytes = 1 * 1024 * 1024
  static let subtitleBytes = 10 * 1024 * 1024
}

enum BuiltinSubtitleTransferError: Error {
  case invalidResponse
  case responseTooLarge(maximumBytes: Int)
  case untrustedRedirect
}

/// Streams built-in provider responses into a bounded buffer and registers the concrete URLSession
/// task with the search token. Plugin providers continue to use their existing protocol defaults.
final class BuiltinSubtitleHTTPTransfer: NSObject, URLSessionDataDelegate {
  typealias Completion = (Swift.Result<(Data, HTTPURLResponse), Swift.Error>) -> Void

  private let lock = NSLock()
  private let request: URLRequest
  private let maximumBytes: Int
  private let allowsURL: (URL) -> Bool
  private let cancellation: SubtitleAudioMatcher.Cancellation
  private let identifier = UUID()
  private let configuration: URLSessionConfiguration
  private let completion: Completion
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var response: HTTPURLResponse?
  private var body = Data()
  private var failure: Swift.Error?
  private var finished = false

  init(request: URLRequest,
       maximumBytes: Int,
       cancellation: SubtitleAudioMatcher.Cancellation,
       configuration: URLSessionConfiguration = .ephemeral,
       allowsURL: @escaping (URL) -> Bool = { _ in true },
       completion: @escaping Completion) {
    self.request = request
    self.maximumBytes = maximumBytes
    self.cancellation = cancellation
    self.configuration = configuration
    self.allowsURL = allowsURL
    self.completion = completion
  }

  func start() {
    guard maximumBytes > 0, let url = request.url, allowsURL(url) else {
      finish(.failure(BuiltinSubtitleTransferError.invalidResponse))
      return
    }
    let activeSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    let activeTask = activeSession.dataTask(with: request)
    lock.lock()
    session = activeSession
    task = activeTask
    lock.unlock()
    guard cancellation.register(activeTask, identifier: identifier) else {
      activeTask.cancel()
      finish(.failure(CancellationError()))
      return
    }
    activeTask.resume()
  }

  func urlSession(_ session: URLSession,
                  dataTask: URLSessionDataTask,
                  didReceive response: URLResponse,
                  completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    guard let httpResponse = response as? HTTPURLResponse,
          let url = response.url, allowsURL(url) else {
      lock.lock()
      failure = BuiltinSubtitleTransferError.invalidResponse
      lock.unlock()
      completionHandler(.cancel)
      return
    }
    lock.lock()
    self.response = httpResponse
    let isFinished = finished
    if response.expectedContentLength > Int64(maximumBytes) {
      failure = BuiltinSubtitleTransferError.responseTooLarge(maximumBytes: maximumBytes)
    }
    let isTooLarge = failure != nil
    lock.unlock()
    completionHandler(!isFinished && !isTooLarge ? .allow : .cancel)
  }

  func urlSession(_ session: URLSession,
                  task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest,
                  completionHandler: @escaping (URLRequest?) -> Void) {
    guard let url = request.url, allowsURL(url) else {
      lock.lock()
      failure = BuiltinSubtitleTransferError.untrustedRedirect
      lock.unlock()
      completionHandler(nil)
      finish(.failure(BuiltinSubtitleTransferError.untrustedRedirect))
      return
    }
    completionHandler(request)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    guard !finished, failure == nil else {
      lock.unlock()
      return
    }
    guard body.count <= maximumBytes, data.count <= maximumBytes - body.count else {
      failure = BuiltinSubtitleTransferError.responseTooLarge(maximumBytes: maximumBytes)
      lock.unlock()
      dataTask.cancel()
      return
    }
    body.append(data)
    lock.unlock()
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Swift.Error?) {
    lock.lock()
    let transferFailure = failure
    let transferResponse = response
    let wasCancelled = cancellation.isCancelled
    lock.unlock()
    if let transferFailure {
      finish(.failure(transferFailure))
    } else if wasCancelled {
      finish(.failure(CancellationError()))
    } else if let error {
      finish(.failure(error))
    } else if let transferResponse {
      lock.lock()
      let completedBody = body
      lock.unlock()
      finish(.success((completedBody, transferResponse)))
    } else {
      finish(.failure(BuiltinSubtitleTransferError.invalidResponse))
    }
  }

  private func finish(_ result: Swift.Result<(Data, HTTPURLResponse), Swift.Error>) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    finished = true
    let activeSession = session
    session = nil
    task = nil
    body.removeAll(keepingCapacity: false)
    lock.unlock()
    cancellation.finish(identifier)
    switch result {
    case .success:
      activeSession?.finishTasksAndInvalidate()
    case .failure:
      activeSession?.invalidateAndCancel()
    }
    completion(result)
  }
}

/// A per-result directory makes failed/cancelled downloads easy to remove without risking a file
/// returned to mpv. The root is intentionally app-owned so startup can later sweep only old entries.
final class BuiltinSubtitleCache {
  static let rootDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("IINAOnlineSubtitles", isDirectory: true)
  static let maximumAggregateBytes = 200 * 1024 * 1024
  /// Limits metadata work as well as bytes: many tiny results must not create an unbounded cache.
  static let maximumAggregateEntries = 2_048
  /// Allow room for lock files and session sentinels while bounding every root scan.
  private static let maximumRootEntriesScanned = maximumAggregateEntries + 1_024
  /// Assrt may return 20 files for one result; allow those plus lease/lock bookkeeping.
  static let maximumFilesPerEntryScanned = 32
  /// Startup cleanup is deliberately a small bounded batch because its caller is app launch.
  static let maximumStartupCleanupEntries = 256
  private static let maximumEntryAge: TimeInterval = 30 * 24 * 60 * 60
  private static let leaseMarkerReservation = 64
  private static let ownedPrefixes = ["opensub-", "assrt-", "shooter-", "subdl-"]
  private static let sessionLeasePrefix = ".iina-lease-session-"
  private static let leaseLock = NSLock()
  private struct AggregateInventory {
    var totalBytes: Int
    var ownedEntryCount: Int
    var rootModificationDate: Date?
  }
  private struct AggregateEntry {
    let url: URL
    let size: Int
    let modified: Date
  }
  /// Under the cross-process aggregate lock, writes update this snapshot incrementally. A changed
  /// root directory date invalidates it so another IINA process's new cache entry is reconciled.
  private static var aggregateInventories: [String: AggregateInventory] = [:]
  /// Internal observer lets the extracted-source harness assert scan work without timing tests.
  private static var aggregateInventoryScanObserver: ((URL, Int) -> Void)?
  private struct SessionLease {
    let fileName: String
    let descriptor: Int32
  }
  /// One permanent descriptor per cache root/process protects every marker in that root.
  private static var sessionLeases: [String: SessionLease] = [:]
  private static var reservedBytes: [String: Int] = [:]

  enum CacheError: Error {
    case aggregateLimitReached(maximumBytes: Int)
    case lockWaitTimedOut
  }

  private let lock = NSLock()
  private let directory: URL
  private let maximumAggregateBytes: Int
  private var discarded = false

  static func observeAggregateInventoryScansForTesting(_ observer: ((URL, Int) -> Void)?) {
    leaseLock.lock()
    aggregateInventoryScanObserver = observer
    leaseLock.unlock()
  }

  init(provider: String,
       rootDirectory: URL = BuiltinSubtitleCache.rootDirectory,
       maximumAggregateBytes: Int = BuiltinSubtitleCache.maximumAggregateBytes) {
    directory = rootDirectory.appendingPathComponent("\(provider.lowercased())-\(UUID().uuidString)",
                                                     isDirectory: true)
    self.maximumAggregateBytes = maximumAggregateBytes
  }

  func store(_ data: Data, suggestedFileName: String,
             cancellation: SubtitleAudioMatcher.Cancellation) throws -> URL {
    lock.lock()
    defer { lock.unlock() }
    guard !discarded, !cancellation.isCancelled else { throw CancellationError() }
    let root = directory.deletingLastPathComponent()
    let quotaLock = try Self.lockAggregateRoot(root, cancellation: cancellation)
    defer { Self.unlockDirectory(quotaLock) }
    let markerURL = directory.appendingPathComponent(".lease", isDirectory: false)
    let addsDirectory = !FileManager.default.fileExists(atPath: directory.path)
    let markerAllowance = addsDirectory && !FileManager.default.fileExists(atPath: markerURL.path)
      ? Self.leaseMarkerReservation : 0
    let (reservationBytes, overflow) = data.count.addingReportingOverflow(markerAllowance)
    guard !overflow else { throw CacheError.aggregateLimitReached(maximumBytes: maximumAggregateBytes) }
    try Self.reserveSpace(in: root, adding: reservationBytes, addingEntry: addsDirectory,
                          maximumBytes: maximumAggregateBytes, preserving: directory)
    var inventoryCommitted = false
    defer {
      Self.releaseReservation(in: root, bytes: reservationBytes,
                              invalidateInventory: !inventoryCommitted)
    }
    guard !discarded, !cancellation.isCancelled else { throw CancellationError() }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let component = URL(fileURLWithPath: suggestedFileName).lastPathComponent
    let stem = String(URL(fileURLWithPath: component).deletingPathExtension().lastPathComponent.prefix(100))
    let rawExtension = URL(fileURLWithPath: component).pathExtension.lowercased()
    let safeExtension = String(rawExtension.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(10))
    let uniqueName = UUID().uuidString + (safeExtension.isEmpty ? "" : ".\(safeExtension)")
    let url = directory.appendingPathComponent(uniqueName, isDirectory: false)
    try data.write(to: url, options: .atomic)
    guard !discarded, !cancellation.isCancelled else {
      try? FileManager.default.removeItem(at: url)
      throw CancellationError()
    }
    // Preserve a short provider stem where possible without trusting it as a path component.
    if !stem.isEmpty {
      let namedURL = directory.appendingPathComponent("\(stem.prefix(60))-\(uniqueName)", isDirectory: false)
      do {
        try FileManager.default.moveItem(at: url, to: namedURL)
        Self.recordStoredFile(in: root, bytes: data.count,
                              addedDirectory: addsDirectory)
        inventoryCommitted = true
        return namedURL
      } catch {
        try? FileManager.default.removeItem(at: url)
        throw error
      }
    }
    Self.recordStoredFile(in: root, bytes: data.count,
                          addedDirectory: addsDirectory)
    inventoryCommitted = true
    return url
  }

  func discard() {
    lock.lock()
    guard !discarded else {
      lock.unlock()
      return
    }
    discarded = true
    let root = directory.deletingLastPathComponent()
    Self.leaseLock.lock()
    if let descriptor = Self.lockDirectory(directory) {
      let isLeased = Self.isDirectoryLeased(directory, in: root)
      if !isLeased, Self.directoryByteCount(directory) != nil,
         (try? FileManager.default.removeItem(at: directory)) != nil {
        Self.aggregateInventories.removeValue(forKey: root.standardizedFileURL.path)
      }
      Self.unlockDirectory(descriptor)
    }
    Self.leaseLock.unlock()
    lock.unlock()
  }

  /// Removes a cached path only while its owned directory is unleased. Callers that cancel after
  /// handing a subtitle to mpv must preserve the path even if they still hold the provider object.
  func discardFileIfUnleased(_ file: URL) {
    guard file.standardizedFileURL.deletingLastPathComponent().path == directory.standardizedFileURL.path else {
      return
    }
    lock.lock()
    let root = directory.deletingLastPathComponent()
    Self.leaseLock.lock()
    if let descriptor = Self.lockDirectory(directory) {
      if !Self.isDirectoryLeased(directory, in: root) {
        if (try? FileManager.default.removeItem(at: file)) != nil {
          Self.aggregateInventories.removeValue(forKey: root.standardizedFileURL.path)
        }
      }
      Self.unlockDirectory(descriptor)
    }
    Self.leaseLock.unlock()
    lock.unlock()
  }

  /// Marks only provider-owned files returned by a completed search as active. Those directories
  /// stay leased for this app process because mpv can retain a selected subtitle path independently
  /// of the result object. A single root-level session descriptor protects all entries, rather than
  /// retaining one descriptor per selected subtitle. At the aggregate limit, new writes fail rather
  /// than deleting a path that a player may still have open.
  @discardableResult
  static func leaseFiles(_ files: [URL], rootDirectory rootURL: URL = rootDirectory) -> Bool {
    let root = rootURL.standardizedFileURL
    let ownedFiles = files.filter { file in
      let directory = file.standardizedFileURL.deletingLastPathComponent()
      return directory.deletingLastPathComponent().standardizedFileURL.path == root.path &&
        ownedPrefixes.contains(where: { directory.lastPathComponent.hasPrefix($0) })
    }
    guard !ownedFiles.isEmpty else { return true }
    leaseLock.lock()
    defer { leaseLock.unlock() }
    let session: SessionLease
    do {
      session = try currentSessionLease(in: root)
    } catch {
      return false
    }
    // The root-level session sentinel changes the directory date once per process. Refresh the
    // snapshot date; the per-directory marker bytes are covered by the conservative reservation.
    if var inventory = aggregateInventories[root.path] {
      inventory.rootModificationDate = rootModificationDate(root)
      aggregateInventories[root.path] = inventory
    }
    for file in ownedFiles {
      let directory = file.standardizedFileURL.deletingLastPathComponent()
      guard FileManager.default.fileExists(atPath: file.path),
            let descriptor = lockDirectory(directory) else { return false }
      do {
        try Data(session.fileName.utf8).write(to: directory.appendingPathComponent(".lease"), options: .atomic)
      } catch {
        unlockDirectory(descriptor)
        return false
      }
      unlockDirectory(descriptor)
    }
    return true
  }

  /// Releases only this process's lease and removes files that were never handed to a chooser or
  /// player. The stale-search path calls this after a result was leased but its callback declined it.
  static func discardUnhandedFiles(_ files: [URL], rootDirectory rootURL: URL = rootDirectory) {
    let root = rootURL.standardizedFileURL
    let rootPath = root.path
    let directories = Set(files.compactMap { file -> URL? in
      let directory = file.standardizedFileURL.deletingLastPathComponent()
      guard directory.deletingLastPathComponent().standardizedFileURL.path == rootPath,
            ownedPrefixes.contains(where: { directory.lastPathComponent.hasPrefix($0) }),
            let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
            values.isDirectory == true, values.isSymbolicLink != true else { return nil }
      return directory
    })
    guard !directories.isEmpty else { return }

    leaseLock.lock()
    defer { leaseLock.unlock() }
    guard let session = sessionLeases[rootPath] else { return }
    let expectedMarker = Data(session.fileName.utf8)
    for directory in directories {
      guard let descriptor = lockDirectory(directory) else { continue }
      let markerURL = directory.appendingPathComponent(".lease", isDirectory: false)
      let markerValues = try? markerURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
      let marker = markerValues?.isRegularFile == true && markerValues?.isSymbolicLink != true &&
        (markerValues?.fileSize ?? Int.max) <= 128 ? try? Data(contentsOf: markerURL) : nil
      if marker == expectedMarker, directoryByteCount(directory) != nil,
         (try? FileManager.default.removeItem(at: directory)) != nil {
        aggregateInventories.removeValue(forKey: rootPath)
      }
      unlockDirectory(descriptor)
    }
  }

  /// The marker names one root-level session file whose exclusive lock is held until process exit.
  /// Checking that sentinel protects active paths across processes without one open fd per subtitle.
  private static func currentSessionLease(in root: URL) throws -> SessionLease {
    let rootPath = root.standardizedFileURL.path
    if let existing = sessionLeases[rootPath] { return existing }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fileName = sessionLeasePrefix + UUID().uuidString
    let sessionURL = root.appendingPathComponent(fileName, isDirectory: false)
    let descriptor = open(sessionURL.path, O_CREAT | O_EXCL | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      _ = close(descriptor)
      try? FileManager.default.removeItem(at: sessionURL)
      throw CocoaError(.fileWriteUnknown)
    }
    let lease = SessionLease(fileName: fileName, descriptor: descriptor)
    sessionLeases[rootPath] = lease
    return lease
  }

  private static func lockDirectory(_ directory: URL) -> Int32? {
    let lockURL = directory.appendingPathComponent(".cache-lock", isDirectory: false)
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
    guard descriptor >= 0 else { return nil }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      close(descriptor)
      return nil
    }
    return descriptor
  }

  /// Requires the directory's short-lived `.cache-lock` to be held. An inaccessible marker is
  /// treated as active so cleanup never unlinks a path whose owner cannot be established.
  private static func isDirectoryLeased(_ directory: URL, in root: URL) -> Bool {
    let markerURL = directory.appendingPathComponent(".lease", isDirectory: false)
    guard FileManager.default.fileExists(atPath: markerURL.path) else { return false }
    guard let values = try? markerURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
          values.isRegularFile == true, values.isSymbolicLink != true,
          let markerSize = values.fileSize, markerSize >= 0, markerSize <= 128 else { return true }
    guard let data = try? Data(contentsOf: markerURL) else { return true }
    if data.isEmpty {
      // Older builds held an flock directly on an empty `.lease` file. Preserve it while that
      // process is alive, then retire the legacy marker after its lock becomes available.
      let descriptor = open(markerURL.path, O_RDWR)
      if descriptor >= 0 {
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
          unlockDirectory(descriptor)
          return false
        }
        _ = close(descriptor)
        return true
      }
      return true
    }
    guard let fileName = String(data: data, encoding: .utf8),
          fileName.hasPrefix(sessionLeasePrefix),
          fileName == URL(fileURLWithPath: fileName).lastPathComponent else { return true }
    let sessionURL = root.appendingPathComponent(fileName, isDirectory: false)
    let descriptor = open(sessionURL.path, O_RDWR)
    guard descriptor >= 0 else {
      try? FileManager.default.removeItem(at: markerURL)
      return false
    }
    if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
      // The owner process exited. The caller may now remove the directory; leave marker cleanup to
      // that removal so touching metadata does not make an expired directory look recently used.
      unlockDirectory(descriptor)
      return false
    }
    _ = close(descriptor)
    return true
  }

  /// Serializes aggregate accounting and file creation across IINA processes sharing the temp root.
  /// Polls nonblocking so cancellation can retire a request waiting behind another cache write.
  private static func lockAggregateRoot(_ root: URL,
                                        cancellation: SubtitleAudioMatcher.Cancellation,
                                        waitTimeout: TimeInterval? = nil) throws -> Int32 {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let lockURL = root.appendingPathComponent(".aggregate.lock", isDirectory: false)
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    let startedAt = ProcessInfo.processInfo.systemUptime
    while true {
      guard !cancellation.isCancelled else {
        _ = close(descriptor)
        throw CancellationError()
      }
      if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return descriptor }
      guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else {
        _ = close(descriptor)
        throw CocoaError(.fileWriteUnknown)
      }
      if let waitTimeout, ProcessInfo.processInfo.systemUptime - startedAt >= max(0, waitTimeout) {
        _ = close(descriptor)
        throw CacheError.lockWaitTimedOut
      }
      let remaining = waitTimeout.map { $0 - (ProcessInfo.processInfo.systemUptime - startedAt) }
      let delay = remaining.map { min(0.025, max(0, $0)) } ?? 0.025
      Thread.sleep(forTimeInterval: delay)
    }
  }

  /// Visits at most `maximumEntries` values and performs one extra read only to distinguish an
  /// exactly-full directory from a truncated scan. Both production scans and the focused harness
  /// use this helper so the work bound is directly testable without timing assertions.
  @discardableResult
  static func visitBoundedEntries(maximumEntries: Int,
                                  next: () -> URL?,
                                  visit: (URL) throws -> Void) rethrows -> Bool {
    guard maximumEntries >= 0 else { return false }
    var visited = 0
    while let entry = next() {
      guard visited < maximumEntries else { return false }
      visited += 1
      try visit(entry)
    }
    return true
  }

  /// Eviction order is needed only after the aggregate inventory exceeds a quota. Keeping this
  /// conditional in one helper makes the common under-quota write path avoid an O(n log n) sort
  /// while retaining deterministic oldest-first pruning when eviction is required.
  @discardableResult
  static func sortEvictionCandidatesIfNeeded<T>(_ entries: inout [T], shouldPrune: Bool,
                                                by areInIncreasingOrder: (T, T) -> Bool) -> Bool {
    guard shouldPrune else { return false }
    entries.sort(by: areInIncreasingOrder)
    return true
  }

  private static func enumerateEntries(in directory: URL,
                                       maximumEntries: Int,
                                       includingPropertiesForKeys keys: [URLResourceKey],
                                       visit: (URL) throws -> Void) throws -> Bool {
    guard let enumerator = FileManager.default.enumerator(
      at: directory, includingPropertiesForKeys: keys, options: [.skipsSubdirectoryDescendants]) else {
      throw CocoaError(.fileReadNoSuchFile)
    }
    return try visitBoundedEntries(maximumEntries: maximumEntries,
                                   next: { enumerator.nextObject() as? URL }, visit: visit)
  }

  private static func unlockDirectory(_ descriptor: Int32) {
    _ = flock(descriptor, LOCK_UN)
    _ = close(descriptor)
  }

  private static func reserveSpace(in root: URL, adding bytes: Int, addingEntry: Bool = true,
                                   maximumBytes: Int, preserving directoryToPreserve: URL) throws {
    guard bytes >= 0, maximumBytes > 0 else {
      throw CacheError.aggregateLimitReached(maximumBytes: maximumBytes)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    leaseLock.lock()
    defer { leaseLock.unlock() }
    let rootPath = root.standardizedFileURL.path
    let reserved = reservedBytes[rootPath] ?? 0
    var inventory = aggregateInventories[rootPath]
    var entries: [AggregateEntry]?
    let currentRootDate = rootModificationDate(root)
    if inventory == nil || currentRootDate == nil ||
        inventory?.rootModificationDate != currentRootDate {
      let scan = try scanAggregateInventory(in: root, maximumBytes: maximumBytes)
      inventory = scan.inventory
      entries = scan.entries
    }
    guard var current = inventory else {
      throw CacheError.aggregateLimitReached(maximumBytes: maximumBytes)
    }

    func needsPruning(total: Int, entryCount: Int) -> Bool {
      wouldExceed(addingWithSaturation(total, reserved), adding: bytes, limit: maximumBytes) ||
        (addingEntry && entryCount >= maximumAggregateEntries)
    }
    if needsPruning(total: current.totalBytes, entryCount: current.ownedEntryCount), entries == nil {
      let scan = try scanAggregateInventory(in: root, maximumBytes: maximumBytes)
      current = scan.inventory
      entries = scan.entries
    }
    if needsPruning(total: current.totalBytes, entryCount: current.ownedEntryCount) {
      var evictionCandidates = entries ?? []
      Self.sortEvictionCandidatesIfNeeded(&evictionCandidates, shouldPrune: true,
                                          by: { $0.modified < $1.modified })
      for entry in evictionCandidates where
          needsPruning(total: current.totalBytes, entryCount: current.ownedEntryCount) {
        guard entry.url.standardizedFileURL != directoryToPreserve.standardizedFileURL else { continue }
        // A short-lived directory lock serializes discard/lease/prune operations. The marker then
        // checks the single process-session sentinel, avoiding a permanent descriptor per result.
        guard let descriptor = lockDirectory(entry.url) else { continue }
        let isLeased = isDirectoryLeased(entry.url, in: root)
        let hasBoundedContents = directoryByteCount(entry.url) != nil
        let removed = !isLeased && hasBoundedContents &&
          (try? FileManager.default.removeItem(at: entry.url)) != nil
        unlockDirectory(descriptor)
        if removed {
          current.totalBytes = max(0, current.totalBytes - entry.size)
          current.ownedEntryCount = max(0, current.ownedEntryCount - 1)
        }
      }
    }
    guard !needsPruning(total: current.totalBytes, entryCount: current.ownedEntryCount) else {
      throw CacheError.aggregateLimitReached(maximumBytes: maximumBytes)
    }
    current.rootModificationDate = rootModificationDate(root)
    aggregateInventories[rootPath] = current
    let (newReservation, overflow) = reserved.addingReportingOverflow(bytes)
    guard !overflow else { throw CacheError.aggregateLimitReached(maximumBytes: maximumBytes) }
    reservedBytes[rootPath] = newReservation
  }

  /// Reconciles the bounded filesystem inventory only when the root changed or quota pressure
  /// requires eviction. Every entry gets a 64-byte lease allowance so later marker creation cannot
  /// exceed the aggregate limit without changing the root directory date.
  private static func scanAggregateInventory(in root: URL, maximumBytes: Int)
    throws -> (inventory: AggregateInventory, entries: [AggregateEntry]) {
    var total = 0
    var ownedEntryCount = 0
    var entries: [AggregateEntry] = []
    var visited = 0
    do {
      let complete = try enumerateEntries(
        in: root, maximumEntries: maximumRootEntriesScanned,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
      ) { entry in
        visited += 1
        guard ownedPrefixes.contains(where: { entry.lastPathComponent.hasPrefix($0) }) else { return }
        guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey,
                                                                .contentModificationDateKey]),
              values.isDirectory == true, values.isSymbolicLink != true,
              let size = directoryByteCountIncludingLeaseAllowance(entry) else {
          throw CacheError.aggregateLimitReached(maximumBytes: maximumBytes)
        }
        ownedEntryCount += 1
        // The helper already includes only the missing marker allowance needed to reach 64 bytes.
        // Adding the full allowance again would double-count existing entries after reconciliation.
        total = addingWithSaturation(total, size)
        entries.append(AggregateEntry(url: entry, size: size,
                                      modified: values.contentModificationDate ?? .distantPast))
      }
      guard complete else { throw CacheError.aggregateLimitReached(maximumBytes: maximumBytes) }
      aggregateInventoryScanObserver?(root, visited)
    } catch {
      aggregateInventoryScanObserver?(root, visited)
      throw CacheError.aggregateLimitReached(maximumBytes: maximumBytes)
    }
    return (AggregateInventory(totalBytes: total, ownedEntryCount: ownedEntryCount,
                               rootModificationDate: rootModificationDate(root)), entries)
  }

  private static func rootModificationDate(_ root: URL) -> Date? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: root.path) else { return nil }
    return attributes[.modificationDate] as? Date
  }

  private static func recordStoredFile(in root: URL, bytes: Int, addedDirectory: Bool) {
    guard bytes >= 0 else { return }
    leaseLock.lock()
    defer { leaseLock.unlock() }
    let rootPath = root.standardizedFileURL.path
    guard var inventory = aggregateInventories[rootPath] else { return }
    inventory.totalBytes = addingWithSaturation(inventory.totalBytes, bytes)
    if addedDirectory {
      inventory.totalBytes = addingWithSaturation(inventory.totalBytes, leaseMarkerReservation)
      inventory.ownedEntryCount += 1
    }
    inventory.rootModificationDate = rootModificationDate(root)
    aggregateInventories[rootPath] = inventory
  }

  private static func releaseReservation(in root: URL, bytes: Int, invalidateInventory: Bool) {
    let path = root.standardizedFileURL.path
    leaseLock.lock()
    let current = reservedBytes[path] ?? 0
    let remaining = max(0, current - bytes)
    if remaining == 0 { reservedBytes.removeValue(forKey: path) }
    else { reservedBytes[path] = remaining }
    if invalidateInventory { aggregateInventories.removeValue(forKey: path) }
    leaseLock.unlock()
  }

  private static func addingWithSaturation(_ first: Int, _ second: Int) -> Int {
    let (sum, overflow) = first.addingReportingOverflow(second)
    return overflow ? Int.max : sum
  }

  private static func wouldExceed(_ total: Int, adding bytes: Int, limit: Int) -> Bool {
    total > limit || bytes > limit - min(total, limit)
  }

  /// Cache directories contain flat subtitle files. Ignore symlinks and nested directories so
  /// accounting never follows a provider-controlled path outside the cache root.
  private static func directoryByteCount(_ directory: URL) -> Int? {
    var total = 0
    do {
      let complete = try enumerateEntries(
        in: directory, maximumEntries: maximumFilesPerEntryScanned,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
      ) { file in
        guard let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey,
                                                              .isSymbolicLinkKey, .fileSizeKey]),
              let isDirectory = values.isDirectory,
              let isSymbolicLink = values.isSymbolicLink else {
          throw CacheError.aggregateLimitReached(maximumBytes: maximumAggregateBytes)
        }
        guard !isDirectory || isSymbolicLink else {
          throw CacheError.aggregateLimitReached(maximumBytes: maximumAggregateBytes)
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0 else { return }
        let (next, overflow) = total.addingReportingOverflow(size)
        total = overflow ? Int.max : next
      }
      return complete ? total : nil
    } catch {
      return nil
    }
  }

  /// Includes enough headroom for a session marker without double-counting marker bytes already
  /// present. This keeps the incremental estimate safe when leaseFiles adds a marker in-place,
  /// which does not modify the cache root directory date.
  private static func directoryByteCountIncludingLeaseAllowance(_ directory: URL) -> Int? {
    guard let bytes = directoryByteCount(directory) else { return nil }
    let markerURL = directory.appendingPathComponent(".lease", isDirectory: false)
    guard FileManager.default.fileExists(atPath: markerURL.path) else {
      return addingWithSaturation(bytes, leaseMarkerReservation)
    }
    guard let values = try? markerURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
          values.isRegularFile == true, values.isSymbolicLink != true,
          let markerSize = values.fileSize, markerSize >= 0 else { return nil }
    let missingAllowance = max(0, leaseMarkerReservation - min(markerSize, leaseMarkerReservation))
    return addingWithSaturation(bytes, missingAllowance)
  }

  /// Call during startup. The scan and lock wait are capped because application launch is the caller.
  /// Active paths remain protected by their session lease even when the bounded scan is repeated.
  @discardableResult
  static func removeStaleEntries(in root: URL = rootDirectory,
                                 olderThan age: TimeInterval = 30 * 24 * 60 * 60,
                                 now: Date = Date()) -> Int {
    guard FileManager.default.fileExists(atPath: root.path),
          let quotaLock = try? lockAggregateRoot(root, cancellation: SubtitleAudioMatcher.Cancellation(),
                                                 waitTimeout: 0.05) else {
      return 0
    }
    defer { unlockDirectory(quotaLock) }
    let cutoff = now.addingTimeInterval(-max(0, age))
    var removed = 0
    leaseLock.lock()
    defer { leaseLock.unlock() }
    var inventoryChanged = false
    _ = try? enumerateEntries(
      in: root, maximumEntries: maximumStartupCleanupEntries,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
    ) { entry in
      if entry.lastPathComponent.hasPrefix(sessionLeasePrefix) {
        inventoryChanged = removeOrphanSessionFile(entry) || inventoryChanged
        return
      }
      guard Self.ownedPrefixes.contains(where: { entry.lastPathComponent.hasPrefix($0) }),
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey,
                                                             .contentModificationDateKey]),
            values.isDirectory == true, values.isSymbolicLink != true,
            let modified = values.contentModificationDate, modified < cutoff,
            let descriptor = lockDirectory(entry) else { return }
      // Refuse recursive deletion unless the owned directory is flat and within the same
      // per-entry bound used by aggregate accounting. This prevents an unexpected temp-tree from
      // turning launch-time cleanup into an unbounded recursive walk.
      guard directoryByteCount(entry) != nil else {
        unlockDirectory(descriptor)
        return
      }
      let isLeased = isDirectoryLeased(entry, in: root)
      let currentValues = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey,
                                                               .contentModificationDateKey])
      let stillStale = currentValues?.isDirectory == true && currentValues?.isSymbolicLink != true &&
        (currentValues?.contentModificationDate ?? now) < cutoff
      if !isLeased, stillStale, (try? FileManager.default.removeItem(at: entry)) != nil {
        removed += 1
        inventoryChanged = true
      }
      unlockDirectory(descriptor)
    }
    if inventoryChanged { aggregateInventories.removeValue(forKey: root.standardizedFileURL.path) }
    return removed
  }

  /// Removes an inactive sentinel left by a crash or previous app session.
  @discardableResult
  private static func removeOrphanSessionFile(_ entry: URL) -> Bool {
    let descriptor = open(entry.path, O_RDWR)
    guard descriptor >= 0 else { return false }
    if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
      let removed = (try? FileManager.default.removeItem(at: entry)) != nil
      unlockDirectory(descriptor)
      return removed
    } else {
      _ = close(descriptor)
      return false
    }
  }
}

fileprivate protocol ProviderProtocol {
  associatedtype F: OnlineSubtitleFetcher
  var id: String { get }
  var name: String { get }
  var origin: OnlineSubtitle.Origin { get }
  func getFetcher() -> F
  func fetchSubtitles(url: URL, player: PlayerCore,
                      cancellation: SubtitleAudioMatcher.Cancellation) -> Promise<[URL]>
}

protocol OnlineSubtitleFetcher {
  associatedtype Subtitle: OnlineSubtitle
  var loggedIn: Bool { get }
  func fetch(from url: URL, withProviderID id: String, playerCore player: PlayerCore) -> Promise<[Subtitle]>
  func fetch(from url: URL, withProviderID id: String, playerCore player: PlayerCore,
             cancellation: SubtitleAudioMatcher.Cancellation) -> Promise<[Subtitle]>
  func logout(timeout: TimeInterval?) -> Promise<Void>
}

extension OnlineSubtitleFetcher {
  /// Providers without cancellable fetch work can keep their existing implementation. The shared
  /// token still gates the fetch and the selected-download stage.
  func fetch(from url: URL, withProviderID id: String, playerCore player: PlayerCore,
             cancellation: SubtitleAudioMatcher.Cancellation) -> Promise<[Subtitle]> {
    guard !cancellation.isCancelled else {
      return Promise(error: OnlineSubtitle.CommonError.dismissed)
    }
    return fetch(from: url, withProviderID: id, playerCore: player)
  }
}

class OnlineSubtitle: NSObject {
  enum CommonError: Error {
    case noResult
    case canceled
    case dismissed
    case cannotConnect(Error)
    case networkError(Error?)
    case timedOut(Error)
    case fsError
  }

  static var loggedIn: Bool {
    let id = Preference.string(for: .onlineSubProvider) ?? Providers.openSub.id
    switch id {
    case Providers.openSub.id:
      return Providers.openSub.getFetcher().loggedIn
    case Providers.subDL.id:
      return Providers.subDL.getFetcher().loggedIn
    case Providers.shooter.id:
      return Providers.shooter.getFetcher().loggedIn
    case Providers.assrt.id:
      return Providers.assrt.getFetcher().loggedIn
    default:
      guard let provider = Providers.fromPlugin[id] else {
        return Providers.openSub.getFetcher().loggedIn
      }
      return provider.getFetcher().loggedIn
    }
  }

  /** Prepend a number before file name to avoid overwriting. */
  var index: Int

  /**
   The name of the release this subtitle was authored for, e.g. `Movie.2019.1080p.BluRay.x264-GROUP`.

   Providers override this so IINA can score how well a result matches the media being played.
   `nil` means the provider cannot describe its results, and such results never auto-select.
   */
  var releaseName: String? { nil }

  /// Whether this provider result has independent evidence beyond uploader-controlled names.
  /// Providers must opt in explicitly; exact filename matches alone are not proof of content.
  var canAutomaticallySelect: Bool { false }

  /// Provider-supplied preference for chooser preselection, without changing result ordering.
  var verifiedSelectionBoost: Int { 0 }

  init(index: Int) {
    self.index = index
  }

  /// Check if the given error indicates IINA was unable to connect to the subtitle server.
  /// - Parameter error: the error object to inspect
  /// - Returns: `true` if the error represents a connection failure; otherwise `false`.
  static func isConnectFailure(_ error: Error?) -> Bool {
    guard let nsError = (error as NSError?) else { return false }
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCannotConnectToHost
  }

  /// Check if the given error indicates IINA timed out while trying to connect to the subtitle server.
  /// - Parameter error: the error object to inspect
  /// - Returns: `true` if the error represents a timed out failure; otherwise `false`.
  static func isTimedOutFailure(_ error: Error?) -> Bool {
    guard let nsError = (error as NSError?) else { return false }
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
  }

  func download() -> Promise<[URL]> { return .value([]) }

  /// Entry point used by the shared search pipeline so every selected subtitle is checked against
  /// the search's cancellation token before its download begins.
  func download(cancellation: SubtitleAudioMatcher.Cancellation) -> Promise<[URL]> {
    guard !cancellation.isCancelled else {
      return Promise(error: CommonError.dismissed)
    }
    return download()
  }

  /// Providers that cache downloaded files can remove them if a later selected download fails.
  func discardCachedDownload() {}
  func getDescription() -> (name: String, left: String, right: String) { return("", "", "") }

  class DefaultFetcher {
    var loggedIn: Bool { false }
    func logout(timeout: TimeInterval?) -> Promise<Void> { .value }
    required init() {}
  }

  class Providers {
    static let subDL = Provider<SubDL.Fetcher>(id: ":subdl", name: "SubDL")
    static let shooter = Provider<Shooter.Fetcher>(id: ":shooter", name: "shooter.cn")
    static let openSub = Provider<OpenSub.Fetcher>(id: ":opensubtitles", name: "opensubtitles.com")
    static let assrt = Provider<Assrt.Fetcher>(id: ":assrt", name: "assrt.net")

    static var fromPlugin: [String: Provider<JSPluginSub.Fetcher>] = [:]

    static func registerFromPlugin(_ pluginID: String, _ pluginName: String, id: String, name: String) {
      let providerID = "plugin:\(pluginID):\(id)"
      fromPlugin[providerID] = Provider(id: id,
                                        name: name,
                                        providerID: providerID,
                                        origin: .plugin(id: pluginID, name: pluginName))
    }

    static func removeAllFromPlugin(_ pluginID: String) {
      let prefix = "plugin:\(pluginID):"
      for key in fromPlugin.keys.filter({ $0.hasPrefix(prefix) }) {
        fromPlugin.removeValue(forKey: key)
      }
    }

    static func nameForID(_ id: String) -> String {
      switch id {
      case Providers.subDL.id:
        return Providers.subDL.name
      case Providers.openSub.id:
        return Providers.openSub.name
      case Providers.shooter.id:
        return Providers.shooter.name
      case Providers.assrt.id:
        return Providers.assrt.name
      default:
        return Providers.fromPlugin[id]?.name ?? Providers.openSub.name
      }
    }
  }

  enum Origin {
    case legacy
    case plugin(id: String, name: String)
  }

  class Provider<F: OnlineSubtitleFetcher>: ProviderProtocol where F: DefaultFetcher {
    let id: String
    let providerID: String
    let name: String
    let origin: Origin

    init(id: String, name: String, providerID: String? = nil, origin: Origin = .legacy) {
      self.id = id
      self.providerID = providerID ?? id
      self.name = name
      self.origin = origin
    }

    func getFetcher() -> F {
      return F()
    }

    func fetchSubtitles(url: URL, player: PlayerCore,
                        cancellation: SubtitleAudioMatcher.Cancellation) -> Promise<[URL]> {
      let fetcher = getFetcher()
      var fetchedSubtitles: [F.Subtitle] = []
      let searchID = player.onlineSubtitleSearchID
      return fetcher.fetch(from: url, withProviderID: providerID, playerCore: player,
                           cancellation: cancellation)
      .then { [self] subtitles -> Promise<[URL]> in
        fetchedSubtitles = subtitles
        guard !cancellation.isCancelled else {
          throw OnlineSubtitle.CommonError.dismissed
        }
        // The chooser temporarily owns this callback while it is displayed. Reinstall the search
        // cancellation after it returns, before the selected-download chain starts.
        let restoreCancellation = {
          guard player.onlineSubtitleSearchID == searchID else {
            cancellation.cancel()
            return
          }
          player.cancelOnlineSubtitleSearch = { cancellation.cancel() }
        }
        if Thread.isMainThread {
          restoreCancellation()
        } else {
          DispatchQueue.main.sync(execute: restoreCancellation)
        }
        guard !cancellation.isCancelled else {
          throw OnlineSubtitle.CommonError.dismissed
        }
        if subtitles.isEmpty {
          throw OnlineSubtitle.CommonError.noResult
        } else {
          player.sendOSD(.downloadingSub(subtitles.count, name))
        }
        return self.downloadSelected(subtitles, at: 0, cancellation: cancellation).map { urls in
          guard !cancellation.isCancelled else {
            throw OnlineSubtitle.CommonError.dismissed
          }
          guard BuiltinSubtitleCache.leaseFiles(urls) else {
            BuiltinSubtitleCache.discardUnhandedFiles(urls)
            throw cancellation.isCancelled ? OnlineSubtitle.CommonError.dismissed : OnlineSubtitle.CommonError.fsError
          }
          guard !cancellation.isCancelled else {
            BuiltinSubtitleCache.discardUnhandedFiles(urls)
            throw OnlineSubtitle.CommonError.dismissed
          }
          return urls
        }
      }.recover { error -> Promise<[URL]> in
        fetchedSubtitles.forEach { $0.discardCachedDownload() }
        if cancellation.isCancelled {
          throw OnlineSubtitle.CommonError.dismissed
        }
        throw error
      }
    }

    private func downloadSelected(_ subtitles: [F.Subtitle],
                                  at index: Int,
                                  cancellation: SubtitleAudioMatcher.Cancellation) -> Promise<[URL]> {
      guard !cancellation.isCancelled else {
        return Promise(error: OnlineSubtitle.CommonError.dismissed)
      }
      guard index < subtitles.count else { return .value([]) }
      return subtitles[index].download(cancellation: cancellation).then { urls -> Promise<[URL]> in
        guard !cancellation.isCancelled else {
          throw OnlineSubtitle.CommonError.dismissed
        }
        return self.downloadSelected(subtitles, at: index + 1, cancellation: cancellation)
          .map { urls + $0 }
      }
    }
  }

  static func logout(timeout: TimeInterval? = nil) {
    let id = Preference.string(for: .onlineSubProvider) ?? Providers.openSub.id
    switch id {
    case Providers.subDL.id:
      _logout(using: Providers.subDL, timeout: timeout)
    case Providers.openSub.id:
      _logout(using: Providers.openSub, timeout: timeout)
    case Providers.shooter.id:
      _logout(using: Providers.shooter, timeout: timeout)
    case Providers.assrt.id:
      _logout(using: Providers.assrt, timeout: timeout)
    default:
      guard let provider = Providers.fromPlugin[id] else {
        _logout(using: Providers.openSub, timeout: timeout)
        return
      }
      _logout(using: provider, timeout: timeout)
    }
  }

  fileprivate static func _logout<P: ProviderProtocol>(using provider: P, timeout: TimeInterval? = nil) {
    provider.getFetcher().logout(timeout: timeout).catch { err in
      let prefix = "Failed to log out of \(provider.name). "
      switch err {
      case CommonError.cannotConnect(let cause):
        log("\(prefix)\(cause.localizedDescription)", level: .error)
      case CommonError.networkError(let cause):
        let error = cause ?? err
        log("\(prefix)\(error.localizedDescription)", level: .error)
      case CommonError.timedOut(let cause):
        log("\(prefix)\(cause.localizedDescription)", level: .error)
      case JSPluginSub.Error.pluginError(let message):
        log("\(prefix)\(message)", level: .error)
      default:
        log("\(prefix)\(err.localizedDescription)", level: .error)
      }
    }.finally {
      NotificationCenter.default.post(Notification(name: .iinaLogoutCompleted, object: self))
    }
  }

  static func search(forFile url: URL, player: PlayerCore, providerID: String? = nil, callback: @escaping ([URL]) -> Void) {
    let id = providerID ?? Preference.string(for: .onlineSubProvider) ?? Providers.openSub.id
    switch id {
    case Providers.subDL.id:
      _search(using: Providers.subDL, forFile: url, player, callback)
    case Providers.openSub.id:
      _search(using: Providers.openSub, forFile: url, player, callback)
    case Providers.shooter.id:
      _search(using: Providers.shooter, forFile: url, player, callback)
    case Providers.assrt.id:
      _search(using: Providers.assrt, forFile: url, player, callback)
    default:
      if let provider = Providers.fromPlugin[id] {
        _search(using: provider, forFile: url, player, callback)
      } else {
        _search(using: Providers.openSub, forFile: url, player, callback)
      }
    }
  }

  fileprivate static func _search<P: ProviderProtocol>(using provider: P, forFile url: URL, _ player: PlayerCore, _ callback: @escaping ([URL]) -> Void) {
    log("Search subtitle from \(provider.name)...")
    player.sendOSD(.startFindingSub(provider.name), autoHide: false)
    let searchID = player.onlineSubtitleSearchID
    let cancellation = SubtitleAudioMatcher.Cancellation()
    DispatchQueue.main.async {
      guard player.onlineSubtitleSearchID == searchID else {
        cancellation.cancel()
        return
      }
      player.cancelOnlineSubtitleSearch = { cancellation.cancel() }
    }

    let clearCancellationForCurrentSearch: () -> Bool = {
      let clear = {
        guard player.onlineSubtitleSearchID == searchID else { return false }
        player.cancelOnlineSubtitleSearch = nil
        return true
      }
      return Thread.isMainThread ? clear() : DispatchQueue.main.sync(execute: clear)
    }

    provider.fetchSubtitles(url: url, player: player, cancellation: cancellation).done { urls in
      guard clearCancellationForCurrentSearch() else {
        cancellation.cancel()
        BuiltinSubtitleCache.discardUnhandedFiles(urls)
        return
      }
      callback(urls)
    }.ensure {
      guard player.onlineSubtitleSearchID == searchID else { return }
      player.hideOSD()
    }.catch { err in
      guard clearCancellationForCurrentSearch() else {
        cancellation.cancel()
        return
      }
      let osdMessage: OSDMessage
      let prefix = "Failed to obtain subtitles for \(url) from \(provider.name). "
      switch err {
      case CommonError.noResult:
        // Not an error.
        log("No subtitles found")
        callback([])
        return
      case CommonError.cannotConnect(let cause):
        osdMessage = .cannotConnect
        log("\(prefix)\(cause.localizedDescription)", level: .error)
      case CommonError.networkError(let cause):
        let error = cause ?? err
        osdMessage = osdMessageForDetailedError(error, fallback: .networkError, providerName: provider.name)
        log("\(prefix)\(error.localizedDescription)", level: .error)
      case CommonError.timedOut(let cause):
        osdMessage = .timedOut
        log("\(prefix)\(cause.localizedDescription)", level: .error)
      case OpenSubClient.Error.errorResponse(let response):
        osdMessage = osdMessageForOpenSubErrorResponse(response, fallback: .networkError, providerName: provider.name)
        log("\(prefix)\(response.message)", level: .error)
      case Shooter.Error.cannotReadFile(let cause),
           OpenSub.Error.cannotReadFile(let cause):
        osdMessage = .fileError
        log("\(prefix)Cannot get file handle. \(cause)", level: .error)
      case Shooter.Error.fileTooSmall(let minimumFileSize),
           OpenSub.Error.fileTooSmall(let minimumFileSize):
        osdMessage = .fileError
        log("\(prefix)File is too small. Minimum file size supported by the site is \(minimumFileSize)",
            level: .error)
      case OpenSub.Error.emptyFile(let reason):
        osdMessage = .fileError
        log("\(prefix)Invalid file, \(reason)", level: .error)
      case OpenSub.Error.loginFailed(let reason):
        osdMessage = .cannotLogin
        log("\(prefix)Login failed, \(reason)", level: .error)
      case SubDL.Error.missingAPIKey:
        osdMessage = .customWithDetail(err.localizedDescription, provider.name)
        log("\(prefix)SubDL API key has not been configured", level: .warning)
      case let subDLError as SubDL.Error:
        osdMessage = .customWithDetail(subDLError.localizedDescription, provider.name)
        log("\(prefix)\(subDLError.localizedDescription)", level: .warning)
      case JSPluginSub.Error.pluginError(let message):
        osdMessage = .customWithDetail(message, provider.name)
        log("\(prefix)\(message)", level: .error)
      case CommonError.canceled:
        osdMessage = .canceled
        // Not an error.
        log("User canceled download of subtitles")
      case CommonError.dismissed:
        // Operation dismissed by, for example, a plugin with custom implementation.
        log("Default subtitle search wokflow dismissed")
        player.isSearchingOnlineSubtitle = false
        player.onlineSubtitleSearchID = nil
        return
      default:
        osdMessage = .networkError
        log("\(prefix)\(err.localizedDescription)", level: .error)
      }
      let timeout: Float? = shouldExtendTimeout(for: osdMessage) ? 5 : nil
      player.sendOSD(osdMessage, forcedTimeout: timeout)
      player.isSearchingOnlineSubtitle = false
      player.onlineSubtitleSearchID = nil
    }
  }

  private static func osdMessageForOpenSubErrorResponse(_ response: OpenSubClient.ErrorResponse,
                                                        fallback: OSDMessage,
                                                        providerName: String) -> OSDMessage {
    guard providerName == Providers.openSub.name, response.remaining == -1 else { return fallback }
    let resetTime = response.resetTimeUtc.map {
      DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short)
    }
    return .onlineSubQuotaExceeded(resetTime)
  }

  private static func osdMessageForDetailedError(_ error: Swift.Error,
                                                 fallback: OSDMessage,
                                                 providerName: String) -> OSDMessage {
    switch error {
    case OpenSubClient.Error.errorResponse(let response):
      return osdMessageForOpenSubErrorResponse(response, fallback: fallback, providerName: providerName)
    default:
      return fallback
    }
  }

  private static func shouldExtendTimeout(for osdMessage: OSDMessage) -> Bool {
    switch osdMessage {
    case .onlineSubQuotaExceeded:
      return true
    default:
      return false
    }
  }

  static func populateMenu(_ menu: NSMenu, action: Selector? = nil, insertSeparator: Bool = true) {
    let defaultProviders = [
      (Providers.subDL.name, Providers.subDL.id),
      (Providers.openSub.name, Providers.openSub.id),
      (Providers.assrt.name, Providers.assrt.id),
      (Providers.shooter.name, Providers.shooter.id)
    ]
    menu.removeAllItems()
    for (name, id) in defaultProviders {
      menu.addItem(withTitle: name, action: action, tag: nil, obj: id)
    }
    if insertSeparator {
      menu.addItem(.separator())
    }
    for (id, provider) in OnlineSubtitle.Providers.fromPlugin {
      guard case .plugin(_, let pluginName) = provider.origin else { break }
      menu.addItem(withTitle: provider.name + " — " + pluginName, action: action, tag: nil, obj: id)
    }
  }

  private static func log(_ message: @autoclosure () -> String, level: Logger.Level = .debug) {
    Logger.log(message, level: level, subsystem: Logger.Sub.onlinesub)
  }
}

extension Logger {
  struct Sub {
    static let onlinesub = Logger.makeSubsystem("onlinesub")
  }
}


// MARK: - Matching a search result against the current media

/// Scores how well an online subtitle's release name matches the media being played.
///
/// Only a score of `100` may trigger automatic download and selection, and it is awarded
/// conservatively. The release name is untrusted input — it is whatever name the uploader of a
/// remote subtitle chose — so a name-based comparison can never be treated as proof that a
/// subtitle belongs to a file. `100` therefore requires **all** of the following:
///
/// 1. Both names reduce to exactly the same title, token for token. Tokens are compared as a
///    sequence; comparing them with separators removed is not safe, because shifting a word
///    boundary by one character (`The.Matrix` vs `t.hematrix`) would then look like a match.
/// 2. Both names carry the same set of *identity anchors* — a release year, or an episode marker —
///    and that set is not empty. The anchors are read from the whole name, not from the reduced
///    title, so a release cannot escape comparison simply by omitting them.
/// 3. Neither name is empty after reduction.
///
/// Requirement 2 is what separates a remake from its original: `The.Thing.1982` and
/// `The.Thing.2011` share a title but not a year, so they never auto-select. It is also why a file
/// with no year and no episode marker in its name — `Movie.mkv` — is never auto-selected: with no
/// anchor there is nothing to corroborate the title with, and the title alone is not evidence.
///
/// A name-based check cannot be made proof against a deliberately crafted release name, because
/// `The.Matrix.1999.1080p.Sinners` is indistinguishable from a legitimate
/// `The.Matrix.1999.1080p.BluRay`. That is why automatic selection is opt-in, why the result is
/// still only ever a *default* the user can change, and why anything short of `100` is capped
/// below it.
enum SubtitleMatchScorer {

  /// Score of a result considered an exact match for the current media.
  static let perfectMatch = 100

  /// Longest name scored. Names arrive from a remote server and are otherwise unbounded, and every
  /// step below is linear in the token count, so this bounds the work a single result can cause.
  private static let maxNameLength = 4096

  /// File extensions that are stripped from a release name before comparing, so that `Movie.srt`
  /// and `Movie` compare equal. Only subtitle formats are stripped, which keeps titles containing
  /// a dot — `Dr. Strangelove` — intact.
  private static let subtitleExtensions: Set<String> = [
    "srt", "ass", "ssa", "sub", "vtt", "smi", "sami", "txt", "ttml", "dfxp", "mpl2", "jss", "epub",
  ]

  /// Tokens that begin the release-tag section of a name, i.e. that describe *how* a release was
  /// produced rather than *what* it is.
  ///
  /// Only the *first* such token matters for reducing a name to its title: everything from it
  /// onwards is discarded. That is what lets an arbitrary release group — `x264-NTb`, `x264-YIFY`,
  /// `x264-组` — be ignored without having to be enumerated.
  private static let releaseTagTokens: Set<String> = [
    // source
    "bluray", "blu", "brrip", "bdrip", "bdremux", "remux", "webrip", "webdl", "web", "dl", "rip",
    "hdtv", "pdtv", "dvdrip", "dvd", "dvdscr", "scr", "cam", "ts", "tc", "r5", "hc", "korsub",
    // video
    "x264", "x265", "h264", "h265", "hevc", "avc", "xvid", "divx", "vp9", "av1", "bit", "hi10p",
    "hdr", "hdr10", "dv", "dolby", "vision", "sdr",
    // audio
    "aac", "ac3", "eac3", "dd", "dts", "dtshd", "truehd", "atmos", "flac", "opus", "mp3", "lpcm",
    // edition
    "extended", "unrated", "remastered", "directors", "director", "cut", "proper", "repack",
    "internal", "limited", "complete", "season", "series", "collection", "anniversary",
    // provenance
    "multi", "dual", "subbed", "dubbed", "subs", "dubs", "retail", "imax", "sbs", "hsbs",
    "yify", "yts", "amzn", "nf", "hmax", "atvp", "criterion",
  ]

  /// Release tags that are not plain words, such as `1080p` or `4k`.
  private static let releaseTagPatterns = [
    #"^\d{3,4}[pi]$"#,  // 1080p, 576i
    #"^\d{3,4}$"#,      // 1080
    #"^\d+k$"#,         // 4k
    #"^(hd|sd|uhd|fhd|hd1080|hd720)$"#,
  ].compactMap { try? NSRegularExpression(pattern: $0) }

  /// Patterns for an episode marker, which identifies *which* episode a release belongs to.
  ///
  /// These are deliberately **not** release tags: an episode marker is part of the title, so it is
  /// always compared, and it doubles as an identity anchor. The first pattern also covers
  /// multi-episode releases such as `S01E01E02`; the dotted and hyphenated spellings that
  /// `tokenize` splits into separate `S01` / `E02` tokens are recombined by
  /// `normalizeEpisodeMarkers(_:)` before anything is compared.
  private static let episodePatterns = [
    #"^s\d+e\d+(e\d+)*$"#,  // S01E02, S01E01E02
    #"^\d+x\d+$"#,          // 1x02
  ].compactMap { try? NSRegularExpression(pattern: $0) }

  /// Season and episode halves, matched separately so that `S01.E02` and `S01-E02` can be
  /// recombined into the single anchor `s01e02`.
  private static let seasonPatterns = [
    #"^s\d+$"#,  // S01
  ].compactMap { try? NSRegularExpression(pattern: $0) }

  private static let episodeHalfPatterns = [
    #"^e\d+$"#,  // E02
  ].compactMap { try? NSRegularExpression(pattern: $0) }

  /// - Parameters:
  ///   - releaseName: The release the subtitle was authored for, e.g.
  ///     `Movie.2019.1080p.BluRay.x264-GROUP.srt`. Untrusted input.
  ///   - mediaName: The name of the media being played, without extension.
  /// - Returns: A score from `0` (no useful resemblance) to `100` (same title, same year or
  ///   episode), where only a `100` may trigger automatic selection.
  static func score(releaseName: String?, mediaName: String) -> Int {
    score(releaseName: releaseName, mediaTokens: prepareMediaName(mediaName))
  }

  static func prepareMediaName(_ mediaName: String) -> [String] {
    normalizeEpisodeMarkers(tokenize(clip(mediaName)))
  }

  static func score(releaseName: String?, mediaTokens: [String]) -> Int {
    guard let releaseName, !releaseName.isEmpty, !mediaTokens.isEmpty else { return 0 }
    let release = normalizeEpisodeMarkers(tokenize(clip(stripSubtitleExtension(from: releaseName))))
    let media = mediaTokens
    guard !release.isEmpty, !media.isEmpty else { return 0 }

    if isIdenticalTitleAndAnchor(release, media) { return perfectMatch }

    // Partial resemblance, used only to order and preselect in the chooser. Capped below
    // `perfectMatch` so it can never trigger automatic selection.
    //
    // A release whose title matches but whose anchor differs — a remake, or an extra year hiding a
    // different film — is ranked just below a real match rather than being lumped in with
    // unrelated results, so it still surfaces near the top for the user to judge.
    let shared = Set(media).intersection(release).count
    guard shared > 0 else { return 0 }
    var value = Int(((2.0 * Double(shared)) / Double(media.count + release.count) * 100).rounded())
    let releaseTitle = titleTokens(of: release)
    let mediaTitle = titleTokens(of: media)
    if releaseTitle == mediaTitle, !releaseTitle.isEmpty {
      value = max(value, 90)
    }
    return min(95, value)
  }

  /// Whether `release` and `media` describe the same title *and* agree on their identity anchors.
  private static func isIdenticalTitleAndAnchor(_ release: [String], _ media: [String]) -> Bool {
    let releaseTitle = titleTokens(of: release)
    let mediaTitle = titleTokens(of: media)
    // An empty title means the very first token was a release tag, which says nothing about the
    // title — the film "1917" reduces to nothing.
    guard !releaseTitle.isEmpty, !mediaTitle.isEmpty else { return false }
    // Compared as an ordered sequence. Joining the tokens instead would treat "The.Matrix" and
    // "t.hematrix" as equal, which is not a property worth having.
    guard releaseTitle == mediaTitle else { return false }
    // Release names are uploader-controlled. A real release tail contains technical tags and at
    // most one arbitrary release-group token; multiple unknown words after the first tag can be a
    // second title inserted after an otherwise matching filename.
    guard hasSafeReleaseTail(release) else { return false }
    // Read from the full names, so a release cannot dodge the comparison by leaving its year or
    // episode out, and so a second year or episode cannot be smuggled in after a release tag.
    let releaseAnchors = identityAnchors(in: release)
    let mediaAnchors = identityAnchors(in: media)
    return !mediaAnchors.isEmpty && releaseAnchors == mediaAnchors
  }

  private static func hasSafeReleaseTail(_ tokens: [String]) -> Bool {
    guard let firstTag = tokens.firstIndex(where: isReleaseTag) else { return true }
    var unclassifiedTokens = 0
    for token in tokens.dropFirst(firstTag + 1) where !isReleaseDetail(token) {
      unclassifiedTokens += 1
      if unclassifiedTokens > 1 { return false }
    }
    return true
  }

  private static func isReleaseDetail(_ token: String) -> Bool {
    if isReleaseTag(token) || ["h", "ddp5", "ddp7"].contains(token) { return true }
    // Channel-count fragments such as the `1` in `DDP5.1` are split out by `tokenize`.
    return token.count <= 2 && Int(token) != nil
  }

  /// The leading tokens of `tokens` that belong to the title, discarding the token that starts the
  /// release-tag section and everything after it.
  private static func titleTokens(of tokens: [String]) -> [String] {
    for (index, token) in tokens.enumerated() where isReleaseTag(token) {
      return Array(tokens[..<index])
    }
    return tokens
  }

  /// The years and episode markers appearing anywhere in `tokens`.
  private static func identityAnchors(in tokens: [String]) -> Set<String> {
    var anchors = Set<String>()
    for token in tokens where isYear(token) || isEpisodeMarker(token) {
      anchors.insert(token)
    }
    return anchors
  }

  /// Merge a season token immediately followed by an episode token, so that the three spellings of
  /// the same marker — `S01E02`, `S01.E02` and `S01-E02` — tokenize alike. Without this the two
  /// halves would sit in the title as separate tokens and never compare equal.
  ///
  /// Requiring the season to come first keeps a title that merely contains a word like `E2` from
  /// being rewritten.
  private static func normalizeEpisodeMarkers(_ tokens: [String]) -> [String] {
    var result: [String] = []
    var index = 0
    while index < tokens.count {
      if isSeasonMarker(tokens[index]), index + 1 < tokens.count, isEpisodeHalf(tokens[index + 1]) {
        result.append(tokens[index] + tokens[index + 1])
        index += 2
      } else {
        result.append(tokens[index])
        index += 1
      }
    }
    return result
  }

  private static func isReleaseTag(_ token: String) -> Bool {
    // An episode marker is never a release tag: it identifies the episode, so it belongs to the
    // title and must always be compared.
    if isEpisodeMarker(token) { return false }
    if releaseTagTokens.contains(token) { return true }
    if isYear(token) { return true }
    return matches(releaseTagPatterns, token)
  }

  private static func isYear(_ token: String) -> Bool {
    guard token.count == 4, let value = Int(token) else { return false }
    return (1900...2099).contains(value)
  }

  private static func isEpisodeMarker(_ token: String) -> Bool {
    matches(episodePatterns, token)
  }

  private static func isSeasonMarker(_ token: String) -> Bool {
    matches(seasonPatterns, token)
  }

  private static func isEpisodeHalf(_ token: String) -> Bool {
    matches(episodeHalfPatterns, token)
  }

  private static func matches(_ patterns: [NSRegularExpression], _ token: String) -> Bool {
    let range = NSRange(token.startIndex..., in: token)
    return patterns.contains { $0.firstMatch(in: token, range: range) != nil }
  }

  /// Strip a trailing subtitle extension, keeping the rest of the path intact.
  private static func stripSubtitleExtension(from name: String) -> String {
    let ext = (name as NSString).pathExtension.lowercased()
    guard subtitleExtensions.contains(ext) else { return name }
    return (name as NSString).deletingPathExtension
  }

  /// Truncate an over-long name so that scoring stays cheap.
  private static func clip(_ name: String) -> String {
    name.count > maxNameLength ? String(name.prefix(maxNameLength)) : name
  }

  /// Lowercase, drop diacritics, and split on everything that is not a letter or a digit.
  private static func tokenize(_ name: String) -> [String] {
    let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                               locale: Locale(identifier: "en_US_POSIX"))
    let separated = String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " })
    return separated.split(separator: " ").map(String.init)
  }
}
