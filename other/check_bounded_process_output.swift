import Foundation

@main
struct BoundedProcessOutputChecks {
  static func main() throws {
    if CommandLine.arguments.contains("--synthetic-lifecycle-only") {
      try checkConcurrentProcessLifecycles()
      try checkStuckHookTimeoutSemantics()
      try checkCallbackBatchFairness()
      checkProcessExecutionAdmissionBound()
      try checkTimedChildProcessIsTerminated()
      try checkTimeoutRejectsBeforeSuccessfulTermination()
      try checkExitedChildDoesNotBecomeTimeout()
      checkCancelledTimeoutReleasesCaptures()
      print("bounded process lifecycle checks passed")
      return
    }
    if CommandLine.arguments.contains("--large-output-child") {
      exit(writeLargeChildOutput())
    }
    if CommandLine.arguments.contains("--pipe-drain-only") {
      try checkPipeDrainsWhileHookBlocks()
      print("blocked-hook pipe drain check passed")
      return
    }

    let decoder = IncrementalProcessOutputDecoder()
    let encoded = Data("字幕🎬 ready".utf8)
    var decoded = ""
    for byte in encoded {
      decoded += decoder.append(Data([byte]))
    }
    decoded += decoder.finish()
    precondition(decoded == "字幕🎬 ready")
    let splitDecoder = IncrementalProcessOutputDecoder()
    let first = Data("caption 🎬".utf8)
    let split = first.count - 2
    let prefix = splitDecoder.append(Data(first.prefix(split)))
    let suffix = splitDecoder.append(Data(first.dropFirst(split)))
    precondition(prefix + suffix + splitDecoder.finish() == "caption 🎬")

    let output = BoundedProcessOutput(maximumBytes: 8)
    output.append(Data("abcdef".utf8))
    output.append(Data("ghijkl".utf8))
    precondition(output.text == "abcdefgh\n[plugin process output truncated after 8 bytes]")

    let utf8Boundary = BoundedProcessOutput(maximumBytes: 4)
    utf8Boundary.append(Data("A🎬B".utf8))
    precondition(utf8Boundary.text == "A\n[plugin process output truncated after 4 bytes]")

    let empty = BoundedProcessOutput(maximumBytes: 0)
    empty.append(Data("discard".utf8))
    precondition(empty.text == "\n[plugin process output truncated after 0 bytes]")

    let concurrent = BoundedProcessOutput(maximumBytes: 128)
    DispatchQueue.concurrentPerform(iterations: 32) { _ in
      concurrent.append(Data(repeating: 0x78, count: 1_024))
    }
    precondition(concurrent.text.count == 128 + "\n[plugin process output truncated after 128 bytes]".count)
    precondition(concurrent.text.hasSuffix("[plugin process output truncated after 128 bytes]"))

    try checkSlowEOFTailHookBarrier()
    try checkBlockedHookDoesNotBlockStop()
    try checkTimedOutDrainSuppressesQueuedHook()
    try checkHeldOpenPipeStop()
    try checkSmallOrderedCallbacks()
    try checkPipeDrainsWhileHookBlocks()
    try checkLargeImmediateProcessOutput()
    print("bounded process output checks passed")
  }

  private static func checkConcurrentProcessLifecycles() throws {
    let firstWaitEntered = DispatchSemaphore(value: 0)
    let releaseFirstWait = DispatchSemaphore(value: 0)
    let firstFinished = DispatchSemaphore(value: 0)
    let secondFinished = DispatchSemaphore(value: 0)

    PluginProcessExecutionQueues.processWait.async {
      firstWaitEntered.signal()
      _ = releaseFirstWait.wait(timeout: .now() + .seconds(3))
      firstFinished.signal()
    }
    precondition(firstWaitEntered.wait(timeout: .now() + .seconds(2)) == .success)

    PluginProcessExecutionQueues.processWait.async {
      secondFinished.signal()
    }
    let secondFinishedBeforeFirst = secondFinished.wait(timeout: .now() + .seconds(1)) == .success
    releaseFirstWait.signal()
    let firstEventuallyFinished = firstFinished.wait(timeout: .now() + .seconds(2)) == .success

    precondition(secondFinishedBeforeFirst,
                 "a blocked process lifecycle prevented another lifecycle from completing")
    precondition(firstEventuallyFinished)
  }

