# Automatic selection of an exactly matching online subtitle

## Goal

When an online subtitle search returns an exactly matching result, Reel may select it automatically
while leaving the user free to choose another subtitle. For OpenSubtitles, filename and provider
metadata alone are not enough: automatic selection also requires a same-language dialogue match
from a local audio sample.

## What existed before

None of this. IINA had no notion of a match score, and neither did this fork before the change:

- `OnlineSubtitle.search` → provider fetch → `showSubSelectWindow` in each provider's `Fetcher`.
- The chooser appeared only when a provider returned more than one result; a single result was
  accepted silently, several results required a click, and nothing was ever ordered by relevance.
- The downloaded file was handed to `loadExternalSubFile`, which is the same path a manually loaded
  external subtitle takes. `sub-add` makes the new track current, so no extra selection step is
  needed — an earlier attempt added a polling `setTrack` and was removed, because it could revert a
  user's own subtitle choice made in the meantime.

## Matching

`SubtitleMatchScorer` in `iina/OnlineSubtitle.swift` scores a release name against the media name,
`0`–`100`. For providers without audio verification, a score of `100` can trigger automatic
selection, so it is awarded only when **all** of the following hold:

1. Both names reduce to exactly the same title, token for token. A name is reduced by discarding
   everything from its first *release tag* onwards — a year, a resolution, or a source/encoder name.
   Reducing rather than enumerating every tag is what lets an arbitrary release group (`x264-NTb`,
   `x264-YIFY`) be ignored. Tokens are compared as an ordered sequence, never with separators
   removed, because joining them would make `The.Matrix` and `t.hematrix` compare equal.
2. Both names carry the same set of **identity anchors** — years and episode markers (`S01E02`,
   `1x02`) — and that set is not empty. Anchors are read from the *whole* name, not the reduced
   title, so a release cannot dodge the comparison by omitting them or by smuggling in a second one.
3. Neither reduced title is empty.

Requirement 2 is what separates a remake from its original: `The.Thing.1982` and `The.Thing.2011`
share a title but not a year, so they never auto-select. It is also why a file with no year and no
episode marker in its name — `Movie.mkv` — is never auto-selected: with nothing to corroborate the
title against, the title alone is not evidence. Such a file gets the chooser with the best match
preselected instead, one click from done.

Episode markers are deliberately *not* release tags, so they are always part of the title and are
always compared. A season token immediately followed by an episode token is recombined before
comparison, so the three spellings of the same marker — `S01E02`, `S01.E02` and `S01-E02` — tokenize
alike, and multi-episode releases such as `S01E01E02` are handled. The recombination does not cross
a release tag, so `S01.1080p.E02` yields no anchor at all rather than a forged one.

Anything short of a title match falls back to a Dice coefficient over token overlap, capped at `95`.
A same-title/different-anchor result is floored at `90`, so a remake still surfaces near the top for
the user to judge rather than being buried among unrelated results.

## Residual risk, stated plainly

The release name is **untrusted input** — it is whatever name the uploader of a remote subtitle
chose. A name-based check cannot be made proof against a deliberately crafted name, because
`The.Matrix.1999.1080p.Sinners` is indistinguishable from a legitimate
`The.Matrix.1999.1080p.BluRay`: the uploader simply picks where the title appears to end. Fuzzing
confirmed such names can reach `100`.

That is why:

- the feature is **opt-in** (`Preference.autoSelectMatchingSubtitle`, default `false`),
- the result is only ever a *default* the user can change,
- and the honest fix — gating on content identity such as the IMDb id that
  `OpenSubClient.SubtitleAttributes.featureDetails` already decodes — is not implemented here.

For OpenSubtitles, a local file's search is sent with *both* `moviehash` and `query`
(`OpenSubClient.subtitles`), and hash matches come back first. That provider ordering is
content-verified information, which is a second reason not to second-guess it.

## OpenSubtitles chooser labels

