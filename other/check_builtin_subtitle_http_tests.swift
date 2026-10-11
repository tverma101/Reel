import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class BuiltinSubtitleURLProtocol: URLProtocol {
  enum Plan {
    case response(status: Int, headers: [String: String], chunks: [Data])
    case waitForCancellation
    case redirect(URL)
  }

  private static let lock = NSLock()
  private static var responder: ((URLRequest) -> Plan)!
  private static var requestPaths: [String] = []
  private static var deliveredBytes = 0
  private let cancellationLock = NSLock()
  private let released = DispatchSemaphore(value: 0)
  private var cancelled = false

  static func configure(_ makePlan: @escaping (URLRequest) -> Plan) {
    lock.lock()
    responder = makePlan
    requestPaths.removeAll()
    deliveredBytes = 0
    lock.unlock()
  }

  static var paths: [String] {
    lock.lock()
    defer { lock.unlock() }
    return requestPaths
  }

  static var byteCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return deliveredBytes
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.lock()
    let makePlan = Self.responder
    Self.requestPaths.append(request.url?.path ?? "")
    Self.lock.unlock()
    guard let makePlan else { return }

    switch makePlan(request) {
    case .response(let status, let headers, let chunks):
      sendResponse(status: status, headers: headers)
      for chunk in chunks {
        Self.lock.lock()
        Self.deliveredBytes += chunk.count
        Self.lock.unlock()
        client?.urlProtocol(self, didLoad: chunk)
      }
      client?.urlProtocolDidFinishLoading(self)
    case .waitForCancellation:
      sendResponse(status: 200, headers: [:])
      _ = released.wait(timeout: .now() + 5)
      cancellationLock.lock()
      let wasCancelled = cancelled
      cancellationLock.unlock()
      if !wasCancelled {
        client?.urlProtocol(self, didLoad: Data([1]))
        client?.urlProtocolDidFinishLoading(self)
      }
    case .redirect(let destination):
      guard let currentURL = request.url,
            let redirect = HTTPURLResponse(url: currentURL,
                                           statusCode: 302,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": destination.absoluteString]) else {
        client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        return
      }
      client?.urlProtocol(self,
                          wasRedirectedTo: URLRequest(url: destination),
                          redirectResponse: redirect)
    }
  }

  override func stopLoading() {
    cancellationLock.lock()
    cancelled = true
    cancellationLock.unlock()
    released.signal()
  }

  private func sendResponse(status: Int, headers: [String: String]) {
    guard let url = request.url,
          let response = HTTPURLResponse(url: url,
                                         statusCode: status,
                                         httpVersion: "HTTP/1.1",
                                         headerFields: headers) else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
  }
}

@main
struct BuiltinSubtitleHTTPChecks {
  private static var checks = 0

