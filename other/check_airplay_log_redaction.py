#!/usr/bin/env python3
"""Prevent bearer tokens from network media URLs from entering AirPlay logs."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "iina/AirPlayAudioBridge.swift").read_text()

def extract(marker):
    start = SOURCE.index(marker)
    opening = SOURCE.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (SOURCE[end] == "{") - (SOURCE[end] == "}")
        end += 1
    return SOURCE[start:end]

HELPER = extract("enum AirPlayAudioSourceLog {")
assert "AirPlayAudioSourceLog.displayName(for: selection.source)" in SOURCE
assert "URL(fileURLWithPath: selection.source).lastPathComponent" not in SOURCE

HARNESS = r'''import Foundation
__HELPER__
func check(_ ok: @autoclosure () -> Bool, _ label: String) {
  guard ok() else { print("FAIL: " + label); exit(1) }
}
let tokenURL = "https://user:password@cdn.example.net/signed/BearerXYZ/audio.mp4?token=SECRET123"
let network = AirPlayAudioSourceLog.displayName(for: tokenURL)
check(network == "network stream" && !network.contains("SECRET123") &&
      !network.contains("BearerXYZ") && !network.contains("password"),
      "signed network URL leaked into AirPlay log")
check(AirPlayAudioSourceLog.displayName(for:
      "HTTPS://cdn.example.net/watch?session=SECRET123") == "network stream",
      "mixed-case HTTPS log leaked token")
check(AirPlayAudioSourceLog.displayName(for:
      "/Users/me/Videos/Clip 01.mkv") == "Clip 01.mkv",
      "local file diagnostic filename lost")
print("AirPlay network URL log-redaction checks passed")
'''
def run(helper):
    with tempfile.TemporaryDirectory(prefix="reel-airplay-log-") as temp:
        path = Path(temp) / "main.swift"
        exe = Path(temp) / "check"
        path.write_text(HARNESS.replace("__HELPER__", helper))
        compiled = subprocess.run(["swiftc", str(path), "-o", str(exe)],
                                  capture_output=True, text=True)
        assert compiled.returncode == 0, compiled.stdout + compiled.stderr
        return subprocess.run([str(exe)], capture_output=True, text=True, timeout=10)

positive = run(HELPER)
assert positive.returncode == 0, positive.stdout + positive.stderr
print(positive.stdout.strip())
bad = HELPER.replace('return "network stream"', 'return URL(fileURLWithPath: source).lastPathComponent')
assert bad != HELPER
negative = run(bad)
assert negative.returncode != 0 and "signed network URL" in negative.stdout, negative.stdout
print("Unredacted network URL negative control failed as expected")