The chooser now removes a trailing format marker such as `(subrip)` from the displayed filename.
When the filename is only a placeholder such as `No Title`, or an accessibility marker such as
`SDH`, it displays the associated media title supplied by OpenSubtitles instead; `SDH` or `CC` is
kept after the title. This is presentation only: the original uploader filename remains the input
to release-name matching, and the provider's media title is not treated as proof that the subtitle
dialogue matches the current audio.

## Wiring

- `OnlineSubtitle.releaseName` — new overridable property, `nil` by default, implemented for
  OpenSub (`files.first?.fileName`), assrt (`nativeName`, or `nil` for the `[No title]` placeholder)
  and JS plugins (`getDescription().name`). It is deliberately *not* implemented for shooter.cn,
  whose fetcher shows no chooser and would never read it.
- `OnlineSubtitle.resolveSelection(_:mediaName:expectedURL:player:chooser:context:)` — shared by the fetchers,
  replacing three near-identical copies of `showSubSelectWindow`. It scores every result, then
  automatically loads a single exact match only when the setting is enabled and the provider says
  it is safe. OpenSubtitles says so only after an opt-in same-language dialogue check; an unverified
  single result opens the chooser. SubDL is eligible through conservative filename matching.
  Anything else, **including several results tied at `100`**, opens the chooser with the best-scoring
  result preselected.
- **Results are not reordered.** An earlier version sorted by score; that was wrong, because it
  demoted the content-verified hash matches OpenSubtitles returns first — and would have
  auto-selected a file the hash had already ruled out. The score now only picks what to preselect.
- `Preference.autoSelectMatchingSubtitle` — Settings ▸ Subtitles ▸ Online subtitles. Keys added to
  both `iina/en.lproj/Localizable.strings` and `iina/Base.lproj/Localizable.strings`, which the
  repository keeps in lockstep; other locales come from Crowdin.

## Audio confirmation for OpenSubtitles results

OpenSubtitles now presents its full result list for ordinary manual fallback without spending a
download until the user chooses one. The separate `verifyOpenSubAudio` setting is off by default.
When enabled, Reel downloads at most the first three candidates to inspect their text and reuses a
selected file instead of downloading it twice. This opt-in check may spend three provider downloads
in one search.

For local media, FFmpeg decodes one 12-second excerpt from the default audio stream and resamples it
to 16 kHz mono in memory. The excerpt is selected from a dense dialogue window shared by the
candidate subtitles. The audio is not uploaded. Subtitle parsing supports SRT, WebVTT, and ASS; the
sample and parsing pipeline handles the file locally.

The first check is a small Silero voice-activity model. It is used only if OpenSubtitles reports a
movie-hash match. At least two speech segments must align with dialogue cues, with at least 75% of
segments within 0.7 seconds of a cue. Then the chooser says **Strong timing match · text unchecked**.
Hash plus cue timing confirms likely synchronization, not dialogue, and
does not auto-select by itself. If that check does not cover every parseable candidate, local multilingual
Whisper transcribes the same excerpt once and compares normalized text only against subtitles whose
declared language matches Whisper's detected language. A text score of at least 0.60 is labelled
**Dialogue matches audio sample** and is eligible for automatic selection; 0.35–0.60 is labelled
**Possible dialogue match**. A different language, too little speech, or a failed check remains
unverified and cannot be auto-selected.

The models are downloaded lazily from pinned public revisions into Reel's Application Support
folder, with SHA-256 verification, and are reused afterward. The VAD model is under 1 MiB; the
multilingual Whisper base-Q5_1 model is about 57 MiB and is downloaded only when the timing check
cannot settle all candidates. If a model cannot be downloaded or loaded, the chooser still appears
with candidates marked unverified.

The local `IINAWhisper` package contains a static universal XCFramework built from upstream
whisper.cpp v1.9.4 for macOS 12.0. It is split into arm64 and x86_64 builds so each gets its CPU
backend; the Intel slice uses AVX and SSE4.2 without assuming AVX2. Metal BF16 is disabled to keep
the upstream library's default 13.3 deployment target from raising Reel's macOS 12 minimum. Details
and upstream source links are in [Packages/IINAWhisper/README.md](../../Packages/IINAWhisper/README.md).

