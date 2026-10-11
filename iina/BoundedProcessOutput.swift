import Foundation
import Darwin

/// Decodes byte chunks without turning a valid UTF-8 character split across reads into U+FFFD.
final class IncrementalProcessOutputDecoder {
  private let lock = NSLock()
  private var incompleteSuffix = Data()

  func append(_ data: Data) -> String {
    lock.lock()
    defer { lock.unlock() }

    var combined = incompleteSuffix
    combined.append(data)
    let completeLength = Self.completeUTF8PrefixLength(in: combined)
    incompleteSuffix = Data(combined.dropFirst(completeLength))
    return String(decoding: combined.prefix(completeLength), as: UTF8.self)
  }

  func finish() -> String {
    lock.lock()
    defer { lock.unlock() }
    let suffix = incompleteSuffix
    incompleteSuffix.removeAll(keepingCapacity: false)
    return String(decoding: suffix, as: UTF8.self)
  }

  static func completeUTF8PrefixLength(in data: Data) -> Int {
    let bytes = Array(data)
    guard !bytes.isEmpty else { return 0 }

    var leadIndex = bytes.count - 1
    while leadIndex > 0, bytes[leadIndex] & 0xC0 == 0x80 {
      leadIndex -= 1
    }

    let lead = bytes[leadIndex]
    let sequenceLength: Int
    switch lead {
    case 0x00...0x7F: sequenceLength = 1
    case 0xC2...0xDF: sequenceLength = 2
    case 0xE0...0xEF: sequenceLength = 3
    case 0xF0...0xF4: sequenceLength = 4
    default: return bytes.count // Invalid bytes are decoded as replacement characters now.
    }

    return bytes.count - leadIndex < sequenceLength ? leadIndex : bytes.count
  }
}

/// Captures a bounded prefix while callers stream the full output to their live hooks.
final class BoundedProcessOutput {
  private let lock = NSLock()
  private let maximumBytes: Int
  private var bytes = Data()
  private var truncated = false

  init(maximumBytes: Int = 64 * 1024) {
    self.maximumBytes = max(0, maximumBytes)
  }

  func append(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    let remaining = maximumBytes - bytes.count
    guard remaining > 0 else {
      if !data.isEmpty { truncated = true }
      return
    }
    let count = min(remaining, data.count)
    bytes.append(data.prefix(count))
    if count < data.count { truncated = true }
  }

  var text: String {
    lock.lock()
    let value = bytes
    let wasTruncated = truncated
    lock.unlock()
    let completeLength = IncrementalProcessOutputDecoder.completeUTF8PrefixLength(in: value)
    var result = String(decoding: value.prefix(completeLength), as: UTF8.self)
    if wasTruncated {
      result += "\n[plugin process output truncated after \(maximumBytes) bytes]"
    }
    return result
  }
}

/// Bounds child-process lifecycles globally and per plugin. A permit is held
/// through Promise settlement, so a stuck JavaScript hook cannot create an
/// unbounded queue of retained native process/output state.
final class BoundedProcessExecutionAdmission {
  static let shared = BoundedProcessExecutionAdmission(
    maximumTotalActiveExecutions: 16,
    maximumActiveExecutionsPerPlugin: 2)

  let maximumTotalActiveExecutions: Int
  let maximumActiveExecutionsPerPlugin: Int
  private let lock = NSLock()
  private var activeExecutions = 0
  private var activeExecutionsByPlugin: [String: Int] = [:]

  init(maximumTotalActiveExecutions: Int, maximumActiveExecutionsPerPlugin: Int) {
    self.maximumTotalActiveExecutions = max(1, maximumTotalActiveExecutions)
    self.maximumActiveExecutionsPerPlugin = max(1, maximumActiveExecutionsPerPlugin)
  }

  func acquire(forPluginIdentifier pluginIdentifier: String) -> ProcessExecutionPermit? {
    lock.lock()
    let pluginExecutions = activeExecutionsByPlugin[pluginIdentifier, default: 0]
    guard activeExecutions < maximumTotalActiveExecutions,
          pluginExecutions < maximumActiveExecutionsPerPlugin else {
      lock.unlock()
      return nil
    }
    activeExecutions += 1
    activeExecutionsByPlugin[pluginIdentifier] = pluginExecutions + 1
    lock.unlock()
    return ProcessExecutionPermit(admission: self, pluginIdentifier: pluginIdentifier)
  }

