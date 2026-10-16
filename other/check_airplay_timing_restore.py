#!/usr/bin/env python3
"""Exercise AirPlay timing restoration, delayed target mapping, and lifecycle guards."""

from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
bridge_source = (ROOT / "iina/AirPlayAudioBridge.swift").read_text()
controller_source = (ROOT / "iina/MPVController.swift").read_text()
player_core_source = (ROOT / "iina/PlayerCore.swift").read_text()

start = bridge_source.index("struct AirPlayTimingRestorePlan")
end = bridge_source.index("// MARK: - Bridge", start)
helper_source = bridge_source[start:end]
bridge = bridge_source.split("final class AirPlayAudioBridge", 1)[1]
assert re.search(
    r"timingRestorePlan\(\s*afterFailure: result,\s*canRestoreSynchronously: request.expectedCurrentTimingValue != nil,\s*"
    r"hasNewerWriteQueued: hasNewerTimingWriteQueued\)",
    bridge,
)
assert "synchronousTimingRestoreBarrier.blocksDrain" in bridge
assert "restoreAirPlayTimingValue(timingRestore.property, value: timingRestore.value," in bridge
assert "ifStillOwned: timingOwnership" in bridge
assert "restoreAirPlayTimingValue(_ property: String, value: Double" in controller_source


def section(source: str, start_marker: str, end_marker: str) -> str:
    start_index = source.index(start_marker)
    end_index = source.index(end_marker, start_index)
    return source[start_index:end_index]