### Efficiency spot-check

An arm64 Release CLI built from the same whisper.cpp v1.9.4 commit was measured on an Apple M4 with
the upstream [11-second JFK sample](https://github.com/ggml-org/whisper.cpp/blob/v1.9.4/samples/jfk.wav)
and the pinned base-Q5_1 model. With four threads, flash attention enabled measured a 0.377-second
median over seven runs; disabled measured 0.422 seconds. All runs returned identical text. A warm
Metal-versus-CPU comparison at four threads measured 0.301 versus 0.585 seconds median over seven
runs, also with identical text. Six threads measured 0.385 seconds versus 0.402 at four threads in
five runs each; that small gap overlapped normal run-to-run variation, so the four-thread cap stays.

These are local CLI measurements, not end-to-end subtitle-search timings, and one short English
sample cannot establish multilingual recognition quality. The first cold Metal invocation took
20.4 seconds; its cause was not isolated, so first-use latency in the app remains unmeasured. The
Whisper defaults already enable flash attention and the matcher already uses Metal where available.

This is a sample-based check, not proof that every line or subtitle translation matches the full
movie. It can miss a match when the excerpt is silent, poorly recognized, or far out of sync; it
does not claim a dialogue match across languages.

## Two pre-existing hazards this work runs into

- **Presenting the chooser off the main thread.** Provider requests complete on a URLSession queue.
  Presenting the OSD, loading the chooser's nib and updating its table all happened on that queue.
  The table reload was already wrong; writing the selection and button state made it worse, so
  `resolveSelection` now hops to the main queue explicitly.
- **A stuck `isSearchingOnlineSubtitle`.** If the chooser is destroyed without a click, nothing
  settles the promise, and the flag stays set. Because `menuFindOnlineSub` returns early when it is
  set, and idle player cores are recycled, that would leave online subtitle search silently dead for
  every later file in that window, recoverable only by quitting Reel.

  Clearing the flag directly is *not* a safe fix and was tried first. `PlayerCore.stop()` also runs
  while the player is merely idle — pressing ⌘. after playback has ended, or the background task
  completing — and in that state it returns without closing the window or dismissing the chooser.
  Clearing the flag there admits a second search while the first chooser is still up; that second
  search's OSD is then dropped because an accessory OSD is already showing, so its chooser never
  appears, its promise never settles, and the flag wedges for good. That is strictly worse than the
  original recoverable state.

  `resolveSelection` now receives the originating `PlayerCore` and media URL. The chooser is shown
  in that player's window, and a late provider response for an older file cannot create a new
  chooser there. `PlayerCore.onlineSubtitleSearchID` prevents an old callback from loading a
  subtitle or clearing the state of a newer search. `stop()` and `fileStarted(path:)` invalidate the
  old search and settle an open chooser. This removes the earlier multi-window mismatch.

## Validation

`bash other/check_subtitle_matcher.sh` extracts the enum from the source, compiles it together with
`other/check_subtitle_matcher_tests.swift` and runs 65 checks: the positive cases, every remake
listed above, the tag-injection and word-boundary attacks, missing anchors, empty and nil input, the
ranking order, and pathological input (1 MB name, 10k tokens, separators-only, NUL/BOM, RTL
override, combining marks) for crashes and hangs. It exits non-zero on failure.

The app target has no test target and CI does not run this script, so it is a developer check, not a
gate. The current change builds in Release for arm64 with the macOS 12 deployment target. The build reports warnings in untouched `LegacyMigration.swift`, `VideoView.swift`, `JavascriptAPIHttp.swift`, and `JavascriptAPIUtils.swift`; no Debug or Intel app build was run for this change.

The installed build made a live manual OpenSubtitles search and displayed 50 chooser results without
downloading any. A provider download and automatic SubDL selection remain unverified; no SubDL API
key was provided for a live search. A manually loaded `.srt` and Apple-generated live caption were
both checked in local playback, including the real subtitle taking priority.