  fileprivate func release(forPluginIdentifier pluginIdentifier: String) {
    lock.lock()
    let pluginExecutions = activeExecutionsByPlugin[pluginIdentifier, default: 0]
    precondition(activeExecutions > 0 && pluginExecutions > 0)
    activeExecutions -= 1
    if pluginExecutions == 1 {
      activeExecutionsByPlugin.removeValue(forKey: pluginIdentifier)
    } else {
      activeExecutionsByPlugin[pluginIdentifier] = pluginExecutions - 1
    }
    lock.unlock()
  }
}

final class ProcessExecutionPermit {
  private let lock = NSLock()
  private var admission: BoundedProcessExecutionAdmission?
  private let pluginIdentifier: String

  fileprivate init(admission: BoundedProcessExecutionAdmission, pluginIdentifier: String) {
    self.admission = admission
    self.pluginIdentifier = pluginIdentifier
  }

  func release() {
    lock.lock()
    let admission = self.admission
    self.admission = nil
    lock.unlock()
    admission?.release(forPluginIdentifier: pluginIdentifier)
  }

  deinit {
    release()
  }
}

enum PluginProcessExecutionQueues {
  /// Process waits must not occupy the serial queue used for plugin JS callbacks
  /// and Promise settlement. Admission bounds the number of blocking waiters.
  static let processWait = DispatchQueue(
    label: "com.colliderli.iina.plugin-process-wait", qos: .utility, attributes: .concurrent)
}

/// Owns bounded callback delivery independently from the pipe reader. A timed
/// stop can discard queued callbacks and release process completion while an
/// already-entered synchronous JavaScript hook finishes. The active stack keeps
/// only its callback and output string; it does not retain the reader or pipe.
final class ProcessOutputCallbackDelivery {
  // Per stream, at most 64 KiB / 128 chunks wait for callbacks, plus one
  // callback of at most 64 KiB may be executing.
  private static let maximumPendingCallbackBytes = 64 * 1024
  private static let maximumPendingCallbackChunks = 128
  static let maximumCallbacksPerDrainBatch = 16

  private let lock = NSLock()
  private var completionGroup: DispatchGroup?
  private var callbackQueue: DispatchQueue?
  private var onOutput: ((String) -> Void)?

  private var started = false
  private var completionSignaled = false
  private var callbacksSuppressed = false
  private var inputFinished = false
  private var pendingOutputs: [String] = []
  private var pendingOutputBytes = 0
  private var activeCallbackBytes = 0
  private var deliveryScheduled = false

  init(completionGroup: DispatchGroup,
       callbackQueue: DispatchQueue,
       onOutput: @escaping (String) -> Void) {
    self.completionGroup = completionGroup
    self.callbackQueue = callbackQueue
    self.onOutput = onOutput
  }

  func start() {
    lock.lock()
    guard !started else {
      lock.unlock()
      return
    }
    started = true
    completionGroup?.enter()
    lock.unlock()
  }

  func enqueue(_ output: String) {
    guard !output.isEmpty else { return }
    let byteCount = output.utf8.count
    var shouldScheduleDelivery = false
    var groupToLeave: DispatchGroup?

    lock.lock()
    guard !callbacksSuppressed, !completionSignaled else {
      lock.unlock()
      return
    }
    guard byteCount <= Self.maximumPendingCallbackBytes,
          pendingOutputs.count < Self.maximumPendingCallbackChunks,
          pendingOutputBytes <= Self.maximumPendingCallbackBytes - byteCount,
          let callbackQueue else {
      suppressPendingCallbacksLocked()
      groupToLeave = completionGroupToLeaveIfReadyLocked()
      lock.unlock()
      groupToLeave?.leave()
      return
    }

    pendingOutputs.append(output)
    pendingOutputBytes += byteCount
    if !deliveryScheduled {
      deliveryScheduled = true
      shouldScheduleDelivery = true
    }
    lock.unlock()

    if shouldScheduleDelivery {
      callbackQueue.async { [self] in drainCallbacks() }
    }
  }

  func finishInput() {
    lock.lock()
    inputFinished = true
    let groupToLeave = completionGroupToLeaveIfReadyLocked()
    lock.unlock()
    groupToLeave?.leave()
  }

