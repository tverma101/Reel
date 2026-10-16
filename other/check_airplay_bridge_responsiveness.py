#!/usr/bin/env python3
"""Guard the AirPlay bridge against synchronous libmpv calls from UI timers."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
bridge_source = (ROOT / "iina/AirPlayAudioBridge.swift").read_text()
controller_source = (ROOT / "iina/MPVController.swift").read_text()
bridge = bridge_source.split("// MARK: - Bridge", 1)[1]

assert "mpv.get" not in bridge, "AirPlay must consume its event-fed mpv snapshot"
assert "mpv.command(rawString:" not in bridge, "ao-reload must not block the UI thread"
assert "mpv.setDouble" not in bridge.split("private func tick()", 1)[1].split("func timeControlStatusChanged", 1)[0]
assert "mpv.setDouble" not in bridge.split("private func pollHold(", 1)[1].split("private func cancelHold", 1)[0]
assert "mpv.setDouble" not in bridge.split("private func engage()", 1)[1].split("private func disengage()", 1)[0]
timing_scope = bridge.split("func withUserTiming", 1)[1].split("func fileStarted", 1)[0]
assert timing_scope.count("mpv.setDouble") == 4, "watch-later timing writes must remain synchronous"
ao_reload_count = bridge.count('MPVCommand("ao-reload")')
assert ao_reload_count > 0, "the bridge must retain its AO reload operations"
assert ao_reload_count == bridge.count(
    'enqueueMPVCommand(MPVCommand("ao-reload")'
), "every ao-reload must go through the serialized async command queue"
assert "activeMPVCommand == nil" in bridge, "bridge mpv commands must be serialized"
assert "replyUserdata: replyUserdata" in bridge
assert "airPlayAudioCommandBase &+ nextMPVCommandReplyId" in bridge
snapshot_request = controller_source.split("func requestAirPlayPlaybackSnapshot()", 1)[1].split("// Set property", 1)[0]
assert '(MPVProperty.timePos, MPV_FORMAT_DOUBLE)' in snapshot_request
assert '(MPVProperty.audioPts, MPV_FORMAT_DOUBLE)' in snapshot_request
assert "mpv_get_property_async" in snapshot_request
assert "MPV_EVENT_GET_PROPERTY_REPLY" in controller_source
assert "mpvSnapshotTimer" in bridge and "requestAirPlayPlaybackSnapshot()" in bridge
observe_map = controller_source.split("let observeProperties:", 1)[1].split("\n  ]", 1)[0]
for high_frequency_property in ("MPVProperty.timePos", "MPVProperty.audioPts",
                                "MPVProperty.pausedForCache", "MPVProperty.estimatedVfFps",
                                "MPVProperty.containerFps"):
    assert high_frequency_property not in observe_map, (
        f"{high_frequency_property} must use throttled async requests, not event observers")
assert "$airPlaySnapshot.withLock" in controller_source

submission_start = controller_source.index("func submitAirPlayCommand(")
submission_end = controller_source.index("func restoreAirPlayAudioOutput(", submission_start)
submission = controller_source[submission_start:submission_end]


def route_lock_follows_ao_lock(body: str) -> bool:
    return body.index("self.airPlayAudioOutputWriteLock.lock()") < body.index(
        "self.airPlayRouteOwnershipLock.lock()"
    )


assert route_lock_follows_ao_lock(submission), (
    "a bridge submission must not hold the route lock while waiting for a direct AO write"
)
submitted = submission.split("let result = submission()", 1)[1]
assert submitted.index("self.airPlayRouteOwnershipLock.unlock()") < submitted.index(
    "self.airPlayAudioOutputWriteLock.unlock()"
), "release submission locks in reverse acquisition order"

route_mismatch = submission.split(
    "guard self.airPlayRouteOwnershipGeneration == expectedRouteOwnershipGeneration else {", 1
)[1].split("\n      }", 1)[0]
assert route_mismatch.index("self.airPlayRouteOwnershipLock.unlock()") < route_mismatch.index(
    "self.airPlayAudioOutputWriteLock.unlock()"
) < route_mismatch.index("self.airPlaySnapshotCallLock.unlock()"), (
    "route-mismatch exit must release every acquired lock in reverse order"
)

intent_mismatch = submission.split(
    "guard currentIntentGeneration == expectedIntentGeneration else {", 1
)[1].split("\n      }", 1)[0]
assert intent_mismatch.index("self.airPlayRouteOwnershipLock.unlock()") < intent_mismatch.index(
    "self.airPlayAudioOutputWriteLock.unlock()"
) < intent_mismatch.index("self.airPlaySnapshotCallLock.unlock()"), (
    "intent-mismatch exit must release every acquired lock in reverse order"
)

mutated_submission = submission.replace(
    "self.airPlayAudioOutputWriteLock.lock()", "__AO_LOCK__", 1
).replace(
    "self.airPlayRouteOwnershipLock.lock()", "self.airPlayAudioOutputWriteLock.lock()", 1
).replace("__AO_LOCK__", "self.airPlayRouteOwnershipLock.lock()", 1)
assert not route_lock_follows_ao_lock(mutated_submission), (
    "negative control must catch route-lock-first acquisition"
)

print("AirPlay bridge responsiveness checks passed")
