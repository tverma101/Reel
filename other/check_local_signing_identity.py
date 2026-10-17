#!/usr/bin/env python3
"""Verify that the installed Reel requirement accepts different builds from the same signer."""

import argparse
from pathlib import Path
import re
import subprocess
import tempfile


def run(*args, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, check=True, **kwargs)


def signature(path):
    result = run("/usr/bin/codesign", "-dvvv", "-r-", str(path))
    details = result.stdout + result.stderr
    requirement = re.search(r"^designated => (.+)$", details, re.MULTILINE).group(1)
    cdhash = re.search(r"^CDHash=(.+)$", details, re.MULTILINE).group(1)
    assert 'anchor apple generic' in requirement, "Reel must have an Apple-issued signing identity"
    assert 'cdhash ' not in requirement, "a binary-hash identity cannot survive rebuilds"
    return requirement, cdhash


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--app", type=Path, default=Path("/Applications/Reel.app"))
parser.add_argument("--signing-identity", default="Apple Development")
args = parser.parse_args()
installed_requirement, _ = signature(args.app)
hashes = []
with tempfile.TemporaryDirectory(prefix="reel-signing-") as folder:
    for index in (1, 2):
        binary = Path(folder) / f"build-{index}"
        run("/usr/bin/xcrun", "clang", "-x", "c", "-", "-o", str(binary),
            input=f"int main(void) {{ return {index}; }}\n")
        run("/usr/bin/codesign", "--force", "--options", "runtime", "--sign", args.signing_identity,
            "--identifier", "io.github.tverma101.reel", str(binary))
        requirement, cdhash = signature(binary)
        assert requirement == installed_requirement, "the app and rebuilds must retain the same requirement"
        run("/usr/bin/codesign", "--verify", "--strict", "-R=" + installed_requirement, str(binary))
        hashes.append(cdhash)
assert len(set(hashes)) == 2, "the regression must use different executable contents"
print("Stable signing identity passed: Reel's requirement accepts two differently hashed builds")
