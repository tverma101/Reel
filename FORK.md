# About this fork

Reel is a fork of [IINA](https://github.com/iina/iina). This file is the fork's
transparency document: where the code comes from, what Reel changed, and how the
licenses apply. Nothing here changes the license — Reel is distributed under the
same [GNU General Public License, version 3](LICENSE) as IINA.

## Credit, claimed by no one here

IINA was created by Collider Li and is developed by the IINA contributors and
community. Every part of Reel that plays, decodes, renders, or manages media is
their work. Reel claims no credit for IINA, mpv, FFmpeg, or any project listed
in the in-app credits, and is not affiliated with or endorsed by the IINA
project. The IINA name and logo belong to the IINA project; Reel ships under
its own name, bundle identifier, and icon.

## Provenance

- Upstream: https://github.com/iina/iina
- Fork point: upstream `master`, at the commit tagged in this repository's
  history immediately before the first `reel:` commit.
- The full upstream commit history is preserved in this repository on purpose:
  attribution and blame flow back to their authors.

## What Reel changes relative to upstream

### Subtitles

- **SubDL provider** (`iina/SubDLSubtitle.swift`): a free-API online subtitle
  provider. The user's own API key is stored in the macOS Keychain, is sent only
  as an `Authorization` header, and never appears in URLs or logs. Downloads are
  restricted to `https` on SubDL's documented download host, archives are
  rejected in favor of raw files, and filenames are sanitized before saving.
- **Exact-match auto-selection** (`SubtitleMatchScorer` in
  `iina/OnlineSubtitle.swift`): an opt-in feature that can automatically load an
  online subtitle only when its release name reduces to exactly the media's
  title *and* carries the same year/episode anchor. The release name is treated
  as untrusted input throughout; anything short of a full match only preselects
  in the chooser. Provider ordering is never modified.
- **OpenSubtitles audio verification** (`iina/SubtitleAudioMatcher.swift`): an
  opt-in check that downloads at most three candidates, parses their cues, and
  compares them against a locally decoded audio excerpt using a pinned,
  checksum-verified on-device VAD/Whisper model. Only a same-language dialogue
  match may auto-select an OpenSubtitles result.

### Captions

- **Apple live captions fallback** (`iina/AppleLiveCaptions.swift`): when a
  local video has no subtitle track, on-device Apple speech transcription
  (`SpeechTranscriber` on macOS 26+, `SFSpeechRecognizer` with
  `requiresOnDeviceRecognition` otherwise) captions the audio over the video.
  Off by default; audio is never uploaded, recorded from a microphone, or sent
  to subtitle providers; it stops the moment a real subtitle track appears.

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

### Upstream contributions

Several of the playback-stability fixes above are general IINA bugs, not fork
needs. They are being prepared as upstream contributions; a fork owes its
upstream more than attribution.

## Legal notes

- **License:** Reel, like IINA, is GPLv3-or-later. All of Reel's own code is
  published under the same license, and the LICENSE file is upstream's file,
  unchanged. If you distribute a build of Reel, you owe recipients the
  Corresponding Source, the license text, and the notices — same as IINA.
- **Trademarks:** the IINA name and logo are not Reel's to use as branding.
  They appear in this repository only to attribute the upstream project.
- **Third-party components:** mpv (mostly GPLv2+, portions LGPL), FFmpeg
  (LGPL/GPL depending on configuration), and the bundled libraries listed in
  the in-app credits are carried from upstream. whisper.cpp is MIT. Model files
  are fetched at runtime from their official upstream releases and verified.
- **No content is included.** Reel ships no media, no catalogs of media, and no
  keys. Online subtitle providers are user-configured; each provider's terms
  are the user's responsibility.