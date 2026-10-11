# Local macOS installation

The installed local fork lives at `/Applications/Reel.app`. Keep one runnable copy of this
bundle identifier (`io.github.tverma101.reel`): macOS chooses between registered copies using its
own launch heuristics. Renaming a backup to another `.app` name does not give it a separate identity.

The paths below are one machine's local layout, not a requirement. The source
checkout is `~/Projects/iina`, and local support files live at `~/Documents/IINA`:

| Folder | Purpose |
| --- | --- |
| `Source` | Link to the canonical checkout |
| `Backups` | Verified ZIP archives, archive manifest, and preserved preinstall preferences |
| `Validation` | Build logs and registration evidence |
| `Test Media` | Local caption and playback fixtures |
| `Build.noindex` | Xcode cache for future local builds |

## Build and install

Build from a committed, canonical Reel checkout, increasing `CURRENT_PROJECT_VERSION` for each
published build and keeping it monotonic across marketing-version changes. The app embeds the
checked-out commit, version, build number, and Xcode configuration; the installer
rejects stale metadata, non-Release products, downgrades, reused build numbers for a new commit,
and commits that are not descendants of the installed build. Close every Reel copy before
installing. Install and repair serialize through a private lock next to `/Applications/Reel.app`;
they also take the same private
launch-transition lock under `~/Library/Caches` that the Desktop command holds through its final
bundle verification, profile migration, LaunchServices request, and bounded startup check. A
durable `~/Library/Caches/.reel-launch-handoff.json` record is published before the open
request. A timed-out or otherwise uncertain request leaves the record pending; install and repair
then fail closed even after the launcher releases its lock, so updates remain blocked while a delayed
LaunchServices request is possible. The launcher clears the record only after observing the canonical Reel
process and a matching private acknowledgement from AppDelegate for that exact immutable playlist path.
AppDelegate publishes the acknowledgement atomically only after `PlayerCore.openURLs` accepts the path;
this proves handoff to that API, not that mpv finished parsing or consumed the playlist. A missing,
unsafe, or mismatched acknowledgement leaves both the pending record and playlist snapshot in place.
Acknowledgements are owner-only files under
`~/Library/Caches/TotalDramaPlayer/.playlist-accepted-<token>.json`; the launcher retains at most 256
bounded acknowledgements for seven days and refuses a new handoff if the cache cannot safely make room.
Install/repair clear only a well-formed confirmed record. If a pending handoff remains after the
launcher’s bounded process or AppDelegate acknowledgement wait, recovery is an explicit operator action. In Terminal,
run:

```sh
bash "$HOME/Desktop/Total Drama Player.command" --recover-pending-handoff \
  --accept-unknown-launchservices-queue-risk
```

Recovery takes the launcher and shared transition locks. The additional flag is a deliberate
acknowledgement that LaunchServices does not expose whether a timed-out request remains queued; the
24-hour wait is not proof that it was cancelled. Do not recover unless you accept that residual risk.
Recovery clears a pending record only when it is valid and unchanged, it is at least 24 hours old,
the original recorded launcher process is gone (or its PID belongs to a different process), and no
Reel process is running. A private process-start identity in the owner-only sibling
`~/Library/Caches/.reel-launch-handoff-identity.json` distinguishes
the original launcher from a reused PID; if a live PID's identity is missing, corrupt, or cannot be
checked, recovery refuses. Recovery does not launch Reel or import playback data. A missing record is
a no-op; a confirmed record can be cleared. Recovery refuses and preserves
the record if it is less than 24 hours old, its timestamp is more than five minutes in the future,
the original launcher is still present, a live PID's identity cannot be checked, any Reel process is
running or cannot be ruled out, the record changes, or lock/process inspection fails. Check the
system clock for a future timestamp. Investigate any refusal or corrupt/unsafe record; do not delete
the handoff file manually to unblock an update.
Target validation and rollback remain inside both locks. The installer
verifies the bundle identity, signs the staged bundle ad hoc, archives the current
`/Applications/Reel.app`, and rechecks that Reel is not running immediately before the swap. It
preserves the build product, source files, dependency caches, and other applications. It never
deletes another `.app` copy automatically.

