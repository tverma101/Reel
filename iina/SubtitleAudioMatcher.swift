import CryptoKit
import Dispatch
import Foundation
import PromiseKit
import whisper
#if canImport(Darwin)
import Darwin
#endif

private enum SubtitleModelTransferError: Error {
  case invalidResponse
  case responseTooLarge(maximumBytes: Int)
  case stagingFileBusy
  case unsafeStagingFile
}

/// Avoids beginning CPU-heavy work when cancellation lands while it is queued on a worker.
private func subtitleCancellableWork<Value>(isCancelled: () -> Bool,
                                             work: () throws -> Value) throws -> Value {
  guard !isCancelled() else { throw CancellationError() }
  return try work()
}

// Darwin also imports the `struct flock` type under this Swift name, so give the C function
// an unambiguous Swift identifier while keeping the system ABI call.
@_silgen_name("flock")
private func reelSubtitleModelFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// Gives each model one reusable private staging file. The advisory lock prevents a second Reel
/// process from truncating a transfer that is still in progress; a crash releases the lock and the
/// next attempt safely truncates the bounded partial file.
private final class SubtitleModelStagingLease {
  private let lockURL: URL
  private let outputURL: URL
  private let stateLock = NSLock()
  private var lockDescriptor: Int32 = -1

  init(outputURL: URL) {
    self.outputURL = outputURL
    lockURL = outputURL.deletingLastPathComponent()
      .appendingPathComponent(".\(outputURL.lastPathComponent).lock", isDirectory: false)
  }

  var isAcquired: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return lockDescriptor >= 0
  }

  func acquire() throws {
    stateLock.lock()
    let alreadyAcquired = lockDescriptor >= 0
    stateLock.unlock()
    if alreadyAcquired { return }

    let lockFD = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
                             mode_t(S_IRUSR | S_IWUSR))
    guard lockFD >= 0 else { throw CocoaError(.fileWriteUnknown) }
    var lockInfo = stat()
    var lockPathInfo = stat()
    guard Darwin.fstat(lockFD, &lockInfo) == 0,
          Darwin.lstat(lockURL.path, &lockPathInfo) == 0,
          lockInfo.st_dev == lockPathInfo.st_dev, lockInfo.st_ino == lockPathInfo.st_ino,
          lockInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
          lockInfo.st_uid == Darwin.geteuid(), lockInfo.st_nlink == 1,
          lockInfo.st_mode & mode_t(0o077) == 0 else {
      _ = Darwin.close(lockFD)
      throw SubtitleModelTransferError.unsafeStagingFile
    }
    guard reelSubtitleModelFlock(lockFD, Int32(LOCK_EX | LOCK_NB)) == 0 else {
      _ = Darwin.close(lockFD)
      throw SubtitleModelTransferError.stagingFileBusy
    }

    stateLock.lock()
    guard lockDescriptor < 0 else {
      stateLock.unlock()
      _ = reelSubtitleModelFlock(lockFD, Int32(LOCK_UN))
      _ = Darwin.close(lockFD)
      throw SubtitleModelTransferError.stagingFileBusy
    }
    lockDescriptor = lockFD
    stateLock.unlock()
  }

  func openForWriting() throws -> FileHandle {
    try acquire()
    let outputFD = Darwin.open(outputURL.path, O_CREAT | O_WRONLY | O_NOFOLLOW | O_CLOEXEC,
                               mode_t(S_IRUSR | S_IWUSR))
    guard outputFD >= 0 else {
      release()
      throw CocoaError(.fileWriteUnknown)
    }
    var outputInfo = stat()
    var pathInfo = stat()
    guard Darwin.fstat(outputFD, &outputInfo) == 0,
          Darwin.lstat(outputURL.path, &pathInfo) == 0,
          outputInfo.st_dev == pathInfo.st_dev, outputInfo.st_ino == pathInfo.st_ino,
          outputInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
          outputInfo.st_uid == Darwin.geteuid(), outputInfo.st_nlink == 1,
          Darwin.fchmod(outputFD, mode_t(S_IRUSR | S_IWUSR)) == 0,
          Darwin.ftruncate(outputFD, 0) == 0,
          Darwin.lseek(outputFD, 0, SEEK_SET) >= 0 else {
      _ = Darwin.close(outputFD)
      release()
      throw SubtitleModelTransferError.unsafeStagingFile
    }
    return FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
  }

  func discardOutputAndRelease() {
    guard isAcquired else { return }
    try? FileManager.default.removeItem(at: outputURL)
    release()
  }

  func release() {
    stateLock.lock()
    let descriptor = lockDescriptor
    lockDescriptor = -1
    stateLock.unlock()
    guard descriptor >= 0 else { return }
    _ = reelSubtitleModelFlock(descriptor, Int32(LOCK_UN))
    _ = Darwin.close(descriptor)
  }

  deinit { release() }
}

/// Rechecks the model only after acquiring its staging lock. Another search may have installed the
/// model after this caller's initial checksum check; in that case, discard any crash-left partial
/// and avoid a duplicate network transfer.
private func subtitleModelStagingLeaseNeedsTransfer(_ stagingLease: SubtitleModelStagingLease,
                                                    destination: URL,
                                                    expectedChecksum: String,
                                                    maximumBytes: Int,
                                                    isCancelled: () -> Bool) throws -> Bool {
  try stagingLease.acquire()
  guard !isCancelled() else {
    stagingLease.release()
    throw CancellationError()
  }
  if subtitleModelHasExpectedChecksum(destination, expected: expectedChecksum,
                                      maximumBytes: maximumBytes, isCancelled: isCancelled) {
    // A bounded crash-left partial is safe to keep; the next owner truncates it only after
    // acquiring the same lock. Avoid unlinking a path we did not open in this transfer.
    stagingLease.release()
    return false
  }
  guard !isCancelled() else {
    stagingLease.release()
    throw CancellationError()
  }
  return true
}

/// Streams a pinned model into its staging file and cancels before retaining more than the bound.
/// A URLSession download task would write an unbounded response to its temporary file first.
private final class BoundedSubtitleModelTransfer: NSObject, URLSessionDataDelegate {
  typealias Completion = (Swift.Result<URL, Error>) -> Void

  private let lock = NSLock()
  private let request: URLRequest
  private let outputURL: URL
  private let maximumBytes: Int
  private let cancellation: SubtitleAudioMatcher.Cancellation
  private let stagingLease: SubtitleModelStagingLease
  private let identifier: UUID
  private let configuration: URLSessionConfiguration
  private let completion: Completion
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var fileHandle: FileHandle?
  private var response: HTTPURLResponse?
  private var receivedBytes = 0
  private var failure: Error?
  private var finished = false

