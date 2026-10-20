#!/usr/bin/env python3
"""Run the production route callbacks with a player stub and real notification/dispatch queues."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "iina/AirPlayAudioBridge.swift").read_text()


def method(marker):
    start = SOURCE.index(marker)
    brace = SOURCE.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (SOURCE[end] == "{") - (SOURCE[end] == "}")
        end += 1
    return SOURCE[start:end]


OBSERVE = method("private func observeOutputContext()")
CLOSE = method("func routePickerViewDidEndPresentingRoutes(")
FEEDER = method("private final class AirPlayPlayheadFeeder:")
assert ".currentTime()" not in SOURCE.split("// MARK: - Bridge", 1)[1], (
    "route transitions must not synchronously read the AVPlayer clock from AppKit"
)

HARNESS = r'''
import Foundation
import AVFoundation

final class AirPlayPCMResourceLoader {
  var feeds: [Double] = []
  func setPlayhead(seconds: Double) { feeds.append(seconds) }
}
__FEEDER__

final class PlayerStub: NSObject {
  let context = NSObject()
  var contextReads = 0
  @objc var outputContext: NSObject {
    contextReads += 1
    return context
  }
}
final class AVRoutePickerView: NSObject {}
final class Bridge {
  let avPlayer: PlayerStub? = PlayerStub()
  var observedContext: NSObject?
  var routeObservers: [NSObjectProtocol] = []
  var changes = 0
  var retryTriggers: [String] = []
  func routeMayHaveChanged() { changes += 1 }
  func retryFailedBridgeIfNeeded(trigger: String) { retryTriggers.append(trigger) }
  func observe() { observeOutputContext() }
  deinit { routeObservers.forEach { NotificationCenter.default.removeObserver($0) } }
  __OBSERVE__
  __CLOSE__
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() {
    print("FAIL: \(message)")
    exit(1)
  }
}
private let feeder = AirPlayPlayheadFeeder()
let loader = AirPlayPCMResourceLoader()
feeder.attach(loader)
check(feeder.position == nil, "a new item inherited a stale clock sample")
for index in 0..<100 {
  feeder.update(CMTime(value: Int64(index), timescale: 100))
}
check(feeder.position == 0.99, "cached clock did not retain the latest observer sample")
check(loader.feeds.count == 4, "fine clock samples caused excess decoder updates")
feeder.update(CMTime(seconds: 0.1, preferredTimescale: 100))
check(feeder.position == 0.1 && loader.feeds.last == 0.1, "a backward seek did not update the decoder")
feeder.prepareForSeek(to: 40)
feeder.update(CMTime(seconds: 0.1, preferredTimescale: 100))
check(feeder.position == nil, "an in-flight pre-seek sample repopulated the clock")
feeder.update(CMTime(seconds: 40, preferredTimescale: 100))
check(feeder.position == 40 && loader.feeds.last == 40, "the seek's time jump was not accepted")
feeder.update(.invalid)
check(feeder.position == nil, "an invalid clock retained stale playback progress")
feeder.attach(nil)
feeder.update(CMTime(seconds: 50, preferredTimescale: 100))
check(feeder.position == nil, "an old callback repopulated the detached clock")

let bridge = Bridge()
bridge.observe()
bridge.observe()
check(bridge.avPlayer!.contextReads == 1, "output context was queried again")

let posted = DispatchSemaphore(value: 0)
let context = bridge.observedContext!
DispatchQueue.global().async {
  NotificationCenter.default.post(name: Notification.Name("AVOutputContextOutputDevicesDidChangeNotification"),
                                  object: context)
  posted.signal()
}
// Deliberately keep AppKit busy. The posting media queue must still be able to return.
check(posted.wait(timeout: .now() + 0.3) == .success, "AVFoundation notification waited for the main queue")
check(bridge.changes == 0, "notification handled route state away from the main queue")
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
check(bridge.changes == 1, "deferred notification did not reconcile the route")

bridge.routePickerViewDidEndPresentingRoutes(AVRoutePickerView())
check(bridge.changes == 1, "picker close re-entered route handling synchronously")
check(bridge.retryTriggers.isEmpty, "picker close retried synchronously")
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
check(bridge.changes == 2, "deferred picker close did not reconcile the route")
RunLoop.main.run(until: Date().addingTimeInterval(1.6))
check(bridge.changes == 4, "picker close did not resample the settled route")
check(bridge.retryTriggers == ["route picker close"], "picker close did not retry once after route settling")
print("AirPlay route callback checks passed")
'''


def run(observe, close):
    with tempfile.TemporaryDirectory(prefix="reel-route-callbacks-") as folder:
        folder = Path(folder)
        swift = folder / "main.swift"
        swift.write_text(HARNESS.replace("__OBSERVE__", observe).replace("__CLOSE__", close)
                         .replace("__FEEDER__", FEEDER))
        binary = folder / "check"
        compiled = subprocess.run(["swiftc", str(swift), "-o", str(binary)],
                                  capture_output=True, text=True)
        assert compiled.returncode == 0, compiled.stdout + compiled.stderr
        return subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)


result = run(OBSERVE, CLOSE)
assert result.returncode == 0, result.stdout + result.stderr
print(result.stdout.strip())

# Each original failure must independently trip the behavioral oracle.
mutations = [
    (OBSERVE.replace("guard observedContext == nil,", "guard true,"), CLOSE,
     "output context was queried again"),
    (OBSERVE, CLOSE.replace(
        "DispatchQueue.main.async { [weak self] in self?.routeMayHaveChanged() }",
        "routeMayHaveChanged()", 1), "picker close re-entered"),
    (OBSERVE.replace("queue: nil)", "queue: .main)"), CLOSE,
     "notification waited for the main queue"),
    (OBSERVE, CLOSE.replace('self.retryFailedBridgeIfNeeded(trigger: "route picker close")', ''),
     "picker close did not retry once"),
]
for observe, close, expected in mutations:
    negative = run(observe, close)
    assert negative.returncode != 0 and expected in negative.stdout, negative.stdout + negative.stderr
print("All four route callback negative controls failed as expected")
