"""Exercise the caption decoder's channel-inclusive FFmpeg frame limit offline."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
LIBRARIES = ROOT / "deps/lib"


@unittest.skipUnless((ROOT / "deps/include/libavcodec/avcodec.h").is_file()
                     and (LIBRARIES / "libavcodec.63.dylib").is_file()
                     and (LIBRARIES / "libavutil.61.dylib").is_file(),
                     "downloaded arm64/x86_64 FFmpeg development dependencies are required")
class FFmpegAudioSampleBound(unittest.TestCase):
    def test_mono_and_multichannel_boundary_and_overflow(self):
        with tempfile.TemporaryDirectory(prefix="reel-ffmpeg-samples-") as folder:
            binary = Path(folder) / "sample-bound"
            libraries = str(LIBRARIES)
            subprocess.run([
                "/usr/bin/xcrun", "--sdk", "macosx", "clang", "-Wall", "-Wextra", "-Werror",
                "-I", str(ROOT / "deps/include"), "-I", str(ROOT / "iina"),
                str(ROOT / "other/test_ffmpeg_audio_sample_bound.c"),
                "-L", str(LIBRARIES), f"-Wl,-rpath,{libraries}",
                "-lavcodec.63", "-lavutil.61", "-o", str(binary),
            ], check=True, cwd=ROOT, capture_output=True, text=True)
            environment = dict(os.environ, DYLD_LIBRARY_PATH=libraries)
            result = subprocess.run([str(binary)], check=True, cwd=ROOT, env=environment,
                                    capture_output=True, text=True)
            self.assertIn("channels=1 samples_per_channel=524288 total_samples=524288 decoded=1",
                          result.stdout)
            self.assertIn("channels=1 samples_per_channel=524289 total_samples=524289 decoded=0",
                          result.stdout)
            self.assertIn("total_samples=49152 decoded=1", result.stdout)
            self.assertIn("total_samples=524286 decoded=1", result.stdout)
            self.assertIn("total_samples=524292 decoded=0", result.stdout)
            self.assertIn("total_samples=524288 decoded=1", result.stdout)
            self.assertIn("total_samples=524296 decoded=0", result.stdout)
            self.assertIn("channels=32 samples_per_channel=16384 total_samples=524288 decoded=1",
                          result.stdout)
            self.assertIn("channels=32 samples_per_channel=16385 total_samples=524320 decoded=0",
                          result.stdout)


if __name__ == "__main__":
    unittest.main()