The normal error path attempts an atomic rollback if verification or registration fails. A forced
process kill or power loss after the directory swap can bypass that rollback: the canonical app may
be the candidate build while the previous bundle remains in
`/Applications/.reel-install-*/Reel.bundle-stage`; the verified archive remains under `Backups`.
The next install/repair does not automatically reconcile that hidden stage or roll back the build.
Preserve both the stage and archive, inspect the read-only install check and validation record, and
use a separately reviewed recovery procedure before removing or restoring either bundle.
After the swap it verifies that Launch Services prefers the canonical app and registers the embedded
Open In Reel extension; if that check fails, it atomically restores the previous bundle. Other
dormant development builds are preserved. Their presence is reported, and the Desktop command refuses
to route a playlist into a same-ID Reel process unless its executable is the canonical installed one.

```sh
mkdir -p "$HOME/Documents/IINA/Validation"
xcodebuild -project iina.xcodeproj -scheme iina -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$HOME/Documents/IINA/Build.noindex" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build \
  > "$HOME/Documents/IINA/Validation/build.log" 2>&1
```

After the build succeeds:

```sh
python3 other/manage-local-install.py install \
  "$HOME/Documents/IINA/Build.noindex/Build/Products/Release/Reel.app"
python3 other/manage-local-install.py check
```

Before installation, the offline installer rollback and bundle-integrity fixtures can be run with
`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest other/test_manage_local_install.py`. The caption
decoder's FFmpeg frame-bound regression can be exercised against the downloaded development
libraries with `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest other/test_ffmpeg_audio_sample_bound.py`.

These commands require Python 3.11 or later, Xcode command line tools, and write access to
`/Applications`. The old app archive is checked for integrity and matching executable and
Info.plist contents before replacement. A validation record includes the source commit, version,
executable hash, previous-app backup, and registration state before and after the install. A
distinct backup is retained for each installed executable; archives are not pruned automatically.
The verifier probes source and staged bundle extended attributes with bounded Darwin size-query
calls, including resource forks. It compares that inventory before signing the staged bundle.
For ZIP backups, it creates bounded canonical AppleDouble payloads with Darwin `copyfile` and
compares every archived sidecar byte-for-byte, so a missing, extra, or altered xattr/resource-fork
payload stops the install. Unsupported metadata probing or packing fails closed. Archive verification
is fail-closed: reuse scans at
most 4096 `Backups` entries, retains at most 64 matching archive candidates, and verifies only the
newest candidate for reuse. Each candidate source bundle is limited to 16 GiB and 100,000 entries.
The archive manifest is replaced atomically under a private sidecar lock: interruption before
replacement leaves the prior complete manifest, and interruption after replacement leaves the new
complete manifest. If the process stops after the verified ZIP is renamed into `Backups` but before
its manifest record is published, a later install can adopt that file only when its name matches the
installer's generated pattern and the complete ZIP, bundle inventory, metadata sidecars, and bounds
verify against the currently installed bundle. This retry leaves the ZIP unchanged and appends its
digest record; it never deletes unmatched files. The same 4096-entry scan and 64-candidate limits
apply during recovery. A verified journaled archive is reused only when its recorded SHA-256 still
matches.
The installer also creates its in-progress archive directory under `Backups` with
an exact `.Reel-archive-<32 lowercase hex>` name and a private ownership marker.
On a later run, the temp-artifact scan reads at most 4096 backup-folder entries
and considers at most 64 exact temp-directory names; the separate archive-reuse
scan has the same bounds. It removes a temp directory only when the owner-only marker
matches that directory token and a generated archive basename, and the directory
contains only that marker plus an optional owner-owned single-link regular
archive no larger than 17 GiB. Unknown names, malformed markers, symlinks,
hardlinks, or extra files are left untouched. The scan and candidate limits fail
closed before cleanup; the installer never recursively deletes a backup folder.
ZIP member bodies are streamed through a separate aggregate decompressed-byte
budget of 16.5 GiB, independent of the sizes declared in the ZIP central directory.
Before Python parses ZIP entries, the classic or Zip64 trailer is checked for a
maximum of 100,000 entries and a central directory no larger than 128 MiB.
The preflight also caps aggregate member-name bytes at 16 MiB and extra-field
plus comment bytes at 8 MiB before Python allocates per-entry objects. The
100,000-entry ceiling includes AppleDouble metadata members. These budgets
assume filesystem-derived Reel paths and small `ditto`/Python ZIP extra fields;
unusually path-heavy or metadata-heavy bundles above them are rejected. Bit-3
data descriptors are checked against central-directory CRC and sizes in classic
and Zip64 forms, with or without the optional signature; conflicting local
header placeholders fail closed. Unsupported or inconsistent trailer layouts
fail closed. Directory members are
also streamed and must have an actually empty body, even when their headers claim
zero uncompressed bytes; their compressed representation is capped at 1 KiB.
If a limit is exceeded or the inventory cannot be measured safely, installation or repair stops
before replacement. Keep enough free disk space for the new build and a recovery archive.

