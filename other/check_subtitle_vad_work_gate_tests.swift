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
enum SubtitleVADWorkGateTests {
  static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
  }

  static func main() {
    let gate = SubtitleVADWorkGate()
    guard let held = gate.tryAcquire() else {
      expect(false, "initial permit is available")
      return
    }

    // Deterministically exercise the repeated-cancel/restart shape: while one synchronous VAD
    // call owns the permit, any number of replacement searches must be rejected before dispatch.
    for _ in 0..<10_000 {
      expect(gate.tryAcquire() == nil, "busy gate admits no queued VAD work")
    }
    held.release()
    held.release() // Release is idempotent, so defer/deinit cannot over-increment the gate.
    guard let afterRelease = gate.tryAcquire() else {
      expect(false, "permit becomes available after the worker settles")
      return
    }
    afterRelease.release()

    let contenders = 64
    let winners = PermitCollector()
    DispatchQueue.concurrentPerform(iterations: contenders) { _ in
      if let permit = gate.tryAcquire() {
        winners.append(permit)
      }
    }
    let acquired = winners.takeAll()
    let winnerCount = acquired.count
    expect(winnerCount == 1, "concurrent contenders acquire at most one permit")
    acquired.forEach { $0.release() }
    guard let recovered = gate.tryAcquire() else {
      expect(false, "gate recovers after concurrent permit release")
      return
    }
    recovered.release()
    print("PASS: VAD gate admits one retained worker, coalesces 10,000 busy attempts, and serializes \(contenders) contenders")
  }
}
