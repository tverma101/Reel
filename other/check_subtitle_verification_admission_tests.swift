import Dispatch
import Foundation

private final class PermitCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var permits: [SubtitleVADWorkGate.Permit] = []

  func append(_ permit: SubtitleVADWorkGate.Permit) {
    lock.lock()
    permits.append(permit)
    lock.unlock()
  }

  func takeAll() -> [SubtitleVADWorkGate.Permit] {
    lock.lock()
    defer { lock.unlock() }
    let result = permits
    permits.removeAll()
    return result
  }
}

@main
enum SubtitleVerificationAdmissionTests {
  static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
  }

  static func main() {
    let gate = SubtitleVADWorkGate()
    guard let activeVerification = gate.tryAcquire() else {
      expect(false, "initial verification is admitted")
      return
    }

    // A canceled/restarted verification attempts admission before it can retain subtitle cues,
    // decoded samples, or enqueue a worker closure. Model that shape without retaining fixtures.
    var queuedHeavyWork = 0
    for _ in 0..<20_000 {
      if let replacement = gate.tryAcquire() {
        queuedHeavyWork += 1
        replacement.release()
      }
    }
    expect(queuedHeavyWork == 0, "restarts while the active matcher drains retain no queued work")

    activeVerification.release()
    activeVerification.release()
    guard let resumedVerification = gate.tryAcquire() else {
      expect(false, "gate recovers after canceled work settles")
      return
    }
    resumedVerification.release()

    let contenders = 64
    let winners = PermitCollector()
    DispatchQueue.concurrentPerform(iterations: contenders) { _ in
      if let permit = gate.tryAcquire() {
        winners.append(permit)
      }
    }
    let acquired = winners.takeAll()
    let winnerCount = acquired.count
    expect(winnerCount == 1, "concurrent verification attempts admit at most one retained working set")
    acquired.forEach { $0.release() }
    guard let recovered = gate.tryAcquire() else {
      expect(false, "gate recovers after concurrent contenders settle")
      return
    }
    recovered.release()
    print("PASS: one verification retained, 20,000 restarts coalesced, and \(contenders) concurrent attempts serialized")
  }
}
