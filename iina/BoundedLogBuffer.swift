//
//  BoundedLogBuffer.swift
//  iina
//
//  Keeps recent log records within a predictable memory budget.
//

import Foundation

struct BoundedLogBuffer<Element> {
  private let maximumCount: Int
  private let maximumBytes: Int
  private let maximumEntryBytes: Int
  private let byteCount: (Element) -> Int

  private var storage: [Element] = []
  private var firstLiveIndex = 0
  private var discardedBytes = 0
  private(set) var retainedBytes = 0

  var count: Int {
    storage.count - firstLiveIndex
  }

  var backingEntryCount: Int {
    storage.count
  }

  var elements: [Element] {
    guard firstLiveIndex < storage.count else { return [] }
    return Array(storage[firstLiveIndex...])
  }

  init(maximumCount: Int, maximumBytes: Int, maximumEntryBytes: Int,
       byteCount: @escaping (Element) -> Int) {
    precondition(maximumCount > 0)
    precondition(maximumBytes > 0)
    precondition(maximumEntryBytes > 0)
    self.maximumCount = maximumCount
    self.maximumBytes = maximumBytes
    self.maximumEntryBytes = maximumEntryBytes
    self.byteCount = byteCount
  }

  mutating func append(_ element: Element) {
    let size = max(0, byteCount(element))
    guard size <= maximumEntryBytes else { return }

    storage.append(element)
    retainedBytes += size
    while count > maximumCount || retainedBytes > maximumBytes {
      let discardedSize = max(0, byteCount(storage[firstLiveIndex]))
      retainedBytes -= discardedSize
      discardedBytes += discardedSize
      firstLiveIndex += 1
    }
    compactIfNeeded()
  }

  mutating func append(contentsOf elements: [Element]) {
    for element in elements {
      append(element)
    }
  }

  mutating func drain() -> [Element] {
    let drained = elements
    storage.removeAll(keepingCapacity: true)
    firstLiveIndex = 0
    discardedBytes = 0
    retainedBytes = 0
    return drained
  }

  private mutating func compactIfNeeded() {
    let discardedByteThreshold = max(1, maximumBytes / 4)
    let staleEntriesNeedCompaction = firstLiveIndex >= 1_024 && firstLiveIndex * 2 >= storage.count
    guard firstLiveIndex > 0 && (discardedBytes >= discardedByteThreshold || staleEntriesNeedCompaction) else {
      return
    }
    storage.removeFirst(firstLiveIndex)
    firstLiveIndex = 0
    discardedBytes = 0
  }
}

/// Coalesces bursts into one queued UI callback while allowing a later burst after delivery.
final class CoalescedNotificationGate {
  private let lock = NSLock()
  private var isScheduled = false

  @discardableResult
  func schedule(on queue: DispatchQueue, execute callback: @escaping () -> Void) -> Bool {
    lock.lock()
    guard !isScheduled else {
      lock.unlock()
      return false
    }
    isScheduled = true
    lock.unlock()

    queue.async { [self] in
      lock.lock()
      isScheduled = false
      lock.unlock()
      callback()
    }
    return true
  }
}