def check_restore_integration(bridge_text: str, controller_text: str) -> None:
    completion = section(
        bridge_text,
        "func mpvCommandCompleted(_ result: Int32, replyUserdata: UInt64)",
        "private func finishSynchronousTimingRestore",
    )
    plan = completion.index("request.operation.timingRestorePlan(")
    begin = completion.index("synchronousTimingRestoreBarrier.begin(replyUserdata: replyUserdata)")
    restore = completion.index("mpv.restoreAirPlayTimingValue(")
    fallback_return = completion.index("      return\n", restore)
    command_clear = completion.index("    activeMPVCommand = nil", begin)
    assert plan < begin < restore < fallback_return < command_clear, (
        "terminal timing fallback must hold the active command until restore completion"
    )
    assert "hasNewerTimingWriteQueued" in completion and (
        "hasNewerWriteQueued: hasNewerTimingWriteQueued" in completion
    ), "a failed hold write must not override a newer queued timing restore"
    assert "completeInternalTimingWrite(for: request)" in completion, (
        "successful or possibly applied setters must retain ownership until their property event"
    )

    enqueue = section(
        bridge_text,
        "private func enqueueMPVRequest(",
        "private func recordInternalTimingWrite(",
    )
    assert enqueue.index("cancelInternalTimingWrite(for: mpvCommandQueue[queuedIndex])") < enqueue.index(
        "recordInternalTimingWrite(for: request.operation)"
    ) < enqueue.index("mpvCommandQueue[queuedIndex] = request"), (
        "coalescing must cancel the replaced echo before recording its replacement"
    )

    release = section(
        bridge_text,
        "private func releaseFile(",
        "private func log(",
    )
    assert "mpv.setDouble(" not in release, (
        "timing release must go through the serialized queue so its file fence is checked"
    )
    assert "expectedFileTransitionGeneration: expectedFileTransitionGeneration" in release
    assert "expectedPlaylistEntryID: expectedPlaylistEntryID" in release
    assert "allowsNoActivePlaylistEntry: allowsNoActivePlaylistEntry" in release
    assert "let shouldRestoreTiming = !currentFileTimingReleaseStarted" in release
    assert release.count("enqueueMPVProperty(") >= 2
    stop_playback = section(
        bridge_text,
        "func stopPlayback()",
        "func whenMPVCommandsDrained(",
    )
    assert "releaseFile()" in stop_playback, (
        "Stop and Quit timing restores must carry their current file identity"
    )

    stop = section(
        player_core_source,
        "func stop() {",
        "func toggleMute(",
    )
    assert stop.index("Pausing playback before releasing AirPlay timing") < stop.index(
        "airPlayAudio.stopPlayback()"
    ) < stop.index("whenMPVCommandsDrained")
    watch_later = section(
        player_core_source,
        "func writeStopWatchLaterIfPending()",
        "/// A [MPV_EVENT_START_FILE]",
    )
    assert watch_later.index("MPVProperty.playlistPlayingPos") < watch_later.index(
        "MPVProperty.playlistNId"
    ) < watch_later.index(
        ".writeWatchLaterConfig"
    ), "watch-later must be written only after verifying the active entry"
    assert "writeStopWatchLaterIfPending()" in controller_text
    assert "MPVHook.onUnLoad" in controller_text
    assert "stopWatchLaterUnloadCompleted()" in controller_text
    assert "mpv.commandIfNotShutdown(.stop" in stop
    assert stop.index("whenMPVCommandsDrained") < stop.index(
        "self.writeStopWatchLaterIfPending()"
    ) < stop.index("mpv.commandIfNotShutdown(.stop"), (
        "Stop must persist the paused entry after its timing restore and before unloading it"
    )

    transition_hook = section(
        controller_text,
        "addHook(MPVHook.onBeforeStartFile",
        "private func removeDedicatedLifecycleHookValues()",
    )
    assert "whenMPVCommandsDrained { next() }" in transition_hook
    assert "isAirPlayPreStartBarrierActive(" in controller_text
    assert controller_text.count("isAirPlayPreStartBarrierActive(") >= 3, (
        "both async submission and synchronous restore must recognize the transition barrier"
    )

    shutdown = section(
        player_core_source,
        "func shutdown() {",
        "/// Notify the task running in the background queue",
    )
    assert shutdown.index("MPVOption.PlaybackControl.pause") < shutdown.index(
        "airPlayAudio.stopPlayback()"
    ) < shutdown.index("whenMPVCommandsDrained") < shutdown.index("mpv.mpvQuit()")

    finish = section(
        bridge_text,
        "private func finishSynchronousTimingRestore",
        "/// Finishes the fail-safe restore before stop/quit drain callbacks",
    )
    assert finish.index("synchronousTimingRestoreBarrier.finish(") < finish.index(
        "activeMPVCommand = nil"
    ) < finish.rindex("runNextMPVCommand()"), (
        "timing completion must release its barrier before advancing the command queue"
    )

    notify = section(
        bridge_text,
        "private func notifyMPVCommandQueueDrained()",
        "/// Completes one serialized libmpv command",
    )
    assert "!synchronousTimingRestoreBarrier.blocksDrain" in notify, (
        "drain callbacks must wait for synchronous timing restoration"
    )

    shutdown = section(
        bridge_text,
        "func playerDidShutDown()",
        "/// Hands mpv's speed and delay back to the user",
    )
    assert shutdown.index("synchronousTimingRestoreBarrier.cancel()") < shutdown.index(
        "notifyMPVCommandQueueDrained()"
    ), "shutdown must cancel the timing barrier before releasing drains"

    worker = section(
        controller_text,
        "func restoreAirPlayTimingValue(_ property: String, value: Double",
        "/// Starts one recovery for either an overflow event",
    )
    ordering = (
        "mpv_wait_async_requests(mpv)",
        "airPlaySnapshotCallLock.lock()",
        "if hasReceivedShutdownEvent || mpv == nil",
        "snapshot.fileTransitionGeneration == timingOwnership.fileTransitionGeneration",
        "snapshot.currentPlaylistEntryID == timingOwnership.playlistEntryID",
        "timingOwnership.allowsNoActivePlaylistEntry",
        "abs(currentValue - expectedValue) < 1e-9",
        "mpv_set_property(mpv, property, MPV_FORMAT_DOUBLE, &mutableValue)",
        "airPlaySnapshotCallLock.unlock()",
        "DispatchQueue.main.async { completion(result, wasSuperseded) }",
    )
    positions = [worker.index(snippet) for snippet in ordering]
    assert positions == sorted(positions), (
        "the restore worker must drain accepted requests, gate shutdown, write off AppKit, "
        "and complete on main"
    )


check_restore_integration(bridge_source, controller_source)

controls_source = (ROOT / "iina/PlayerWindowController.swift").read_text()
assert "MPVCommand.add.rawValue, MPVOption.PlaybackControl.speed" in controls_source
assert "MPVCommand.multiply.rawValue, MPVOption.Audio.audioDelay" in controls_source
assert "adjustUserSpeedForScroll(by: relativeDelta" in controls_source
assert "endFile.playlist_entry_id" in controller_source

