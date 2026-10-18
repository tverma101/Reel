# Reel TV plugin

A Netflix-style **local** TV library for Reel. No media server, no background
services: point the plugin at a folder of episodes and it builds a browsable
library inside the player's sidebar.

## What it does

- **Scan** — walks your TV folder (up to three levels deep), detects episodes
  from filenames (`Show S02E03.mkv`, `Show.2x04.mp4`, `Show.S01.E05.avi`),
  groups them into shows, and remembers playback progress between launches.
  Scans process at most 20,000 entries and keep the last complete library when
  a folder is too large or cannot be read. Each host directory listing is
  stopped at 20,001 entries, so a single oversized directory is bounded too.
- **Browse** — a dark, poster-forward sidebar tab with *Continue watching*,
  *Recently played*, and an *All shows* grid. Click a show for its episode list
  with watched/progress badges.
- **Play** — click any episode to open it in the player; resuming jumps back to
  where you stopped. If mpv does not expose duration yet, the plugin retries
  for up to two minutes and then gives up instead of making a late seek. The
  plugin menu adds **Reel TV: Rescan Library** and
  **Reel TV: Play Next Unwatched**.
- **Decorate (optional)** — with a TMDB API key, posters, overviews, and official
  episode titles are fetched directly from TMDB, with at most 40 requests per
  scan. Without a key, the library works fully with plain tiles and
  filename-derived titles. Rescans can repeat lookups for shows without matches.

## Install

From the repository root, create the local plugin package with the package files
at the archive root:

```sh
(cd plugins/ReelTV.iinaplugin && zip -r -X ../../ReelTV.iinaplgz .)
```

Then choose Reel → Settings → Plugins → Install from local package and select
`ReelTV.iinaplgz`. Set your TV folder using its full absolute path (for example
`/Users/you/Movies/TV`; do not use `~/...`) and optionally add the TMDB key in
the plugin's preferences. Hit ↻ in the sidebar to rescan.

## Privacy

Media files never leave this Mac. When a TMDB key is configured, search requests
send parsed show names to TMDB; poster images can also be fetched from TMDB using
saved metadata after the key is removed. Library state lives in the plugin's
own data folder shared by player windows. Progress is journaled per episode so
updates to different episodes do not replace one another across player windows.
Progress is written every 15 seconds; a direct mpv IPC quit can lose the most
recent interval.
