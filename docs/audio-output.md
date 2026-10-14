# Audio output

Reel plays through mpv. Its AirPlay control can send Reel's sound alone to an AirPlay speaker while
the picture stays on the Mac.

## AirPlay audio

Click **AirPlay Audio** in the on-screen controller and choose a speaker in Apple's list. Only Reel's
audio moves; other apps and the Mac's default output are unchanged. Choose the Mac in the same list
to bring Reel's audio back. The OSD confirms the change with "Reel audio: <speaker>" or
"Reel audio: this Mac".

macOS routes one app's audio only through an AVPlayer bound to an
[AVRoutePickerView](https://developer.apple.com/documentation/avkit/avroutepickerview), and AVPlayer
cannot open most files mpv plays. While a speaker is selected, Reel therefore decodes the selected
audio track with FFmpeg (to 48 kHz stereo) and plays it in a hidden AVPlayer. mpv keeps the
picture, subtitles, Live Text and live captions; its own audio output is switched to `null`.

- **Starting, resuming and seeking.** The picture waits, at mpv's slowest speed, until the speaker is
  playing the matching sound. The speaker's buffering (about two seconds on AirPlay 2) shows as a
  short wait instead of a lip-sync offset. Selecting a speaker restarts mpv's own audio output, and
  Reel starts the speaker only once that output is running, so nothing is timed against a clock that
  has not started. If the picture's clock stops anyway, the speaker pauses with it and re-aligns when
  it resumes, instead of correcting against the stall.
- **Keeping sync.** Four times a second Reel compares the picture with AVPlayer's clock. When they
  drift more than 45 ms apart, it adjusts mpv's audio delay, which moves the picture.
- **What carries over.** Pause, seek, speed, audio-track changes, **Audio Delay**, mute and volume all
  apply to the speaker. Watch-later files keep your own speed and audio delay.
- **Supported sources.** Local files, external audio tracks and direct http(s) streams, with any
  audio codec FFmpeg decodes.

Limits:

- mpv audio filters and the equalizer are not applied to AirPlay audio.
- Volume above 100% plays at 100%.
- Other sources play on the Mac, with a message. These include ytdl pages, EDL and other protocols.
- A file also falls back to the Mac until the next file if its audio cannot be decoded, or if the
  speaker does not start within 10 seconds.
- An external audio file that starts later than its own timeline's zero may be misaligned.
- One file's AirPlay audio is limited to about six hours.

Diagnostics are logged with the prefix `AirPlay audio:`. To check sync without a speaker, launch Reel
with the argument `-ReelAirPlayBridgeLocalTest YES`, which runs the same path on the Mac's own
output. If a receiver's latency is not included in AVPlayer's clock,
`-ReelAirPlayBridgeLatencyCompensation <seconds>` subtracts it. The decoder's alignment with mpv's
timeline is checked by `python3 other/test_pcm_stream_reader.py`. Audible routing, other apps'
output and speaker disconnects need a real receiver.

## mpv audio devices

For files using the full mpv player, use **Settings → Audio**, *Preferred audio device* under
Hardware, to save a device for future sessions. Use **Audio → Audio Device** for a current-session
change. auto follows the Mac's configured output. A named device applies to Reel's mpv player, not
the system output.

This device list comes from Reel's active mpv output driver. A HomePod or AirPlay receiver appears
only if that driver exposes it; Apple's native route picker and mpv's device list are separate.
When mpv exposes a receiver, selecting it routes only Reel's mpv audio. A successful menu action
means mpv accepted the request, not that the receiver is playing sound.

If an mpv device disappears, Reel returns mpv to auto so playback can continue on the system
output. That reset also runs after a file finishes loading. It does not change the saved
preference; Settings labels a missing device until you choose another one. While AirPlay audio
is on, mpv's output is off; a device chosen here applies once Reel's audio returns to the Mac.

Reel's bundled AirPlay video-casting plugin is a separate feature. It sends a local video to a TV while Reel stays the remote; see [AirPlay video casting](airplay-casting.md).

## Related

- [Subtitle setup](subtitle-setup.md) describes Reel's caption and subtitle behavior, including the mpv audio clock used by its live-caption path.
- [Local macOS installation](local-installation.md) describes how this fork is installed and launched.