harness = r"""
import Foundation

__PRODUCTION_HELPERS__

func expect(_ condition: Bool, _ message: String) {
  if !condition {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
  }
}

var requestedAudioDelays = AirPlayUserAudioDelayTargets()
requestedAudioDelays.append(userValue: 0.2, correction: 0.1, osdMode: .none)
let firstDelayTarget = requestedAudioDelays.target(forMPVValue: 0.3)
expect(firstDelayTarget?.userValue == 0.2,
       "a delayed raw audio-delay event must use its request-time correction")
expect(requestedAudioDelays.complete(firstDelayTarget!) == AirPlayTimingOSDMode.none,
       "the matching no-OSD delay request must retain its presentation mode")
requestedAudioDelays.append(userValue: 0.25, correction: 0.2, osdMode: .bar)
let secondDelayTarget = requestedAudioDelays.target(forMPVValue: 0.45)
expect(secondDelayTarget?.userValue == 0.25,
       "a later correction must not change the logical delay target")
expect(requestedAudioDelays.complete(secondDelayTarget!) == .bar,
       "audio-delay presentation mode must follow the matched target")

let speed = AirPlayTimingRestorePlan.afterFailure(
  property: "speed", value: 0.01, result: -11, canRestoreSynchronously: true)
expect(speed == AirPlayTimingRestorePlan(property: "speed", value: 0.01),
       "terminal speed restore must preserve its requested value")

let delay = AirPlayTimingRestorePlan.afterFailure(
  property: "audio-delay", value: 0.25, result: -11, canRestoreSynchronously: true)
expect(delay == AirPlayTimingRestorePlan(property: "audio-delay", value: 0.25),
       "terminal delay restore must preserve its requested value")
expect(AirPlayTimingRestorePlan.afterFailure(
  property: "speed", value: 0.01, result: -11,
  canRestoreSynchronously: true, hasNewerWriteQueued: true) == nil,
  "a failed hold write must defer to a newer queued speed restore")
expect(AirPlayAudioOutputRestorePolicy.shouldEnqueue(
  "A", pendingOutputs: ["A", "B"], observedOutput: "A", forceReload: false),
  "A→B→A must append A after the queued B restore")
expect(!AirPlayAudioOutputRestorePolicy.shouldEnqueue(
  "A", pendingOutputs: ["B", "A"], observedOutput: "B", forceReload: false),
  "a matching queue tail must deduplicate")
expect(!AirPlayAudioOutputRestorePolicy.shouldEnqueue(
  "A", pendingOutputs: [], observedOutput: "A", forceReload: false),
  "an already-current output must not be restored again")
expect(AirPlayAudioOutputRestorePolicy.shouldEnqueue(
  "A", pendingOutputs: [], observedOutput: "A", forceReload: true),
  "a forced reload must still enqueue when the output name matches")
expect(AirPlayTimingRestorePlan.afterFailure(
  property: "speed", value: 1, result: 0, canRestoreSynchronously: true) == nil,
  "successful async writes must not schedule fallback")
expect(AirPlayTimingRestorePlan.afterFailure(
  property: "speed", value: 1, result: -11, canRestoreSynchronously: false) == nil,
  "non-final timing writes must not schedule a restore fallback")
expect(AirPlayTimingRestorePlan.afterFailure(
  property: "volume", value: 1, result: -11, canRestoreSynchronously: true) == nil,
  "unrelated properties must not use timing fallback")
expect(AirPlayTimingRestorePlan.afterFailure(
  property: "speed", value: .infinity, result: -11, canRestoreSynchronously: true) == nil,
  "non-finite timing values must not be restored")

var delayedWrites = AirPlayInternalWrites(observedValue: 1)
let delayedToken = delayedWrites.record(0.01)
expect(delayedToken != nil, "a changed internal speed must be tracked")
__DELAYED_PROPERTY_EVENT__
expect(delayedWrites.consume(0.01),
       "a delayed internal speed event must remain owned beyond two seconds")
delayedWrites.complete(delayedToken)
expect(delayedWrites.record(0.01) == nil,
       "repeating the already-observed value must not leave a stale echo")

var cancelledWrites = AirPlayInternalWrites(observedValue: 1)
let cancelledToken = cancelledWrites.record(0.01, commandPending: true)
cancelledWrites.cancel(cancelledToken)
expect(!cancelledWrites.consume(0.01),
       "a coalesced, unsubmitted write must not consume a later user event")

var reorderedWrites = AirPlayInternalWrites(observedValue: 1)
let pendingHoldToken = reorderedWrites.record(0.01, commandPending: true)
let pendingRestoreToken = reorderedWrites.record(1, commandPending: true)
expect(pendingRestoreToken != nil, "a queued restore must remain tracked")
expect(reorderedWrites.consume(1), "a direct restore echo must be owned")
expect(reorderedWrites.consume(0.01),
       "a still-pending hold write must survive a newer restore echo")
reorderedWrites.complete(pendingHoldToken)
reorderedWrites.complete(pendingRestoreToken)
expect(!reorderedWrites.consume(0.01), "completed echoes must retire after observation")

var coalescedWrites = AirPlayInternalWrites(observedValue: 1)
let supersededToken = coalescedWrites.record(0.01, commandPending: true)
coalescedWrites.complete(supersededToken)
let latestToken = coalescedWrites.record(1, commandPending: true)
expect(coalescedWrites.consume(1), "the latest coalesced property value must be owned")
coalescedWrites.complete(latestToken)
expect(!coalescedWrites.consume(0.01),
       "a completed, coalesced hold write must not become a stale user-speed marker")

var barrier = AirPlayTimingRestoreBarrier()
expect(barrier.begin(replyUserdata: 7), "fallback should claim its reply token")
expect(barrier.blocksDrain, "pending fallback must hold Stop/quit drain callbacks")
expect(!barrier.begin(replyUserdata: 8), "one fallback must own the barrier at a time")
expect(!barrier.finish(replyUserdata: 8), "a stale reply must not release the barrier")
expect(barrier.blocksDrain, "stale reply must leave the barrier held")
expect(barrier.finish(replyUserdata: 7), "matching completion must release the barrier")
expect(!barrier.blocksDrain, "completed fallback must allow queue drain")
expect(barrier.begin(replyUserdata: 9), "barrier must be reusable")
barrier.cancel()
expect(!barrier.blocksDrain, "shutdown must cancel a pending fallback barrier")
print("AirPlay timing restore checks passed")
"""


