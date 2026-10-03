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

## Manual selection and fallback

The Subtitles → Find Online Subtitles menu keeps **OpenSubtitles** and installed subtitle plugins
selectable even when SubDL is the automatic source. A manual OpenSubtitles search shows the full
result list, including a single result, without pre-downloading candidates. Selecting a result
spends one download. The separate **Check OpenSubtitles dialogue against audio** switch is off by
default because it can use up to three downloads per search; when enabled, it checks a short audio
sample locally. VAD may identify timing alignment but cannot auto-select on timing alone; only a
same-language dialogue match can permit automatic selection.

Podnapisi and YIFY were suggested as additional sources, but this checkout does not run browser
scrapers for them. Downloaded files from those sites can be loaded through Subtitles → Load External
Subtitle or the Subtitles sidebar. The file picker accepts `.srt` even on macOS versions that give
it only a dynamic file type; Reel checks the selected extension before loading it. Their current
public integration contract was not verified, so they are not part of the automatic chain.

## Apple speech fallback

When a local video has no subtitle track, **Caption video when no subtitles are available** uses
Apple's Speech framework to transcribe short audio chunks on device and shows the text over the
video at playback time. macOS 26 and later uses `SpeechTranscriber` without the older Speech
Recognition permission prompt; earlier systems use `SFSpeechRecognizer` and ask for that
permission on first use. The default
speech language is the Mac's current language; the setting accepts a language tag such as `en-US`.
On-device recognition must be available for that language. The overlay stops when a subtitle track
appears, playback stops, or a different file opens. On macOS 26 and later, Reel first checks Apple's
installed speech-language list. If no model for that language is installed, it stops instead of
repeatedly decoding chunks; toggle the caption setting off and on after installing one to retry. If
the speech framework cannot provide a compatible audio format, Reel also stops after its initial
check. Apple's changing draft captions replace text for the overlapping audio range, including when
the framework revokes a draft because it detects no speech there. Captions can lag and recognition
can make mistakes.

A local playback check showed the Apple-generated caption over a subtitle-free video, then showed
a manually loaded `.srt` in its place. This verifies that path on this Mac, not every speech
language or media format.

This implementation reads local media files; network streams and protected media are outside its
audio-decoding path. Reel does not control the separate macOS system-wide Live Captions window.

## Related debugging notes

- [Audio output devices](audio-output.md)
- [Automatic selection and audio matching](troubleshooting/auto-select-matching-online-subtitle.md)
- [Blank online subtitle chooser](troubleshooting/blank-osd-subtitle-chooser.md)
- [Blank Video, Audio, or Subtitles sidebar](troubleshooting/blank-sidebar-pane-after-tab-switch.md)
