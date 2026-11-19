"""Check the AirPlay bridge's guard against mpv losing its audio output during a playback restart.

The bridge switches mpv's `ao` to `null` and reloads it. If that lands after mpv has opened its audio
output for a file start or a seek, but before playback has restarted, mpv drops the output and never
restarts: the picture stays on its first frame, silent, until the next seek. mpv re-seeks after a
reload only once audio is playing. This reproduced on every resume of a saved position with AirPlay
active. The bridge seeks in place when a reply shows that a switch ran in that window
(`MPVAirPlaySnapshot.playbackRestartPending`).

Runs the bundled libmpv with the `null` audio output only, so it makes no sound. Needs the downloaded
deps (`other/download_libs.sh`) and an ffmpeg command to make test media.
"""

from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
DEPS = ROOT / "deps"
LIBRARIES = DEPS / "lib"
FFMPEG = shutil.which("ffmpeg")


def between(text, start, end):
    """From `start` up to the first `end` after it."""
    begin = text.index(start)
    return text[begin:text.index(end, begin + len(start))]


class SourceWiring(unittest.TestCase):
    """The flag must follow mpv's own event order, and replies must carry it as of the command."""

    controller = (ROOT / "iina/MPVController.swift").read_text()
    bridge = (ROOT / "iina/AirPlayAudioBridge.swift").read_text()

    def test_restart_window_is_tracked_from_events(self):
        start = between(self.controller, "case MPV_EVENT_START_FILE:", "case MPV_EVENT_FILE_LOADED:")
        self.assertIn("snapshot.playbackRestartPending = true", start)
        loaded = between(self.controller, "case MPV_EVENT_FILE_LOADED:", "activeFileTransitionGeneration = nil")
        self.assertIn("snapshot.playbackRestartPending = true", loaded, "recovered START_FILE")
        seek = between(self.controller, "case MPV_EVENT_SEEK:", "DispatchQueue.main.async")
        self.assertIn("playbackRestartPending = true", seek, "must be set on the event thread")
        restart = between(self.controller, "case MPV_EVENT_PLAYBACK_RESTART:", "DispatchQueue.main.async")
        self.assertIn("snapshot.playbackRestartPending = false", restart)
        ended = between(self.controller, "case MPV_EVENT_END_FILE:", "DispatchQueue.main.async")
        self.assertIn("snapshot.playbackRestartPending = false", ended)

    def test_replies_carry_the_flag_read_on_the_event_thread(self):
        for event in ["case MPV_EVENT_COMMAND_REPLY:", "case MPV_EVENT_SET_PROPERTY_REPLY:"]:
            reply = between(self.controller, event, "case MPV_EVENT_")
            body = reply[reply.index("isAirPlayAudioCommand(reply)"):]
            captured = body.index("let restartPending = $airPlaySnapshot.withLock")
            self.assertLess(captured, body.index("DispatchQueue.main.async"), event)
            self.assertIn("playbackRestartPending: restartPending", body, event)

    def test_bridge_seeks_in_place_after_an_output_switch_in_the_window(self):
        completed = between(self.bridge, "func mpvCommandCompleted(", "private func refreshSeekAfterAudioOutputChange")
        self.assertRegex(completed, r"result >= 0, playbackRestartPending,\s+request\.operation\.isAudioOutputSetter"
                                    r" \|\| request\.operation\.name == \"ao-reload\" \{\s+"
                                    r"refreshSeekAfterAudioOutputChange\(\)\s+\}")
        refresh = between(self.bridge, "private func refreshSeekAfterAudioOutputChange()", "\n  }\n")
        self.assertIn('enqueueMPVCommand(.seek, arguments: ["0", "relative+exact"]', refresh)
        fallback = between(self.controller, "func restoreAirPlayAudioOutput(", "completion(result")
        reload = fallback.index('command(rawString: "ao-reload"')
        self.assertLess(reload, fallback.index('"seek 0 relative+exact"'),
                        "the synchronous restore fallback reloads too")


@unittest.skipUnless((DEPS / "include/mpv/client.h").is_file() and (LIBRARIES / "libmpv.2.dylib").is_file()
                     and FFMPEG, "downloaded mpv development dependencies and an ffmpeg command are required")
class ReloadDuringRestart(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder = tempfile.TemporaryDirectory(prefix="reel-ao-reload-")
        work = Path(cls.folder.name)
        cls.driver = work / "driver"
        libraries = str(LIBRARIES)
        cls.run_checked(["/usr/bin/xcrun", "--sdk", "macosx", "clang", "-O2", "-Wall", "-Werror",
                         "-I", str(DEPS / "include"), str(ROOT / "other/test_airplay_ao_reload_restart.c"),
                         "-L", libraries, f"-Wl,-rpath,{libraries}", "-lmpv.2", "-o", str(cls.driver)])
        # Twenty-second keyframe intervals make the precise seek decode for a while before playback
        # restarts, which holds the window open for the driver.
        cls.media = work / "media.mkv"
        cls.run_checked([FFMPEG, "-v", "error", "-y",
                         "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30:duration=60",
                         "-f", "lavfi", "-i", "sine=frequency=440:duration=60",
                         "-c:v", "mpeg4", "-g", "600", "-q:v", "4", "-c:a", "aac", str(cls.media)])

    @classmethod
    def tearDownClass(cls):
        cls.folder.cleanup()

    @staticmethod
    def run_checked(command):
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
        if result.returncode != 0:
            raise AssertionError(f"{command[0]} failed ({result.returncode}):\n{result.stdout}\n{result.stderr}")
        return result.stdout

    def restart(self, refresh):
        """Whether playback restarted, from a run whose reload landed in the window."""
        for _ in range(5):
            output = subprocess.run([str(self.driver), str(self.media), "39.5", str(refresh)], cwd=ROOT,
                                    capture_output=True, text=True, timeout=60).stdout
            if "window=hit" in output:
                return re.search(r"restarted=(\d)", output).group(1) == "1"
        self.fail(f"the reload never landed before playback restarted:\n{output}")

    def test_reload_during_restart_loses_playback(self):
        # Negative control. If a newer libmpv recovers by itself, the bridge's seek is redundant.
        self.assertFalse(self.restart(refresh=0), "mpv now restarts after a reload in the window")

    def test_seek_in_place_restarts_playback(self):
        self.assertTrue(self.restart(refresh=1))


if __name__ == "__main__":
    unittest.main()