def run_helper(source: str, simulate_delayed_event: bool = False) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory(prefix="airplay-timing-restore-") as directory:
        root = Path(directory)
        swift = root / "main.swift"
        binary = root / "checks"
        delayed_event = "Thread.sleep(forTimeInterval: 2.1)" if simulate_delayed_event else ""
        swift.write_text(
            harness.replace("__PRODUCTION_HELPERS__", source)
            .replace("__DELAYED_PROPERTY_EVENT__", delayed_event)
        )
        subprocess.run(["swiftc", str(swift), "-o", str(binary)], check=True)
        return subprocess.run([str(binary)], capture_output=True, text=True)


result = run_helper(helper_source, simulate_delayed_event=True)
if result.returncode != 0:
    raise SystemExit(result.stderr or result.stdout or "AirPlay timing restore checks failed")

mutant = helper_source.replace(
    "guard canRestoreSynchronously, result < 0, value.isFinite,",
    "guard result < 0, value.isFinite,",
    1,
)
assert mutant != helper_source, "negative-control mutation did not match the production policy"
negative_control = run_helper(mutant)
assert negative_control.returncode != 0, "negative control failed to catch a missing restore guard"
print(result.stdout, end="")
print("AirPlay timing restore negative control passed")

mutant = helper_source.replace(
    """if let lastPendingOutput = pendingOutputs.last {
      return lastPendingOutput != output
    }""",
    """if pendingOutputs.contains(output) { return false }
    if !pendingOutputs.isEmpty { return true }""",
    1,
)
assert mutant != helper_source, "A→B→A negative-control mutation did not match the policy"
negative_control = run_helper(mutant)
assert negative_control.returncode != 0, "negative control failed to catch an earlier-match dedupe"
print("AirPlay output-restore ordering checks passed")
print("AirPlay output-restore ordering negative control passed")

no_op_worker = """func restoreAirPlayTimingValue(_ property: String, value: Double,
                                 completion: @escaping (Int32) -> Void) {
    DispatchQueue.main.async { completion(0) }
  }
"""
mutant_controller = controller_source.replace(
    section(
        controller_source,
        "func restoreAirPlayTimingValue(_ property: String, value: Double",
        "/// Starts one recovery for either an overflow event",
    ),
    no_op_worker,
    1,
)
assert mutant_controller != controller_source, "no-op worker mutation did not match"
try:
    check_restore_integration(bridge_source, mutant_controller)
except (AssertionError, ValueError):
    pass
else:
    raise AssertionError("integration checks failed to catch a no-op restore worker")
print("AirPlay restore integration negative control passed")
