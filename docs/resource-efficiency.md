# Resource efficiency

Release build 202 uses mpv's `cache=auto` when **Prefetch and buffer network data** is enabled.
mpv buffers network inputs and avoids forcing its large read-ahead cache on ordinary local files.
Disabling the preference still sets `cache=no`. The network byte/time limits and user-specified
mpv configuration remain available; advanced options are applied after these defaults.

Rendering, mpv event/snapshot work, playlist/thumbnail work, and AirPlay audio jobs use dispatch
queues with an autorelease pool per job. This gives temporary Foundation, Core Animation, and
driver objects an explicit release boundary during sustained playback. Render notifications
coalesce into one pending draw while preserving forced redraws and updates arriving during a draw.
Display-link reporting, frame presentation, decoder settings, and AirPlay synchronization are unchanged.

Thumbnail decoding runs at utility priority. Its serial worker relinquishes its private image and
timestamp collections after publication, failure, or cancellation. Published thumbnails remain owned
by the player, so seek previews and Now Playing artwork continue to work.

## Verification

From the source checkout with the existing development dependencies:

```sh
python3 other/check_render_update.py
python3 other/check_thumbnail_lifetime.py
python3 other/check_airplay_volume.py
python3 -m unittest other/test_manage_local_install.py other/test_ffmpeg_audio_sample_bound.py
```

The render test exercises bursts, forced redraws, and a request arriving during rendering, with
negative controls for unbounded scheduling and lost forced redraws. The thumbnail test compiles
the production decoder, publishes real images, injects cancellation after image creation, and
checks worker ownership after success, failure, and cancellation. Its negative control retains
the private image collection and must fail.

Measure physical footprint, malloc allocations, IOSurface, and CPU separately on the same media,
route, window size, and playback interval. RSS can hide swapped allocations. Restarting an old
process can itself reduce memory; a post-install reading alone does not demonstrate a fixed leak.
These changes do not implement idle renderer suspension or memory-pressure reclamation.

References: [mpv caching options](https://mpv.io/manual/stable/#options-cache) and
[Apple dispatch autorelease pools](https://developer.apple.com/documentation/dispatch/dispatchqueue/autoreleasefrequency/workitem).
