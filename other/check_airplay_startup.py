#!/usr/bin/env python3
"""Measure the bridge hold/release against the bundled libmpv, including the old-speed control."""

from pathlib import Path
import re
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "iina/AirPlayAudioBridge.swift").read_text()
hold_speed = re.search(r"private static let holdSpeed = ([0-9.]+)", source).group(1)
ffmpeg = shutil.which("ffmpeg")
assert ffmpeg, "ffmpeg is required for the startup fixture"

C_SOURCE = r'''
#include <mpv/client.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static double audio_pts(mpv_handle *h) {
  double value = 0;
  if (mpv_get_property(h, "audio-pts", MPV_FORMAT_DOUBLE, &value) < 0) exit(3);
  return value;
}

int main(int argc, char **argv) {
  if (argc != 3) return 2;
  mpv_handle *h = mpv_create();
  if (!h) return 3;
  const char *options[][2] = {
    {"config", "no"}, {"terminal", "no"}, {"vo", "null"}, {"ao", "null"},
    {"sid", "no"}, {"audio-pitch-correction", "yes"},
  };
  for (size_t i = 0; i < sizeof(options) / sizeof(options[0]); i++) {
    if (mpv_set_option_string(h, options[i][0], options[i][1]) < 0) return 3;
  }
  if (mpv_initialize(h) < 0) return 3;
  const char *load[] = {"loadfile", argv[1], NULL};
  if (mpv_command(h, load) < 0) return 3;
  for (;;) {
    mpv_event *event = mpv_wait_event(h, 5);
    if (event->event_id == MPV_EVENT_FILE_LOADED) break;
    if (event->event_id == MPV_EVENT_NONE || event->event_id == MPV_EVENT_END_FILE) return 3;
  }
  usleep(1000000);
  if (mpv_set_property_string(h, "speed", argv[2]) < 0) return 3;
  usleep(1000000);
  if (mpv_set_property_string(h, "speed", "1") < 0) return 3;
  double before = audio_pts(h);
  usleep(1500000);
  double advanced = audio_pts(h) - before;
  printf("hold=%s audio clock advanced %.3fs during 1.5s after release\n", argv[2], advanced);
  mpv_terminate_destroy(h);
  return advanced > 0.6 ? 0 : 1;
}
'''

with tempfile.TemporaryDirectory(prefix="reel-startup-") as folder:
    folder = Path(folder)
    media = folder / "fixture.mp4"
    subprocess.run([
        ffmpeg, "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24:duration=20",
        "-f", "lavfi", "-i", "sine=sample_rate=48000:duration=20", "-c:v", "mpeg4", "-c:a", "aac",
        "-y", str(media),
    ], check=True)
    c_file = folder / "startup.c"
    binary = folder / "startup"
    c_file.write_text(C_SOURCE)
    libraries = str(ROOT / "deps/lib")
    subprocess.run([
        "xcrun", "clang", "-O2", "-Wall", "-Werror", "-I", str(ROOT / "deps/include"),
        str(c_file), "-L", libraries, f"-Wl,-rpath,{libraries}", "-lmpv.2", "-o", str(binary),
    ], check=True)
    for speed, expected_success in [(hold_speed, True), ("0.01", False)]:
        result = subprocess.run([str(binary), str(media), speed], capture_output=True,
                                text=True, timeout=15)
        print(result.stdout.strip())
        assert (result.returncode == 0) == expected_success, result.stdout + result.stderr
    print("Startup recovery passed; the previous 0.01x hold fails the same clock-progress check")