  private static func checkStuckHookTimeoutSemantics() throws {
    let callbackQueue = DispatchQueue(label: "bounded-process-output-synthetic-hook-check")
    let completionGroup = DispatchGroup()
    let hookEntered = DispatchSemaphore(value: 0)
    let releaseHook = DispatchSemaphore(value: 0)
    let deliveredLock = NSLock()
    var delivered: [String] = []
    let delivery = ProcessOutputCallbackDelivery(
      completionGroup: completionGroup,
      callbackQueue: callbackQueue) { output in
        deliveredLock.lock()
        delivered.append(output)
        deliveredLock.unlock()
        hookEntered.signal()
        _ = releaseHook.wait(timeout: .now() + .seconds(3))
      }

    delivery.start()
    delivery.enqueue("admitted")
    precondition(hookEntered.wait(timeout: .now() + .seconds(2)) == .success)
    delivery.enqueue("queued and suppressed")
    delivery.finishInput()
    precondition(completionGroup.wait(timeout: .now()) == .timedOut,
                 "normal completion should wait for a pending admitted callback")

    delivery.suppressPendingCallbacks()
    let completedWhileHookBlocked = completionGroup.wait(timeout: .now() + .seconds(1)) == .success
    releaseHook.signal()
    callbackQueue.sync {}

    deliveredLock.lock()
    let outputs = delivered
    deliveredLock.unlock()
    precondition(completedWhileHookBlocked,
                 "timeout suppression should release process completion while a hook is active")
    precondition(outputs == ["admitted"], "timeout suppression delivered queued callback work")
  }

  private static func checkCallbackBatchFairness() throws {
    let callbackQueue = DispatchQueue(label: "bounded-process-output-batch-fairness-check")
    let callbackQueueStarted = DispatchSemaphore(value: 0)
    let releaseCallbackQueue = DispatchSemaphore(value: 0)
    callbackQueue.async {
      callbackQueueStarted.signal()
      _ = releaseCallbackQueue.wait(timeout: .now() + .seconds(3))
    }
    precondition(callbackQueueStarted.wait(timeout: .now() + .seconds(2)) == .success)

    let completionGroup = DispatchGroup()
    let markerReached = DispatchSemaphore(value: 0)
    let deliveredLock = NSLock()
    var delivered: [String] = []
    var interleavedCount: Int?
    let delivery = ProcessOutputCallbackDelivery(
      completionGroup: completionGroup,
      callbackQueue: callbackQueue) { output in
        deliveredLock.lock()
        delivered.append(output)
        let count = delivered.count
        deliveredLock.unlock()
        if count == ProcessOutputCallbackDelivery.maximumCallbacksPerDrainBatch {
          // This task is queued from inside the final callback in a batch.
          // The next drain must yield behind it on the serial callback queue.
          callbackQueue.async {
            deliveredLock.lock()
            interleavedCount = delivered.count
            deliveredLock.unlock()
            markerReached.signal()
          }
        }
      }

    delivery.start()
    let outputs = (0..<(ProcessOutputCallbackDelivery.maximumCallbacksPerDrainBatch + 1))
      .map { "output-\($0)" }
    outputs.forEach(delivery.enqueue)
    delivery.finishInput()
    // Keep the serial queue blocked until every item is enqueued, so the first
    // drain starts with a full batch and this fairness assertion is deterministic.
    releaseCallbackQueue.signal()

    let interleaved = markerReached.wait(timeout: .now() + .seconds(2)) == .success
    let completed = completionGroup.wait(timeout: .now() + .seconds(2)) == .success
    deliveredLock.lock()
    let deliveredSnapshot = delivered
    let interleavedCountSnapshot = interleavedCount
    deliveredLock.unlock()
    precondition(interleaved, "an unrelated callback-queue task did not run between batches")
    precondition(interleavedCountSnapshot == ProcessOutputCallbackDelivery.maximumCallbacksPerDrainBatch,
                 "callback draining did not yield at the configured batch boundary")
    precondition(completed, "yielding delayed or lost callback completion")
    precondition(deliveredSnapshot == outputs, "yielding changed FIFO callback order")
  }

