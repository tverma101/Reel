#!/usr/bin/env python3
"""Exercise the production AirPlay pause recovery methods without a receiver."""

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


RECOVER = method("private func recoverAfterPause(_ duration:")
RETRY = method("private func retryFailedBridgeIfNeeded(trigger:")
FAIL = method("private func failForFile(_ reason:")

HARNESS = r'''
import Foundation

enum ItemStatus { case ready, failed }
final class ItemStub { var status: ItemStatus = .ready }
final class AVPlayerStub { var currentItem: ItemStub? = ItemStub() }
enum OSDMessage { case custom(String) }
enum LogLevel { case info, warning }
final class StateStub { var loaded = true }
final class InfoStub { let state = StateStub() }
final class PlayerStub {
  let info = InfoStub()
  var osdCount = 0
  func sendOSD(_ message: OSDMessage, external: Bool) { osdCount += 1 }
}
struct Selection: Equatable { let name: String }
enum AudioSelection { case pending, unsupported, supported(Selection) }

final class Bridge {
  static let longPauseStreamRefreshThreshold: TimeInterval = 30
  var avPlayer: AVPlayerStub? = AVPlayerStub()
  var bridgeFailedForFile = false
  var itemGeneration = 10
  var routeActive = true
  var isCarrying = true
  var stoppingOrQuitting = false
  var player: PlayerStub? = PlayerStub()
  var isEngaged = true
  var itemSelection: Selection? = Selection(name: "current")
  var availableSelection: AudioSelection = .supported(Selection(name: "current"))
  var routeSample: (() -> Void)?
  var routeSampleCount = 0
  var selectionReadCount = 0
  var replaceCount = 0
  var replacedSelection: Selection?
  var reconcileCount = 0
  var logs: [String] = []

  func routeMayHaveChanged() { routeSampleCount += 1; routeSample?() }
  func audioSelection() -> AudioSelection { selectionReadCount += 1; return availableSelection }
  func replaceItem(with selection: Selection?) {
    replaceCount += 1
    replacedSelection = selection
    itemSelection = selection
    itemGeneration += 1
  }
  func reconcile() { reconcileCount += 1 }
  func log(_ message: String, level: LogLevel = .info) { logs.append(message) }
  func recover(_ duration: TimeInterval) { recoverAfterPause(duration) }
  func fail(_ reason: String) { failForFile(reason) }

  __RECOVER__
  __RETRY__
  __FAIL__
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { print("FAIL: \(message)"); exit(1) }
}
let current = Selection(name: "current")

let shortPause = Bridge()
shortPause.recover(29.999)
check(shortPause.routeSampleCount == 0 && shortPause.replaceCount == 0,
      "a pause shorter than 30 seconds must not refresh the stream")

let thresholdPause = Bridge()
thresholdPause.recover(30)
check(thresholdPause.routeSampleCount == 1 && thresholdPause.replaceCount == 1 &&
      thresholdPause.replacedSelection == current,
      "a supported, stable stream refreshes exactly at the 30-second threshold")

let routeLostLongPause = Bridge()
routeLostLongPause.routeSample = { routeLostLongPause.routeActive = false }
routeLostLongPause.recover(30)
check(routeLostLongPause.routeSampleCount == 1 && routeLostLongPause.replaceCount == 0,
      "a long pause with an inactive route must not build an AirPlay stream")

let routeLostFailure = Bridge()
routeLostFailure.bridgeFailedForFile = true
routeLostFailure.routeSample = { routeLostFailure.routeActive = false }
routeLostFailure.recover(1)
check(routeLostFailure.bridgeFailedForFile && routeLostFailure.reconcileCount == 0 &&
      routeLostFailure.replaceCount == 0,
      "a failure latch remains while the route is inactive")

let failedBridgeRetry = Bridge()
failedBridgeRetry.bridgeFailedForFile = true
failedBridgeRetry.recover(1)
check(!failedBridgeRetry.bridgeFailedForFile && failedBridgeRetry.reconcileCount == 1 &&
      failedBridgeRetry.replaceCount == 0,
      "resume retries a latched failure through normal reconciliation")
failedBridgeRetry.fail("second failure")
check(failedBridgeRetry.bridgeFailedForFile && failedBridgeRetry.reconcileCount == 2 &&
      failedBridgeRetry.replaceCount == 0 && failedBridgeRetry.player?.osdCount == 1,
      "a repeated item failure re-latches and falls back without a retry loop")
failedBridgeRetry.recover(1)
check(!failedBridgeRetry.bridgeFailedForFile && failedBridgeRetry.reconcileCount == 3 &&
      failedBridgeRetry.replaceCount == 0,
      "a re-latched failure gets one more user-triggered retry on resume")

let failedItemRetry = Bridge()
failedItemRetry.avPlayer?.currentItem?.status = .failed
failedItemRetry.recover(1)
check(failedItemRetry.replaceCount == 1 && failedItemRetry.replacedSelection == current,
      "a failed AVPlayer item retries the same supported selection")

let changedGeneration = Bridge()
changedGeneration.routeSample = {
  changedGeneration.itemGeneration += 1
  changedGeneration.availableSelection = .supported(Selection(name: "newer"))
}
changedGeneration.recover(30)
check(changedGeneration.replaceCount == 0 && changedGeneration.selectionReadCount == 0,
      "recovery does not replace a newer item installed during route sampling")

let unsupported = Bridge()
unsupported.availableSelection = .unsupported
unsupported.recover(30)
check(unsupported.replaceCount == 0,
      "an unsupported selection is not rebuilt by pause recovery")

print("AirPlay pause recovery checks passed")
'''


def run(recover, retry, fail):
    with tempfile.TemporaryDirectory(prefix="reel-airplay-pause-recovery-") as directory:
        directory = Path(directory)
        swift = directory / "main.swift"
        swift.write_text(HARNESS.replace("__RECOVER__", recover)
                         .replace("__RETRY__", retry)
                         .replace("__FAIL__", fail))
        binary = directory / "check"
        compiled = subprocess.run(["swiftc", str(swift), "-o", str(binary)],
                                  capture_output=True, text=True)
        assert compiled.returncode == 0, compiled.stdout + compiled.stderr
        return subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)


result = run(RECOVER, RETRY, FAIL)
assert result.returncode == 0, result.stdout + result.stderr
print(result.stdout.strip())

mutations = [
    (RECOVER.replace("guard routeActive else { return }", ""), RETRY, FAIL,
     "inactive route must not build"),
    (RECOVER.replace("guard itemGeneration == itemGenerationBeforeRouteCheck,\n"
                      "          duration >= Self.longPauseStreamRefreshThreshold, isCarrying,\n"
                      "          case .supported(let selection) = audioSelection() else { return }",
                      "guard duration >= Self.longPauseStreamRefreshThreshold, isCarrying,\n"
                      "          case .supported(let selection) = audioSelection() else { return }"), RETRY, FAIL,
     "newer item installed during route sampling"),
    (RECOVER.replace("guard duration >= Self.longPauseStreamRefreshThreshold || bridgeFailedForFile || failedItem else {",
                      "guard duration >= 0 || bridgeFailedForFile || failedItem else {"), RETRY, FAIL,
     "pause shorter than 30 seconds"),
]
for recover, retry, fail, expected in mutations:
    negative = run(recover, retry, fail)
    assert negative.returncode != 0 and expected in negative.stdout, negative.stdout + negative.stderr
print("All three pre-fix negative controls failed as expected")