  init(request: URLRequest,
       outputURL: URL,
       maximumBytes: Int,
       cancellation: SubtitleAudioMatcher.Cancellation,
       stagingLease: SubtitleModelStagingLease? = nil,
       configuration: URLSessionConfiguration = .ephemeral,
       completion: @escaping Completion) {
    self.request = request
    self.outputURL = outputURL
    self.maximumBytes = maximumBytes
    self.cancellation = cancellation
    self.stagingLease = stagingLease ?? SubtitleModelStagingLease(outputURL: outputURL)
    self.configuration = configuration
    self.completion = completion
    identifier = UUID()
  }

  func start() {
    guard maximumBytes > 0, request.url?.scheme?.lowercased() == "https" else {
      finish(.failure(SubtitleModelTransferError.invalidResponse))
      return
    }
    do {
      try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                              withIntermediateDirectories: true)
      fileHandle = try stagingLease.openForWriting()
    } catch {
      finish(.failure(error))
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
    guard let httpResponse = response as? HTTPURLResponse else {
      lock.lock()
      failure = SubtitleModelTransferError.invalidResponse
      lock.unlock()
      completionHandler(.cancel)
      return
    }
    lock.lock()
    self.response = httpResponse
    if httpResponse.statusCode != 200 {
      failure = SubtitleModelTransferError.invalidResponse
    } else if response.expectedContentLength > Int64(maximumBytes) {
      failure = SubtitleModelTransferError.responseTooLarge(maximumBytes: maximumBytes)
    }
    let isFinished = finished
    let mayContinue = !isFinished && failure == nil
    lock.unlock()
    completionHandler(mayContinue ? .allow : .cancel)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    guard !finished, failure == nil else {
      lock.unlock()
      return
    }
    guard receivedBytes <= maximumBytes, data.count <= maximumBytes - receivedBytes else {
      failure = SubtitleModelTransferError.responseTooLarge(maximumBytes: maximumBytes)
      lock.unlock()
      dataTask.cancel()
      return
    }
    do {
      try fileHandle?.write(contentsOf: data)
      receivedBytes += data.count
      lock.unlock()
    } catch {
      failure = error
      lock.unlock()
      dataTask.cancel()
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
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
    } else if transferResponse?.statusCode == 200 {
      finish(.success(outputURL))
    } else {
      finish(.failure(SubtitleModelTransferError.invalidResponse))
    }
  }

  private func finish(_ result: Swift.Result<URL, Error>) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    finished = true
    let activeSession = session
    session = nil
    task = nil
    let handle = fileHandle
    fileHandle = nil
    var finalResult = result
    do {
      try handle?.close()
    } catch {
      if case .success = finalResult { finalResult = .failure(error) }
    }
    let shouldRemoveOutput: Bool
    if case .failure = finalResult { shouldRemoveOutput = true } else { shouldRemoveOutput = false }
    lock.unlock()

    cancellation.finish(identifier)
    if shouldRemoveOutput { stagingLease.discardOutputAndRelease() }
    switch finalResult {
    case .success:
      activeSession?.finishTasksAndInvalidate()
    case .failure:
      activeSession?.invalidateAndCancel()
    }
    completion(finalResult)
  }

  func releaseStagingFileLock() {
    stagingLease.release()
  }
}

/// Hashes in bounded chunks and checks cancellation before every read and before finalizing.
/// `chunkSize` is injectable so a focused test can exercise mid-hash cancellation on a small file.
private func subtitleModelHasExpectedChecksum(_ url: URL,
                                             expected: String,
                                             maximumBytes: Int = Int.max,
                                             chunkSize: Int = 1024 * 1024,
                                             isCancelled: () -> Bool) -> Bool {
  guard maximumBytes >= 0, chunkSize > 0,
        let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
        let fileSize = values.fileSize, fileSize >= 0, fileSize <= maximumBytes,
        let handle = try? FileHandle(forReadingFrom: url) else { return false }
  defer { try? handle.close() }
  var hasher = SHA256()
  var bytesRead = 0
  do {
    while true {
      guard !isCancelled() else { return false }
      guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { break }
      guard bytesRead <= maximumBytes, data.count <= maximumBytes - bytesRead else { return false }
      bytesRead += data.count
      hasher.update(data: data)
    }
  } catch {
    return false
  }
  guard !isCancelled() else { return false }
  let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
  return digest == expected
}

/// Promotes a fully verified staging file without creating a window where another process sees
/// the destination missing. POSIX rename replaces a destination symlink itself, not its target.
private func subtitleModelInstallStagingFile(_ stagingURL: URL, at destination: URL) throws {
  guard stagingURL.deletingLastPathComponent().standardizedFileURL ==
          destination.deletingLastPathComponent().standardizedFileURL,
        stagingURL != destination else {
    throw CocoaError(.fileWriteInvalidFileName)
  }
  let result = stagingURL.path.withCString { sourcePath in
    destination.path.withCString { destinationPath in
      Darwin.rename(sourcePath, destinationPath)
    }
  }
  guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
}

private func subtitleMatcherWhisperAbortCallback(_ userData: UnsafeMutableRawPointer?) -> Bool {
  guard let userData else { return false }
  return Unmanaged<SubtitleAudioMatcher.Cancellation>.fromOpaque(userData).takeUnretainedValue().isCancelled
}

enum SubtitleAudioMatchStatus: Equatable {
  case pending
  case timingMatch
  case timingOtherLanguage
  case dialogueMatch
  case possibleDialogueMatch
  case noDialogueMatch
  case differentLanguage
  case unverified

  var displayString: String {
    let key: String
    switch self {
    case .pending: key = "subtitle.audioMatch.pending"
    case .timingMatch: key = "subtitle.audioMatch.timing"
    case .timingOtherLanguage: key = "subtitle.audioMatch.timingOtherLanguage"
    case .dialogueMatch: key = "subtitle.audioMatch.dialogue"
    case .possibleDialogueMatch: key = "subtitle.audioMatch.possible"
    case .noDialogueMatch: key = "subtitle.audioMatch.noMatch"
    case .differentLanguage: key = "subtitle.audioMatch.otherLanguage"
    case .unverified: key = "subtitle.audioMatch.unverified"
    }
    return NSLocalizedString(key, comment: "Online subtitle audio-match status")
  }
}

/// Checks at most three OpenSubtitles candidates against a short excerpt decoded locally.
/// A hash plus speech/cue timing can establish synchronization, but only a same-language
/// Whisper text comparison can establish a dialogue match.
/// A fail-fast one-permit gate for heavyweight subtitle matching work. Admission happens before
/// downloads, parsing, decoding, and dispatch, so canceled/restarted searches cannot queue closures
/// retaining candidate cues and sampled audio behind synchronous model work.
final class SubtitleVADWorkGate: @unchecked Sendable {
  final class Permit: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private let releaseAction: () -> Void

    fileprivate init(releaseAction: @escaping () -> Void) {
      self.releaseAction = releaseAction
    }

