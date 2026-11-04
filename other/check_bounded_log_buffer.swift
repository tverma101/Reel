import Foundation

@main
struct BoundedLogBufferChecks {
  static func main() {
    var buffer = BoundedLogBuffer<String>(
      maximumCount: 4,
      maximumBytes: 6,
      maximumEntryBytes: 6,
      byteCount: { $0.utf8.count }
    )

    for value in ["aa", "bbb", "cc", "dd"] {
      buffer.append(value)
    }
    precondition(buffer.elements == ["cc", "dd"])
    precondition(buffer.retainedBytes == 4)

    buffer.append("1234567")
    precondition(buffer.elements == ["cc", "dd"], "oversized entries must not be retained")

    for value in 0..<100_000 {
      buffer.append("x\(value)")
    }
    precondition(buffer.count <= 4)
    precondition(buffer.retainedBytes <= 6)
    precondition(buffer.elements == ["x99999"])

    let drained = buffer.drain()
    precondition(drained == ["x99999"])
    precondition(buffer.count == 0)
    precondition(buffer.retainedBytes == 0)

    buffer.append("ok")
    precondition(buffer.elements == ["ok"])

    var countBound = BoundedLogBuffer<Int>(
      maximumCount: 4,
      maximumBytes: 100,
      maximumEntryBytes: 10,
      byteCount: { _ in 1 }
    )
    for value in 0..<100_000 {
      countBound.append(value)
    }
    precondition(countBound.elements == [99_996, 99_997, 99_998, 99_999])
    precondition(countBound.retainedBytes == 4)

    var largeEntries = BoundedLogBuffer<String>(
      maximumCount: 100,
      maximumBytes: 1_024,
      maximumEntryBytes: 256,
      byteCount: { $0.utf8.count }
    )
    for _ in 0..<5_000 {
      largeEntries.append(String(repeating: "z", count: 200))
    }
    precondition(largeEntries.count == 5)
    precondition(largeEntries.retainedBytes == 1_000)
    precondition(largeEntries.backingEntryCount <= 8, "evicted large records must be released promptly")

    let notificationQueue = DispatchQueue(label: "bounded-log-notification-test")
    let gate = CoalescedNotificationGate()
    let blockerStarted = DispatchSemaphore(value: 0)
    let releaseBlocker = DispatchSemaphore(value: 0)
    notificationQueue.async {
      blockerStarted.signal()
      releaseBlocker.wait()
    }
    blockerStarted.wait()
    var scheduled = 0
    var notifications = 0
    for _ in 0..<10_000 {
      if gate.schedule(on: notificationQueue, execute: { notifications += 1 }) {
        scheduled += 1
      }
    }
    precondition(scheduled == 1, "a burst should queue one UI callback")
    releaseBlocker.signal()
    notificationQueue.sync {}
    precondition(notifications == 1)
    precondition(gate.schedule(on: notificationQueue, execute: { notifications += 1 }),
                 "a later burst can queue after delivery")
    notificationQueue.sync {}
    precondition(notifications == 2)
    print("bounded log buffer checks passed: count, byte budget, oversize rejection, ordering, compaction, and drain")
  }
}
