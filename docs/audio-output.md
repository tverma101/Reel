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
  has not started. Stall detection follows both mpv's audio clock and AVPlayer's media clock, so a
  low-frame-rate picture does not pause sound while audio is advancing. If mpv's audio clock stalls,
  the speaker pauses and re-aligns when it resumes. If the selected route reports playback but its
  media clock stops, Reel returns audio to the Mac so the file keeps playing.
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

Maintenance note: bridge timers must read the event-fed mpv snapshot rather than call synchronous
libmpv getters. Snapshot requests and AirPlay command submissions run on a dedicated serial queue
because libmpv serializes its client API through a shared core lock; AppKit does not wait for those
submissions. The AVPlayer time observer feeds the WAV loader on its own serial queue, independent
of AppKit and mpv snapshot latency. Audio-output changes and routine speed/delay adjustments use
the bridge's serialized async command queue; speed and delay updates are coalesced while a prior
mpv command is pending. Snapshot requests are disabled and drained
before sending quit or destroying the mpv handle. The quit command is queued behind outstanding
snapshot submissions so shutdown does not synchronously wait on the AppKit thread. If mpv reports an
event queue overflow, discard that snapshot generation, wait off-main for accepted async requests to
finish, and request a fresh sample. This lets the bridge command queue recover if a dropped event
was a command reply. Each bridge command uses a distinct reply token so late replies cannot
complete a later command. AirPlay submissions share a gate with the terminal
shutdown marker, preventing a recovered command from being submitted after MPV reports shutdown.
If the bridge still has an unconfirmed command after the drain, it conservatively marks AirPlay
failed for that file and returns its audio to the Mac; overflow does not identify the dropped event.
Rejected async requests get at most three submissions total: the initial submission plus two
retries. If an async request to restore the saved local audio output fails, Reel waits for earlier
async requests and performs the saved `ao` change plus `ao-reload` synchronously on the serial
background queue. Stop/quit drain callbacks remain pending until that fallback completes, and the
event reader remains free to service MPV.
After overflow recovery drains the event reader, sample `ao` directly on the background MPV queue
before resuming route reconciliation; the overflow may have dropped its property-change event.
Tag event-fed and direct `ao` changes so a later write wins over a recovery sample that has not
reached the main thread yet, and defer route engagement while a direct `ao` write is in flight.
Publish a direct setter's cached output only if no newer `ao` generation appeared while its
libmpv call ran. Retain the newest successful direct `ao` setter intent separately from event-fed
bridge state, including `mpv.command("set", ["ao", value])` and a custom key binding using
`set ao VALUE` with mpv command prefixes such as `no-osd`; serialize synchronous setters so their
saved order matches their libmpv writes. The raw-command scanner respects quoted semicolons and
tracks `set`, `cycle`, and `cycle-values` AO actions with each command's own prefixes. An async
raw `set ao` with a literal target updates the saved intent only after mpv accepts the command and
reports that value (including after event-queue recovery); an older completion cannot replace a
newer confirmed choice. A literal `null` target is recorded at acceptance because AirPlay itself
uses that valid output, so a later property event cannot identify which writer selected it. A
rejected raw async command never leaves a pending target. Accepted async selectors and expanded
targets have no identifiable completion value, so Reel retires an older explicit target and follows
mpv's reported AO value without inferring the selector's result from an unrelated change. An
event-fed `ao = null` is retained when no route restore is in flight.
A failed queued restore's synchronous fallback must not replace that user intent. Preserve an
explicit direct `ao = null` choice through disconnect as well. If a local output change races AirPlay
engagement or arrives while the bridge is carrying audio, retain that output for disconnect and
queue `ao = null` plus `ao-reload` again. If the write callback arrives after disconnect queued a
different restore, append the direct output restore after it. Avoid re-queuing a restore already
pending for the same output. Allow only one synchronous restore per failed command reply.
Unexpected MPV shutdown must pause and remove the hidden AVPlayer item, invalidate its loader and
timers, and detach its playhead feeder without calling back into the destroyed MPV core.
Keep the cached local output separate from the bridge's engaged state: a fast route reconnect can
arrive while the event-fed `ao` snapshot still says `null`. Retain the last local output across
that transition, and refresh it from mpv only after pending route restores have drained.
Keep the snapshot
request-state lock out of libmpv calls so the main-thread timer cannot inherit core-lock waits.
AVPlayer clock monitoring starts even when its first reported time is invalid, allowing the startup
timeout to trigger the normal fallback. Player stop and quit
must also wait asynchronously for the bridge command queue to finish its final timing restores
before sending mpv's stop or quit command. The event reader stays free to service unload hooks while
stop runs, and quit remains queued behind snapshot submissions. This preserves the user's speed and
audio delay for watch-later files; the bridge-drain wait is asynchronous, while the final watch-later
state save still runs synchronously.
Keep the queue order intact. File teardown queues its final speed/delay restore behind pending
bridge writes and also writes synchronously so stop/quit can persist watch-later state. `withUserTiming`
remains synchronous because its caller immediately writes a watch-later file between temporary timing
changes.

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