    func release() {
      lock.lock()
      guard !released else {
        lock.unlock()
        return
      }
      released = true
      lock.unlock()
      releaseAction()
    }

    deinit { release() }
  }

  private let semaphore = DispatchSemaphore(value: 1)

  /// Returns immediately. Callers must do this before creating/dispatching work that captures
  /// subtitle candidates or audio samples; busy callers skip optional local audio matching.
  func tryAcquire() -> Permit? {
    guard semaphore.wait(timeout: .now()) == .success else { return nil }
    return Permit { [semaphore] in semaphore.signal() }
  }
}

enum SubtitleAudioMatcher {

  /// Bounds the entire optional local verification pipeline, including work that precedes VAD.
  /// A contending search keeps its results and falls back to an unverified status instead of
  /// retaining another parsed subtitle set/audio excerpt while the current search drains.
  private static let verificationWorkGate = SubtitleVADWorkGate()
  /// Defense in depth around the synchronous VAD API if a future caller bypasses `verify`.
  private static let vadWorkGate = SubtitleVADWorkGate()
  final class Cancellation {
    private let lock = NSLock()
    private var cancelled = false
    private var tasks: [UUID: URLSessionTask] = [:]
    private var cancellationHandlers: [UUID: () -> Void] = [:]

    var isCancelled: Bool {
      lock.lock()
      defer { lock.unlock() }
      return cancelled
    }

    func cancel() {
      lock.lock()
      cancelled = true
      let activeTasks = Array(tasks.values)
      let handlers = Array(cancellationHandlers.values)
      tasks.removeAll()
      cancellationHandlers.removeAll()
      lock.unlock()
      activeTasks.forEach { $0.cancel() }
      handlers.forEach { $0() }
    }

    func register(_ task: URLSessionTask, identifier: UUID) -> Bool {
      lock.lock()
      guard !cancelled else {
        lock.unlock()
        task.cancel()
        return false
      }
      tasks[identifier] = task
      lock.unlock()
      return true
    }

    func finish(_ identifier: UUID) {
      lock.lock()
      tasks.removeValue(forKey: identifier)
      lock.unlock()
    }

    /// Runs cache cleanup immediately on cancellation, including the narrow interval after a file
    /// request succeeds but before the search hands the completed paths to the player.
    @discardableResult
    func onCancel(_ handler: @escaping () -> Void) -> UUID? {
      lock.lock()
      guard !cancelled else {
        lock.unlock()
        handler()
        return nil
      }
      let identifier = UUID()
      cancellationHandlers[identifier] = handler
      lock.unlock()
      return identifier
    }

    /// Removes a cancellation callback after its associated work settles. If cancellation has
    /// already copied the callback for invocation, the work's own completion gate must tolerate
    /// that callback racing with normal completion.
    func removeCancellationHandler(_ identifier: UUID?) {
      guard let identifier else { return }
      lock.lock()
      cancellationHandlers.removeValue(forKey: identifier)
      lock.unlock()
    }
  }

  private struct Cue {
    let start: Double
    let end: Double
    let text: String
    let dialogueWordCount: Int

    init(start: Double, end: Double, text: String) {
      self.start = start
      self.end = end
      self.text = text
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty,
            !trimmed.hasPrefix("["), !trimmed.hasPrefix("("),
            !trimmed.hasPrefix("♪"), !trimmed.hasPrefix("♫") else {
        dialogueWordCount = 0
        return
      }
      dialogueWordCount = Self.wordCount(in: trimmed)
    }

    var isDialogue: Bool { dialogueWordCount >= 2 }

    private static func wordCount(in text: String) -> Int {
      var count = 0
      var insideWord = false
      for scalar in text.unicodeScalars {
        let category = scalar.properties.generalCategory
        let isWord = CharacterSet.alphanumerics.contains(scalar) ||
          category == .nonspacingMark || category == .spacingMark || category == .enclosingMark
        if isWord && !insideWord { count += 1 }
        insideWord = isWord
      }
      return count
    }
  }

  private struct Candidate {
    let subtitle: OpenSub.Subtitle
    let cues: [Cue]
  }

  private struct SamplePlan {
    let start: Double
    let duration: Double
    var end: Double { start + duration }
  }

  private struct SpeechSegment {
    let start: Double
    let end: Double
  }

  private struct VADAssessment {
    let timingMatches: Set<ObjectIdentifier>
  }

  private struct Transcript {
    let text: String
    let language: String?
  }

  /// Prefix sums let the excerpt planner score every candidate window in O(log n), even for a
  /// large or unusually dense subtitle file.
  private struct CueMetric {
    let time: Double
    let words: Int
  }

  private struct CueWindowIndex {
    let starts: [CueMetric]
    let ends: [CueMetric]
    private let startWordPrefix: [Int]
    private let endWordPrefix: [Int]

    init(cues: [Cue]) {
      let dialogue = cues.filter(\.isDialogue)
      let sortedStarts = dialogue.map { CueMetric(time: $0.start, words: $0.dialogueWordCount) }
        .sorted { $0.time < $1.time }
      let sortedEnds = dialogue.map { CueMetric(time: $0.end, words: $0.dialogueWordCount) }
        .sorted { $0.time < $1.time }
      starts = sortedStarts
      ends = sortedEnds
      startWordPrefix = Self.wordPrefix(for: sortedStarts)
      endWordPrefix = Self.wordPrefix(for: sortedEnds)
    }

    func overlaps(_ plan: SamplePlan) -> (cueCount: Int, wordCount: Int) {
      let started = prefixCount(in: starts, while: { $0 <= plan.end })
      let alreadyEnded = prefixCount(in: ends, while: { $0 < plan.start })
      return (started - alreadyEnded, startWordPrefix[started] - endWordPrefix[alreadyEnded])
    }

    private func prefixCount(in values: [CueMetric], while predicate: (Double) -> Bool) -> Int {
      var lower = 0
      var upper = values.count
      while lower < upper {
        let middle = lower + (upper - lower) / 2
        if predicate(values[middle].time) {
          lower = middle + 1
        } else {
          upper = middle
        }
      }
      return lower
    }

    private static func wordPrefix(for values: [CueMetric]) -> [Int] {
      var prefix = [0]
      prefix.reserveCapacity(values.count + 1)
      for value in values { prefix.append(prefix[prefix.count - 1] + value.words) }
      return prefix
    }
  }

  /// Answers whether any dialogue cue overlaps a VAD segment without rescanning every cue for
  /// each segment. The prefix maximum end preserves correctness for nested and overlapping cues.
  private struct CueTimingIndex {
    private let starts: [Double]
    private let maximumEndPrefix: [Double]

    init(cues: [Cue]) {
      let dialogue = cues.filter(\.isDialogue).sorted { $0.start < $1.start }
      starts = dialogue.map(\.start)

      var prefix: [Double] = []
      prefix.reserveCapacity(dialogue.count)
      var maximumEnd = -Double.infinity
      for cue in dialogue {
        maximumEnd = max(maximumEnd, cue.end)
        prefix.append(maximumEnd)
      }
      maximumEndPrefix = prefix
    }

