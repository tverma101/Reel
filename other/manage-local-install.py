#!/usr/bin/env python3
"""Keep /Applications/Reel.app as the only registered local Reel copy."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone
import zipfile


IDENTIFIER = "io.github.tverma101.reel"
INSTALLED = Path("/Applications/Reel.app")
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
AUDIT_SWIFT = '''import AppKit
let workspace = NSWorkspace.shared
let result: [String: Any] = [
  "preferred": workspace.urlForApplication(withBundleIdentifier: "io.github.tverma101.reel")?.path ?? "NONE",
  "copies": workspace.urlsForApplications(withBundleIdentifier: "io.github.tverma101.reel").map(\\.path),
  "running": workspace.runningApplications.filter { $0.bundleIdentifier == "io.github.tverma101.reel" }.map { $0.bundleURL?.path ?? "NONE" }
]
print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
'''


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed ({result.returncode}): {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def identity(app):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != IDENTIFIER or app.suffix != ".app" or app.is_symlink():
        raise RuntimeError(f"Not an ordinary Reel app bundle: {app}")
    return info


def audit():
    with tempfile.TemporaryDirectory(prefix="iina-registration-") as folder:
        source = Path(folder) / "audit.swift"
        source.write_text(AUDIT_SWIFT)
        return json.loads(run("/usr/bin/xcrun", "swift", str(source)))


def registrations():
    dump = run(LSREGISTER, "-dump")
    paths = []
    for block in dump.split("--------------------------------------------------------------------------------"):
        if re.search(r"^identifier:\s+com\.colliderli\.iina\s*$", block, re.M):
            match = re.search(r"^path:\s+(.*?) \(0x", block, re.M)
            if match:
                paths.append(Path(match[1]))
    return list(dict.fromkeys(paths))


def discoverable_copies():
    paths = run("/usr/bin/mdfind", f'kMDItemCFBundleIdentifier == "{IDENTIFIER}"').splitlines()
    return [Path(p) for p in paths if Path(p).exists()]


def archive(app, support):
    info = identity(app)
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    executable_hash = sha256(executable)
    # Reuse an earlier backup only if every file and symlink still matches.
    for candidate in sorted((support / "Backups").glob(f"{app.stem}-*-{executable_hash[:12]}.zip")):
        with zipfile.ZipFile(candidate) as bundle:
            matches = True
            source_entries = set()
            for path in app.rglob("*"):
                member = f"{app.name}/{path.relative_to(app)}"
                if path.is_symlink():
                    expected = os.readlink(path).encode()
                elif path.is_file():
                    expected = None
                else:
                    continue
                source_entries.add(member)
                try:
                    with bundle.open(member) as stream:
                        digest = hashlib.file_digest(stream, "sha256").hexdigest()
                    source_digest = hashlib.sha256(expected).hexdigest() if expected is not None else sha256(path)
                    if digest != source_digest:
                        matches = False
                        break
                except (KeyError, zipfile.BadZipFile):
                    matches = False
                    break
            archived_entries = {n for n in bundle.namelist() if n.startswith(f"{app.name}/") and not n.endswith("/")}
            if matches and archived_entries == source_entries:
                print(f"Reusing verified backup: {candidate}", flush=True)
                return {"original": str(app), "archive": str(candidate), "executableSHA256": executable_hash}
    name = f"{app.stem}-{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}-{executable_hash[:12]}.zip"
    destination = support / "Backups" / name
    # ditto retains resource forks, extended attributes, permissions, and bundle symlinks.
    run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(destination))
    with zipfile.ZipFile(destination) as bundle:
        if bundle.testzip() is not None:
            raise RuntimeError(f"Damaged backup: {destination}")
        archived_exec = bundle.read(f"{app.name}/Contents/MacOS/{info['CFBundleExecutable']}")
        if hashlib.sha256(archived_exec).hexdigest() != executable_hash:
            raise RuntimeError(f"Backup executable differs: {destination}")
        if bundle.read(f"{app.name}/Contents/Info.plist") != (app / "Contents/Info.plist").read_bytes():
            raise RuntimeError(f"Backup Info.plist differs: {destination}")
    record = {"original": str(app), "archive": str(destination),
              "version": info.get("CFBundleShortVersionString"), "build": info.get("CFBundleVersion"),
              "executableSHA256": executable_hash, "archiveSHA256": sha256(destination)}
    with (support / "Backups/archive-manifest.jsonl").open("a") as manifest:
        manifest.write(json.dumps(record) + "\n")
    print(f"Verified backup: {destination}", flush=True)
    return record


def repair(support):
    identity(INSTALLED)
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(INSTALLED))
    before = audit()
    if before["running"]:
        raise RuntimeError("Quit IINA before retiring its other copies.")
    paths = registrations()
    registered_apps = set(paths)
    paths.extend(Path(p) for p in before["copies"])
    paths.extend(discoverable_copies())
    extras = list(dict.fromkeys(p for p in paths if p != INSTALLED))
    plugins = run("/usr/bin/pluginkit", "-m", "-A", "-D", "-v", "-i", IDENTIFIER + ".OpenInIINA")
    registered_plugins = {Path(m) for m in re.findall(r"\t(/[^\n]+)$", plugins, re.M)}
    # Preflight every live extra before changing anything. Never retire other users' apps.
    for app in extras:
        if app.exists():
            identity(app)
            if not app.resolve().is_relative_to(Path.home()) or app.stat().st_uid != os.getuid():
                raise RuntimeError(f"Extra IINA copy requires manual review: {app}")
    retired = []
    for app in extras:
        if app.exists():
            record = archive(app, support)
            # Unregister the extension while its containing bundle still exists.
            for plugin in (app / "Contents/PlugIns").glob("*.appex"):
                if plugin in registered_plugins:
                    run("/usr/bin/pluginkit", "-r", str(plugin))
            if app in registered_apps:
                run(LSREGISTER, "-u", str(app))
            shutil.rmtree(app)
            retired.append(record)
        else:
            run(LSREGISTER, "-u", str(app))
    run(LSREGISTER, "-f", str(INSTALLED))
    after = audit()
    after["registered"] = [str(p) for p in registrations()]
    if (after["preferred"] != str(INSTALLED) or after["copies"] != [str(INSTALLED)]
            or after["registered"] != [str(INSTALLED)]):
        raise RuntimeError(f"IINA registration still ambiguous: {after}")
    return {"before": before, "after": after, "retired": retired}


def install(source, support):
    source = source.resolve()
    identity(source)
    if source == INSTALLED:
        raise RuntimeError("Build source must differ from /Applications/Reel.app.")
    if not source.is_relative_to(Path.home()):
        raise RuntimeError("Local build source must be in the current user's home folder.")
    if audit()["running"]:
        raise RuntimeError("Quit IINA before replacing the installed build.")
    # A stage without the .app suffix avoids introducing another discoverable application.
    with tempfile.TemporaryDirectory(prefix=".iina-install-", dir=INSTALLED.parent) as folder:
        stage = Path(folder) / "IINA.bundle-stage"
        run("/usr/bin/ditto", str(source), str(stage))
        run("/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(stage))
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(stage))
        if INSTALLED.exists():
            archive(INSTALLED, support)
            old = Path(folder) / "previous.bundle-stage"
            INSTALLED.rename(old)
        try:
            stage.rename(INSTALLED)
            run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(INSTALLED))
        except Exception:
            if INSTALLED.exists():
                shutil.rmtree(INSTALLED)
            if 'old' in locals():
                old.rename(INSTALLED)
            raise
    # Register the source so repair also archives an undiscovered build output.
    run(LSREGISTER, "-f", str(source))
    return repair(support)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["check", "repair", "install"])
    parser.add_argument("app", nargs="?", type=Path, help="build product for install; archived and retired afterward")
    parser.add_argument("--support-folder", type=Path, default=Path.home() / "Documents/IINA")
    args = parser.parse_args()
    if (args.action == "install") != (args.app is not None):
        parser.error("Only install requires an app path.")
    if args.action == "check":
        result = audit()
        result["registered"] = [str(p) for p in registrations()]
        result["discoverable"] = [str(p) for p in discoverable_copies()]
        print(json.dumps(result, indent=2))
        return 0 if (result["preferred"] == str(INSTALLED)
                     and result["copies"] == [str(INSTALLED)]
                     and result["registered"] == [str(INSTALLED)]
                     and set(result["discoverable"]) <= {str(INSTALLED)}) else 1
    support = args.support_folder.expanduser().resolve()
    for folder in [support, support / "Backups", support / "Validation"]:
        folder.mkdir(parents=True, exist_ok=True)
        folder.chmod(0o700)
    result = install(args.app, support) if args.action == "install" else repair(support)
    evidence = support / "Validation" / f"registration-{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}.json"
    evidence.write_text(json.dumps(result, indent=2) + "\n")
    print(f"IINA resolves only to {INSTALLED}. Evidence: {evidence}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        raise SystemExit(str(error))