The Reel application bundle and its user profile are separate. Reel keeps using the bundle
identifier `io.github.tverma101.reel`; replacing `/Applications/Reel.app` therefore preserves
`~/Library/Application Support/io.github.tverma101.reel`, its preferences, playback history,
watch-later positions, plugins, and model files. Install and repair do not move or delete that
profile, and they do not merge or delete the separate upstream-IINA profile. Keeping the Reel
bundle identifier stable is what keeps these data in place across future app updates. Any future
profile-format migration must keep a recoverable backup and be documented before it changes data.

The Desktop `Total Drama Player.command` opens the canonical `/Applications/Reel.app` and keeps its
playlist cache, validated metadata cache, resume ledger, and immutable launch snapshots in
`~/Library/Caches/TotalDramaPlayer`. Valid metadata is reused for up to six hours; after that, the
launcher refreshes it and falls back to the last valid playlist if the network or metadata response
fails. After the final signed-bundle check, the launcher can import only an eligible per-URL playback
position from the separate upstream-IINA `watch_later` directory. It leaves original IINA saves in
place, does not copy IINA preferences or plugins, and never overwrites an existing Reel playback
position. A private ledger records consumed legacy save identities so the same unchanged save is not
reimported after Reel clears its active watch-later file; a later, changed legacy save is evaluated
again under the same precedence and validation rules. If a save was unreadable or oversized when
baselined, the launcher uses bounded file metadata until it can read the save. The first readable
observation after a same-inode permission-only change stays suppressed and captures a digest; later
content changes to that inode are then reconsidered. Reel watch-later filenames
use lowercase MD5 names, with read-only compatibility checks for uppercase names made by earlier
launcher candidates.
The import and playlist cache scans have fixed byte and entry limits; if a save, playlist, or cache
cannot be validated within those limits, the command refuses the unsafe migration or stale-URL
resume. The Reel application updater is intentionally manual, so installing a later build at the same
canonical path keeps the Desktop command and Reel profile pointing at the updated app.

## Check or repair registration

```sh
python3 other/manage-local-install.py check
python3 other/manage-local-install.py repair
```

`check` is read-only. It succeeds when Launch Services prefers `/Applications/Reel.app`, that app is
registered, and no other same-ID Reel executable is running. It also verifies the installed Open In
Reel extension registration. It reports other dormant copies without deleting or changing them.
`repair` requires Reel to be quit. It clears registrations only for app or extension paths that are
already missing, re-registers the canonical app, and preserves every existing build product. A live
alternate Reel process keeps the result in a review state; quit it and run `repair` again. Existing
file type defaults for other applications remain available.

Use the Desktop `Total Drama Player.command` for launches that must serialize with installation; it
targets the canonical app and holds the shared handoff lock. A direct `open -a /Applications/Reel.app`,
Finder, or Dock launch bypasses that lock. Do not start Reel from those paths while an install or
repair is in progress; the installer also rechecks for running copies before swapping, but cannot
serialize a direct launch that begins in the final check-to-swap interval. The durable launcher
handoff record protects only requests made through the Desktop command. Avoid launching a retained
Xcode product or using a restored copy for ordinary playback, since either can register another app
with the same bundle ID.

The installer uses the verified old-app archive for its automatic rollback if a replacement cannot
be registered successfully. The current CLI has no archive-restore or downgrade operation, and its
normal install action deliberately refuses older versions. Extracting an archive into `Build.noindex`
does not make it eligible for a normal install. Keep archives intact as recovery evidence; an
intentional rollback after a successful update requires a separately reviewed recovery procedure.
Keep backups compressed during normal use and prune them only after confirming that they are no
longer needed.

The registration check uses Apple's [NSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace)
application lookup APIs. Targeted cleanup uses the system `lsregister` tool rather than resetting
the entire Launch Services database.
