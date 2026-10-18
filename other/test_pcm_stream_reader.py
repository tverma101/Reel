"""Check the AirPlay audio bridge's decoder and WAV stream against mpv's own timeline.

FFmpegPCMStreamReader (iina/FFmpegController.m) must place every sample where mpv plays it, after
any seek, or the speaker and the picture drift apart. The reference is the bundled libmpv decoding
the same file. AirPlayPCMResourceLoader (iina/AirPlayAudioBridge.swift) is then played in a muted
AVPlayer. Needs the downloaded deps (`other/download_libs.sh`) and an ffmpeg command to make
test media.

Set `REEL_TEST_AUDIO_UID` to an AVPlayer output-device UID (for example,
`BuiltInSpeakerDevice`) to keep this muted playback check independent of the Mac's current route.
"""

import os
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
SAMPLE_RATE = 48000
DURATION = 60.0
# Matroska rounds timestamps to the millisecond.
MAX_LAG_FRAMES = SAMPLE_RATE // 1000


def extract(path, start, end, after=None):
    """The text from `start` through the first `end` that follows `after` (default: `start`)."""
    text = path.read_text()
    begin = text.index(start)
    finish = text.index(end, text.index(after, begin) if after else begin)
    return text[begin:finish + len(end)]


@unittest.skipUnless((DEPS / "include/libavformat/avformat.h").is_file()
                     and (DEPS / "include/mpv/client.h").is_file()
                     and (LIBRARIES / "libmpv.2.dylib").is_file() and FFMPEG,
                     "downloaded FFmpeg/mpv development dependencies and an ffmpeg command are required")