    func overlaps(_ segment: SpeechSegment, planStart: Double) -> Bool {
      // Keep the same inclusive 700 ms tolerance and arithmetic ordering as the original scan.
      let latestCueStart = planStart + segment.end + 0.7
      let earliestCueEnd = planStart + segment.start
      var lower = 0
      var upper = starts.count
      while lower < upper {
        let middle = lower + (upper - lower) / 2
        if starts[middle] <= latestCueStart {
          lower = middle + 1
        } else {
          upper = middle
        }
      }
      return lower > 0 && maximumEndPrefix[lower - 1] + 0.7 >= earliestCueEnd
    }
  }

  private enum MatcherError: LocalizedError {
    case cancelled
    case noUsableAudio
    case modelLoadFailed
    case transcriptionFailed
    case badModelDownload

    var errorDescription: String? {
      switch self {
      case .cancelled: return "Subtitle search was cancelled"
      case .noUsableAudio: return "Could not decode an audio excerpt"
      case .modelLoadFailed: return "Could not load the local Whisper model"
      case .transcriptionFailed: return "Local Whisper did not return a transcript"
      case .badModelDownload: return "The local audio model failed its integrity check"
      }
    }
  }

  private static let sampleRate = 16_000
  private static let maxSubtitleBytes = 10 * 1024 * 1024
  private static let modelDirectory: URL = {
    let url = Utility.appSupportDirUrl.appendingPathComponent("SubtitleAudioModels", isDirectory: true)
    Utility.createDirIfNotExist(url: url)
    return url
  }()

  private static let vadModel = Model(
    name: "ggml-silero-v6.2.0.bin",
    url: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v6.2.0.bin")!,
    sha256: "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987",
    maximumBytes: 2 * 1024 * 1024
  )

  private static let whisperModel = Model(
    name: "ggml-base-q5_1.bin",
    url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/f281eb45af861ab5e5297d23694b7d46e090c02c/ggml-base-q5_1.bin")!,
    sha256: "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898",
    maximumBytes: 100 * 1024 * 1024
  )

  private struct Model {
    let name: String
    let url: URL
    let sha256: String
    let maximumBytes: Int
  }

  static func verify(mediaURL: URL,
                     mediaDuration: Double?,
                     candidates: [OpenSub.Subtitle],
                     cancellation: Cancellation) -> Promise<Void> {
    guard !cancellation.isCancelled else { return Promise(error: MatcherError.cancelled) }
    // Streaming media has no local audio excerpt to inspect. Return before downloadCandidates so
    // showing the chooser never spends OpenSubtitles quota merely to discover that fact later.
    guard mediaURL.isFileURL else {
      candidates.forEach { $0.audioMatchStatus = .unverified }
      return .value(())
    }
    guard let permit = verificationWorkGate.tryAcquire() else {
      guard !cancellation.isCancelled else { return Promise(error: MatcherError.cancelled) }
      candidates.forEach { $0.audioMatchStatus = .unverified }
      return .value(())
    }
    guard !cancellation.isCancelled else {
      permit.release()
      return Promise(error: MatcherError.cancelled)
    }
    let verification = downloadCandidates(candidates, index: 0, prepared: [], cancellation: cancellation).then { prepared -> Promise<Void> in
      guard !cancellation.isCancelled else { throw MatcherError.cancelled }
      let parsed = prepared.compactMap { item -> Candidate? in
        guard let url = item.fileURL, let cues = SubtitleCueParser.parse(fileURL: url), !cues.isEmpty else {
          item.subtitle.audioMatchStatus = .unverified
          return nil
        }
        return Candidate(subtitle: item.subtitle, cues: cues)
      }
      guard let plan = samplePlan(for: parsed, mediaDuration: mediaDuration), !parsed.isEmpty else {
        prepared.forEach { $0.subtitle.audioMatchStatus = .unverified }
        return .value(())
      }

      return onWorker {
        guard !cancellation.isCancelled,
              let data = FFmpegController.readMonoAudio(fromFile: mediaURL.path,
                                                       startTime: plan.start,
                                                       duration: plan.duration,
                                                       cancellationCheck: { cancellation.isCancelled }),
              !cancellation.isCancelled,
              data.count >= MemoryLayout<Float>.size * sampleRate * 2 else {
          throw cancellation.isCancelled ? MatcherError.cancelled : MatcherError.noUsableAudio
        }
        let samples = data.withUnsafeBytes { rawBuffer -> [Float] in
          Array(rawBuffer.bindMemory(to: Float.self))
        }
        return (parsed, plan, samples)
      }.then { parsed, plan, samples -> Promise<Void> in
        guard !cancellation.isCancelled else { throw MatcherError.cancelled }
        let assessmentPromise: Promise<VADAssessment>
        assessmentPromise = ensureModel(vadModel, cancellation: cancellation).then { vadURL -> Promise<VADAssessment> in
          guard !cancellation.isCancelled else { throw MatcherError.cancelled }
          // Do not queue work that retains `parsed` and `samples` behind a non-interruptible VAD
          // call. A contending verification still runs transcript matching below without timing
          // evidence, matching the existing VAD failure fallback.
          guard let permit = vadWorkGate.tryAcquire() else {
            return .value(VADAssessment(timingMatches: []))
          }
          return onWorker {
            defer { permit.release() }
            return try subtitleCancellableWork(isCancelled: { cancellation.isCancelled }) {
              assessTiming(candidates: parsed, plan: plan, samples: samples, vadModelURL: vadURL)
            }
          }
        }.recover { error -> Promise<VADAssessment> in
          if cancellation.isCancelled { throw MatcherError.cancelled }
          Logger.log("Local voice-activity check unavailable: \(error.localizedDescription)",
                     level: .warning, subsystem: Logger.Sub.opensub)
          return .value(VADAssessment(timingMatches: []))
        }
        return assessmentPromise.then { assessment -> Promise<Void> in
          guard !cancellation.isCancelled else { throw MatcherError.cancelled }
          for candidate in parsed where assessment.timingMatches.contains(ObjectIdentifier(candidate.subtitle)) {
            candidate.subtitle.audioMatchStatus = .timingMatch
          }
          return ensureModel(whisperModel, cancellation: cancellation).then { modelURL -> Promise<Void> in
            onWorker {
              guard !cancellation.isCancelled else { throw MatcherError.cancelled }
              let transcript = try transcribe(samples: samples, modelURL: modelURL, vadModelURL: nil,
                                              cancellation: cancellation)
              applyTranscript(transcript, candidates: parsed, plan: plan, timingMatches: assessment.timingMatches)
            }
          }.recover { error -> Promise<Void> in
            if case MatcherError.cancelled = error { throw error }
            Logger.log("Local Whisper check unavailable: \(error.localizedDescription)",
                       level: .warning, subsystem: Logger.Sub.opensub)
            for candidate in parsed where !assessment.timingMatches.contains(ObjectIdentifier(candidate.subtitle)) {
              candidate.subtitle.audioMatchStatus = .unverified
            }
            return .value(())
          }
        }
      }
    }
    return verification.ensure {
      permit.release()
    }
  }

