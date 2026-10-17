import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class SubtitleModelURLProtocol: URLProtocol {
  enum Plan {
    case response(status: Int, headers: [String: String], chunks: [Data])
    case openResponse
    case redirect(URL)
  }

  private static let lock = NSLock()
  private static var responder: ((URLRequest) -> Plan)!
  private static var startedHandler: (() -> Void)?
  private static var requestPaths: [String] = []
  private let stateLock = NSLock()
  private var cancelled = false

  static func configure(started: (() -> Void)? = nil, _ makePlan: @escaping (URLRequest) -> Plan) {
    lock.lock()
    responder = makePlan
    startedHandler = started
    requestPaths.removeAll()
    lock.unlock()
  }

  static var paths: [String] {
    lock.lock()
    defer { lock.unlock() }
    return requestPaths
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.lock()
    let makePlan = Self.responder
    let started = Self.startedHandler
    Self.requestPaths.append(request.url?.path ?? "")
    Self.lock.unlock()
    guard let makePlan else { return }

    switch makePlan(request) {
    case .response(let status, let headers, let chunks):
      sendResponse(status: status, headers: headers)
      for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
      client?.urlProtocolDidFinishLoading(self)
    case .openResponse:
      sendResponse(status: 200, headers: ["Content-Length": "16"])
      started?()
      // Leave the URLProtocol response open: URLSession keeps the data task active until canceled.
    case .redirect(let destination):
      guard let currentURL = request.url,
            let redirect = HTTPURLResponse(url: currentURL, statusCode: 302,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": destination.absoluteString]) else {
        client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        return
      }
      client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: redirect)
    }
  }

  override func stopLoading() {
    stateLock.lock()
    cancelled = true
    stateLock.unlock()
  }

  private func sendResponse(status: Int, headers: [String: String]) {
    guard let url = request.url,
          let response = HTTPURLResponse(url: url, statusCode: status,
                                         httpVersion: "HTTP/1.1", headerFields: headers) else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
  }
}