  /// Discards callback work that has not entered JavaScript. An admitted hook
  /// may continue, but no longer holds process completion or the pipe reader.
  func suppressPendingCallbacks() {
    lock.lock()
    suppressPendingCallbacksLocked()
    let groupToLeave = completionGroupToLeaveIfReadyLocked()
    lock.unlock()
    groupToLeave?.leave()
  }

  private func suppressPendingCallbacksLocked() {
    callbacksSuppressed = true
    pendingOutputs.removeAll(keepingCapacity: false)
    pendingOutputBytes = 0
    deliveryScheduled = false
    onOutput = nil
  }

  /// Must be called with lock held. Completion normally waits until delivery
  /// drains. After suppression it waits only for input finalization; an active
  /// JavaScript call cannot be interrupted safely and must not retain readers.
  private func completionGroupToLeaveIfReadyLocked() -> DispatchGroup? {
    guard started, inputFinished, !completionSignaled,
          callbacksSuppressed || (!deliveryScheduled && pendingOutputs.isEmpty && activeCallbackBytes == 0) else {
      return nil
    }
    completionSignaled = true
    let group = completionGroup
    completionGroup = nil
    callbackQueue = nil
    onOutput = nil
    return group
  }

  private func drainCallbacks() {
    var callbacksDelivered = 0
    while callbacksDelivered < Self.maximumCallbacksPerDrainBatch {
      lock.lock()
      if callbacksSuppressed {
        pendingOutputs.removeAll(keepingCapacity: false)
        pendingOutputBytes = 0
        deliveryScheduled = false
        let groupToLeave = completionGroupToLeaveIfReadyLocked()
        lock.unlock()
        groupToLeave?.leave()
        return
      }
      guard !pendingOutputs.isEmpty else {
        deliveryScheduled = false
        let groupToLeave = completionGroupToLeaveIfReadyLocked()
        lock.unlock()
        groupToLeave?.leave()
        return
      }

      let output = pendingOutputs.removeFirst()
      let byteCount = output.utf8.count
      pendingOutputBytes -= byteCount
      activeCallbackBytes = byteCount
      let callback = onOutput
      lock.unlock()

      // The callback buffer, rather than the pipe reader, is retained by this
      // queue block. A timed-out hook therefore cannot keep the pipe open.
      callback?(output)
      callbacksDelivered += 1

      lock.lock()
      activeCallbackBytes = 0
      if callbacksSuppressed {
        pendingOutputs.removeAll(keepingCapacity: false)
        pendingOutputBytes = 0
        deliveryScheduled = false
        let groupToLeave = completionGroupToLeaveIfReadyLocked()
        lock.unlock()
        groupToLeave?.leave()
        return
      }
      lock.unlock()
    }

    lock.lock()
    if callbacksSuppressed {
      pendingOutputs.removeAll(keepingCapacity: false)
      pendingOutputBytes = 0
      deliveryScheduled = false
      let groupToLeave = completionGroupToLeaveIfReadyLocked()
      lock.unlock()
      groupToLeave?.leave()
      return
    }
    guard !pendingOutputs.isEmpty else {
      deliveryScheduled = false
      let groupToLeave = completionGroupToLeaveIfReadyLocked()
      lock.unlock()
      groupToLeave?.leave()
      return
    }
    guard let callbackQueue else {
      suppressPendingCallbacksLocked()
      deliveryScheduled = false
      let groupToLeave = completionGroupToLeaveIfReadyLocked()
      lock.unlock()
      groupToLeave?.leave()
      return
    }
    // Keep deliveryScheduled true across the yield. This prevents a producer
    // from scheduling a second drain and preserves FIFO callback order.
    lock.unlock()
    callbackQueue.async { [self] in drainCallbacks() }
  }
}

/// Streams one process pipe into a bounded capture and callback delivery.
/// Pipe draining is serialized independently from plugin callbacks.
final class ProcessOutputStreamReader {
  private let fileHandle: FileHandle
  private let readQueue = DispatchQueue(label: "com.colliderli.iina.plugin-process-output-reader")
  private let capture: BoundedProcessOutput
  private let decoder = IncrementalProcessOutputDecoder()
  private let delivery: ProcessOutputCallbackDelivery
  private let lock = NSLock()

  private var started = false
  private var stopped = false
  private var reachedEOF = false
  private var readScheduled = false
  private var readPending = false
  private var inputFinished = false
  private var finalizationScheduled = false

