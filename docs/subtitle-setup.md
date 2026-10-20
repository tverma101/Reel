# Subtitle setup in Reel

## Automatic search with SubDL

1. Create a free SubDL account and obtain a key from [the SubDL API panel](https://subdl.com/panel/api).
2. In Reel, open Settings → Subtitles → Online Subtitles, select **SubDL**, and save the key. Reel
   stores it in macOS Keychain. Saving the key does not change any search setting: **Search online
   subtitles automatically** stays where you left it, so no search runs until you turn it on
   yourself. Exact-match selection is the separate **Automatically select an exactly matching
   subtitle** switch and also stays off unless you enable it.
3. Turn on **Search online subtitles automatically**, then play a local video longer than the
   automatic-search threshold (20 minutes by default) with no loaded subtitle track. Reel searches
   SubDL. An unambiguous exact title/year/episode match with SubDL's confident match score (0.8+)
   can load automatically; other results open the ordinary chooser with the best match preselected.
   Results remain in provider order. The release name is supplied by an uploader, so an exact-name
   match is useful evidence but not proof that every line is correct.

[SubDL's current developer documentation](https://subdl.com/developers) requires a key for API
searches and lists daily free-tier quotas of 2,000 searches and 50 downloads. Limits may change;
check SubDL's API panel for the account's current quota. Reel uses the returned raw-file download
link, limits search and subtitle response sizes, rejects archive payloads, and does not extract
provider archives. Reel's SubDL path handles per-file results; it does not expand season packs or
download subtitle files for other episodes in a pack. If the file has no per-episode match, use a
manual provider search or load a subtitle file yourself.

## Preferred language

**Settings → Subtitles → Online Subtitles → Preferred language** is the language list that online
results are judged against and that Reel uses to choose a primary subtitle track. Entries may be
written as a two-letter code (`en`), a three-letter code (`eng`), a regional tag (`pt-BR`), or a
language name (`English`), and they are read in order. Reel converts names and three-letter codes to
tags mpv understands while keeping valid region and script subtags. The default is English. Leaving
the list empty also means English, which is the language both built-in providers already fell back
to on their own. **Settings → Audio → Preferred language** works the same way for audio tracks.

**Automatically select preferred audio and subtitles** is on by default. When media opens, Reel
selects the best available audio and primary subtitle track matching the language lists. If either
list is empty, English is used. This preference does not turn on subtitles when a file has none.
Reel shows one primary subtitle along the bottom by default. Turn on **Automatically select a
second subtitle track** in Settings → Subtitles → Other to ask mpv to select a secondary subtitle as
well. You can still select a second track manually while this setting is off.

The subtitle setting does three things:

- **Filters the search.** OpenSubtitles and SubDL are asked for these languages, so results in
  another language are usually not returned at all. The language is matched by identity rather than
  by spelling: `eng`, `en`, and `English` all mean the same language. OpenSubtitles preserves an
  explicit supported region such as `pt-BR`; a broad `pt` preference asks it for both `pt-pt` and
  `pt-br`. An unsupported explicit region does not broaden to other OpenSubtitles regions; it falls
  back to English when no requested code is supported. SubDL documents base-language codes, so
  regional preferences use SubDL's language-wide fallback (for example, `pt-BR` is sent as `pt`).
- **Orders the chooser.** Reel preselects the strongest media match. Preferred language breaks ties
  between similarly scoring results when a provider reports the result language; a weaker title
  match does not displace a stronger one. Providers without language metadata cannot be ranked by
  language, and results themselves keep the provider's order.
- **Decides between exact matches.** When several results are exact title and anchor matches *and*
  their provider vouches for them, automatic selection now picks the one in the first preferred
  language instead of leaving the choice to the chooser. It still asks when two of them are in that
  same language, and a result whose language no provider could identify is judged on its release
  name alone, exactly as before.

assrt.net results are not filtered server-side, so a language preference only orders and preselects
them; its Chinese language descriptions are recognized where they name exactly one language
(`简体`, `英文`), while bilingual descriptions (`双语`) are left unranked rather than guessed.

## Manual selection and fallback

The Subtitles → Find Online Subtitles menu keeps **OpenSubtitles** and installed subtitle plugins
selectable even when SubDL is the automatic source. A manual OpenSubtitles search shows the full
result list, including a single result, without pre-downloading candidates. Selecting a result
spends one download. The separate **Check OpenSubtitles dialogue against audio** switch is off by
default because it can use up to three downloads per search; when enabled, it checks a short audio
sample locally. VAD may identify timing alignment but cannot auto-select on timing alone; only a
same-language dialogue match can permit automatic selection.

Canceling a search closes its progress display and prevents a later provider, selected-file download,
or verification step from starting. Built-in HTTP requests are canceled as tasks; installed plugins
that do not implement cancellation may finish their current request. If an OpenSubtitles quota
response arrives after cancellation, Reel stops before fetching the candidate subtitle file.

**Choosing a result.** Unless an exact result qualifies for the separate opt-in automatic-selection
rule, built-in providers show the chooser and download only what you pick. shooter.cn is included:
its search returns up to thirty files, and asking first is the difference between one download and
all of them. It labels results with the provider's own description, because it returns links rather
than file names, and that description is not treated as a release name.

One consequence of routing a search through the chooser: the search remains cancellable while the
chooser is up, and the shared cancellation token also reaches built-in downloads after a result is
selected. A Stop or media change cancels those downloads and removes their temporary files. An
installed plugin provider may finish its current request if it does not implement cancellation;
Reel does not load its result after cancellation.

Built-in subtitle downloads use bounded responses and stop when their search is canceled. Assrt and
Shooter links are checked against provider-specific hosts before requests and redirects; Shooter's
legacy HTTP links are upgraded to HTTPS. Assrt's documented file server does not negotiate TLS, so
its legacy HTTP download is limited to numbered `file*.assrt.net` hosts and redirects within that
host family. Other hosts, credentials in URLs, and nonstandard ports are rejected. Failed or canceled
downloads remove their temporary files; successful files stay available to the player.
The provider cache has a 200 MiB aggregate limit. To make room, Reel removes only its own unleased
provider-cache directories after 30 days. Subtitle paths leased to a player are preserved, including
when a search is canceled after the result has been handed off; those leases last until the app exits
because mpv can retain a subtitle path after the chooser closes. If active files fill the cache cap,
new downloads fail rather than unlinking a path in use. Age-based cleanup also runs at application
startup, so abandoned temporary downloads do not accumulate indefinitely.

The optional dialogue check downloads pinned local speech models with a 2 MiB limit for its VAD model
and a 100 MiB limit for Whisper. Downloads are streamed to temporary staging files, canceled on
search cancellation, and checked against their pinned SHA-256 before being kept in Application
Support. Each model has one private staging file shared under an OS lock, so a force quit can leave
at most one size-capped partial per model; the next attempt verifies any installed model and safely
truncates that partial after acquiring the lock. A verified model replaces the prior file atomically.
The checksum reader also checks cancellation between bounded reads.

Podnapisi and YIFY were suggested as additional sources, but this checkout does not run browser
scrapers for them. Downloaded files from those sites can be loaded through Subtitles → Load External
Subtitle or the Subtitles sidebar. The file picker accepts `.srt` even on macOS versions that give
it only a dynamic file type; Reel checks the selected extension before loading it. Their current
public integration contract was not verified, so they are not part of the automatic chain.

## Apple speech fallback

When a video has no subtitle track, **Caption video when no subtitles are available** uses
Apple's Speech framework to transcribe short audio chunks on device and shows the text over the
video at playback time. Captions decode the selected source audio independently of the audio
output. While AirPlay audio is on they follow the speaker's clock; otherwise they follow mpv's
audio clock. Pausing cancels the
current decode/recognition request and retires its
generation, so a late result cannot appear; resuming retries the excerpt that covers the current
playhead. macOS 26 and later uses `SpeechTranscriber` without the older Speech
Recognition permission prompt; earlier systems use `SFSpeechRecognizer` and ask for that
permission on first use. The default
speech language is the Mac's current language; the setting accepts a language tag such as `en-US`.
On-device recognition must be available for that language. The overlay stops when a subtitle track
appears, playback stops, or a different file opens. On macOS 26 and later, Reel first checks Apple's
installed speech-language list. If no model for that language is installed, it stops instead of
repeatedly decoding chunks; toggle the caption setting off and on after installing one to retry. If
the speech framework cannot provide a compatible audio format, Reel also stops after its initial
check. Reel asks the recognizer for final results only, with word timings, so on-screen text does
not rewrite itself as drafts change. The words are grouped into short lines (about 42 characters
or 4 seconds, broken at pauses and sentence ends). Each line appears when its first word is spoken
and stays about a second after its last word, and only one line is shown at a time. Timing follows
the audio clock (`audio-pts`), so a per-file **Audio Delay** shifts captions together with the
sound rather than the picture. mpv's CoreAudio output does not count an output's stream latency,
which is where an AirPlay speaker reports about two seconds of buffering, so Reel subtracts that
latency before choosing the caption. **Subtitle Delay** also applies to these captions (positive is
later) for any remaining fine-tuning. Recognition can make mistakes. A recently returned caption may still
appear briefly after its time has passed, so chunk-processing delay does not leave a gap.

Caption appearance follows the existing Settings → Subtitles → Text and Position controls. Font,
size, bold/italic, color, outline or box style, shadow, character spacing, alignment, margins,
vertical position, and scaling with the window update while captions are active. The player’s
Subtitles sidebar also applies its live scale, position, font, size, color, and border controls to
generated captions. Long captions wrap
inside the available video width, with extra inset for the glyph outline and shadow. If a long
caption cannot fit vertically at the selected size, Reel reduces that caption's font size until
the full text fits; later captions return to the selected size. Position stays inside the video and
updates when the text or window size changes. The default uses the configured text with its outline
and shadow instead of a permanent caption card. The default font is the system font, and the outline
is drawn behind the letters so it does not thin them. These controls style the generated words; they do
not edit the speech recognizer's transcript.

A local playback check showed the Apple-generated caption over a subtitle-free video, then showed
a manually loaded `.srt` in its place. This verifies that path on this Mac, not every speech
language or media format.

Turn captions on or off from **Subtitles → Apple Live Captions** in the menu bar, the **Apple Live
Captions** switch in the player's Subtitles sidebar, or the Settings checkbox; all three change the
same setting.

Local files and direct `http`/`https` sources are candidates. Captions follow the selected internal
audio track; external audio and tracks without a matching FFmpeg stream index are not transcribed.
A network source must support seeking to each short excerpt; live or nonseekable sources are stopped
after the first failed seek. Other stream read failures stop captions after three consecutive
attempts. Reel keeps one FFmpeg reader open per active caption session, reads only the selected audio
track, and requests the next 10-second excerpt
four seconds before the current chunk ends for a local file or six seconds ahead for a network source.
Each decode uses a monotonic 15-second deadline that includes time waiting for the serial decode
queue and is checked between FFmpeg operations; an individual noninterruptible codec call may finish
after that deadline before cancellation is observed. Network reconnects are bounded. PCM output is
capped at 12 seconds (about 750 KiB of mono
16 kHz float samples). FFmpeg also bounds each decoded frame across all channels, so ordinary
surround audio remains supported while an unusually large frame is rejected before its decoded
buffer is allocated. Protected media is outside this path. Reel does not control the separate
macOS system-wide Live Captions window.

## Related debugging notes

- [Audio output devices](audio-output.md)
- [Automatic selection and audio matching](troubleshooting/auto-select-matching-online-subtitle.md)
- [Blank online subtitle chooser](troubleshooting/blank-osd-subtitle-chooser.md)
- [Blank Video, Audio, or Subtitles sidebar](troubleshooting/blank-sidebar-pane-after-tab-switch.md)