class PCMStreamReader(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder = tempfile.TemporaryDirectory(prefix="reel-pcm-reader-")
        work = Path(cls.folder.name)
        interface = extract(ROOT / "iina/FFmpegController.h", "@interface FFmpegPCMStreamReader", "@end")
        (work / "pcm_stream_reader.h").write_text("#import <Foundation/Foundation.h>\n" + interface + "\n")
        implementation = extract(ROOT / "iina/FFmpegController.m", "// MARK: - FFmpegPCMStreamReader",
                                 "\n@end", after="@implementation FFmpegPCMStreamReader")
        (work / "pcm_stream_reader.m").write_text("\n".join([
            "#import <Foundation/Foundation.h>", "#include <errno.h>", "#include <limits.h>",
            '#import "FFmpegAudioLimits.h"', "#import <libavcodec/avcodec.h>",
            "#import <libavformat/avformat.h>", "#import <libavutil/channel_layout.h>",
            "#import <libswresample/swresample.h>", '#import "pcm_stream_reader.h"', implementation, ""]))
        loader = extract(ROOT / "iina/AirPlayAudioBridge.swift", "// MARK: - WAV stream", "// MARK: - Bridge")
        (work / "loader.swift").write_text("import AVFoundation\nimport Foundation\n\n" + loader + "\n")
        # Top-level statements are allowed only in main.swift.
        shutil.copyfile(ROOT / "other/test_pcm_stream_reader_loader.swift", work / "main.swift")

        libraries = str(LIBRARIES)
        link = ["-L", libraries, f"-Wl,-rpath,{libraries}", "-lavcodec.63", "-lavformat.63", "-lavutil.61",
                "-lswresample.7"]
        clang = ["/usr/bin/xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-O2", "-Wall", "-Wextra",
                 "-Wno-unused-parameter", "-Werror", "-I", str(DEPS / "include"), "-I", str(ROOT / "iina"),
                 "-I", str(work)]
        cls.run_checked(clang + ["-c", str(work / "pcm_stream_reader.m"), "-o", str(work / "reader.o")])
        cls.reader = work / "reader"
        cls.run_checked(clang + [str(work / "reader.o"), str(ROOT / "other/test_pcm_stream_reader.m"),
                                 "-framework", "Foundation", *link, "-o", str(cls.reader)])
        cls.mpv = work / "mpv"
        cls.run_checked(["/usr/bin/xcrun", "--sdk", "macosx", "clang", "-O2", "-Wall", "-Werror",
                         "-I", str(DEPS / "include"), str(ROOT / "other/test_pcm_stream_reader_mpv.c"),
                         "-L", libraries, f"-Wl,-rpath,{libraries}", "-lmpv.2", "-o", str(cls.mpv)])
        cls.loader = work / "loader"
        cls.run_checked(["/usr/bin/xcrun", "--sdk", "macosx", "swiftc", "-O",
                         "-import-objc-header", str(work / "pcm_stream_reader.h"), str(work / "loader.swift"),
                         str(work / "main.swift"), str(work / "reader.o"),
                         "-L", libraries, "-Xlinker", "-rpath", "-Xlinker", libraries, "-lavcodec.63",
                         "-lavformat.63", "-lavutil.61", "-lswresample.7", "-o", str(cls.loader)])

        # Noise at 44.1 kHz, so the reader resamples, beside a video track, whose index is the only
        # one Matroska writes. It is band-limited like a soundtrack: mpv's resampler filters
        # differently near the top of the band. MPEG-TS starts at about 1.4 s, so mpv's timeline
        # origin matters.
        cls.media = {}
        mkv = work / "media.mkv"
        cls.run_checked([FFMPEG, "-v", "error", "-y",
                         "-f", "lavfi", "-i", f"testsrc2=size=320x240:rate=24:duration={DURATION}",
                         "-f", "lavfi", "-i", f"anoisesrc=d={DURATION}:c=pink:r=44100:a=0.3:seed=7",
                         "-filter_complex", "[1:a]lowpass=f=4000,lowpass=f=4000,pan=stereo|c0=c0|c1=0.5*c0[a]",
                         "-map", "0:v", "-map", "[a]", "-c:v", "mpeg4", "-g", "48", "-c:a", "aac",
                         "-b:a", "192k", str(mkv)])
        cls.media["mkv"] = mkv
        for name, extra in [("ts", ["-f", "mpegts"]), ("mp4", [])]:
            path = work / f"media.{name}"
            cls.run_checked([FFMPEG, "-v", "error", "-y", "-i", str(mkv), "-c", "copy", *extra, str(path)])
            cls.media[name] = path

    @classmethod
    def tearDownClass(cls):
        cls.folder.cleanup()

    @staticmethod
    def run_checked(command):
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
        if result.returncode != 0:
            raise AssertionError(f"{command[0]} failed ({result.returncode}):\n{result.stdout}\n{result.stderr}")
        return result.stdout

    def run_tool(self, *arguments):
        environment = dict(os.environ, DYLD_LIBRARY_PATH=str(LIBRARIES))
        result = subprocess.run([str(argument) for argument in arguments], cwd=ROOT, env=environment,
                                capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, f"{arguments[0]}:\n{result.stdout}\n{result.stderr}")
        return result.stdout

    def test_reader_matches_mpv_timeline(self):
        starts = {}
        for name, path in self.media.items():
            for start in [7.3, 31.05, 52.5]:
                with self.subTest(media=name, start=start):
                    raw = Path(self.folder.name) / f"mpv-{name}-{start}.raw"
                    output = self.run_tool(self.mpv, path, 1, start, 4, raw)
                    origin = float(re.search(r"demuxer-start-time=(\S+)", output).group(1))
                    starts[name] = origin
                    result = self.run_tool(self.reader, "compare", path, 1, origin, start, raw)
                    match = re.search(r"compare lag=(-?\d+) corr=(\S+)", result)
                    self.assertIsNotNone(match, result)
                    self.assertLessEqual(abs(int(match.group(1))), MAX_LAG_FRAMES, result)
                    self.assertGreaterEqual(float(match.group(2)), 0.99, result)
        self.assertGreater(starts["ts"], 1, "the MPEG-TS case should exercise a non-zero origin")

    def test_seeks_match_sequential_decode(self):
        for name, path in self.media.items():
            with self.subTest(media=name):
                output = self.run_tool(self.reader, "seeks", path, 1)
                reads = re.findall(r"^(seek|skip|reread) (\S+) lag=(\S+) corr=(\S+)$", output, re.MULTILINE)
                self.assertEqual(len(reads), 8, output)
                for kind, offset, lag, corr in reads:
                    self.assertNotEqual(lag, "nil", f"{kind} {offset}: {output}")
                    self.assertLessEqual(abs(int(lag)), MAX_LAG_FRAMES, f"{kind} {offset}: {output}")
                    self.assertGreaterEqual(float(corr), 0.99, f"{kind} {offset}: {output}")
                self.assertIn("end ok nonzero=0", output)
                for line in ["oversize rejected", "negative rejected", "cancelled nil failed=1",
                             "after-failure nil", "video-stream rejected"]:
                    self.assertIn(line, output)

    def test_wav_stream_plays_and_seeks_in_avplayer(self):
        output = self.run_tool(self.loader, self.media["mkv"], 1, DURATION)
        ready = re.search(r"ready status=(\d) seconds=(\S+) duration=(\S+) expected=(\S+)", output)
        self.assertIsNotNone(ready, output)
        self.assertEqual(ready.group(1), "1", output)
        self.assertLess(float(ready.group(2)), 3, output)
        self.assertAlmostEqual(float(ready.group(3)), float(ready.group(4)), places=2)
        self.assertGreater(float(re.search(r"play advanced=(\S+)", output).group(1)), 0.5, output)
        seeks = re.findall(r"seek target=(\S+) finished=(\d) landed=(\S+) advanced=(\S+)", output)
        self.assertEqual(len(seeks), 2, output)
        for target, finished, landed, advanced in seeks:
            self.assertEqual(finished, "1", output)
            self.assertAlmostEqual(float(landed), float(target), delta=0.01)
            self.assertGreater(float(advanced), 0.3, output)
        self.assertIn("done status=1", output)


if __name__ == "__main__":
    unittest.main()
