# About this fork

Reel is a fork of [IINA](https://github.com/iina/iina). This file is the fork's
transparency document: where the code comes from, what Reel changed, and how the
licenses apply. Nothing here changes the license — Reel is distributed under the
same [GNU General Public License, version 3](LICENSE) as IINA.

## Credit, claimed by no one here

IINA was created by Collider Li and is developed by the IINA contributors and
community. Reel inherits its core player and playback architecture from IINA;
fork-specific additions are described below. Reel claims no credit for IINA,
mpv, FFmpeg, or any project listed in the in-app credits, and is not affiliated
with or endorsed by the IINA project. The IINA name and logo belong to the IINA
project; Reel ships under its own name, bundle identifier, and icon.

## Provenance

- Upstream: https://github.com/iina/iina
- Fork point: upstream `develop` at `3133714` ("New icon (#6401)"). The initial
  fork history has three commits after that baseline: `2205042` (subtitle and
  caption features), `996be01` (Reel identity and fork documentation), and
  `e6a7382` (player stability and subtitle/audio hardening). This stabilization
  branch extends that history.
- The full upstream commit history is preserved in this repository on purpose:
  attribution and blame flow back to their authors.

## What Reel changes relative to upstream

### Subtitles

- **SubDL provider** (`iina/SubDLSubtitle.swift`): a free-API online subtitle
  provider. The user's own API key is stored in the macOS Keychain, is sent only
  as an `Authorization` header, and never appears in URLs or logs. Downloads are
  limited to 2 MiB for search responses and 10 MiB for subtitle files, pinned to
  SubDL's HTTPS origins across redirects, and rejects archive payloads. Filenames
  are sanitized before saving. Only SubDL's confident provider score (0.8 or
  higher), plus an exact title and year/episode match, can permit auto-selection.
  The per-file search does not expand season packs or retrieve other episodes from a pack.
- **Exact-match auto-selection** (`SubtitleMatchScorer` in
  `iina/OnlineSubtitle.swift`): an opt-in feature that can automatically load an
  online subtitle only when its release name reduces to exactly the media's
  title *and* carries the same year/episode anchor. The release name is treated
  as untrusted input throughout; anything short of a full match only preselects
  in the chooser. Provider ordering is never modified.
- **OpenSubtitles audio verification** (`iina/SubtitleAudioMatcher.swift`): an
  opt-in check that downloads at most three candidates, parses their cues, and
  compares them against a locally decoded audio excerpt using pinned,
  checksum-verified on-device VAD/Whisper models. VAD checks every parseable
  candidate, whether or not OpenSubtitles reports a hash match. Timing evidence
  is shown as unconfirmed; only same-language dialogue evidence can permit
  auto-selection.
- **Automatic search is opt-in.** Saving a provider's API key stores the key
  and nothing else: it no longer turns on automatic online searching as a side
  effect. Only the **Search online subtitles automatically** setting does that,
  so a key cannot silently start network searches.

### Captions

- **Apple live captions fallback** (`iina/AppleLiveCaptions.swift`): when a
  local video has no subtitle track, on-device Apple speech transcription
  (`SpeechTranscriber` on macOS 26+, `SFSpeechRecognizer` with
  `requiresOnDeviceRecognition` otherwise) captions the audio over the video.
  Off by default; audio is never uploaded, recorded from a microphone, or sent
  to subtitle providers; it stops the moment a real subtitle track appears.
  It also captions `http`/`https` streams, reading only the audio track over
  one kept-open connection (`FFmpegAudioChunkReader` in
  `iina/FFmpegController.m`), and can be switched from the Subtitles menu and
  the Subtitles sidebar as well as Settings. Captions use final, word-timed
  results shown one line at a time, follow the audio clock (so audio delay
  moves them with the sound) minus the AirPlay stream latency mpv does not
  count, honor Subtitle Delay, and draw the outline behind the letters.

### AirPlay video casting

- Reel bundles the pinned `ozykhan/iina-airplay` v0.3.2 plugin with a small
  hardening patch. It installs disabled, and enabling it requires the plugin's
  filesystem-permission approval. Video is remuxed or transcoded to HLS by the
  bundled helper and streamed to the selected TV over the local network; the
  plugin keeps Reel as the playback remote. See
  [docs/airplay-casting.md](docs/airplay-casting.md) for setup, limitations,
  network behavior, and source/license details.

### Audio output

- **AirPlay button** (`iina/AirPlayAudioRoutePicker.swift`): an on-screen
  controller button, on by default, that opens Apple's `AVRoutePickerView`
  speaker picker. Choosing speakers changes the Mac's output, which Reel
  follows while `audio-device` is `auto`.
