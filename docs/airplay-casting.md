# AirPlay video casting

Reel bundles the `ozykhan/iina-airplay` plugin so you can send a local video to an AirPlay
receiver and keep Reel as the playback remote. This video path is separate from selecting an
audio output for Reel in the on-screen controller or Settings → Audio.

## Enable and cast

1. In the playback window, open the **Plugins** sidebar and choose **Set Up AirPlay** on the
   AirPlay Video card. This opens Settings → Plugins. Turn on **AirPlay** there; Reel asks you to
   approve the plugin's filesystem permission before enabling it. The helper needs that permission
   to read the selected media and run its bundled tools.
2. Return to the card and choose **Open AirPlay**, then start casting from the AirPlay sidebar tab.
   Choose a receiver in Apple's playback target picker. The first cast may cause macOS to ask for
   Local Network access. When AirPlay is enabled, **Plugins → AirPlay → Cast to TV** is also
   available from the menu bar.
3. Use Reel's play, pause, and seek controls as usual. Stop the cast from the AirPlay sidebar.

On first launch, Reel installs the bundled plugin only when no plugin with that identifier is
already present, and leaves it disabled until you approve its filesystem permission. Existing
installs are preserved when Reel itself is upgraded. For a Reel-managed install, the AirPlay Video
card offers an explicit **Update** action when the bundled package is newer or its identified files
have changed. Reel also checks the helper and FFmpeg against `bin/VERSIONS`, including executable
permissions; those large-file hashes run in the background. A missing or malformed manifest, or a
missing, modified, or non-executable binary, exposes the explicit repair action when the bundled
version is the same or newer. The staged
replacement is checked before it is installed. The update keeps the plugin's position, preferences,
and data. It stays enabled only when its permission set is unchanged; a permission change leaves it
disabled until you approve the new set in Settings → Plugins. A newer managed version is kept only
when its own manifest verifies both binaries; Reel does not downgrade it. If a newer installed
version cannot be verified, Reel marks it unavailable and does not offer Retry because the bundled
version cannot safely replace that newer package. External installs are not replaced. If the bundle
is missing, run `./other/download_libs.sh` to prepare the pinned package before building Reel.

## How it works and limits

The plugin does not capture Reel's mpv-rendered window. Its helper creates an HLS stream from the
local file and serves it to the receiver over the local network. It remuxes compatible media and
uses the bundled FFmpeg build for transcoding when needed. Reel keeps the playback controls; the TV
plays the HLS stream. Casting starts from Reel's captured media position while keeping HLS timestamps
on the source timeline, so later seeks remain aligned with Reel. FFmpeg may begin at an earlier key
frame; the TV seeks within the rolling playlist when the requested position is available.

The plugin casts local files, not network streams. Text subtitles can be converted to WebVTT;
bitmap subtitle tracks such as PGS and VobSub are not carried through this path. Reel paces local
input in real time and keeps a rolling HLS window of about three minutes; seeking much farther
behind the current stream position may no longer work. A cast creates temporary media output in
Reel's private temporary directory. The helper retains a rolling segment window, stops if its
output approaches 8 GiB or the volume has less than 1 GiB free, and removes the output after a
confirmed stop. These are fail-stop guards rather than a filesystem quota, so a write burst can
overshoot the thresholds slightly. Reel streams helper output as it arrives and retains at most 64
KiB of each plugin process output stream. If no receiver joins, Reel stops the cast helper after two
minutes. If a receiver disconnects during a cast, Reel allows a 30-second reconnect window before
stopping that cast and cleaning its temporary output. Closing the player window or unloading the
plugin requests cast shutdown. AirPlay stop commands have a separate, bounded lane that is available
across player contexts even when long-running serve processes occupy ordinary process slots. The
helper stop command is capped at 36 seconds; the host waits up to 45 seconds for all loaded player
contexts to confirm shutdown. If it cannot be confirmed, Reel keeps the package and cast identity
available for another in-app attempt and does not claim the output was cleaned. A retry checks the
recorded helper and FFmpeg processes under the cast lifecycle lock and cleans the output only after
they have stopped. App Quit proceeds without waiting for the plugin stop Promise; the helper's parent
monitor then attempts cleanup. A later cast also revisits expired failure-marked output, but preserves
it when process records are unreadable, mismatched, or still alive. The parent monitor is a fallback,
not a guaranteed cleanup deadline.