  private struct DownloadedCandidate {
    let subtitle: OpenSub.Subtitle
    let fileURL: URL?
  }

  private static func downloadCandidates(_ candidates: [OpenSub.Subtitle],
                                         index: Int,
                                         prepared: [DownloadedCandidate],
                                         cancellation: Cancellation) -> Promise<[DownloadedCandidate]> {
    guard index < candidates.count else { return .value(prepared) }
    guard !cancellation.isCancelled else { return Promise(error: MatcherError.cancelled) }
    let subtitle = candidates[index]
    return subtitle.download(cancellation: cancellation).then { urls -> Promise<[DownloadedCandidate]> in
      var next = prepared
      next.append(DownloadedCandidate(subtitle: subtitle, fileURL: urls.first))
      return downloadCandidates(candidates, index: index + 1, prepared: next, cancellation: cancellation)
    }.recover { error -> Promise<[DownloadedCandidate]> in
      if cancellation.isCancelled { throw MatcherError.cancelled }
      subtitle.audioMatchStatus = .unverified
      Logger.log("Could not download candidate subtitle for local checking: \(error.localizedDescription)",
                 level: .warning, subsystem: Logger.Sub.opensub)
      return downloadCandidates(candidates, index: index + 1, prepared: prepared, cancellation: cancellation)
    }
  }

  private static func samplePlan(for candidates: [Candidate], mediaDuration: Double?) -> SamplePlan? {
    let mediaDuration = mediaDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    let starts = Set(candidates.flatMap { candidate in
      candidate.cues.filter { cue in
        guard cue.isDialogue else { return false }
        guard let mediaDuration else { return true }
        return cue.start < mediaDuration
      }.map { floor($0.start / 6) * 6 }
    }).sorted()
    guard !starts.isEmpty else { return nil }

    let indexes = candidates.map { CueWindowIndex(cues: $0.cues) }
    var best: (plan: SamplePlan, score: Int)?
    for start in starts {
      let duration = mediaDuration.map { min(12, $0 - start) } ?? 12
      guard duration >= 2 else { continue }
      let plan = SamplePlan(start: start, duration: duration)
      var candidatesWithDialogue = 0
      var cueCount = 0
      var wordCount = 0
      for index in indexes {
        let overlap = index.overlaps(plan)
        if overlap.cueCount > 0 { candidatesWithDialogue += 1 }
        cueCount += overlap.cueCount
        wordCount += overlap.wordCount
      }
      let score = candidatesWithDialogue * 1000 + min(cueCount, 30) * 20 + min(wordCount, 80) + (start >= 15 ? 2 : 0)
      if best == nil || score > best!.score || (score == best!.score && start < best!.plan.start) {
        best = (plan, score)
      }
    }
    return best?.plan
  }

  private static func assessTiming(candidates: [Candidate],
                                   plan: SamplePlan,
                                   samples: [Float],
                                   vadModelURL: URL) -> VADAssessment {
    guard let speech = detectSpeech(samples: samples, modelURL: vadModelURL), speech.count >= 2 else {
      return VADAssessment(timingMatches: [])
    }
    var matches = Set<ObjectIdentifier>()
    for candidate in candidates {
      let timingIndex = CueTimingIndex(cues: candidate.cues)
      let aligned = speech.reduce(into: 0) { count, segment in
        if timingIndex.overlaps(segment, planStart: plan.start) { count += 1 }
      }
      if aligned >= 2 && Double(aligned) / Double(speech.count) >= 0.75 {
        matches.insert(ObjectIdentifier(candidate.subtitle))
      }
    }
    return VADAssessment(timingMatches: matches)
  }

