# Local macOS installation

The installed local fork lives at `/Applications/Reel.app`. Keep one runnable copy of this
bundle identifier (`io.github.tverma101.reel`): macOS chooses between registered copies using its
own launch heuristics. Renaming a backup to another `.app` name does not give it a separate identity.

The source checkout is `~/Projects/iina`. Local support files live at `~/Documents/IINA`:

| Folder | Purpose |
| --- | --- |
| `Source` | Link to the canonical checkout |
| `Backups` | Verified ZIP archives, archive manifest, and preserved preinstall preferences |
| `Validation` | Build logs and registration evidence |
| `Test Media` | Local caption and playback fixtures |
| `Build.noindex` | Xcode cache for future local builds |

## Build and install

Quit Reel, then run these commands from the source checkout. The install command replaces
`/Applications/Reel.app`, signs the local build ad hoc, archives the previous installation,
and archives and removes the other registered upstream-IINA app copies owned by the current user.
The build product is also archived and removed after installation. Source files, dependency
caches, and other applications are preserved.

```sh
mkdir -p "$HOME/Documents/IINA/Validation"
xcodebuild -project iina.xcodeproj -scheme iina -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$HOME/Documents/IINA/Build.noindex" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO -quiet build \
  > "$HOME/Documents/IINA/Validation/build.log" 2>&1
```

After the build succeeds:

```sh
python3 other/manage-local-install.py install \
  "$HOME/Documents/IINA/Build.noindex/Build/Products/Release/Reel.app"
python3 other/manage-local-install.py check
```

These commands require Python 3.11 or later, Xcode command line tools, and write access to
`/Applications`. They validate the bundle identifier and ownership before retiring copies.
Every removed live bundle has a ZIP backup checked for archive integrity and matching executable
and Info.plist contents. The archive manifest records its original path and checksums.

## Check or repair registration

```sh
python3 other/manage-local-install.py check
python3 other/manage-local-install.py repair
```

`check` is read-only and succeeds only when the preferred app, available copies, and Launch
Services app records all point solely to `/Applications/Reel.app`. `repair` requires the installed app to
be quit. It preserves the installed app, archives other registered local copies, unregisters
their app and extension entries, clears missing app paths, and registers the installed app.
It stops if a live duplicate is outside the current user's home folder or has different ownership.
Existing file type defaults for other applications remain available.

Open the installed app with `open -a /Applications/Reel.app`. Avoid launching a retained Xcode
product or extracting a backup for ordinary playback. Use the install command after local
builds; an independently launched or restored copy can register itself again.

To restore a ZIP backup, extract it into `Build.noindex` and pass the extracted app to the same
install command. Keep backups compressed during normal use.

The registration check uses Apple's [NSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace)
application lookup APIs. Targeted cleanup uses the system `lsregister` tool rather than resetting
the entire Launch Services database.
