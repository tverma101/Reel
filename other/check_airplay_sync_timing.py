#!/usr/bin/env python3
"""Check the AirPlay bridge's control of mpv's audio queue and of the timing it saves.

While the bridge carries audio, mpv's `null` output plays a short queue (`audio-buffer` plus its own
buffer), so holds and speed changes reach the picture sooner. Changing `audio-buffer` reopens mpv's
output, so it may change only while `null` is open, and `ao-null-buffer` is set before
initialization. An mpv `quit-watch-later` binding must save the user's timing, not the bridge's.
Each wiring check also runs against a mutated source that must fail.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = (ROOT / "iina/AirPlayAudioBridge.swift").read_text()
CONTROLLER = (ROOT / "iina/MPVController.swift").read_text()
WINDOW = (ROOT / "iina/PlayerWindowController.swift").read_text()


def extract(source, marker):
    """`marker` through the end of the braces that follow it."""
    start = source.index(marker)
    brace = source.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def between(source, start, end):
    begin = source.index(start)
    return source[begin:source.index(end, begin + len(start))]


def check_wiring(bridge, controller, window):
    # `audio-buffer` reopens the output when it changes, so it changes only while `null` is open: after
    # the bridge's own switch to `null`, and before any switch to a local output.
    submission = between(bridge, "submission: {", "}, completion:")
    restore = submission.index('if let target, target != "null" { mpv.setAirPlayAudioBufferAsync(forAudioOutput: target) }')
    switch = submission.index("switch operation {")
    shorten = submission.index('if target == "null", result >= 0 { mpv.setAirPlayAudioBufferAsync(forAudioOutput: "null") }')
    assert restore < switch < shorten, submission
    synchronous = extract(controller, "private func beginSynchronousAudioOutputWrite(")
    assert "var audioBuffer = localAudioBuffer" in synchronous
    assert synchronous.index("airPlayAudioOutputWriteLock.lock()") < synchronous.index(
        "mpv_set_property(mpv, MPVOption.Audio.audioBuffer, MPV_FORMAT_DOUBLE, &audioBuffer)")
    helper = extract(controller, "func setAirPlayAudioBufferAsync(")
    assert 'audioOutput == "null" ? Self.airPlayNullAudioBuffer : localAudioBuffer' in helper
    # Only `null` reads `ao-null-buffer`; it is set before initialization, where a rejection must not be fatal.
    null_buffer = controller.index('setOptionString("ao-null-buffer", String(Self.airPlayNullAudioBuffer)')
    assert null_buffer < controller.index("mpv_initialize(mpv)")
    assert not controller[null_buffer - 20:null_buffer].rstrip().endswith("chkErr("), "a rejected tuning option aborts"
    assert controller.index("localAudioBuffer = getDoubleIfAvailable(MPVOption.Audio.audioBuffer)") > \
        controller.index("mpv_initialize(mpv)")

    # mpv's own `quit-watch-later` would save the bridge's hold speed or correction as the user's.
    quit_later = between(window, "case MPVCommand.quitWatchLater.rawValue:", "returnValue = 0")
    saved = quit_later.index("player.airPlayAudio.withUserTiming {")
    assert saved < quit_later.index("player.mpv.command(.writeWatchLaterConfig") < quit_later.index("NSApp.terminate(nil)")
    assert "player.mpv.command(rawString" not in quit_later


check_wiring(BRIDGE, CONTROLLER, WINDOW)
print("audio-queue and watch-later wiring ok")

MUTATIONS = {
    "buffer never shortened for null": ("bridge",
        'if target == "null", result >= 0 { mpv.setAirPlayAudioBufferAsync(forAudioOutput: "null") }\n        return result',
        'return result'),
    "local buffer not restored before a local switch": ("bridge",
        'if let target, target != "null" { mpv.setAirPlayAudioBufferAsync(forAudioOutput: target) }', ''),
    "synchronous writes keep the short buffer": ("controller",
        "mpv_set_property(mpv, MPVOption.Audio.audioBuffer, MPV_FORMAT_DOUBLE, &audioBuffer)", ""),
    "quit-watch-later saves the bridge timing": ("window",
        "player.airPlayAudio.withUserTiming {\n            player.mpv.command(.writeWatchLaterConfig, level: .verbose)\n          }",
        "player.mpv.command(.writeWatchLaterConfig, level: .verbose)"),
}
for name, (target, old, new) in MUTATIONS.items():
    sources = {"bridge": BRIDGE, "controller": CONTROLLER, "window": WINDOW}
    assert sources[target].count(old) == 1, name
    sources[target] = sources[target].replace(old, new)
    try:
        check_wiring(sources["bridge"], sources["controller"], sources["window"])
    except (AssertionError, ValueError):
        continue
    raise SystemExit(f"negative control passed: {name}")
print(f"All {len(MUTATIONS)} wiring negative controls failed as expected")