  private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else {
      fputs("FAIL: \(message)\n", stderr)
      exit(1)
    }
  }

  private static func configuration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BuiltinSubtitleURLProtocol.self]
    configuration.urlCache = nil
    return configuration
  }

  private static func request(_ path: String, host: String = "trusted.test") -> URLRequest {
    URLRequest(url: URL(string: "https://\(host)\(path)")!)
  }

  private static func transfer(maximumBytes: Int,
                               cancellation: SubtitleAudioMatcher.Cancellation = .init(),
                               path: String = "/download",
                               host: String = "trusted.test",
                               allowedHost: String? = "trusted.test",
                               done: @escaping (Result<(Data, HTTPURLResponse), Error>) -> Void) -> BuiltinSubtitleHTTPTransfer {
    BuiltinSubtitleHTTPTransfer(request: request(path, host: host),
                                maximumBytes: maximumBytes,
                                cancellation: cancellation,
                                configuration: configuration(),
                                allowsURL: { url in allowedHost == nil || url.host == allowedHost },
                                completion: done)
  }

  private static func execute(maximumBytes: Int,
                              path: String = "/download",
                              allowedHost: String? = "trusted.test") -> Result<(Data, HTTPURLResponse), Error> {
    let finished = DispatchSemaphore(value: 0)
    var result: Result<(Data, HTTPURLResponse), Error>!
    transfer(maximumBytes: maximumBytes, path: path, allowedHost: allowedHost) {
      result = $0
      finished.signal()
    }.start()
    guard finished.wait(timeout: .now() + 5) == .success else { fatalError("transfer timed out at \(path)") }
    return result
  }

  static func main() {
    BuiltinSubtitleURLProtocol.configure { _ in
      .response(status: 200, headers: ["Content-Type": "text/plain"],
                chunks: [Data([1, 2]), Data([3, 4, 5])])
    }
    let absentLength = execute(maximumBytes: 8)
    check((try? absentLength.get().0) == Data([1, 2, 3, 4, 5]),
          "responses without Content-Length are accepted below the byte cap")

    BuiltinSubtitleURLProtocol.configure { _ in
      .response(status: 200, headers: [:], chunks: [Data(repeating: 1, count: 6), Data(repeating: 2, count: 4)])
    }
    let chunkedOverLimit = execute(maximumBytes: 8)
    check((try? chunkedOverLimit.get()) == nil && BuiltinSubtitleURLProtocol.byteCount == 10,
          "unknown-length transfer is rejected when streamed bytes exceed the cap")

    BuiltinSubtitleURLProtocol.configure { _ in
      .response(status: 200, headers: ["Content-Length": "1"], chunks: [Data(repeating: 3, count: 9)])
    }
    let dishonestLength = execute(maximumBytes: 8)
    check((try? dishonestLength.get()) == nil,
          "actual body bytes are capped even when Content-Length is understated")

    BuiltinSubtitleURLProtocol.configure { _ in
      .response(status: 200, headers: ["Content-Length": "9"], chunks: [])
    }
    let declaredOverLimit = execute(maximumBytes: 8)
    check((try? declaredOverLimit.get()) == nil && BuiltinSubtitleURLProtocol.byteCount == 0,
          "a declared oversized body is rejected before any test body bytes are delivered")

    BuiltinSubtitleURLProtocol.configure { request in
      request.url?.path == "/redirect"
        ? .redirect(URL(string: "https://trusted.test/final")!)
        : .response(status: 200, headers: [:], chunks: [Data([7])])
    }
    let sameHostRedirect = execute(maximumBytes: 8, path: "/redirect")
    check((try? sameHostRedirect.get().0) == Data([7]) &&
          BuiltinSubtitleURLProtocol.paths == ["/redirect", "/final"],
          "redirects accepted by the provider host policy still complete")

    BuiltinSubtitleURLProtocol.configure { request in
      request.url?.path == "/redirect"
        ? .redirect(URL(string: "https://evil.test/final")!)
        : .response(status: 200, headers: [:], chunks: [Data([7])])
    }
    let crossHostRedirect = execute(maximumBytes: 8, path: "/redirect")
    check((try? crossHostRedirect.get()) == nil && BuiltinSubtitleURLProtocol.paths == ["/redirect"],
          "a redirect to an untrusted host is not followed")

    let started = DispatchSemaphore(value: 0)
    BuiltinSubtitleURLProtocol.configure { _ in
      started.signal()
      return .waitForCancellation
    }
    let cancellation = SubtitleAudioMatcher.Cancellation()
    let cancellationDone = DispatchSemaphore(value: 0)
    var cancellationError: Error?
    transfer(maximumBytes: 8, cancellation: cancellation) {
      if case .failure(let error) = $0 { cancellationError = error }
      cancellationDone.signal()
    }.start()
    check(started.wait(timeout: .now() + 5) == .success, "local cancellable transfer started")
    cancellation.cancel()
    check(cancellationDone.wait(timeout: .now() + 5) == .success && cancellationError != nil,
          "cancellation interrupts the registered URLSession task")

    let preCancelled = SubtitleAudioMatcher.Cancellation()
    preCancelled.cancel()
    BuiltinSubtitleURLProtocol.configure { _ in
      .response(status: 200, headers: [:], chunks: [Data([1])])
    }
    let preCancelledDone = DispatchSemaphore(value: 0)
    var preCancelledError: Error?
    transfer(maximumBytes: 8, cancellation: preCancelled) {
      if case .failure(let error) = $0 { preCancelledError = error }
      preCancelledDone.signal()
    }.start()
    check(preCancelledDone.wait(timeout: .now() + 5) == .success && preCancelledError != nil &&
          BuiltinSubtitleURLProtocol.paths.isEmpty,
          "a token cancelled before start cannot create a follow-on request")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("subtitle-cache-test-\(UUID())",
                                                                           isDirectory: true)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = BuiltinSubtitleCache(provider: "subdl", rootDirectory: root)
    let cacheToken = SubtitleAudioMatcher.Cancellation()
    cacheToken.onCancel { cache.discard() }
    let saved = try! cache.store(Data("subtitle".utf8), suggestedFileName: "../sample.srt",
                                cancellation: cacheToken)
    check(FileManager.default.fileExists(atPath: saved.path) && saved.pathExtension == "srt",
          "a completed download is stored under its owned cache directory")
    cacheToken.cancel()
    check(!FileManager.default.fileExists(atPath: saved.path) &&
          (try? FileManager.default.contentsOfDirectory(atPath: root.path)
            .allSatisfy { !$0.hasPrefix("subdl-") }) == true,
          "cancellation removes the owned cached file and directory")

    let unhandedRoot = FileManager.default.temporaryDirectory.appendingPathComponent("subtitle-cache-unhanded-\(UUID())",
                                                                                     isDirectory: true)
    try! FileManager.default.createDirectory(at: unhandedRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: unhandedRoot) }
    let unhandedCache = BuiltinSubtitleCache(provider: "opensub", rootDirectory: unhandedRoot)
    let unhandedURL = try! unhandedCache.store(Data("not handed off".utf8), suggestedFileName: "orphan.srt",
                                               cancellation: .init())
    check(BuiltinSubtitleCache.leaseFiles([unhandedURL], rootDirectory: unhandedRoot),
          "the result is leased before the simulated stale-search handoff")
    BuiltinSubtitleCache.discardUnhandedFiles([unhandedURL], rootDirectory: unhandedRoot)
    check(!FileManager.default.fileExists(atPath: unhandedURL.path) &&
          !FileManager.default.fileExists(atPath: unhandedURL.deletingLastPathComponent().path),
          "a stale search releases its own lease and immediately removes files never handed to the UI")

    let quotaRoot = FileManager.default.temporaryDirectory.appendingPathComponent("subtitle-cache-quota-\(UUID())",
                                                                                 isDirectory: true)
    try! FileManager.default.createDirectory(at: quotaRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: quotaRoot) }
    let cap = 200
    let activeCache = BuiltinSubtitleCache(provider: "opensub", rootDirectory: quotaRoot,
                                           maximumAggregateBytes: cap)
    let activeURL = try! activeCache.store(Data(repeating: 1, count: 6), suggestedFileName: "active.srt",
                                           cancellation: .init())
    check(BuiltinSubtitleCache.leaseFiles([activeURL], rootDirectory: quotaRoot),
          "the selected subtitle is durably marked with the current process lease")
    try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-31 * 24 * 60 * 60)],
                                           ofItemAtPath: activeURL.deletingLastPathComponent().path)

    let oldDirectory = quotaRoot.appendingPathComponent("shooter-expired", isDirectory: true)
    try! FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
    try! Data(repeating: 2, count: 4).write(to: oldDirectory.appendingPathComponent("old.srt"))
    try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-31 * 24 * 60 * 60)],
                                           ofItemAtPath: oldDirectory.path)

    let nextCache = BuiltinSubtitleCache(provider: "subdl", rootDirectory: quotaRoot,
                                         maximumAggregateBytes: cap)
    let nextURL = try! nextCache.store(Data(repeating: 3, count: 6), suggestedFileName: "next.srt",
                                       cancellation: .init())
    check(BuiltinSubtitleCache.leaseFiles([nextURL], rootDirectory: quotaRoot),
          "the next selected subtitle receives a lease marker")
    check(FileManager.default.fileExists(atPath: activeURL.path) &&
          FileManager.default.fileExists(atPath: nextURL.path) &&
          !FileManager.default.fileExists(atPath: oldDirectory.path),
          "aggregate pruning removes an expired unleased cache while preserving selected subtitle files")
    let activeMarker = try! Data(contentsOf: activeURL.deletingLastPathComponent().appendingPathComponent(".lease"))
    let nextMarker = try! Data(contentsOf: nextURL.deletingLastPathComponent().appendingPathComponent(".lease"))
    check(activeMarker == nextMarker && String(data: activeMarker, encoding: .utf8)?.hasPrefix(".iina-lease-session-") == true,
          "all selected files share one process-session sentinel instead of retaining one fd per result")

    let overQuotaCache = BuiltinSubtitleCache(provider: "assrt", rootDirectory: quotaRoot,
                                              maximumAggregateBytes: cap)
    var quotaRejected = false
    do {
      _ = try overQuotaCache.store(Data(repeating: 4, count: 20),
                                   suggestedFileName: "over.srt", cancellation: .init())
    } catch BuiltinSubtitleCache.CacheError.aggregateLimitReached {
      quotaRejected = true
    } catch {}
    check(quotaRejected && FileManager.default.fileExists(atPath: activeURL.path) &&
          FileManager.default.fileExists(atPath: nextURL.path),
          "the aggregate cap rejects a new file rather than evicting directories leased by mpv")
    activeCache.discard()
    check(FileManager.default.fileExists(atPath: activeURL.path),
          "discarding a canceled result cannot unlink a subtitle directory already leased by the player")
    nextCache.discardFileIfUnleased(nextURL)
    nextCache.discard()
    check(FileManager.default.fileExists(atPath: nextURL.path),
          "cancel after handoff preserves the exact subtitle path leased by mpv")

    let repeatedRoot = FileManager.default.temporaryDirectory.appendingPathComponent("subtitle-cache-repeat-\(UUID())",
                                                                                   isDirectory: true)
    try! FileManager.default.createDirectory(at: repeatedRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: repeatedRoot) }
    let repeatedCache = BuiltinSubtitleCache(provider: "assrt", rootDirectory: repeatedRoot,
                                             maximumAggregateBytes: 75)
    let repeatedFirst = try! repeatedCache.store(Data(repeating: 5, count: 6),
                                                 suggestedFileName: "first.srt", cancellation: .init())
    var repeatedStoreRejected = false
    do {
      _ = try repeatedCache.store(Data(repeating: 6, count: 6),
                                 suggestedFileName: "second.srt", cancellation: .init())
    } catch BuiltinSubtitleCache.CacheError.aggregateLimitReached {
      repeatedStoreRejected = true
    } catch {}
    check(repeatedStoreRejected && FileManager.default.fileExists(atPath: repeatedFirst.path),
          "aggregate accounting includes files already stored in the current result directory")

    for file in [activeURL, nextURL] {
      try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-31 * 24 * 60 * 60)],
                                             ofItemAtPath: file.deletingLastPathComponent().path)
    }
    let activeSweepCount = BuiltinSubtitleCache.removeStaleEntries(in: quotaRoot)
    check(activeSweepCount == 0 && FileManager.default.fileExists(atPath: activeURL.path) &&
          FileManager.default.fileExists(atPath: nextURL.path),
          "startup cleanup preserves old directories whose shared session sentinel is still locked")

    let stale = root.appendingPathComponent("opensub-old", isDirectory: true)
    let fresh = root.appendingPathComponent("assrt-fresh", isDirectory: true)
    let unrelated = root.appendingPathComponent("unrelated-old", isDirectory: true)
    for directory in [stale, fresh, unrelated] {
      try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let now = Date()
    try! FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3 * 24 * 60 * 60)],
                                           ofItemAtPath: stale.path)
    try! FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: fresh.path)
    try! FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3 * 24 * 60 * 60)],
                                           ofItemAtPath: unrelated.path)
    let removed = BuiltinSubtitleCache.removeStaleEntries(in: root, olderThan: 24 * 60 * 60, now: now)
    check(removed == 1 && !FileManager.default.fileExists(atPath: stale.path) &&
          FileManager.default.fileExists(atPath: fresh.path) &&
          FileManager.default.fileExists(atPath: unrelated.path),
          "age-bounded cleanup deletes only stale owned provider directories")

    let tamperedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "subtitle-cache-tampered-\(UUID())", isDirectory: true)
    try! FileManager.default.createDirectory(at: tamperedRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tamperedRoot) }
    let validStaleDirectory = tamperedRoot.appendingPathComponent("opensub-valid-stale", isDirectory: true)
    let assrtFanoutDirectory = tamperedRoot.appendingPathComponent("assrt-twenty-files", isDirectory: true)
    let oversizedStaleDirectory = tamperedRoot.appendingPathComponent("shooter-too-many", isDirectory: true)
    let nestedStaleDirectory = tamperedRoot.appendingPathComponent("assrt-nested", isDirectory: true)
    let oversizedMarkerDirectory = tamperedRoot.appendingPathComponent("subdl-marker-too-large", isDirectory: true)
    for directory in [validStaleDirectory, assrtFanoutDirectory, oversizedStaleDirectory, nestedStaleDirectory,
                      oversizedMarkerDirectory] {
      try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    for index in 0..<20 {
      try! Data([UInt8(index & 0xff)]).write(
        to: assrtFanoutDirectory.appendingPathComponent("subtitle-\(index).srt"))
    }
    for index in 0...BuiltinSubtitleCache.maximumFilesPerEntryScanned {
      try! Data([UInt8(index & 0xff)]).write(
        to: oversizedStaleDirectory.appendingPathComponent("extra-\(index).bin"))
    }
    let childDirectory = nestedStaleDirectory.appendingPathComponent("nested", isDirectory: true)
    try! FileManager.default.createDirectory(at: childDirectory, withIntermediateDirectories: true)
    try! Data([1]).write(to: childDirectory.appendingPathComponent("nested.bin"))
    try! Data(repeating: 7, count: 4_096).write(to: oversizedMarkerDirectory.appendingPathComponent(".lease"))
    for directory in [validStaleDirectory, assrtFanoutDirectory, oversizedStaleDirectory, nestedStaleDirectory,
                      oversizedMarkerDirectory] {
      try! FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3 * 24 * 60 * 60)],
                                             ofItemAtPath: directory.path)
    }
    let tamperedRemoved = BuiltinSubtitleCache.removeStaleEntries(
      in: tamperedRoot, olderThan: 24 * 60 * 60, now: now)
    check(tamperedRemoved == 2 && !FileManager.default.fileExists(atPath: validStaleDirectory.path) &&
          !FileManager.default.fileExists(atPath: assrtFanoutDirectory.path) &&
          FileManager.default.fileExists(atPath: oversizedStaleDirectory.path) &&
          FileManager.default.fileExists(atPath: nestedStaleDirectory.path) &&
          FileManager.default.fileExists(atPath: oversizedMarkerDirectory.path),
          "stale cleanup removes only bounded flat entries and refuses oversized or nested cache contents")

    let crashedRoot = FileManager.default.temporaryDirectory.appendingPathComponent("subtitle-cache-crash-\(UUID())",
                                                                                   isDirectory: true)
    let crashedDirectory = crashedRoot.appendingPathComponent("opensub-crashed", isDirectory: true)
    let crashedSessionName = ".iina-lease-session-crashed"
    try! FileManager.default.createDirectory(at: crashedDirectory, withIntermediateDirectories: true)
    try! Data(crashedSessionName.utf8).write(to: crashedDirectory.appendingPathComponent(".lease"))
    try! Data().write(to: crashedRoot.appendingPathComponent(crashedSessionName))
    try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-31 * 24 * 60 * 60)],
                                           ofItemAtPath: crashedDirectory.path)
    let crashedRemoved = BuiltinSubtitleCache.removeStaleEntries(in: crashedRoot)
    check(crashedRemoved == 1 && !FileManager.default.fileExists(atPath: crashedDirectory.path) &&
          !FileManager.default.fileExists(atPath: crashedRoot.appendingPathComponent(crashedSessionName).path),
          "startup cleanup retires unheld session markers left by a crashed process")
    try? FileManager.default.removeItem(at: crashedRoot)

    let sharedRoot = FileManager.default.temporaryDirectory.appendingPathComponent("subtitle-cache-shared-\(UUID())",
                                                                                  isDirectory: true)
    let sharedCache = BuiltinSubtitleCache(provider: "opensub", rootDirectory: sharedRoot)
    let sharedURL = try! sharedCache.store(Data([1, 2, 3]), suggestedFileName: "shared.srt",
                                           cancellation: .init())
    let sharedSessionName = ".iina-lease-session-live"
    let sharedSessionURL = sharedRoot.appendingPathComponent(sharedSessionName)
    try! Data().write(to: sharedSessionURL)
    let sharedDescriptor = open(sharedSessionURL.path, O_RDWR)
    check(sharedDescriptor >= 0 && flock(sharedDescriptor, LOCK_EX | LOCK_NB) == 0,
          "a separate cache process can hold its root-level session sentinel")
    try! Data(sharedSessionName.utf8).write(to: sharedURL.deletingLastPathComponent().appendingPathComponent(".lease"))
    sharedCache.discardFileIfUnleased(sharedURL)
    sharedCache.discard()
    try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-31 * 24 * 60 * 60)],
                                           ofItemAtPath: sharedURL.deletingLastPathComponent().path)
    check(BuiltinSubtitleCache.removeStaleEntries(in: sharedRoot) == 0 &&
          FileManager.default.fileExists(atPath: sharedURL.path),
          "discard and stale sweep preserve a subtitle whose other-process sentinel is locked")
    _ = flock(sharedDescriptor, LOCK_UN)
    _ = close(sharedDescriptor)
    check(BuiltinSubtitleCache.removeStaleEntries(in: sharedRoot) == 1 &&
          !FileManager.default.fileExists(atPath: sharedURL.path) &&
          !FileManager.default.fileExists(atPath: sharedSessionURL.path),
          "stale cleanup removes the file after the owning process releases its sentinel")
    try? FileManager.default.removeItem(at: sharedRoot)

    var underQuotaCandidates = Array((0..<BuiltinSubtitleCache.maximumAggregateEntries).reversed())
    let originalUnderQuotaOrder = underQuotaCandidates
    var underQuotaComparisons = 0
    let underQuotaSorted = BuiltinSubtitleCache.sortEvictionCandidatesIfNeeded(
      &underQuotaCandidates, shouldPrune: false,
      by: { left, right in
        underQuotaComparisons += 1
        return left < right
      })
    check(!underQuotaSorted && underQuotaComparisons == 0 &&
          underQuotaCandidates == originalUnderQuotaOrder,
          "under-quota writes skip eviction sorting even with the maximum candidate count")

    var overQuotaCandidates = [3, 1, 2]
    var overQuotaComparisons = 0
    let overQuotaSorted = BuiltinSubtitleCache.sortEvictionCandidatesIfNeeded(
      &overQuotaCandidates, shouldPrune: true,
      by: { left, right in
        overQuotaComparisons += 1
        return left < right
      })
    check(overQuotaSorted && overQuotaComparisons > 0 && overQuotaCandidates == [1, 2, 3],
          "quota pressure still sorts eviction candidates into deterministic order")

    var generated = 0
    var nextCalls = 0
    var visited = 0
    let scanWasComplete = BuiltinSubtitleCache.visitBoundedEntries(
      maximumEntries: BuiltinSubtitleCache.maximumStartupCleanupEntries,
      next: {
        nextCalls += 1
        guard generated < 100_000 else { return nil }
        generated += 1
        return URL(fileURLWithPath: "/synthetic/cache-entry-\(generated)")
      },
      visit: { _ in visited += 1 }
    )
    check(!scanWasComplete && visited == BuiltinSubtitleCache.maximumStartupCleanupEntries &&
          nextCalls == BuiltinSubtitleCache.maximumStartupCleanupEntries + 1,
          "startup cleanup scan stops after its entry budget plus one truncation check")

    let fastRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "subtitle-cache-fast-inventory-\(UUID())", isDirectory: true)
    try! FileManager.default.createDirectory(at: fastRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fastRoot) }
    var inventoryScans = 0
    var inventoryVisits = 0
    BuiltinSubtitleCache.observeAggregateInventoryScansForTesting { scannedRoot, count in
      guard scannedRoot.standardizedFileURL == fastRoot.standardizedFileURL else { return }
      inventoryScans += 1
      inventoryVisits += count
    }
    var fastCaches: [BuiltinSubtitleCache] = []
    for index in 0..<128 {
      let cache = BuiltinSubtitleCache(provider: "opensub", rootDirectory: fastRoot)
      let file = try! cache.store(Data([UInt8(index & 0xff)]), suggestedFileName: "fast.srt",
                                  cancellation: .init())
      check(BuiltinSubtitleCache.leaseFiles([file], rootDirectory: fastRoot),
            "a completed fast-path cache write can be leased")
      fastCaches.append(cache)
    }
    BuiltinSubtitleCache.observeAggregateInventoryScansForTesting(nil)
    check(fastCaches.count == 128 && inventoryScans == 1 && inventoryVisits <= 2,
          "128 cache writes reconcile the root once and then update aggregate accounting incrementally")

    let reconciledRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "subtitle-cache-reconciled-size-\(UUID())", isDirectory: true)
    try! FileManager.default.createDirectory(at: reconciledRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: reconciledRoot) }
    let existingDirectory = reconciledRoot.appendingPathComponent("opensub-existing", isDirectory: true)
    try! FileManager.default.createDirectory(at: existingDirectory, withIntermediateDirectories: true)
    let existingFile = existingDirectory.appendingPathComponent("existing.srt")
    try! Data(repeating: 1, count: 10).write(to: existingFile)
    check(BuiltinSubtitleCache.leaseFiles([existingFile], rootDirectory: reconciledRoot),
          "seeded cache entry receives a process lease before inventory reconciliation")
    let exactlyFittingCache = BuiltinSubtitleCache(provider: "subdl", rootDirectory: reconciledRoot,
                                                   maximumAggregateBytes: 148)
    let exactlyFittingFile = try! exactlyFittingCache.store(Data(repeating: 2, count: 10),
                                                              suggestedFileName: "fitting.srt",
                                                              cancellation: .init())
    check(FileManager.default.fileExists(atPath: existingFile.path) &&
          FileManager.default.fileExists(atPath: exactlyFittingFile.path),
          "reconciled inventory counts the marker allowance once and preserves a leased entry at exact capacity")

    let crowdedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "subtitle-cache-count-cap-\(UUID())", isDirectory: true)
    try! FileManager.default.createDirectory(at: crowdedRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: crowdedRoot) }
    for index in 0..<(BuiltinSubtitleCache.maximumAggregateEntries + 3) {
      try! FileManager.default.createDirectory(
        at: crowdedRoot.appendingPathComponent("opensub-seed-\(index)", isDirectory: true),
        withIntermediateDirectories: false)
    }
    let crowdedCache = BuiltinSubtitleCache(provider: "opensub", rootDirectory: crowdedRoot)
    _ = try! crowdedCache.store(Data([1]), suggestedFileName: "last.srt", cancellation: .init())
    let crowdedEntryCount = (try! FileManager.default.contentsOfDirectory(atPath: crowdedRoot.path))
      .filter { $0.hasPrefix("opensub-") }.count
    check(crowdedEntryCount == BuiltinSubtitleCache.maximumAggregateEntries,
          "write-side accounting evicts only unleased entries to keep the aggregate entry count capped")
    crowdedCache.discard()

    print("\(checks) built-in subtitle HTTP/cache checks passed")
  }
}
