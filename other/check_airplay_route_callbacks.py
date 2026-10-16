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

HARNESS = r'''
import Foundation

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
  func routeMayHaveChanged() { changes += 1 }
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
let bridge = Bridge()
bridge.observe()
bridge.observe()
check(bridge.avPlayer!.contextReads == 1, "output context was queried again")

bridge.routePickerViewDidEndPresentingRoutes(AVRoutePickerView())
check(bridge.changes == 0, "picker close re-entered route handling synchronously")
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
check(bridge.changes == 1, "deferred picker close did not reconcile the route")

let posted = DispatchSemaphore(value: 0)
let context = bridge.observedContext!
DispatchQueue.global().async {
  NotificationCenter.default.post(name: Notification.Name("AVOutputContextOutputDevicesDidChangeNotification"),
                                  object: context)
  posted.signal()
}
// Deliberately keep AppKit busy. The posting media queue must still be able to return.
check(posted.wait(timeout: .now() + 0.3) == .success, "AVFoundation notification waited for the main queue")
check(bridge.changes == 1, "notification handled route state away from the main queue")
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
check(bridge.changes == 2, "deferred notification did not reconcile the route")
print("AirPlay route callback checks passed")
'''


def run(observe, close):
    with tempfile.TemporaryDirectory(prefix="reel-route-callbacks-") as folder:
        folder = Path(folder)
        swift = folder / "main.swift"
        swift.write_text(HARNESS.replace("__OBSERVE__", observe).replace("__CLOSE__", close))
        binary = folder / "check"
        subprocess.run(["swiftc", str(swift), "-o", str(binary)], check=True,
                       capture_output=True, text=True)
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
]
for observe, close, expected in mutations:
    negative = run(observe, close)
    assert negative.returncode != 0 and expected in negative.stdout, negative.stdout + negative.stderr
print("All three deadlock regression negative controls failed as expected")
