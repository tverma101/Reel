import Foundation
import Dispatch

@main
struct OpenSubCancellableDelayChecks {
  private static var checks = 0

  private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else {
      fputs("FAIL: \(message)\n", stderr)
      exit(1)
    }
  }

  private static func wait(_ semaphore: DispatchSemaphore, seconds: TimeInterval = 2,
                           _ message: String) {
    check(semaphore.wait(timeout: .now() + seconds) == .success, message)
  }

  private static func waitForRelease(_ object: () -> AnyObject?, _ message: String) {
    for _ in 0..<100 {
      if object() == nil { return }
      Thread.sleep(forTimeInterval: 0.01)
    }
    check(object() == nil, message)
  }

  static func main() {
    let alreadyCancelled = SubtitleAudioMatcher.Cancellation()
    alreadyCancelled.cancel()
    let beforeScheduleDone = DispatchSemaphore(value: 0)
    var beforeScheduleError: Error?
    OpenSubCancellableDelay(seconds: 60, cancellation: alreadyCancelled) { error in
      beforeScheduleError = error
      beforeScheduleDone.signal()
    }.start()
    wait(beforeScheduleDone, "cancel-before-schedule settles synchronously")
    check(beforeScheduleError is CancellationError && alreadyCancelled.cancellationHandlers.isEmpty,
          "pre-cancelled delay rejects without retaining a timer handler")

    let pendingCancellation = SubtitleAudioMatcher.Cancellation()
    let pendingDone = DispatchSemaphore(value: 0)
    let pendingOutcome = DelayOutcome(done: pendingDone)
    var pendingDelay: OpenSubCancellableDelay? = OpenSubCancellableDelay(seconds: 60,
                                                                        cancellation: pendingCancellation) {
      pendingOutcome.finish($0)
    }
    weak var weakPendingDelay = pendingDelay
    pendingDelay?.start()
    pendingDelay = nil
    check(pendingCancellation.cancellationHandlers.count == 1,
          "a long pending delay registers exactly one cancellation handler")
    pendingCancellation.cancel()
    wait(pendingDone, "cancelling a long pending delay settles promptly")
    check(pendingOutcome.count == 1 && pendingOutcome.wasCancelled &&
          pendingCancellation.cancellationHandlers.isEmpty,
          "cancel removes the handler and completes the delay exactly once")
    waitForRelease({ weakPendingDelay }, "cancelled delay releases its timer/self cycle")

    let firedCancellation = SubtitleAudioMatcher.Cancellation()
    let firedDone = DispatchSemaphore(value: 0)
    let firedOutcome = DelayOutcome(done: firedDone)
    var firedDelay: OpenSubCancellableDelay? = OpenSubCancellableDelay(seconds: 0.03,
                                                                      cancellation: firedCancellation) {
      firedOutcome.finish($0)
    }
    weak var weakFiredDelay = firedDelay
    firedDelay?.start()
    wait(firedDone, "a short rate-limit delay fires")
    check(firedOutcome.count == 1 && !firedOutcome.wasCancelled &&
          firedCancellation.cancellationHandlers.isEmpty,
          "normal settle unregisters the handler and resolves once")
    firedDelay = nil
    firedCancellation.cancel()
    waitForRelease({ weakFiredDelay }, "fired delay releases its timer/self cycle")

    // Compete timer expiry with cancellation repeatedly. Either terminal event may win, but the
    // promise completion and cancellation registration must each settle exactly once.
    for _ in 0..<100 {
      let token = SubtitleAudioMatcher.Cancellation()
      let done = DispatchSemaphore(value: 0)
      let outcome = DelayOutcome(done: done)
      OpenSubCancellableDelay(seconds: 0.004, cancellation: token) { outcome.finish($0) }.start()
      let cancelDone = DispatchSemaphore(value: 0)
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.004) {
        token.cancel()
        cancelDone.signal()
      }
      wait(done, "fire-vs-cancel race settles")
      wait(cancelDone, "racing cancellation completes")
      check(outcome.count == 1 && token.cancellationHandlers.isEmpty,
            "fire-vs-cancel race has one completion and no retained handler")
    }

    // Exercise cancellation-handler registration and removal racing the token's cancel lock.
    for _ in 0..<100 {
      let token = SubtitleAudioMatcher.Cancellation()
      let callbackCount = AtomicCounter()
      let registrationDone = DispatchSemaphore(value: 0)
      let cancelDone = DispatchSemaphore(value: 0)
      DispatchQueue.global().async {
        let identifier = token.onCancel { callbackCount.increment() }
        token.removeCancellationHandler(identifier)
        registrationDone.signal()
      }
      DispatchQueue.global().async {
        token.cancel()
        cancelDone.signal()
      }
      wait(registrationDone, "handler registration/removal race completes")
      wait(cancelDone, "handler cancellation race completes")
      check(callbackCount.value <= 1 && token.cancellationHandlers.isEmpty,
            "cancel/register/settle race invokes at most once and retires the handler")
    }

    let limiter = OpenSubClientRateLimiterOwner.RateLimiter()
    limiter.processRateLimitHeaders(CaseInsensitiveDictionary(values: [
      "ratelimit-remaining": "0",
      "ratelimit-reset": String(Int.max),
    ]))
    let oversizedResetDelay = limiter.delayBeforeCall()
    check(oversizedResetDelay <= OpenSubClientRateLimiterOwner.RateLimiter.maximumResetInterval &&
          oversizedResetDelay >= OpenSubClientRateLimiterOwner.RateLimiter.maximumResetInterval - 2,
          "oversized server reset is capped at the documented 24-hour maximum")

    let concurrentLimiter = OpenSubClientRateLimiterOwner.RateLimiter()
    let headers = CaseInsensitiveDictionary(values: [
      "ratelimit-remaining": "2",
      "ratelimit-reset": "120",
    ])
    let group = DispatchGroup()
    let invalidDelay = AtomicCounter()
    for worker in 0..<8 {
      group.enter()
      DispatchQueue.global().async {
        for iteration in 0..<500 {
          if (worker + iteration).isMultiple(of: 3) {
            concurrentLimiter.processRateLimitHeaders(headers)
          } else if (worker + iteration).isMultiple(of: 17) {
            concurrentLimiter.reset()
          } else {
            let delay = concurrentLimiter.delayBeforeCall()
            if !delay.isFinite || delay < 0 ||
                delay > OpenSubClientRateLimiterOwner.RateLimiter.maximumResetInterval {
              invalidDelay.increment()
            }
          }
        }
        group.leave()
      }
    }
    check(group.wait(timeout: .now() + 5) == .success,
          "concurrent rate-limit header/delay/reset stress completes")
    check(invalidDelay.value == 0,
          "concurrent limiter state stays finite, nonnegative, and within its maximum")

    print("\(checks) OpenSub cancellable-delay checks passed")
  }
}

private final class DelayOutcome {
  private let lock = NSLock()
  private let done: DispatchSemaphore
  private(set) var count = 0
  private(set) var wasCancelled = false

  init(done: DispatchSemaphore) { self.done = done }

  func finish(_ error: Error?) {
    lock.lock()
    count += 1
    wasCancelled = error is CancellationError
    lock.unlock()
    done.signal()
  }
}

private final class AtomicCounter {
  private let lock = NSLock()
  private var countStorage = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return countStorage
  }

  func increment() {
    lock.lock()
    countStorage += 1
    lock.unlock()
  }
}