@main
struct BoundedSubtitleModelChecks {
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
    configuration.protocolClasses = [SubtitleModelURLProtocol.self]
    configuration.urlCache = nil
    return configuration
  }

  private static func execute(maximumBytes: Int,
                              path: String = "/model",
                              cancellation: SubtitleAudioMatcher.Cancellation = .init(),
                              outputURL: URL) -> Result<URL, Error> {
    let finished = DispatchSemaphore(value: 0)
    var result: Result<URL, Error>!
    let transfer = BoundedSubtitleModelTransfer(
      request: URLRequest(url: URL(string: "https://huggingface.test\(path)")!),
      outputURL: outputURL,
      maximumBytes: maximumBytes,
      cancellation: cancellation,
      configuration: configuration()
    ) {
      result = $0
      finished.signal()
    }
    transfer.start()
    guard finished.wait(timeout: .now() + 5) == .success else { fatalError("model transfer timed out") }
    transfer.releaseStagingFileLock()
    return result
  }

  static func main() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-transfer-check-\(UUID())",
                                                                            isDirectory: true)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    SubtitleModelURLProtocol.configure { _ in
      .response(status: 200, headers: ["Content-Type": "application/octet-stream"],
                chunks: [Data([1, 2]), Data([3, 4, 5])])
    }
    let underLimitURL = root.appendingPathComponent("under-limit.download")
    try! Data(repeating: 0xEE, count: 64).write(to: underLimitURL)
    let underLimit = execute(maximumBytes: 8, outputURL: underLimitURL)
    check((try? underLimit.get()) == underLimitURL &&
          (try? Data(contentsOf: underLimitURL)) == Data([1, 2, 3, 4, 5]),
          "an existing crash-left partial is truncated and replaced by a bounded response")

    SubtitleModelURLProtocol.configure { _ in
      .response(status: 200, headers: [:], chunks: [Data(repeating: 1, count: 6), Data(repeating: 2, count: 4)])
    }
    let chunkedURL = root.appendingPathComponent("chunked-over-limit.download")
    let chunked = execute(maximumBytes: 8, outputURL: chunkedURL)
    check((try? chunked.get()) == nil && !FileManager.default.fileExists(atPath: chunkedURL.path),
          "unknown-length chunked responses are stopped and partial staging files removed")

    SubtitleModelURLProtocol.configure { _ in
      .response(status: 200, headers: ["Content-Length": "1"], chunks: [Data(repeating: 3, count: 9)])
    }
    let dishonestURL = root.appendingPathComponent("dishonest-length.download")
    let dishonest = execute(maximumBytes: 8, outputURL: dishonestURL)
    check((try? dishonest.get()) == nil && !FileManager.default.fileExists(atPath: dishonestURL.path),
          "actual streamed bytes enforce the cap despite understated Content-Length")

    SubtitleModelURLProtocol.configure { _ in
      .response(status: 200, headers: ["Content-Length": "9"], chunks: [])
    }
    let declaredURL = root.appendingPathComponent("declared-over-limit.download")
    let declared = execute(maximumBytes: 8, outputURL: declaredURL)
    check((try? declared.get()) == nil && !FileManager.default.fileExists(atPath: declaredURL.path),
          "declared oversized responses are rejected and staging files removed before body delivery")

    let redirectURL = URL(string: "https://cdn.huggingface.test/final")!
    SubtitleModelURLProtocol.configure { request in
      request.url?.path == "/redirect"
        ? .redirect(redirectURL)
        : .response(status: 200, headers: [:], chunks: [Data([7])])
    }
    let redirectOutput = root.appendingPathComponent("redirect.download")
    let redirected = execute(maximumBytes: 8, path: "/redirect", outputURL: redirectOutput)
    check((try? redirected.get()) == redirectOutput && SubtitleModelURLProtocol.paths == ["/redirect", "/final"],
          "the bounded transfer preserves URLSession's ordinary redirect handling")

    let started = DispatchSemaphore(value: 0)
    SubtitleModelURLProtocol.configure(started: { started.signal() }) { _ in
      .openResponse
    }
    let cancelOutput = root.appendingPathComponent("cancelled.download")
    let cancellation = SubtitleAudioMatcher.Cancellation()
    let cancellationDone = DispatchSemaphore(value: 0)
    var cancellationResult: Result<URL, Error>!
    let transfer = BoundedSubtitleModelTransfer(
      request: URLRequest(url: URL(string: "https://huggingface.test/cancel")!),
      outputURL: cancelOutput,
      maximumBytes: 8,
      cancellation: cancellation,
      configuration: configuration()
    ) {
      cancellationResult = $0
      cancellationDone.signal()
    }
    transfer.start()
    let cancelBodyStarted = started.wait(timeout: .now() + 5) == .success
    check(cancelBodyStarted && FileManager.default.fileExists(atPath: cancelOutput.path),
          "a started model response holds its private staging file while awaiting more bytes")
    cancellation.cancel()
    check(cancellationDone.wait(timeout: .now() + 5) == .success &&
          (try? cancellationResult.get()) == nil && !FileManager.default.fileExists(atPath: cancelOutput.path),
          "cancellation stops the registered task and deletes its staging file")

    SubtitleModelURLProtocol.configure { _ in
      .response(status: 200, headers: [:], chunks: [Data([4, 5, 6])])
    }
    let sharedOutput = root.appendingPathComponent("one-model.download")
    let firstDone = DispatchSemaphore(value: 0)
    var firstResult: Result<URL, Error>!
    let firstTransfer = BoundedSubtitleModelTransfer(
      request: URLRequest(url: URL(string: "https://huggingface.test/first")!),
      outputURL: sharedOutput,
      maximumBytes: 16,
      cancellation: SubtitleAudioMatcher.Cancellation(),
      configuration: configuration()
    ) {
      firstResult = $0
      firstDone.signal()
    }
    firstTransfer.start()
    check(firstDone.wait(timeout: .now() + 5) == .success &&
          (try? firstResult.get()) == sharedOutput &&
          (try? Data(contentsOf: sharedOutput)) == Data([4, 5, 6]),
          "the completed transfer retains its per-model staging lease until checksum handoff")

    let secondDone = DispatchSemaphore(value: 0)
    var secondResult: Result<URL, Error>!
    let secondTransfer = BoundedSubtitleModelTransfer(
      request: URLRequest(url: URL(string: "https://huggingface.test/second")!),
      outputURL: sharedOutput,
      maximumBytes: 16,
      cancellation: SubtitleAudioMatcher.Cancellation(),
      configuration: configuration()
    ) {
      secondResult = $0
      secondDone.signal()
    }
    secondTransfer.start()
    check(secondDone.wait(timeout: .now() + 1) == .success &&
          (try? secondResult.get()) == nil && SubtitleModelURLProtocol.paths == ["/first"] &&
          (try? Data(contentsOf: sharedOutput)) == Data([4, 5, 6]),
          "a concurrent Reel process fails fast without truncating the staged model or starting network work")
    firstTransfer.releaseStagingFileLock()

    let installedModel = root.appendingPathComponent("installed-before-delayed-download.bin")
    let modelContents = Data([0x10, 0x20, 0x30, 0x40])
    try! modelContents.write(to: installedModel)
    let modelChecksum = SHA256.hash(data: modelContents).map { String(format: "%02x", $0) }.joined()
    let stalePartial = root.appendingPathComponent("installed-before-delayed-download.bin.download")
    let boundedCrashPartial = Data(repeating: 0xEE, count: 8)
    try! boundedCrashPartial.write(to: stalePartial)
    // Model the delayed continuation: its earlier miss has already happened, but another search
    // installs the verified model before this caller takes the staging lock.
    SubtitleModelURLProtocol.configure { _ in
      .response(status: 200, headers: [:], chunks: [Data([0xFF])])
    }
    let delayedLease = SubtitleModelStagingLease(outputURL: stalePartial)
    let delayedCheck = try! subtitleModelStagingLeaseNeedsTransfer(
      delayedLease,
      destination: installedModel,
      expectedChecksum: modelChecksum,
      maximumBytes: 16,
      isCancelled: { false }
    )
    check(!delayedCheck && SubtitleModelURLProtocol.paths.isEmpty &&
          (try? Data(contentsOf: stalePartial)) == boundedCrashPartial,
          "a delayed stale model miss rechecks under lock, preserves bounded crash data, and avoids another transfer")

    let protectedContents = Data([0xA1, 0xB2, 0xC3])
    let protectedFile = root.appendingPathComponent("protected.fixture")
    try! protectedContents.write(to: protectedFile)
    let symlinkOutput = root.appendingPathComponent("symlink.download")
    try! FileManager.default.createSymbolicLink(at: symlinkOutput, withDestinationURL: protectedFile)
    SubtitleModelURLProtocol.configure { _ in
      .response(status: 200, headers: [:], chunks: [Data([9])])
    }
    let symlinkResult = execute(maximumBytes: 8, outputURL: symlinkOutput)
    check((try? symlinkResult.get()) == nil && (try? Data(contentsOf: protectedFile)) == protectedContents,
          "a symlink staging target is rejected without changing its destination")

    let hardlinkOutput = root.appendingPathComponent("hardlink.download")
    try! FileManager.default.linkItem(at: protectedFile, to: hardlinkOutput)
    let hardlinkResult = execute(maximumBytes: 8, outputURL: hardlinkOutput)
    check((try? hardlinkResult.get()) == nil && (try? Data(contentsOf: protectedFile)) == protectedContents,
          "a hardlinked staging target is rejected without truncating the shared inode")

    let lockVictim = root.appendingPathComponent("lock-victim.fixture")
    try! protectedContents.write(to: lockVictim)
    let lockForSymlinkOutput = root.appendingPathComponent("lock-symlink.download")
    let lockPath = root.appendingPathComponent(".lock-symlink.download.lock")
    try! FileManager.default.createSymbolicLink(at: lockPath, withDestinationURL: lockVictim)
    let symlinkLockResult = execute(maximumBytes: 8, outputURL: lockForSymlinkOutput)
    check((try? symlinkLockResult.get()) == nil && (try? Data(contentsOf: lockVictim)) == protectedContents,
          "a symlink lock target is rejected without opening or changing its destination")

    let atomicDestination = root.appendingPathComponent("installed-model.bin")
    let atomicStage = root.appendingPathComponent("installed-model.bin.download")
    try! Data([1, 1, 1]).write(to: atomicDestination)
    try! Data([2, 2, 2]).write(to: atomicStage)
    try! subtitleModelInstallStagingFile(atomicStage, at: atomicDestination)
    check((try? Data(contentsOf: atomicDestination)) == Data([2, 2, 2]) &&
          !FileManager.default.fileExists(atPath: atomicStage.path),
          "verified model installation atomically replaces an existing model without a delete gap")

    let symlinkDestination = root.appendingPathComponent("symlink-model.bin")
    let symlinkStage = root.appendingPathComponent("symlink-model.bin.download")
    try! FileManager.default.createSymbolicLink(at: symlinkDestination, withDestinationURL: lockVictim)
    try! Data([3, 3, 3]).write(to: symlinkStage)
    try! subtitleModelInstallStagingFile(symlinkStage, at: symlinkDestination)
    let replacedPathIsSymlink = (try? symlinkDestination.resourceValues(forKeys: [.isSymbolicLinkKey])
      .isSymbolicLink) ?? true
    check(FileManager.default.fileExists(atPath: symlinkDestination.path) && !replacedPathIsSymlink,
          "model installation replaces a destination symlink rather than following it")
    check((try? Data(contentsOf: lockVictim)) == protectedContents &&
          (try? Data(contentsOf: symlinkDestination)) == Data([3, 3, 3]),
          "atomic model replacement leaves the former symlink target untouched")

    let directoryDestination = root.appendingPathComponent("model-directory", isDirectory: true)
    let failedStage = root.appendingPathComponent("model-directory.download")
    try! FileManager.default.createDirectory(at: directoryDestination, withIntermediateDirectories: false)
    try! Data([7, 7]).write(to: failedStage)
    do {
      try subtitleModelInstallStagingFile(failedStage, at: directoryDestination)
      check(false, "a directory destination must reject model installation")
    } catch {
      check(FileManager.default.fileExists(atPath: failedStage.path) &&
            FileManager.default.fileExists(atPath: directoryDestination.path),
            "failed atomic installation preserves the staging data for bounded cleanup and the destination")
    }

    let hashURL = root.appendingPathComponent("hash-cancel.fixture")
    let hashData = Data(repeating: 0xA5, count: 4 * 1024 * 1024)
    try! hashData.write(to: hashURL)
    let expectedHash = SHA256.hash(data: hashData).map { String(format: "%02x", $0) }.joined()
    var cancellationPolls = 0
    let cancelledHash = subtitleModelHasExpectedChecksum(hashURL, expected: expectedHash, chunkSize: 1024) {
      cancellationPolls += 1
      return cancellationPolls > 5
    }
    check(!cancelledHash && cancellationPolls == 6,
          "checksum streaming exits when canceled mid-hash instead of reading to EOF")
    check(subtitleModelHasExpectedChecksum(hashURL, expected: expectedHash, isCancelled: { false }),
          "the bounded streaming hasher accepts the complete pinned model checksum")

    var cancelledWorkBegan = false
    let cancelledWorker = try? subtitleCancellableWork(isCancelled: { true }) {
      cancelledWorkBegan = true
      return true
    }
    check(cancelledWorker == nil && !cancelledWorkBegan,
          "a worker canceled while queued exits before beginning CPU-heavy analysis")

    print("\(checks) bounded subtitle-model checks passed")
  }
}