  private static func detectSpeech(samples: [Float], modelURL: URL) -> [SpeechSegment]? {
    var params = whisper_vad_default_context_params()
    params.n_threads = Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount)))
    params.use_gpu = false
    let context = modelURL.path.withCString {
      whisper_vad_init_from_file_with_params($0, params)
    }
    guard let context else { return nil }
    defer { whisper_vad_free(context) }

    var vadParams = whisper_vad_default_params()
    vadParams.min_speech_duration_ms = 250
    vadParams.min_silence_duration_ms = 100
    vadParams.speech_pad_ms = 120
    let segments = samples.withUnsafeBufferPointer { buffer in
      whisper_vad_segments_from_samples(context, vadParams, buffer.baseAddress, Int32(buffer.count))
    }
    guard let segments else { return nil }
    defer { whisper_vad_free_segments(segments) }
    let count = whisper_vad_segments_n_segments(segments)
    return (0..<count).compactMap { index in
      let start = whisper_vad_segments_get_segment_t0(segments, index)
      let end = whisper_vad_segments_get_segment_t1(segments, index)
      return end > start ? SpeechSegment(start: Double(start), end: Double(end)) : nil
    }
  }

  private static func transcribe(samples: [Float],
                                 modelURL: URL,
                                 vadModelURL: URL?,
                                 cancellation: Cancellation) throws -> Transcript {
    var contextParams = whisper_context_default_params()
    contextParams.use_gpu = true
    let context = modelURL.path.withCString { whisper_init_from_file_with_params($0, contextParams) }
    guard let context else { throw MatcherError.modelLoadFailed }
    defer { whisper_free(context) }
    guard !cancellation.isCancelled else { throw MatcherError.cancelled }

    var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
    params.n_threads = Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount)))
    params.no_context = true
    params.no_timestamps = true
    params.print_progress = false
    params.print_realtime = false
    params.print_timestamps = false
    params.print_special = false
    params.suppress_blank = true
    params.suppress_nst = true
    params.abort_callback = subtitleMatcherWhisperAbortCallback
    params.abort_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()

    let result: (String, String?) = "auto".withCString { language in
      params.language = language
      params.detect_language = true
      if let vadModelURL {
        return vadModelURL.path.withCString { vadPath in
          params.vad = true
          params.vad_model_path = vadPath
          return runTranscription(context: context, params: params, samples: samples)
        }
      }
      return runTranscription(context: context, params: params, samples: samples)
    }
    guard !cancellation.isCancelled else { throw MatcherError.cancelled }
    guard !result.0.isEmpty else { throw MatcherError.transcriptionFailed }
    return Transcript(text: result.0, language: result.1)
  }

  private static func runTranscription(context: OpaquePointer,
                                       params: whisper_full_params,
                                       samples: [Float]) -> (String, String?) {
    let result = samples.withUnsafeBufferPointer { buffer in
      whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
    }
    guard result == 0 else { return ("", nil) }
    let texts = (0..<whisper_full_n_segments(context)).compactMap { index -> String? in
      guard let pointer = whisper_full_get_segment_text(context, index) else { return nil }
      return String(cString: pointer)
    }
    let languageID = whisper_full_lang_id(context)
    let language = whisper_lang_str(languageID).map { String(cString: $0) }
    return (texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines), language)
  }

  private static func applyTranscript(_ transcript: Transcript,
                                     candidates: [Candidate],
                                     plan: SamplePlan,
                                     timingMatches: Set<ObjectIdentifier>) {
    let detectedLanguage = transcript.language.flatMap(whisperLanguageCode(for:))
    let transcriptTokens = normalizedTokens(transcript.text)
    for candidate in candidates {
      let identifier = ObjectIdentifier(candidate.subtitle)
      let hasTimingMatch = timingMatches.contains(identifier)
      guard let detectedLanguage,
            let subtitleLanguage = whisperLanguageCode(forOpenSubtitles: candidate.subtitle.subtitleLanguage) else {
        candidate.subtitle.audioMatchStatus = hasTimingMatch ? .timingMatch : .unverified
        continue
      }
      guard detectedLanguage == subtitleLanguage else {
        candidate.subtitle.audioMatchStatus = hasTimingMatch ? .timingOtherLanguage : .differentLanguage
        continue
      }
      let subtitleText = candidate.cues.filter {
        $0.isDialogue && $0.end >= plan.start - 0.8 && $0.start <= plan.end + 0.8
      }.map(\.text).joined(separator: " ")
      let subtitleTokens = normalizedTokens(subtitleText)
      guard transcriptTokens.count >= 5, subtitleTokens.count >= 5 else {
        candidate.subtitle.audioMatchStatus = hasTimingMatch ? .timingMatch : .unverified
        continue
      }
      let score = tokenF1(transcriptTokens, subtitleTokens)
      if score >= 0.60 {
        candidate.subtitle.audioMatchStatus = .dialogueMatch
      } else if score >= 0.35 {
        candidate.subtitle.audioMatchStatus = .possibleDialogueMatch
      } else {
        candidate.subtitle.audioMatchStatus = .noDialogueMatch
      }
    }
  }

  private static func whisperLanguageCode(forOpenSubtitles code: String) -> String? {
    let locale = Locale(identifier: code.trimmingCharacters(in: .whitespacesAndNewlines))
    let language: String
    if #available(macOS 13.0, *) {
      language = locale.language.languageCode?.identifier ?? ""
    } else {
      language = locale.languageCode ?? ""
    }
    return whisperLanguageCode(for: language)
  }

  private static func whisperLanguageCode(for code: String) -> String? {
    guard !code.isEmpty else { return nil }
    let identifier = code.withCString { whisper_lang_id($0) }
    guard identifier >= 0, let language = whisper_lang_str(identifier) else { return nil }
    return String(cString: language)
  }

  private static func normalizedTokens(_ text: String) -> [String] {
    let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                              locale: Locale(identifier: "en_US_POSIX"))
    var tokens: [String] = []
    var word = ""
    var unspacedRun: [Character] = []

    func flushWord() {
      if !word.isEmpty { tokens.append(word); word.removeAll(keepingCapacity: true) }
    }
    func flushUnspacedRun() {
      guard !unspacedRun.isEmpty else { return }
      if unspacedRun.count == 1 {
        tokens.append(String(unspacedRun[0]))
      } else {
        for index in 0..<(unspacedRun.count - 1) {
          tokens.append(String(unspacedRun[index...index + 1]))
        }
      }
      unspacedRun.removeAll(keepingCapacity: true)
    }

    for character in folded {
      if isUnspacedScriptCharacter(character) {
        flushWord()
        unspacedRun.append(character)
      } else if character.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) {
        flushUnspacedRun()
        word.append(character)
      } else {
        flushWord()
        flushUnspacedRun()
      }
    }
    flushWord()
    flushUnspacedRun()
    return tokens
  }

  private static func isUnspacedScriptCharacter(_ character: Character) -> Bool {
    guard let base = character.unicodeScalars.first else { return false }
    let value = base.value
    let isScriptScalar = (0x3400...0x4DBF).contains(value) ||
      (0x4E00...0x9FFF).contains(value) || (0xF900...0xFAFF).contains(value) ||
      (0x20000...0x3134F).contains(value) ||
      (0x3040...0x30FF).contains(value) || (0x31F0...0x31FF).contains(value) ||
      (0xFF66...0xFF9D).contains(value) ||
      (0x1100...0x11FF).contains(value) || (0x3130...0x318F).contains(value) ||
      (0xA960...0xA97F).contains(value) || (0xAC00...0xD7AF).contains(value) ||
      (0xD7B0...0xD7FF).contains(value) ||
      (0x0E00...0x0E7F).contains(value) || (0x0E80...0x0EFF).contains(value) ||
      (0x1000...0x109F).contains(value) || (0x1780...0x17FF).contains(value)
    guard isScriptScalar else { return false }
    return character.unicodeScalars.dropFirst().allSatisfy {
      let category = $0.properties.generalCategory
      return category == .nonspacingMark || category == .spacingMark || category == .enclosingMark
    }
  }

  private static func tokenF1(_ first: [String], _ second: [String]) -> Double {
    guard !first.isEmpty, !second.isEmpty else { return 0 }
    var counts: [String: Int] = [:]
    for token in first { counts[token, default: 0] += 1 }
    var overlap = 0
    for token in second {
      guard let count = counts[token], count > 0 else { continue }
      overlap += 1
      counts[token] = count - 1
    }
    return (2 * Double(overlap)) / Double(first.count + second.count)
  }

  private static func ensureModel(_ model: Model, cancellation: Cancellation) -> Promise<URL> {
    let destination = modelDirectory.appendingPathComponent(model.name, isDirectory: false)
    return onWorker {
      guard !cancellation.isCancelled else { throw MatcherError.cancelled }
      return hasExpectedChecksum(destination, expected: model.sha256, maximumBytes: model.maximumBytes,
                                 cancellation: cancellation)
    }.then { isValid -> Promise<URL> in
      guard !cancellation.isCancelled else { throw MatcherError.cancelled }
      if isValid { return .value(destination) }
      return download(model, to: destination, cancellation: cancellation)
    }
  }

  private static func download(_ model: Model, to destination: URL, cancellation: Cancellation) -> Promise<URL> {
    Promise { resolver in
      // A fixed per-model stage bounds crash leftovers to one maximum-sized partial file.
      // The lock lets the next attempt recover it without truncating another process's transfer.
      let stagingURL = destination.appendingPathExtension("download")
      let stagingLease = SubtitleModelStagingLease(outputURL: stagingURL)
      let request = URLRequest(url: model.url, cachePolicy: .reloadIgnoringLocalCacheData,
                               timeoutInterval: 300)
      let transfer = BoundedSubtitleModelTransfer(request: request,
                                                  outputURL: stagingURL,
                                                  maximumBytes: model.maximumBytes,
                                                  cancellation: cancellation,
                                                  stagingLease: stagingLease) { result in
        switch result {
        case .failure(let error):
          resolver.reject(cancellation.isCancelled ? MatcherError.cancelled : error)
        case .success:
          onWorker {
            defer {
              try? FileManager.default.removeItem(at: stagingURL)
              stagingLease.release()
            }
            guard !cancellation.isCancelled else { throw MatcherError.cancelled }
            guard hasExpectedChecksum(stagingURL, expected: model.sha256, maximumBytes: model.maximumBytes,
                                      cancellation: cancellation) else {
              if cancellation.isCancelled { throw MatcherError.cancelled }
              throw MatcherError.badModelDownload
            }
            guard !cancellation.isCancelled else { throw MatcherError.cancelled }
            do {
              try subtitleModelInstallStagingFile(stagingURL, at: destination)
            } catch {
              // A concurrent verification of the same model can have installed the destination first.
              // That file passes the same pinned checksum, so treat it as success instead of failing
              // the whole verification.
              guard !cancellation.isCancelled,
                    hasExpectedChecksum(destination, expected: model.sha256, maximumBytes: model.maximumBytes,
                                        cancellation: cancellation) else {
                if cancellation.isCancelled { throw MatcherError.cancelled }
                throw error
              }
            }
            return destination
          }.pipe { result in
            resolver.resolve(result)
          }
        }
      }
      // Recheck under the per-model lock so a delayed stale miss cannot download a model another
      // search has already installed. The lock stays held through the checksum and transfer.
      onWorker {
        try subtitleModelStagingLeaseNeedsTransfer(stagingLease,
                                                   destination: destination,
                                                   expectedChecksum: model.sha256,
                                                   maximumBytes: model.maximumBytes,
                                                   isCancelled: { cancellation.isCancelled })
      }.done { needsTransfer in
        if needsTransfer {
          // The data delegate registers the actual URLSession task and writes only bytes within the cap.
          transfer.start()
        } else {
          resolver.fulfill(destination)
        }
      }.catch { error in
        stagingLease.discardOutputAndRelease()
        resolver.reject(error)
      }
    }
  }

  private static func hasExpectedChecksum(_ url: URL, expected: String, maximumBytes: Int,
                                          cancellation: Cancellation) -> Bool {
    subtitleModelHasExpectedChecksum(url, expected: expected, maximumBytes: maximumBytes,
                                     isCancelled: { cancellation.isCancelled })
  }

  private static func onWorker<T>(_ work: @escaping () throws -> T) -> Promise<T> {
    Promise { resolver in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          resolver.fulfill(try work())
        } catch {
          resolver.reject(error)
        }
      }
    }
  }

  private enum SubtitleCueParser {
    private static let maximumSubtitleLines = 200_000
    private static let maximumWebVTTLineLength = 4_096
    private static let maximumWebVTTBlockLines = 32
    private static let maximumWebVTTBlockLength = 16_384
    private static let timingRegex = try! NSRegularExpression(
      pattern: #"(?m)(\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}|\d{1,2}:\d{2}[,.]\d{1,3})[ \t]*-->[ \t]*(\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}|\d{1,2}:\d{2}[,.]\d{1,3})"#
    )
    private static let htmlRegex = try! NSRegularExpression(pattern: #"<[^>]+>"#)
    private static let assTagRegex = try! NSRegularExpression(pattern: #"\{[^}]*\}"#)
    private static let numericLineRegex = try! NSRegularExpression(pattern: #"(?m)^\s*\d+\s*$"#)

    static func parse(fileURL: URL) -> [Cue]? {
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let size = attributes[.size] as? NSNumber,
            size.int64Value > 0, size.int64Value <= Int64(SubtitleAudioMatcher.maxSubtitleBytes),
            let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return nil }
      let text = String(data: data, encoding: .utf8)
        ?? String(data: data, encoding: .utf16)
        ?? String(data: data, encoding: .windowsCP1252)
        ?? String(data: data, encoding: .isoLatin1)
      guard let text else { return nil }
      let assCues = parseASS(text)
      if !assCues.isEmpty { return assCues }
      return parseTimedText(text)
    }

    private static func parseASS(_ text: String) -> [Cue] {
      var cues: [Cue] = []
      var lineCount = 0
      enumerateBoundedLines(in: text, maximumLength: 4_096) { boundedLine in
        lineCount += 1
        guard lineCount <= maximumSubtitleLines else {
          return false
        }
        guard let boundedLine, boundedLine.hasPrefix("Dialogue:") else { return true }
        let line = String(boundedLine)
        let fields = line.split(maxSplits: 9, omittingEmptySubsequences: false) { $0 == "," }
        guard fields.count == 10,
              let start = parseTime(String(fields[1])),
              let end = parseTime(String(fields[2])), end > start else { return true }
        let body = cleanText(String(fields[9]).replacingOccurrences(of: #"\\[Nn]"#, with: " ", options: .regularExpression))
        if !body.isEmpty { cues.append(Cue(start: start, end: end, text: body)) }
        return cues.count < 50_000
      }
      return cues
    }

    private static func parseTimedText(_ text: String) -> [Cue] {
      let text = text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
      let firstLineEnd = text.firstIndex(where: \.isNewline) ?? text.endIndex
      let firstLine = text[..<firstLineEnd]
      // Only the first line is needed to identify WebVTT. Avoid `String.split`, which eagerly
      // materializes every line of a newline-dense file before the parser's limits can apply.
      let header = String(firstLine.prefix(maximumWebVTTLineLength))
        .trimmingCharacters(in: .whitespaces)
      if header == "WEBVTT" || header.hasPrefix("WEBVTT ") || header.hasPrefix("WEBVTT\t") {
        return parseWebVTT(text)
      }

      let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
      var matches: [NSTextCheckingResult] = []
      timingRegex.enumerateMatches(in: text, range: fullRange) { match, _, stop in
        guard let match else { return }
        if matches.count >= 50_000 {
          // The cue-body limit below bounds the final cue even without a lookahead timestamp.
          stop.pointee = true
          return
        }
        matches.append(match)
      }
      guard !matches.isEmpty else { return [] }
      var cues: [Cue] = []
      for (index, match) in matches.prefix(50_000).enumerated() {
        guard let startRange = Range(match.range(at: 1), in: text),
              let endRange = Range(match.range(at: 2), in: text),
              let start = parseTime(String(text[startRange])),
              let end = parseTime(String(text[endRange])), end > start else { continue }
        let contentStart = match.range.location + match.range.length
        let nextStart = index + 1 < matches.count ? matches[index + 1].range.location : fullRange.length
        guard nextStart >= contentStart else { continue }
        let bodyLength = min(nextStart - contentStart, 4_096)
        let rawBody = (text as NSString).substring(with: NSRange(location: contentStart, length: bodyLength))
        let body = cleanText(rawBody)
        if !body.isEmpty { cues.append(Cue(start: start, end: end, text: body)) }
        if cues.count >= 50_000 { break }
      }
      return cues
    }

    private static func parseWebVTT(_ text: String) -> [Cue] {
      var cues: [Cue] = []
      cues.reserveCapacity(256)
      var block: [String] = []
      block.reserveCapacity(maximumWebVTTBlockLines)
      var blockLength = 0
      var discardingBlock = false
      var lineCount = 0

      func appendCue(from block: [String]) {
        guard cues.count < 50_000,
              let firstLine = block.first?.trimmingCharacters(in: .whitespaces),
              !firstLine.isEmpty,
              let timingIndex = block.firstIndex(where: { $0.contains("-->") }),
              timingIndex <= 1 else { return }
        if timingIndex == 0 {
          let isHeaderOrMetadata = firstLine == "WEBVTT" || firstLine.hasPrefix("WEBVTT ") ||
            firstLine.hasPrefix("WEBVTT\t") || firstLine == "NOTE" || firstLine.hasPrefix("NOTE ") ||
            firstLine == "STYLE" || firstLine == "REGION"
          if isHeaderOrMetadata { return }
        }
        let timingLine = block[timingIndex]
        let timingRange = NSRange(timingLine.startIndex..<timingLine.endIndex, in: timingLine)
        guard let match = timingRegex.firstMatch(in: timingLine, range: timingRange),
              let startRange = Range(match.range(at: 1), in: timingLine),
              let endRange = Range(match.range(at: 2), in: timingLine),
              let start = parseTime(String(timingLine[startRange])),
              let end = parseTime(String(timingLine[endRange])), end > start else { return }
        let rawBody = block.dropFirst(timingIndex + 1).joined(separator: " ")
        let bodyLength = min(rawBody.utf16.count, 4_096)
        let boundedBody = (rawBody as NSString).substring(to: bodyLength)
        let body = cleanText(boundedBody)
        if !body.isEmpty { cues.append(Cue(start: start, end: end, text: body)) }
      }

      enumerateBoundedLines(in: text, maximumLength: maximumWebVTTLineLength) { boundedLine in
        lineCount += 1
        guard lineCount <= maximumSubtitleLines, cues.count < 50_000 else {
          return false
        }
        guard let boundedLine else {
          block.removeAll(keepingCapacity: true)
          blockLength = 0
          discardingBlock = true
          return true
        }
        if boundedLine.trimmingCharacters(in: .whitespaces).isEmpty {
          if !discardingBlock { appendCue(from: block) }
          block.removeAll(keepingCapacity: true)
          blockLength = 0
          discardingBlock = false
        } else {
          guard !discardingBlock else { return true }
          let lineLength = boundedLine.utf16.count
          guard lineLength <= maximumWebVTTLineLength,
                block.count < maximumWebVTTBlockLines,
                blockLength <= maximumWebVTTBlockLength - lineLength else {
            block.removeAll(keepingCapacity: true)
            blockLength = 0
            discardingBlock = true
            return true
          }
          // The iterator only creates a slice after it has established that the line fits the
          // bound, so a single enormous subtitle line cannot cause a second enormous allocation.
          block.append(String(boundedLine))
          blockLength += lineLength
        }
        return true
      }
      if lineCount <= maximumSubtitleLines, cues.count < 50_000, !discardingBlock {
        appendCue(from: block)
      }
      return cues
    }

    /// Visits bounded line slices without first creating a `String` for an overlong line.
    /// Subtitle input is file-size capped, but a single newline-free 10 MiB line would otherwise
    /// still be copied before the parser could reject it.
    private static func enumerateBoundedLines(in text: String,
                                              maximumLength: Int,
                                              _ body: (Substring?) -> Bool) {
      let scalars = text.unicodeScalars
      var lineStart = text.startIndex
      var cursor = scalars.startIndex
      var lineLength = 0
      var lineIsTooLong = false

      func emitLine(endingAt end: String.Index, nextStart: String.Index) -> Bool {
        let line: Substring? = lineIsTooLong ? nil : text[lineStart..<end]
        guard body(line) else { return false }
        lineStart = nextStart
        lineLength = 0
        lineIsTooLong = false
        return true
      }

      while cursor < scalars.endIndex {
        let scalar = scalars[cursor]
        let scalarIndex = cursor
        let next = scalars.index(after: cursor)
        let value = scalar.value
        let isLineBreak = value == 0x0A || value == 0x0D || value == 0x85 || value == 0x2028 || value == 0x2029
        if isLineBreak {
          var nextStart = next
          // Treat CRLF as one delimiter, matching String.enumerateLines.
          if value == 0x0D, next < scalars.endIndex, scalars[next].value == 0x0A {
            nextStart = scalars.index(after: next)
          }
          guard emitLine(endingAt: scalarIndex, nextStart: nextStart) else { return }
          cursor = nextStart
          continue
        }

        if !lineIsTooLong {
          lineLength += value > 0xFFFF ? 2 : 1
          if lineLength > maximumLength { lineIsTooLong = true }
        }
        cursor = next
      }

      // Like enumerateLines, a terminating newline does not add a final empty line.
      if lineStart < text.endIndex {
        _ = body(lineIsTooLong ? nil : text[lineStart..<text.endIndex])
      }
    }

    private static func cleanText(_ text: String) -> String {
      let range = NSRange(text.startIndex..<text.endIndex, in: text)
      let withoutHTML = htmlRegex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
      let htmlRange = NSRange(withoutHTML.startIndex..<withoutHTML.endIndex, in: withoutHTML)
      let withoutASS = assTagRegex.stringByReplacingMatches(in: withoutHTML, range: htmlRange, withTemplate: " ")
      let assRange = NSRange(withoutASS.startIndex..<withoutASS.endIndex, in: withoutASS)
      let withoutIndices = numericLineRegex.stringByReplacingMatches(in: withoutASS, range: assRange, withTemplate: " ")
      return withoutIndices.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseTime(_ raw: String) -> Double? {
      let normalized = raw.replacingOccurrences(of: ",", with: ".")
      let parts = normalized.split(separator: ":", omittingEmptySubsequences: false)
      guard parts.count == 2 || parts.count == 3 else { return nil }
      let seconds = Double(parts.last ?? "")
      let minutes = Double(parts[parts.count - 2])
      guard let seconds, let minutes, seconds >= 0, minutes >= 0 else { return nil }
      if parts.count == 2 { return minutes * 60 + seconds }
      guard let hours = Double(parts[0]), hours >= 0 else { return nil }
      return hours * 3600 + minutes * 60 + seconds
    }
  }
}
