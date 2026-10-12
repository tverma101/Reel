# Audio output

Reel has two playback paths. Apple playback is used for eligible local videos so the native AirPlay picker can control that Reel player. Reel keeps its full mpv player for files or features Apple playback cannot handle.

## Apple AirPlay for supported local videos

The on-screen AirPlay button is Apple's native route picker attached to Reel's own AVPlayer. Apple
documents that the picker routes media from its attached player to nearby receivers. Reel disables
external video playback so the picture stays in Reel's window. The intended HomePod behavior is to
route only Reel's audio through that player without changing the Mac's system output or other apps'
audio; verify this with a physical HomePod before relying on it. See Apple's documentation for
[AVRoutePickerView](https://developer.apple.com/documentation/avkit/avroutepickerview), its
[player property](https://developer.apple.com/documentation/avkit/avroutepickerview/player), and
[AVPlayer.allowsExternalPlayback](https://developer.apple.com/documentation/avfoundation/avplayer/allowsexternalplayback).

When the AirPlay button is enabled, Reel automatically uses Apple's player for eligible files,
even before a receiver is selected. The native path requires a local file Apple can play, exactly
one video and one audio track, a single-item playlist, and no active subtitles, A-B loop, mpv
filters or effects, audio passthrough, audio or subtitle delay, custom mpv options, Picture in
Picture, mini player, Reel plugin, or Apple live captions. Files with more tracks, network streams,
unsupported formats, or volume above 100 stay in mpv. Reel checks that the Apple player is ready
before switching.

Controls that need mpv — for example subtitles, external tracks, audio delay, filters, chapters,
A-B loop, playlist controls, or the Audio Device menu — return playback to mpv at the current
position. That ends Reel's native route for the current file. Reel stays in mpv for that file;
reopen it to use the native route again. Changing volume above 100% also returns to mpv.

The native picker is hidden when Reel cannot use Apple's player for the current file. Reel does not
receive a confirmed device name from the picker, so a listed receiver is not proof that sound is
playing through it. This code has not yet been verified with a physical HomePod; HomePod playback,
pause/seek, disconnect/reconnect, and local video behavior still need a device check.

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
preference; Settings labels a missing device until you choose another one. The paused mpv device
list does not control Apple playback.

Reel's bundled AirPlay video-casting plugin is a separate feature. It sends a local video to a TV while Reel stays the remote; see [AirPlay video casting](airplay-casting.md).

## Related

- [Subtitle setup](subtitle-setup.md) describes Reel's caption and subtitle behavior, including the mpv audio clock used by its live-caption path.
- [Local macOS installation](local-installation.md) describes how this fork is installed and launched.
