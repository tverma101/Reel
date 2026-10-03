# AirPlay video casting

Reel bundles the `ozykhan/iina-airplay` plugin so you can send a local video to an AirPlay
receiver and keep Reel as the playback remote. This video path is separate from selecting an
AirPlay speaker under Settings → Audio.

## Enable and cast

1. Open Settings → Plugins and enable **AirPlay**. Reel asks you to approve the plugin's
   filesystem permission before it is enabled; the helper needs that permission to read the
   selected media and run its bundled tools.
2. Open the plugin's AirPlay sidebar tab and start casting. Choose a receiver in Apple's playback
   target picker. The first cast may cause macOS to ask for Local Network access.
3. Use Reel's play, pause, and seek controls as usual. Stop the cast from the AirPlay sidebar.

The plugin is installed disabled on first launch and on upgrade for existing Reel users. If it is
missing, run `./other/download_libs.sh` to prepare the pinned package before building Reel.

## How it works and limits

The plugin does not capture Reel's mpv-rendered window. Its helper creates an HLS stream from the
local file and serves it to the receiver over the local network. It remuxes compatible media and
uses the bundled FFmpeg build for transcoding when needed. Reel keeps the playback controls; the TV
plays the HLS stream. The TV starts from the beginning and then seeks toward Reel's current
position after enough stream data is ready.

The plugin casts local files, not network streams. Text subtitles can be converted to WebVTT;
bitmap subtitle tracks such as PGS and VobSub are not carried through this path. A cast creates a
second, temporary copy of the media in Reel's temporary directory, which remains until the cast
stops or Reel quits.

## Network and privacy

The helper listens on the Mac's selected LAN IPv4 address and an ephemeral port. Each cast URL has
a cryptographically random 128-bit path token, the server only serves expected HLS files, and the
cast directory is private to the current user. The token limits casual discovery and guessing; it
does not encrypt the HTTP stream. Someone who can observe local-network traffic can read the URL
and the video while the cast is active. Stop the cast when finished.

Reel's plugin permission sheet covers the filesystem access needed to launch the helper. macOS
Local Network permission controls network access at the operating-system level. Reel and the
bundled plugin send the stream to the receiver on the local network; they do not upload it to the
plugin maintainer or an online subtitle service.

## Pinned component sources and licenses

- Plugin source: [`ozykhan/iina-airplay` v0.3.2](https://github.com/ozykhan/iina-airplay/tree/123245a5e9921794caf63fb67ffb04ea9bd8711f),
  commit `123245a5e9921794caf63fb67ffb04ea9bd8711f`; source archive SHA-256
  `1a9e63c5679c75f9e76c363aa514703ea4f6b7bc4c709c4cff166c4c4f485900`.
- The official v0.3.2 plugin package is downloaded from its
  [release](https://github.com/ozykhan/iina-airplay/releases/tag/v0.3.2) and checked against SHA-256
  `277ae8235ebe911d22814022eaf7ab10074a83e58016a2e25d717ae2523e2b6e`.
- Reel's helper hardening is the patch in
  [`other/iina-airplay-reel.patch`](../other/iina-airplay-reel.patch). The build script applies it,
  runs the upstream Go and JavaScript tests, builds a universal helper, and repackages the plugin.
  Preparing the package requires Go 1.26.4 or newer, Node.js with the built-in test runner, and
  Xcode command-line tools. `--skip-plugins` skips optional upstream plugins but still builds AirPlay.
- The plugin and helper changes are MIT licensed. The complete upstream MIT notice is included as
  `LICENSE` inside the plugin archive and in Reel's in-app credits.
- The bundled FFmpeg 9.0.1 binary is unmodified and built with LGPL components only. Its LGPL 2.1
  license text, complete matching source tarball (`bin/ffmpeg-9.0.1.tar.xz`), source checksum and
  upstream build-recipe link are included in the plugin archive and summarized in Reel's in-app
  credits.

“AirPlay” is Apple's service mark. This compatibility feature is provided by Reel; Apple does not
endorse Reel or the bundled plugin.