  private static func checkProcessExecutionAdmissionBound() {
    precondition(BoundedProcessExecutionAdmission.shared.maximumTotalActiveControlExecutions >=
                 BoundedProcessExecutionAdmission.shared.maximumTotalActiveExecutions &&
                 BoundedProcessExecutionAdmission.shared.maximumActiveControlExecutionsPerPlugin >=
                 BoundedProcessExecutionAdmission.shared.maximumTotalActiveExecutions,
                 "production lifecycle-control capacity must cover the global bounded fan-out")
    let admission = BoundedProcessExecutionAdmission(
      maximumTotalActiveExecutions: 4,
      maximumActiveExecutionsPerPlugin: 2,
      maximumTotalActiveControlExecutions: 4,
      maximumActiveControlExecutionsPerPlugin: 4)
    let airPlayServePermits = [
      admission.acquire(forPluginIdentifier: "dev.faruk.iina-airplay")!,
      admission.acquire(forPluginIdentifier: "dev.faruk.iina-airplay")!
    ]
    precondition(admission.acquire(forPluginIdentifier: "dev.faruk.iina-airplay") == nil,
                 "per-plugin admission exceeded its limit")

    let otherPluginPermits = [
      admission.acquire(forPluginIdentifier: "other-plugin")!,
      admission.acquire(forPluginIdentifier: "other-plugin")!
    ]
    precondition(admission.acquire(forPluginIdentifier: "third-plugin") == nil,
                 "global admission exceeded its limit")

    let airPlayStopPermits = (0..<4).map { _ in
      admission.acquireLifecycleControl(forPluginIdentifier: "dev.faruk.iina-airplay")!
    }
    precondition(admission.acquireLifecycleControl(forPluginIdentifier: "dev.faruk.iina-airplay") == nil,
                 "AirPlay stop admission exceeded its reserved bound")
    precondition(admission.acquireLifecycleControl(forPluginIdentifier: "other-plugin") == nil,
                 "reserved control admission exceeded its global bound")
    airPlayStopPermits[0].release()
    let replacementStop = admission.acquireLifecycleControl(forPluginIdentifier: "dev.faruk.iina-airplay")
    precondition(replacementStop != nil, "a released AirPlay stop slot was not reusable")
    replacementStop?.release()
    airPlayStopPermits.dropFirst().forEach { $0.release() }

    airPlayServePermits.forEach { $0.release() }
    let replacement = admission.acquire(forPluginIdentifier: "third-plugin")
    precondition(replacement != nil, "a released plugin slot was not reusable")
    otherPluginPermits.forEach { $0.release() }
    replacement?.release()
    let idleProbe = admission.acquire(forPluginIdentifier: "idle-probe")
    precondition(idleProbe != nil, "admission did not return to idle")
    idleProbe?.release()
  }

  private static func checkTimedChildProcessIsTerminated() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["10"]
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    try process.run()