  init(fileHandle: FileHandle,
       completionGroup: DispatchGroup,
       callbackQueue: DispatchQueue,
       maximumBytes: Int = 64 * 1024,
       onOutput: @escaping (String) -> Void) {
    self.fileHandle = fileHandle
    self.capture = BoundedProcessOutput(maximumBytes: maximumBytes)
    self.delivery = ProcessOutputCallbackDelivery(completionGroup: completionGroup,
                                                  callbackQueue: callbackQueue,
                                                  onOutput: onOutput)
  }

  func start() {
    lock.lock()
    guard !started, !stopped else {
      lock.unlock()
      return
    }
    started = true
    delivery.start()
    lock.unlock()

    fileHandle.readabilityHandler = { [weak self] handle in
      self?.scheduleRead(from: handle)
    }
    lock.lock()
    let shouldRemoveHandler = stopped
    lock.unlock()
    if shouldRemoveHandler {
      fileHandle.readabilityHandler = nil
    }
  }

  /// Stops further reads and queues any incomplete UTF-8 suffix for delivery.
  /// Suppression releases process completion without waiting for a synchronous
  /// plugin hook that has already entered JavaScript.
  func stop(suppressPendingCallbacks: Bool = false) {
    lock.lock()
    if suppressPendingCallbacks {
      // Share the reader lock with enqueue so suppression wins atomically
      // against callbacks that have not yet been admitted to the delivery FIFO.
      delivery.suppressPendingCallbacks()
    }
    stopped = true
    let shouldScheduleFinalization = started && !inputFinished && !finalizationScheduled
    if shouldScheduleFinalization {
      finalizationScheduled = true
    }
    lock.unlock()

    fileHandle.readabilityHandler = nil
    if shouldScheduleFinalization {
      readQueue.async { [self] in finishStoppedStream() }
    }
  }

  var text: String {
    capture.text
  }

  var didReachEOF: Bool {
    lock.lock()
    defer { lock.unlock() }
    return reachedEOF
  }

  private func scheduleRead(from handle: FileHandle) {
    lock.lock()
    guard started, !stopped else {
      lock.unlock()
      return
    }
    if readScheduled {
      readPending = true
      lock.unlock()
      return
    }
    readScheduled = true
    lock.unlock()

    readQueue.async { [self] in readAvailableData(from: handle) }
  }

  private func readAvailableData(from handle: FileHandle) {
    while true {
      lock.lock()
      guard !stopped else {
        readScheduled = false
        readPending = false
        lock.unlock()
        return
      }
      lock.unlock()

      // FileHandle notifications can coalesce while the reader queue is
      // delivering a hook. Recheck readiness before another read so a stale
      // notification cannot make availableData block on an open, empty pipe.
      guard hasReadableData(from: handle) else {
        lock.lock()
        if stopped {
          readScheduled = false
          readPending = false
          lock.unlock()
          return
        }
        if readPending {
          readPending = false
          lock.unlock()
          continue
        }
        readScheduled = false
        lock.unlock()
        return
      }

      let data = handle.availableData
      var output = ""

      lock.lock()
      if data.isEmpty {
        stopped = true
        reachedEOF = true
        readScheduled = false
        readPending = false
        inputFinished = true
        let tail = decoder.finish()
        delivery.enqueue(tail)
        delivery.finishInput()
        lock.unlock()

        handle.readabilityHandler = nil
        return
      }

      capture.append(data)
      output = decoder.append(data)
      // Any notifications received while this chunk was being read are
      // revalidated with poll() at the top of the loop.
      readPending = false
      delivery.enqueue(output)
      lock.unlock()
    }
  }

  private func hasReadableData(from handle: FileHandle) -> Bool {
    var descriptor = pollfd()
    descriptor.fd = Int32(handle.fileDescriptor)
    descriptor.events = Int16(POLLIN)
    let result = Darwin.poll(&descriptor, 1, 0)
    let readableEvents = Int16(POLLIN | POLLHUP | POLLERR)
    return result > 0 && (descriptor.revents & readableEvents) != 0
  }

  private func finishStoppedStream() {
    lock.lock()
    let tail = decoder.finish()
    inputFinished = true
    delivery.enqueue(tail)
    delivery.finishInput()
    lock.unlock()
  }
}