If Quit cancels an in-app plugin update while its stop confirmation is pending, Reel discards the staged
package and leaves the installed package unchanged without presenting an installation-error alert.

## Network and privacy

The helper listens on the Mac's selected network IPv4 address and an ephemeral port. The AirPlay
plugin's **LAN address** preference can choose the address reachable by a receiver when automatic
selection is wrong, such as with a VPN or multiple network interfaces. The helper validates that an
override is an IPv4 address assigned to an active interface. Otherwise, it selects an active
non-tunnel address when the default route uses a recognized VPN or tunnel. With multiple active
physical networks, automatic selection may still choose a different network from the receiver.
Each cast URL has a cryptographically random 128-bit path token, the server only serves expected HLS
files, and the cast directory is private to the current user. The token limits casual discovery and
guessing; it does not encrypt the HTTP stream. Someone who can observe local-network traffic can
read the URL and the video while the cast is active. Stop the cast when finished.

Reel's plugin permission sheet covers the filesystem access needed to launch the helper. macOS
Local Network permission controls network access at the operating-system level. Reel and the
bundled plugin send the stream to the receiver on the local network; they do not upload it to the
plugin maintainer or an online subtitle service.

## Pinned component sources and licenses

- Plugin source: [`ozykhan/iina-airplay` v0.4.0](https://github.com/ozykhan/iina-airplay/tree/7c2bfe839b1370bcbb322e9b0662a4f06857fb2d),
  commit `7c2bfe839b1370bcbb322e9b0662a4f06857fb2d`; source archive SHA-256
  `a81ad8188c15fa895c8e606b0658388c43257c0d129fae2587ee7e5c4982dd8d`.
- The official v0.4.0 plugin package is downloaded from its
  [release](https://github.com/ozykhan/iina-airplay/releases/tag/v0.4.0) and checked against SHA-256
  `6bad39d1d05f7c0c6f335248e557092e2a5a0fe1f99662b53c9f3f6cd6ef71fe`.
- Reel's helper hardening is the patch in
  [`other/iina-airplay-reel.patch`](../other/iina-airplay-reel.patch). Run
  `bash other/download_airplay_plugin.sh` to apply it to the pinned upstream source, run the Go and
  JavaScript suites, build a universal helper, and refresh the ignored
  `deps/plugins/iina-airplay.iinaplgz` build input. `other/download_libs.sh` also runs this packaging
  step. The Xcode build phase copies the prepared archive; it does not regenerate it, so refresh
  the package after changing the patch and before building Reel. Preparing the package requires Go
  1.26.4 or newer, Node.js with the built-in test runner, and Xcode command-line tools.
  `--skip-plugins` skips optional upstream plugins but still builds AirPlay.
- The plugin and helper changes are MIT licensed. The complete upstream MIT notice is included as
  `LICENSE` inside the plugin archive and in Reel's in-app credits.
- The bundled manifest retains `ghRepo: ozykhan/iina-airplay` as package provenance for Reel's
  narrowly scoped post-mpv helper cleanup. It omits `ghVersion`, so the generic plugin auto-updater
  stays disabled and Reel distributes reviewed package updates with the app.
- The bundled FFmpeg 9.0.1 binary is unmodified and built with LGPL components only. Its LGPL 2.1
  license text, complete matching source tarball (`bin/ffmpeg-9.0.1.tar.xz`), source checksum and
  upstream build-recipe link are included in the plugin archive and summarized in Reel's in-app
  credits.

“AirPlay” is Apple's service mark. This compatibility feature is provided by Reel; Apple does not
endorse Reel or the bundled plugin.
