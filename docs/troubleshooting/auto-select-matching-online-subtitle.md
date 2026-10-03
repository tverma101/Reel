# Online subtitle selection and audio matching

Automatic exact-match selection is opt-in under Settings → Subtitles → Online Subtitles. When it is
off, search results open in the chooser. Reel preserves the provider's result order and preselects
the strongest eligible result when it can identify one.

## Exact-match rules

`SubtitleMatchScorer` compares the release name with the media name. Automatic selection requires
all of these conditions:

- The normalized titles match token for token.
- Both names contain the same year or episode marker, and at least one such identity anchor exists.
- Exactly one result qualifies; ties stay in the chooser.
- The provider opts in based on evidence beyond a filename alone.

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
Reel downloads at most three candidates, parses their cues, and compares them with a 12-second audio
excerpt decoded locally from the current file. Audio is not uploaded. The check is a short sample,
not proof that the full subtitle matches the whole film.

Reel runs a small Silero voice-activity model against every parseable candidate, whether or not
OpenSubtitles reports a movie-hash match. A timing label requires at least two speech segments to
align with dialogue cues, with at least 75% of the detected speech within 0.7 seconds of a cue. The
**Strong timing match · text unchecked** label describes synchronization only; timing alone never
auto-selects.

If VAD does not find a timing match for every parseable candidate, a local multilingual Whisper
model transcribes the same excerpt once. Reel compares text only for subtitles whose declared
language matches Whisper's detected language. A score of at least `0.60` is labeled **Dialogue
matches audio sample** and may satisfy the provider-evidence gate; `0.35`–`0.60` is labeled
**Possible dialogue match**. Automatic selection still needs the exact title and identity-anchor
rules above. A language mismatch, short transcript, or unavailable model leaves the candidate
without dialogue-match evidence, even if a VAD timing label is available.

The VAD model is under 1 MiB. The multilingual Whisper model is about 57 MiB and is downloaded only
when timing does not match every parseable candidate. Both models are fetched lazily from pinned
revisions, checked by SHA-256, and reused from Reel's Application Support folder. If a download or
model load fails, the chooser still appears.

The audio sample is local and brief. It can miss a match if it is silent, poorly recognized, or far
out of sync. Different-language subtitles are not compared by text. Cue parsing is limited to SRT,
WebVTT, and ASS; unsupported, oversized, or malformed files remain unverified.

## Developer checks

Run `bash other/check_subtitle_matcher.sh` for the 66 exact-title, anchor, tie, adversarial-name, and
pathological-input checks. Run `bash other/check_subdl_search_parser.sh` for SubDL response-schema,
URL-origin, filename, and provider-score checks. The app target has no unit-test target.
