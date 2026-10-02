# Subtitle setup in this checkout

## Automatic search with SubDL

1. Create a free SubDL account and obtain a key from [the SubDL API panel](https://subdl.com/panel/api).
2. In IINA, open Settings → Subtitles → Online Subtitles, select **SubDL**, and save the key. IINA
   stores it in macOS Keychain. Saving also enables **Search online subtitles automatically**; either
   setting can be changed afterward. Exact-match selection is the separate **Automatically select an
   exactly matching subtitle** switch and stays off unless you enable it.
3. Play a local video longer than the automatic-search threshold (20 minutes by default) with no
   loaded subtitle track. IINA searches SubDL. One unambiguous exact title/year/episode match can
   load automatically; other results open the ordinary chooser with the best match preselected.
   Results remain in provider order. The release name is supplied by an uploader, so an exact-name
   match is useful evidence but not proof that every line is correct.

[SubDL's current developer documentation](https://subdl.com/developers) requires a key for API
searches and lists 2,000 searches plus 50 authenticated downloads per day on its free tier.
[The older API documentation](https://subdl.com/api-doc) describes an anonymous limit of 300
ordinary downloads per IP, but that does not enable anonymous API searches. Limits may change.
IINA uses the documented raw-file download links and does not extract provider archives.

## Manual selection and fallback

The Subtitles → Find Online Subtitles menu keeps **OpenSubtitles** and installed subtitle plugins
selectable even when SubDL is the automatic source. A manual OpenSubtitles search shows the full
result list, including a single result, without pre-downloading candidates. Selecting a result
spends one download. The separate **Check OpenSubtitles dialogue against audio** switch is off by
default because it can use up to three downloads per search; when enabled, it checks a short audio
sample locally and may allow an exact dialogue match to load automatically.

Podnapisi and YIFY were suggested as additional sources, but this checkout does not run browser
scrapers for them. Downloaded files from those sites can be loaded through Subtitles → Load External
Subtitle or the Subtitles sidebar. The file picker accepts `.srt` even on macOS versions that give
it only a dynamic file type; IINA checks the selected extension before loading it. Their current
public integration contract was not verified, so they are not part of the automatic chain.

## Apple speech fallback

When a local video has no subtitle track, **Caption video when no subtitles are available** uses
Apple's Speech framework to transcribe short audio chunks on device and shows the text over the
video at playback time. macOS 26 and later uses `SpeechTranscriber` without the older Speech
Recognition permission prompt; earlier systems use `SFSpeechRecognizer` and ask for that
permission on first use. The default
speech language is the Mac's current language; the setting accepts a language tag such as `en-US`.
On-device recognition must be available for that language. The overlay stops when a subtitle track
appears, playback stops, or a different file opens. It can lag and make recognition mistakes.

A local playback check showed the Apple-generated caption over a subtitle-free video, then showed
a manually loaded `.srt` in its place. This verifies that path on this Mac, not every speech
language or media format.

This implementation reads local media files; network streams and protected media are outside its
audio-decoding path. IINA does not control the separate macOS system-wide Live Captions window.

## Related debugging notes

- [Automatic selection and audio matching](troubleshooting/auto-select-matching-online-subtitle.md)
- [Blank online subtitle chooser](troubleshooting/blank-osd-subtitle-chooser.md)
- [Blank Video, Audio, or Subtitles sidebar](troubleshooting/blank-sidebar-pane-after-tab-switch.md)