    let timedOut = DispatchSemaphore(value: 0)
    let timeout = BoundedProcessTimeout.schedule(
      for: process,
      after: 0.05,
      terminationGrace: 0.05) {
        timedOut.signal()
      }
    let timeoutSignaled = timedOut.wait(timeout: .now() + .seconds(2)) == .success
    timeout.cancel()
    let processExited = exited.wait(timeout: .now() + .seconds(2)) == .success
    precondition(timeoutSignaled, "timed child did not report expiration")
    precondition(processExited && !process.isRunning,
                 "timed child remained alive after timeout termination")
  }

  private static func checkTimeoutRejectsBeforeSuccessfulTermination() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "trap 'exit 0' TERM; while :; do :; done"]
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    try process.run()

    let timeoutCalled = DispatchSemaphore(value: 0)
    let processWasAliveAtTimeout = NSLock()
    var wasAliveAtTimeout = false
    let timeout = BoundedProcessTimeout.schedule(for: process, after: 0.05) {
      processWasAliveAtTimeout.lock()
      wasAliveAtTimeout = process.isRunning
      processWasAliveAtTimeout.unlock()
      timeoutCalled.signal()
    }
    let timeoutSignaled = timeoutCalled.wait(timeout: .now() + .seconds(2)) == .success
    let processExited = exited.wait(timeout: .now() + .seconds(2)) == .success
    timeout.cancel()
    process.waitUntilExit()
    processWasAliveAtTimeout.lock()
    let wasAlive = wasAliveAtTimeout
    processWasAliveAtTimeout.unlock()
    precondition(timeoutSignaled && processExited, "timed process lifecycle did not finish")
    precondition(wasAlive, "timeout callback must win before TERM reaches the child")
    precondition(process.terminationStatus == 0,
                 "test child should exit successfully on TERM to exercise the Promise race")
  }

  private static func checkExitedChildDoesNotBecomeTimeout() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try process.run()
    process.waitUntilExit()
    precondition(process.terminationStatus == 0)

    let timedOut = DispatchSemaphore(value: 0)
    let timeout = BoundedProcessTimeout.schedule(for: process, after: 0.05) {
      timedOut.signal()
    }
    let incorrectlyTimedOut = timedOut.wait(timeout: .now() + .milliseconds(150)) == .success
    timeout.cancel()
    precondition(!incorrectlyTimedOut,
                 "a timeout callback scheduled after process exit must not reject a timely result")
  }

  private static func checkCancelledTimeoutReleasesCaptures() {
    final class Probe {}
    final class WeakBox<T: AnyObject> {
      weak var value: T?
      init(_ value: T) { self.value = value }
    }

    func scheduleAndCancel() -> (WeakBox<Process>, WeakBox<Probe>) {
      let process = Process()
      let probe = Probe()
      let processBox = WeakBox(process)
      let probeBox = WeakBox(probe)
      let timeout = BoundedProcessTimeout.schedule(for: process, after: 86_400) { [probe] in
        _ = probe
      }
      timeout.cancel()
      return (processBox, probeBox)
    }

    let (processBox, probeBox) = scheduleAndCancel()
    precondition(processBox.value == nil,
                 "a canceled day-long timeout does not retain a completed process")
    precondition(probeBox.value == nil,
                 "a canceled day-long timeout drops its callback captures immediately")
  }

  private static func writeLargeChildOutput() -> Int32 {
    let stdout = Data(repeating: 0x6F, count: 1_500_000) + Data("🎬 end\n".utf8)
    let stderr = Data(repeating: 0x65, count: 1_250_000) + Data("字幕 end\n".utf8)
    let errorsLock = NSLock()
    var writeFailed = false

    DispatchQueue.concurrentPerform(iterations: 2) { stream in
      do {
        try (stream == 0 ? FileHandle.standardOutput : FileHandle.standardError).write(
          contentsOf: stream == 0 ? stdout : stderr)
      } catch {
        errorsLock.lock()
        writeFailed = true
        errorsLock.unlock()
      }
    }
    return writeFailed ? 1 : 0
  }

  private static func checkPipeDrainsWhileHookBlocks() throws {
    let pipe = Pipe()
    let completionGroup = DispatchGroup()
    let callbackQueue = DispatchQueue(label: "bounded-process-output-blocked-child-hook-check")
    let callbackEntered = DispatchSemaphore(value: 0)
    let releaseCallback = DispatchSemaphore(value: 0)
    let callbackLock = NSLock()
    var callbackCount = 0
    let reader = ProcessOutputStreamReader(
      fileHandle: pipe.fileHandleForReading,
      completionGroup: completionGroup,
      callbackQueue: callbackQueue) { _ in
        callbackLock.lock()
        callbackCount += 1
        let shouldBlock = callbackCount == 1
        callbackLock.unlock()
        if shouldBlock {
          callbackEntered.signal()
          _ = releaseCallback.wait(timeout: .now() + .seconds(12))
        }
      }
    let writerFinished = DispatchSemaphore(value: 0)
    let writeFailed = NSLock()
    var writerError: Error?

    reader.start()
    DispatchQueue.global().async {
      do {
        try pipe.fileHandleForWriting.write(contentsOf:
          Data(repeating: 0x71, count: 1_500_000) + Data("writer finished\n".utf8))
      } catch {
        writeFailed.lock()
        writerError = error
        writeFailed.unlock()
      }
      pipe.fileHandleForWriting.closeFile()
      writerFinished.signal()
    }

    let hookStarted = callbackEntered.wait(timeout: .now() + .seconds(2)) == .success
    // A write larger than the kernel pipe buffer must complete while the live
    // callback is blocked. This is the same backpressure deadlock that would
    // keep a child alive inside Process.waitUntilExit().
    let writerFinishedBeforeHookRelease = writerFinished.wait(timeout: .now() + .seconds(3)) == .success

    releaseCallback.signal()
    let writerFinishedAfterRelease = writerFinishedBeforeHookRelease ||
      writerFinished.wait(timeout: .now() + .seconds(3)) == .success
    let drained = completionGroup.wait(timeout: .now() + .seconds(3)) == .success
    reader.stop(suppressPendingCallbacks: true)

    let expected = String(repeating: "q", count: 1_500_000) + "writer finished\n"
    let captured = reader.text
    callbackLock.lock()
    let deliveredCallbackCount = callbackCount
    callbackLock.unlock()
    writeFailed.lock()
    let hadWriterError = writerError != nil
    writeFailed.unlock()

    precondition(hookStarted, "the first output hook did not start")
    precondition(writerFinishedBeforeHookRelease,
                 "large pipe writer blocked while the JS output hook was blocked")
    precondition(writerFinishedAfterRelease, "fixture writer did not finish")
    precondition(!hadWriterError, "fixture pipe write failed")
    precondition(drained && reader.didReachEOF)
    precondition(captured == expectedCapturedPrefix(for: expected))
    precondition(deliveredCallbackCount <= 2,
                 "bounded callback admission should suppress queued hooks on overflow")
  }

  private static func checkLargeImmediateProcessOutput() throws {
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let completionGroup = DispatchGroup()
    let callbackQueue = DispatchQueue(label: "bounded-process-output-check-callbacks")
    let stdoutCapture = ProcessOutputCapture()
    let stderrCapture = ProcessOutputCapture()
    let stdoutReader = ProcessOutputStreamReader(
      fileHandle: stdoutPipe.fileHandleForReading,
      completionGroup: completionGroup,
      callbackQueue: callbackQueue,
      onOutput: { stdoutCapture.append($0) })
    let stderrReader = ProcessOutputStreamReader(
      fileHandle: stderrPipe.fileHandleForReading,
      completionGroup: completionGroup,
      callbackQueue: callbackQueue,
      onOutput: { stderrCapture.append($0) })
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["--large-output-child"]
    child.standardOutput = stdoutPipe
    child.standardError = stderrPipe

    stdoutReader.start()
    stderrReader.start()
    do {
      try child.run()
    } catch {
      stdoutReader.stop()
      stderrReader.stop()
      throw error
    }

    child.waitUntilExit()
    let drained = completionGroup.wait(timeout: .now() + .seconds(2)) == .success
    stdoutReader.stop()
    stderrReader.stop()

    let expectedStdout = String(repeating: "o", count: 1_500_000) + "🎬 end\n"
    let expectedStderr = String(repeating: "e", count: 1_250_000) + "字幕 end\n"
    let stdoutSnapshot = stdoutCapture.snapshot()
    let stderrSnapshot = stderrCapture.snapshot()
    stdoutCapture.markSettled()
    stderrCapture.markSettled()

    precondition(child.terminationStatus == 0)
    precondition(drained, "the child exited before both output pipes reached EOF")
    precondition(stdoutReader.didReachEOF && stderrReader.didReachEOF)
    precondition(expectedStdout.hasPrefix(stdoutSnapshot.text))
    precondition(expectedStderr.hasPrefix(stderrSnapshot.text))
    precondition(stdoutReader.text == expectedCapturedPrefix(for: expectedStdout))
    precondition(stderrReader.text == expectedCapturedPrefix(for: expectedStderr))

    Thread.sleep(forTimeInterval: 0.05)
    precondition(stdoutCapture.snapshot().callbacksAfterSettlement == 0)
    precondition(stderrCapture.snapshot().callbacksAfterSettlement == 0)
  }

  private static func checkSmallOrderedCallbacks() throws {
    let pipe = Pipe()
    let completionGroup = DispatchGroup()
    let callbackQueue = DispatchQueue(label: "bounded-process-output-small-order-check")
    let capture = ProcessOutputCapture()
    let reader = ProcessOutputStreamReader(
      fileHandle: pipe.fileHandleForReading,
      completionGroup: completionGroup,
      callbackQueue: callbackQueue,
      onOutput: { capture.append($0) })
    reader.start()
    try pipe.fileHandleForWriting.write(contentsOf: Data("first:second:third".utf8))
    pipe.fileHandleForWriting.closeFile()
    let completed = completionGroup.wait(timeout: .now() + .seconds(2)) == .success
    let snapshot = capture.snapshot()
    capture.markSettled()

    precondition(completed && reader.didReachEOF)
    precondition(snapshot.text == "first:second:third")
    precondition(capture.snapshot().callbacksAfterSettlement == 0)
  }

  private static func checkHeldOpenPipeStop() throws {
    let pipe = Pipe()
    let completionGroup = DispatchGroup()
    let callbackQueue = DispatchQueue(label: "bounded-process-output-held-pipe-check")
    let capture = ProcessOutputCapture()
    let reader = ProcessOutputStreamReader(
      fileHandle: pipe.fileHandleForReading,
      completionGroup: completionGroup,
      callbackQueue: callbackQueue,
      onOutput: { capture.append($0) })
    reader.start()
    try pipe.fileHandleForWriting.write(contentsOf: Data("inherited writer still open".utf8))

    let drainedWithoutEOF = completionGroup.wait(timeout: .now() + .milliseconds(50)) == .success
    reader.stop()
    let stopped = completionGroup.wait(timeout: .now() + .milliseconds(50)) == .success
    pipe.fileHandleForWriting.closeFile()
    let snapshot = capture.snapshot()
    capture.markSettled()

    precondition(!drainedWithoutEOF)
    precondition(stopped)
    precondition(!reader.didReachEOF)
    precondition(reader.text == "inherited writer still open")
    precondition(snapshot.text == "inherited writer still open")
    Thread.sleep(forTimeInterval: 0.05)
    precondition(capture.snapshot().callbacksAfterSettlement == 0)
  }

  private static func checkSlowEOFTailHookBarrier() throws {
    let pipe = Pipe()
    let completionGroup = DispatchGroup()
    let callbackQueue = DispatchQueue(label: "bounded-process-output-slow-eof-check")
    let callbackEntered = DispatchSemaphore(value: 0)
    let releaseCallback = DispatchSemaphore(value: 0)
    let stopReturned = DispatchSemaphore(value: 0)
    let reader = ProcessOutputStreamReader(
      fileHandle: pipe.fileHandleForReading,
      completionGroup: completionGroup,
      callbackQueue: callbackQueue) { _ in
        callbackEntered.signal()
        _ = releaseCallback.wait(timeout: .now() + .seconds(5))
      }

    reader.start()
    try pipe.fileHandleForWriting.write(contentsOf: Data([0xF0, 0x9F]))
    pipe.fileHandleForWriting.closeFile()
    precondition(callbackEntered.wait(timeout: .now() + .seconds(2)) == .success)

    DispatchQueue.global().async {
      reader.stop()
      stopReturned.signal()
    }
    let stoppedWhileHookBlocked = stopReturned.wait(timeout: .now() + .milliseconds(100)) == .success
    let groupStayedEntered = completionGroup.wait(timeout: .now()) == .timedOut
    releaseCallback.signal()
    let completed = completionGroup.wait(timeout: .now() + .seconds(2)) == .success

    precondition(stoppedWhileHookBlocked, "stop() waited for an EOF tail hook")
    precondition(groupStayedEntered, "the completion group left before the tail hook returned")
    precondition(completed)
    precondition(reader.didReachEOF)
  }

  private static func checkBlockedHookDoesNotBlockStop() throws {
    let pipe = Pipe()
    let completionGroup = DispatchGroup()
    let callbackQueue = DispatchQueue(label: "bounded-process-output-blocked-hook-check")
    let callbackEntered = DispatchSemaphore(value: 0)
    let releaseCallback = DispatchSemaphore(value: 0)
    let stopReturned = DispatchSemaphore(value: 0)
    let capture = ProcessOutputCapture()
    let reader = ProcessOutputStreamReader(
      fileHandle: pipe.fileHandleForReading,
      completionGroup: completionGroup,
      callbackQueue: callbackQueue) { output in
        capture.append(output)
        callbackEntered.signal()
        _ = releaseCallback.wait(timeout: .now() + .seconds(5))
      }

    reader.start()
    try pipe.fileHandleForWriting.write(contentsOf: Data("blocked data hook".utf8))
    precondition(callbackEntered.wait(timeout: .now() + .seconds(2)) == .success)

    DispatchQueue.global().async {
      reader.stop(suppressPendingCallbacks: true)
      stopReturned.signal()
    }
    let stoppedWhileHookBlocked = stopReturned.wait(timeout: .now() + .milliseconds(100)) == .success
    let groupCompletedWhileHookBlocked = completionGroup.wait(timeout: .now() + .seconds(2)) == .success
    let settled = DispatchSemaphore(value: 0)
    completionGroup.notify(queue: .global()) {
      capture.markSettled()
      settled.signal()
    }
    let settledWhileHookBlocked = settled.wait(timeout: .now() + .seconds(1)) == .success
    releaseCallback.signal()
    pipe.fileHandleForWriting.closeFile()
    let completed = completionGroup.wait(timeout: .now() + .seconds(2)) == .success
    reader.stop()

    let snapshot = capture.snapshot()
    Thread.sleep(forTimeInterval: 0.05)

    precondition(stoppedWhileHookBlocked, "stop() waited for an in-flight data hook")
    precondition(groupCompletedWhileHookBlocked,
                 "suppression kept process completion blocked by an active hook")
    precondition(settledWhileHookBlocked,
                 "completion settlement did not run while a synchronous hook remained active")
    precondition(completed)
    precondition(snapshot.text == "blocked data hook")
    precondition(capture.snapshot().callbacksAfterSettlement == 0)
  }

  private static func checkTimedOutDrainSuppressesQueuedHook() throws {
    let pipe = Pipe()
    let completionGroup = DispatchGroup()
    let callbackQueue = DispatchQueue(label: "bounded-process-output-timeout-queue-check")
    let callbackQueueBlocked = DispatchSemaphore(value: 0)
    let releaseCallbackQueue = DispatchSemaphore(value: 0)
    let stopReturned = DispatchSemaphore(value: 0)
    let settled = DispatchSemaphore(value: 0)
    let capture = ProcessOutputCapture()

    callbackQueue.async {
      callbackQueueBlocked.signal()
      _ = releaseCallbackQueue.wait(timeout: .now() + .seconds(5))
    }
    precondition(callbackQueueBlocked.wait(timeout: .now() + .seconds(2)) == .success)

    let reader = ProcessOutputStreamReader(
      fileHandle: pipe.fileHandleForReading,
      completionGroup: completionGroup,
      callbackQueue: callbackQueue,
      onOutput: { capture.append($0) })
    reader.start()
    try pipe.fileHandleForWriting.write(contentsOf: Data("queued hook".utf8))

    let captureDeadline = DispatchTime.now() + .seconds(2)
    while reader.text.isEmpty && DispatchTime.now() < captureDeadline {
      Thread.sleep(forTimeInterval: 0.005)
    }
    precondition(!reader.text.isEmpty, "the stream reader did not queue its callback")

    DispatchQueue.global().async {
      reader.stop(suppressPendingCallbacks: true)
      stopReturned.signal()
    }
    let stoppedWhileCallbackQueueBlocked = stopReturned.wait(timeout: .now() + .milliseconds(100)) == .success
    completionGroup.notify(queue: .global()) {
      capture.markSettled()
      settled.signal()
    }
    let settledWhileCallbackQueueBlocked = settled.wait(timeout: .now() + .seconds(2)) == .success

    releaseCallbackQueue.signal()
    pipe.fileHandleForWriting.closeFile()
    let completed = completionGroup.wait(timeout: .now() + .seconds(2)) == .success
    Thread.sleep(forTimeInterval: 0.05)
    let snapshot = capture.snapshot()

    precondition(stoppedWhileCallbackQueueBlocked, "stop() waited for a queued hook")
    precondition(settledWhileCallbackQueueBlocked,
                 "suppression did not settle while a queued callback was blocked")
    precondition(completed)
    precondition(snapshot.text.isEmpty, "a queued hook ran after the timed-out drain was stopped")
    precondition(capture.snapshot().callbacksAfterSettlement == 0)
  }

  private static func expectedCapturedPrefix(for output: String) -> String {
    let cap = 64 * 1024
    let prefix = String(decoding: Data(output.utf8).prefix(cap), as: UTF8.self)
    return prefix + "\n[plugin process output truncated after \(cap) bytes]"
  }
}

private final class ProcessOutputCapture {
  private let lock = NSLock()
  private var values: [String] = []
  private var settled = false
  private var callbacksAfterSettlement = 0

  func append(_ output: String) {
    lock.lock()
    defer { lock.unlock() }
    if settled {
      callbacksAfterSettlement += 1
    }
    values.append(output)
  }

  func markSettled() {
    lock.lock()
    settled = true
    lock.unlock()
  }

  func snapshot() -> (text: String, callbacksAfterSettlement: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (values.joined(), callbacksAfterSettlement)
  }
}
