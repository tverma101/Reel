# Online subtitle selection and audio matching

Automatic exact-match selection is opt-in under Settings → Subtitles → Online Subtitles. When it is
off, search results open in the chooser. Reel preserves the provider's result order and preselects
the strongest eligible result when it can identify one. Preferred language breaks ties between
similarly scoring results; a weak language match does not displace a stronger title match.

## Exact-match rules

`SubtitleMatchScorer` compares the release name with the media name. Automatic selection requires
all of these conditions:

- The normalized titles match token for token.
- Both names contain the same year or episode marker, and at least one such identity anchor exists.
- Exactly one result qualifies after the preferred language is applied; ties stay in the chooser.
- The provider opts in based on evidence beyond a filename alone.

When several results qualify, the *Preferred language* setting (Settings → Subtitles → Online
Subtitles) decides between them: the first preferred language that any qualifying result is in wins,
and only when exactly one result is in that language. Languages are compared by identity, not by
spelling, so `eng`, `en`, and `English` are one language and OpenSubtitles' `pt-br` matches `pt`.
When no qualifying result is in a preferred language the setting says nothing and the single-exact-
match rule above decides, so a result whose language no provider could identify is still selected on
its release name alone. With the setting left empty, English is preferred.

SubDL opts in only when its `match_score` is at least `0.8`. OpenSubtitles opts in only after an
opt-in, same-language dialogue comparison against locally decoded audio. Other providers default
to no automatic selection. A provider score and a matching filename can still be wrong: the title
comes from an uploader, and neither signal proves every subtitle line is accurate. The chooser lets
the user review or change the selection.

A missing year or episode marker prevents automatic selection even when the title is exact. A remake
with a different year, a different episode, an ambiguous tie, or a result from a provider that has
not opted in also stays in the chooser.

## OpenSubtitles audio check

The separate **Check OpenSubtitles dialogue against audio** setting is off by default. When enabled,
Reel downloads at most three candidates, parses their cues, and compares them with up to 12 seconds
of audio decoded locally from the current file. A sample near the end of a shorter file can be
shorter. Audio is not uploaded. The check is a short sample, not proof that the full subtitle
matches the whole film.

If the search is canceled or the current media changes, Reel dismisses the progress display and
does not start another provider request or candidate download. A request already in flight may
finish; after a canceled OpenSubtitles quota response, Reel does not fetch the subtitle file.
OpenSubtitles response bodies are capped at 10 MiB as bytes arrive, including responses without a
declared size. Candidate files above 10 MiB are not parsed; cue parsing also caps line, block, and
cue counts so newline-dense or unusually long WebVTT/ASS input cannot create an unbounded list of
temporary strings.

Reel runs a small Silero voice-activity model against every parseable candidate, whether or not
OpenSubtitles reports a movie-hash match. A timing label requires at least two speech segments to
align with dialogue cues, with at least 75% of the detected speech within 0.7 seconds of a cue. The
**Strong timing match · text unchecked** label describes synchronization only; timing alone never
auto-selects.

After the timing check, a local multilingual Whisper model transcribes the same excerpt once. This
content check still runs when every candidate shares the same timing, so Reel can distinguish
dialogue instead of treating synchronized cues as a content match. Reel compares text only for
subtitles whose declared language matches Whisper's detected language. A score of at least `0.60`
is labeled **Dialogue matches audio sample** and may satisfy the provider-evidence gate;
`0.35`–`0.60` is labeled **Possible dialogue match**. Automatic selection still needs the exact
title and identity-anchor rules above. A language mismatch, short transcript, or unavailable model
leaves the candidate without dialogue-match evidence, even if a VAD timing label is available.

The VAD model is under 1 MiB. The multilingual Whisper model is about 57 MiB and is downloaded only
when the opt-in check has a usable audio excerpt to compare. Both models are fetched lazily from
pinned revisions, checked by SHA-256, and reused from Reel's Application Support folder. If a
download or model load fails, the chooser still appears.

The audio sample is local and brief. It can miss a match if it is silent, poorly recognized, or far
out of sync. Different-language subtitles are not compared by text. Cue parsing is limited to SRT,
WebVTT, and ASS; unsupported, oversized, or malformed files remain unverified.

## Developer checks

Run `bash other/check_subtitle_matcher.sh` for the exact-title, anchor, tie, adversarial-name, and
pathological-input checks. Run `bash other/check_subtitle_language_preference.sh` for the language
recognition (codes, names, regional codes, Chinese descriptions), preference ordering, and selection
rule checks, including a source guard that the providers report their language and OpenSubtitles
compares canonical languages. Run `bash other/check_subtitle_audio_parser.sh` for bounded WebVTT/ASS
and SRT parsing checks, `bash other/check_opensub_bounded_download.sh` for streamed response caps
and cancellation, and `bash other/check_subdl_search_parser.sh` for SubDL response-schema,
URL-origin, filename, and provider-score checks. The app target has no unit-test target.
