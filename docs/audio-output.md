# Audio output

Reel plays through mpv. Its AirPlay control can send Reel's sound alone to an AirPlay speaker while
the picture stays on the Mac.

## AirPlay audio

Click **AirPlay Audio** in the on-screen controller and choose a speaker in Apple's list. Only Reel's
audio moves; other apps and the Mac's default output are unchanged. Choose the Mac in the same list
to bring Reel's audio back. The OSD reports speaker selection or disconnection and explains when
playback falls back to the Mac. These notices remain available while a newly selected file loads.

macOS routes one app's audio only through an AVPlayer bound to an
[AVRoutePickerView](https://developer.apple.com/documentation/avkit/avroutepickerview), and AVPlayer
cannot open most files mpv plays. While a speaker is selected, Reel therefore decodes the selected
audio track with FFmpeg (to 48 kHz stereo) and plays it in a hidden AVPlayer. mpv keeps the
picture, subtitles, Live Text and live captions; its own audio output is switched to `null`.
When playback stops or reaches idle, Reel restores mpv's saved local output. If the speaker remains
selected, Reel engages the bridge again when the next supported file loads.

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
- Custom MPV `set`, `add`, `multiply` and `cycle-values` bindings for speed and Audio Delay keep
  applying to the user's timing while AirPlay carries audio. Their OSD settings are preserved, and
  timing commands stay in order within a command list, including bindings with an async prefix.
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

Maintenance note: route notifications and the picker-close callback defer reconciliation to a later
main-queue turn, so AVFoundation never waits for route handling inside its own notification. The
bridge caches its single AVPlayer's output context and does not query private buffered-playback
state for diagnostics; re-reading the player's context while closing the picker can deadlock AppKit.
Clock reads also use the time observer's cached position, including during disconnect cleanup:
`AVPlayerItem.currentTime()` can block on AVFoundation's route teardown. The observer samples at
10 ms intervals while decoder playhead updates remain throttled to a quarter second.
Bridge timers must read the event-fed mpv snapshot rather than call synchronous
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
Publish a direct setter's cached output only while the observed value remains at its pre-write
value (or has reached the setter target) and no newer direct output intent appeared. Retain the
newest successful direct `ao` setter intent separately from event-fed bridge state, including
`mpv.command("set", ["ao", value])` and a custom key binding using
`set ao VALUE` with mpv command prefixes such as `no-osd`; serialize synchronous setters so their
saved order matches their libmpv writes. The raw-command scanner respects quoted semicolons and
tracks `set`, `cycle`, and `cycle-values` AO actions with each command's own prefixes. An async
raw `set ao` with a literal target updates the saved intent only after mpv accepts the command and
reports that value (including after event-queue recovery); an older completion cannot replace a
newer confirmed choice. An explicit literal `null` remains a direct user intent after its async
command reply confirms it; a property event alone cannot distinguish that value from AirPlay's
own `null` write. The raw-command scanner follows mpv's delimiter rules: unquoted semicolons always
separate commands, including after a backslash, while quoted semicolons stay inside their argument.
A decodable single raw async AO action uses libmpv's reply-bearing API; after
completion, Reel reads AO once to resolve selectors and coalesced changes without using an older
queued property event as the selector result. For a semicolon-separated raw command list, Reel
submits the original string so mpv can validate the whole list before executing any part; AO
property commands run inline even with the `async` prefix, so Reel samples AO after the string
returns. The compatibility path for AO tokens Reel cannot translate samples only after that
command string returns.
mpv's command-list result does not propagate every child setter failure, so Reel accepts the
sampled AO if it changed from the pre-command value, matches the final literal AO target, or a
valid selector chain can be shown to leave it unchanged. For an unchanged sample, literal
`set`/`cycle-values` chains are simulated when every state-changing command is a recognized AO
operation; `show-text` and `print-text` may accompany the chain. `cycle` is accepted only as a
single selector because its available choices depend on runtime state. Dynamic values, duplicate
cycle values, and lists containing other commands fail closed.
A failed literal setter list that leaves AO unchanged cannot replace the saved local-output choice.
Overflow recovery uses its final AO readback to resolve every accepted async AO command in the batch.
Reel keeps the prior output as a fallback while an async AO command is pending. Pending async AO
commands prevent a stale snapshot from refreshing the saved output or the bridge from reasserting
`ao = null` over the new choice. The synchronous fallback checks the saved intent epoch under the AO
setter lock before writing; queued restore setters recheck that epoch atomically with submission.
Route or track-metadata changes that alter ownership advance a separate epoch. Queued AO setters
and reloads compare it before submission, while the synchronous fallback checks it before writing
and before `ao-reload`; route handling never waits for the blocking fallback call. A route change
after that fallback has started cannot cancel its in-flight `ao-reload`; main-thread reconciliation
checks ownership again as soon as the call returns.
After a restore setter is accepted, its paired `ao-reload` finishes unless a route takes ownership;
a failed reload's synchronous fallback still checks the saved intent epoch. Reel
also waits for pending direct AO commands before engaging the AirPlay bridge. If the route disconnects
while one is pending, Reel waits for its result before restoring the selected output, and retains the
previous local output if the command fails. If AirPlay reconnects before that result arrives, Reel
reconciles route ownership first and avoids briefly restoring local output while the bridge can carry
the file; unsupported audio still falls back to the saved local output. An event-fed `ao = null` is
retained when no route restore is in flight.
A queued local-output restore canceled by a reconnect keeps its target until route ownership is known:
a supported route takes ownership, pending track metadata keeps the decision open, and an inactive or
unsupported route restores the saved output. Route ownership stays pending through `loading` and
`starting`, before mpv has supplied the track metadata used to decide support. If the restore setter
already ran when the route took ownership, the retained target records that a local `ao-reload` is
still due if AirPlay later proves unavailable. Bridge-owned `ao = null` writes and their
`ao-reload` commands each carry the current AO-intent generation, so a stale command is discarded
if a newer user choice arrives before its submission.
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
that transition, and refresh it from mpv only after pending route restores have drained. A successful
bridge `ao` setter reply may fill the cached value when the observed output still matches its
pre-submit value or has reached the target, provided no newer direct output intent exists. A repeated
delayed event for the prior value does not veto confirmation. Failed direct setter attempts do not
invalidate that confirmation; the broader snapshot generation still fences readbacks during attempted
writes. `ao-reload` completes separately and is not treated as a pending output selection.
Keep the snapshot
request-state lock out of libmpv calls so the main-thread timer cannot inherit core-lock waits.
AVPlayer clock monitoring starts even when its first reported time is invalid, allowing the startup
timeout to trigger the normal fallback. Player stop and quit pause the current item, then wait
asynchronously for the bridge command queue to finish before sending mpv's stop or quit command.
START_FILE, END_FILE, Stop, and Quit defer speed/delay restores and fence them to the captured file
generation, playlist-entry ID, and timing value immediately before MPV submission. This prevents a
delayed event or restore from applying an old item's timing to the next item. A rejected final
restore uses the existing off-AppKit fail-safe before the queue drain is released. Stop writes
watch-later only while the paused active playlist entry still matches the item recorded when Stop
began. The event reader stays free to service unload hooks while Stop runs.
An audio-output restore failure during unload is held until the next file is loaded, when Reel can
present the warning through its normal OSD path.

Keep the queue order intact. Any use of `withUserTiming` must remain synchronous because its body
may immediately write a watch-later file between temporary timing changes.

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