- Device selection itself is inherited, not reimplemented: Settings → Audio,
  *Preferred audio device*, and the Audio → Audio Device menu both set mpv's
  `audio-device`, and selecting an AirPlay destination such as a HomePod routes
  Reel's playback there while other Mac applications keep using macOS's
  configured output. Reel documents this in
  [docs/audio-output.md](docs/audio-output.md).
- The upstream reset of a vanished device to mpv's `auto` now also runs when a
  file finishes loading, so a speaker that dropped off the network during load
  does not leave playback pointing at a device that cannot be used.

### Playback stability

- mpv property observers no longer re-query mpv on the main thread during file
  loading, which could deadlock against mpv's synchronous loading hooks:
  `track-list` is parsed from the change event's `MPV_FORMAT_NODE` payload, and
  several observers defer UI work until the file is loaded.
- The online-subtitle chooser no longer accumulates constraints or detached
  views across presentations, and its dismissal no longer truncates the OSD
  fade.
- The sidebar tab switch no longer leaks a `CATransition` onto the container
  layer, where it could hijack later, unrelated layout animations.

### Packaging and identity

- App identity: name `Reel`, bundle identifier `io.github.tverma101.reel`
  (the Safari extension becomes `io.github.tverma101.reel.OpenInIINA`). The
  upstream `iina-cli` and plugin-development targets keep their upstream names.
- Sparkle's update feed is disabled in code: a fork must never download and
  replace itself with upstream IINA builds.
- New icon built as an Icon Composer bundle with the same glass structure as
  upstream's, with a distinct reel-and-play mark and palette.
- `Packages/IINAWhisper`: a local Swift package wrapping a statically built
  [whisper.cpp](https://github.com/ggml-org/whisper.cpp) `v1.9.4`
  XCFramework (MIT license, included in the package). The Speech and VAD model
  files it uses at runtime are downloaded once, pinned to specific upstream
  commits, and verified by SHA-256 before use.

### Repository hygiene

- CI runs on this repository's `main` branch and builds `Reel.app`; the
  upstream workflow referenced a `develop` branch and an `IINA.app` build
  product that no longer exists here.
- `other/generate_dmg.sh` looks for the built `Reel.app`, its `Reel`
  executable, and the `OpenInIINA.appex` extension (the extension target keeps
  its upstream name), and writes a `Reel.v<version>.dmg`.
- `.github/FUNDING.yml` no longer lists upstream IINA's donation accounts, so
  a reader clicking Sponsor on this fork is not silently sent to the IINA
  project's funding pages.
- The upstream `crowdin.yml` was removed. This fork has no localization
  project of its own and must not push translations into upstream's Crowdin
  project; translations arrive through upstream merges.
- `CONTRIBUTING.md` is fork-specific. It no longer asks contributors to assign
  their work to the IINA team, and it points general upstream bugs upstream.
- The app's project, issue-report, release, and contributor links now point to
  Reel. The Crowdin translator link remains upstream because Reel inherits those
  translations and does not operate its own localization project.

### Upstream contributions

Several of the playback-stability fixes above are general IINA bugs, not fork
needs. They are being prepared as upstream contributions; a fork owes its
upstream more than attribution.

## Legal notes

- **License:** Reel's application code is distributed under GPLv3, and the
  LICENSE file is upstream's file, unchanged. Individual third-party
  components retain their own licenses. If you distribute a build of Reel,
  provide recipients the Corresponding Source, the license text, and required
  notices.
- **Bundled AirPlay components:** the plugin and Reel's helper changes are MIT
  licensed; the upstream license is included inside the bundled plugin archive.
  Its unmodified FFmpeg 9.0.1 binary is LGPL 2.1-or-later, with its license,
  complete matching source tarball, source checksum, and build-recipe link
  shipped alongside it. The AirPlay guide records the component pins.
  Source pins and the helper patch are documented in
  [docs/airplay-casting.md](docs/airplay-casting.md).
- **Trademarks:** the IINA name and logo are not Reel's to use as branding.
  They appear in this repository only to attribute the upstream project. “AirPlay”
  identifies compatibility with Apple's service; Apple does not endorse Reel or
  the plugin.
- **Third-party components:** mpv (mostly GPLv2+, portions LGPL), FFmpeg
  (LGPL/GPL depending on configuration), and the bundled libraries listed in
  the in-app credits are carried from upstream. whisper.cpp is MIT. Model files
  are fetched at runtime from their official upstream releases and verified.
- **Warranty and liability:** GPLv3 sections 15 and 16 already disclaim
  warranty and limit liability to the extent permitted by applicable law.
  Reel makes no separate promise beyond that, and no statement in this
  repository can extend the protection of the IINA, mpv, FFmpeg, or
  whisper.cpp contributors to code they do not own. A disclaimer added by
  this fork cannot remove upstream obligations or liability that other parties
  hold.
- **No content is included.** Reel ships no media, no catalogs of media, and no
  keys. Online subtitle providers are user-configured; each provider's terms
  are the user's responsibility.
