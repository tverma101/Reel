# Audio output devices

Reel selects its own audio output device through mpv, the same way IINA does.
Choosing a device in Reel changes where Reel's audio plays and nothing else:
other applications on the Mac keep using whatever output macOS is configured
for. If a HomePod or AirPlay destination appears in the device list, Reel can
send a film there while a music app keeps playing to the built-in speakers.

## Where to change it

Use **Settings → Audio**, *Preferred audio device* under the Hardware section,
for the persistent setting that is saved for future sessions. Use
**Audio → Audio Device** in the menu bar for a switch that applies to the
current session only.

`auto` follows the system default; any other entry pins Reel to that specific
device. Only the settings popup writes the saved preference. The menu bar
switch changes what is playing right now and leaves the saved setting alone, so
the next launch goes back to whatever Settings still has.

## AirPlay button

The AirPlay button in the on-screen controller opens Reel's audio-output menu. It lists the devices
available through the active mpv output driver, including AirPlay destinations when macOS and that
driver expose them. Choosing a named device changes Reel's output only; other Mac apps keep their
current output. **System Default** selects `auto` and follows the macOS default. The video stays in
the Reel window. The same current-session choice is available from **Audio → Audio Device**.

AirPlay speakers add delay. If the sound runs behind the picture, adjust it with the audio delay
controls in the Audio sidebar; a resumed file remembers its delay.

## When a device goes away

If the selected device disappears — an AirPlay speaker goes off the network,
say — Reel sets mpv back to `auto` once the device list changes and the
selection is no longer present, so playback follows the system output instead of
going silent. That check also runs after a file finishes loading, so a device
that dropped off while the file was still loading is caught rather than leaving
a dead selection behind.

This reset changes what is playing, not what is saved. The saved preference
still names the vanished device, and the settings popup shows it labelled
`(missing)`. Pick a device again to clear that.

Startup is handled the same way: if the saved device is not in the device list
when Reel launches, playback starts on `auto` rather than on a device that is
not there.

## How it works

mpv exposes the selection through its
[`--audio-device`](https://mpv.io/manual/stable/#options-audio-device) option
and the matching `audio-device` property. Reel applies the selected output to its mpv player; it does
not change the system-wide output. Device discovery can vary with the macOS version, network, and
active mpv output driver.

The menu checkmark reflects the device Reel requested from mpv. mpv can fall back if that output
cannot be opened, and its `audio-device` property does not confirm which physical endpoint is
actually playing. A successful menu action means the request was accepted; listen for the result
and switch back to **System Default** if the selected device stays silent.

Reel also chooses the mpv audio output driver, and mpv ties each listed device
to one driver. The list is filtered to the active driver so that selecting a
device cannot silently fail by pairing a device with the wrong driver. If the
driver changes underneath a saved selection, Reel maps the selection to the
equivalent device for the new driver; if there is no equivalent, the device is
shown as missing in the settings popup rather than silently pretending it is
still usable.

Audio-device output is separate from Reel's bundled AirPlay video-casting plugin.
For casting the current video to an Apple TV while keeping Reel as the remote, see
[AirPlay video casting](airplay-casting.md).

## What has and has not been verified

The behavior described above is what the code does. It has not been exercised
against every HomePod generation, speaker, network configuration, or macOS
release. Treat a specific device pairing as unverified until you have played
through it yourself, and report the macOS version, the device, and the driver
setting if it misbehaves.

## Related

- [Subtitle setup](subtitle-setup.md) covers the audio decoding path used for
  subtitle verification; it is separate from where the audio is sent.
- Upstream's documentation of the underlying mpv options is linked above.
