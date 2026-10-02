<p align="center"><img height="200" src="https://github.com/tverma101/Reel/raw/main/iina/iina.icon/Assets/Image.svg" alt="Reel"></p>

<h1 align="center">Reel</h1>

<p align="center">An independent community fork of <a href="https://github.com/iina/iina">IINA</a>, the <b>modern</b> video player for macOS — extended with a local TV library and an on-device subtitle stack.</p>

> [!IMPORTANT]
> **Fork notice.** Reel is an independent fork of [IINA](https://github.com/iina/iina). We claim no credit for IINA: it was created by Collider Li and is built by the IINA contributors and community, and all credit for the underlying player belongs to them. Reel is not affiliated with, endorsed by, or connected to the IINA project; the IINA name and logo remain the property of the IINA project, and this fork ships under its own name and icon. Reel carries IINA's license unchanged: the [GNU General Public License, version 3](LICENSE). Every change this fork makes relative to upstream is documented in [FORK.md](FORK.md).

---
## Features

* Based on [mpv](https://github.com/mpv-player/mpv), which provides the best decoding capacity on macOS
* Designed for macOS 12.0 and later
* All the features you need for video and music: subtitles, playlists, chapters…and much, much more!
* Force Touch, picture-in-picture and advanced Touch Bar support
* Customizable user interface including multiple color schemes and on screen controller (OSC) layout positioning
* Standalone Music Mode designed for audio files
* Video thumbnails
* Online subtitle searching and intelligent local subtitle matching
* Unlimited playback history
* Convenient and interactive settings for video/audio filters
* Fully customizable keyboard, mouse, trackpad, and gesture controls
* mpv configuration files and script system for advanced users
* Command line tool and browser extensions provided
* In active development

## Downloading

Reel does not ship signed releases yet; build it from source (see *Building* below) or check this repository's releases. For the original IINA application, visit the [upstream IINA release page](https://github.com/iina/iina/releases) or the [IINA official website](https://iina.io/) — that project deserves your downloads and stars, not this fork.

> [!IMPORTANT]
> Reel disables IINA's update appcast on purpose. A fork must never silently replace itself with upstream builds, so Sparkle update checks are inert here.

## Building

Reel uses mpv for media playback. To build Reel, you can either fetch copies of the libraries upstream has already built (using the instructions below) or build them yourself by skipping to [these instructions](#building-mpv-manually).

### Using the pre-compiled libraries

1. Download pre-compiled libraries by running

```console
./other/download_libs.sh
```

> [!TIP]
> - By default the shell script downloads universal binaries. You can download arch-specific binaries using `--arch <ARCH>` (`universal`, `arm64` or `x86_64`)
> - Files are downloaded in parallel (5 concurrent downloads by default). You can change this using `--parallel <N>` (from 1 to...)
> - If you want to build against an older set of dylibs you must change `DYLIBS_DOWNLOAD_PATH` in the script to download the corresponding dylibs. For example, `https://iina.io/dylibs/1.2.0/universal/fileList.txt`.

2. Open iina.xcodeproj in the [latest public version of Xcode](https://apps.apple.com/app/xcode/id497799835). *Reel may not build if you use any other version; this requirement is inherited from IINA.*

3. Build the project.

### Building mpv manually

1. Build your own copy of mpv. You can use our [official build scripts](https://github.com/iina/deps-buildscripts) to build mpv and all other dependencies.

2. Run `other/parse_doc.rb`. This script will fetch the latest mpv documentation and generate `MPVOption.swift`, `MPVCommand.swift` and `MPVProperty.swift`. Copy them from `other/` to `iina/`, replacing the current files. This is only needed when updating libmpv. Note that if the API changes, the player source code may also need to be changed.

3. Link the *yt-dlp* dependency to deps/executable

   ```console
   mkdir -p deps/executable
   ln -s $(which yt-dlp) deps/executable/youtube-dl
   ```

4. Open `iina.xcodeproj` in the [latest public version of Xcode](https://apps.apple.com/app/xcode/id497799835). *Reel may not build if you use any other version; this requirement is inherited from IINA.*

5. Remove all references to `.dylib` files from the Frameworks group in the sidebar and add all the `.dylib` files in `deps/lib` to that group by clicking  "Add Files to iina..." in the context menu.

6. Add all the imported `.dylib` files into the "Copy Dylibs" phase under "Build Phases" tab of the iina target.

7. Make sure the necessary `.dylib` files are present in the "Link Binary With Libraries" phase under "Build Phases". Xcode should have already added all dylibs under this section.

8. Build the project.

## Subtitle setup

For this checkout's SubDL automatic search, OpenSubtitles manual fallback, and Apple speech
caption setup, see [Subtitle setup](docs/subtitle-setup.md).

For installing this local fork and preventing stale app copies in macOS launch choices,
see [Local macOS installation](docs/local-installation.md).

## Audio output

Reel selects its own audio output device through mpv, so you can send playback to an AirPlay
device without changing what the rest of the Mac does. See
[Audio output devices](docs/audio-output.md).

## Contributing

Reel is a fork, and its own development happens in this repository. Read
[CONTRIBUTING.md](CONTRIBUTING.md) for how to propose a change here.

* If you find a bug in **IINA** itself, report it to
  [upstream](https://github.com/iina/iina/issues). General playback, decoding, and
  interface bugs belong upstream, where they get fixed for everyone.

* If you want to contribute code to Reel, or you find a bug specific to this fork, open an
  issue or pull request in this repository.

* Translations are inherited from upstream. This repository does not run a translation service
  of its own; if you want to translate Reel, translate it upstream, where the Crowdin project
  for this codebase lives, and the strings will reach this fork with the next merge.

## Plugins

The plugin interface and file formats are unchanged from IINA, so IINA's plugins work in
Reel. These are upstream's plugins, maintained by their authors, not by this fork.

### Upstream-maintained plugins
- **[Online Media](https://github.com/iina/plugin-online-media)** (`iina/plugin-online-media`) - Enhances online streaming and downloading.
- **[OpenSubtitles](https://github.com/iina/plugin-opensub)** (`iina/plugin-opensub`) - Search and download subtitles.
- **[User Scripts](https://github.com/iina/plugin-userscript)** (`iina/plugin-userscript`) - Run custom JavaScript snippets.

### Community plugins
- **[AirPlay](https://github.com/ozykhan/iina-airplay)** (`ozykhan/iina-airplay`) - Cast the current file to an Apple TV over AirPlay; the player stays the remote. Reel can also send its own audio to an AirPlay speaker through Settings → Audio without this plugin — see [Audio output devices](docs/audio-output.md).
- **[Anime4K](https://github.com/yorkyang2333/iina-anime4k)** (`yorkyang2333/iina-anime4k`) - Apply Anime4K shaders for real-time anime upscaling.
- **[Auto Skip](https://github.com/pangziqiang/iina-auto-skip)** (`pangziqiang/iina-auto-skip`) - Automatically skip intro and outro sections with visual drag-to-set overlay.
- **[Bilingual Audio](https://github.com/glechic/iina-bilingual-audio)** (`glechic/iina-bilingual-audio`) - Play two audio tracks with left/right channel separation for bilingual viewing.
- **[Bookmarks](https://github.com/wyattowalsh/iina-plugin-bookmarks)** (`wyattowalsh/iina-plugin-bookmarks`) - Save and manage video timestamps.
- **[CineMode](https://github.com/D0CA/iina-cinemode)** (`D0CA/iina-cinemode`) - Fullscreen pause overlay and skip intro; optional Stremio next-episode shortcut.
- **[Clickable Subtitles](https://github.com/kerim/iina-clickable-subtitles)** (`kerim/iina-clickable-subtitles`) - Click subtitles to define words (macOS Look Up).
- **[Danmaku](https://github.com/xjbeta/iina-plugin-danmaku)** (`xjbeta/iina-plugin-danmaku`) - Overlay comments/danmaku on video.
- **[Danmaku Cosmos](https://github.com/karappo-yu/iina-plugin-danmaku-cosmos)** (`karappo-yu/iina-plugin-danmaku-cosmos`) - Niconico/Bilibili danmaku with CSS/Canvas dual rendering, Comment Art support.
- **[Detached Playlist](https://github.com/HowDidTheCatGetSoFat/iina-detached-playlist)** (`HowDidTheCatGetSoFat/iina-detached-playlist`) - Show the playlist in a separate floating window.
- **[Episode Info](https://github.com/Zain-Imam/iina-episode-info)** (`Zain-Imam/iina-episode-info`) - TMDB episode/movie info overlay on pause, with built-in subtitle search.
- **[File Viewer](https://github.com/qktechies/iina-plugin-file-viewer)** (`qktechies/iina-plugin-file-viewer`) - bookmark folders, browse directory contents, and play video files directly within the player.
- **[Hold to Speed](https://github.com/Tommy12356F/iina-hold-to-speed)** (`Tommy12356F/iina-hold-to-speed`) - Hold Space to play at 2× speed, just like YouTube.
- **[Jellyfin](https://github.com/mhajder/iina-jellyfin)** (`mhajder/iina-jellyfin`) - Browse and play media from Jellyfin servers.
- **[Jump to Frame](https://github.com/bbeny123/iina-jump-to-frame)** (`bbeny123/iina-jump-to-frame`) - Navigate video by specific frame number.
- **[ListenBrainz Scrobbler](https://git.notfire.cc/notfire/iina-listenbrainz)** - Scrobble your music to ListenBrainz.
- **[Multiple Clips](https://github.com/karthisnk/multi-cutter-iina)** (`karthisnk/multi-cutter-iina`) - multiple clip of a video using ffmpeg, with Batch Clipping, Vertical Clip, Format Selection, Preview Clip.
- **[PiP Toggle for IINA](https://github.com/nastarandarjani/iina-pip-toggle)** (`nastarandarjani/iina-pip-toggle`) - Simple plugin to toggle Picture-in-Picture (PiP) to fullscreen.
- **[Playlist Pro](https://github.com/CatCodeDanix/iina-playlist-pro)** (`CatCodeDanix/iina-playlist-pro`) - Seamless management of local and online playlists.
- **[Playlist Searchbox](https://github.com/icsarisakal/iina-playlist-searchbox)** (`icsarisakal/iina-playlist-searchbox`) - Search the current playlist by song title and artist.
- **[PolyScript](https://github.com/SammoMichael/polyplugin-release)** (`SammoMichael/polyplugin-release`) - Dual subtitles, hover dictionary, and AI-assisted translation for language learning.
- **[recorder](https://github.com/5thDimensionalVader/recorder-iina)** (`5thDimensionalVader/recorder-iina`) - to clip a video using ffmpeg.
- **[Skip Intro](https://github.com/pparanoiidd/iina-skip-intro)** (`pparanoiidd/iina-skip-intro`) - Detect and skip intros, recaps and credits.
- **[SubTandem](https://github.com/janwee-sha/SubTandem)** (`janwee-sha/SubTandem`) - A powerful plugin for real-time AI-powered bilingual subtitle translation.
- **[Thumbnails](https://github.com/aminozuur/iina-thumbnails)** (`aminozuur/iina-thumbnails`) - A plugin that shows clickable thumbnails for each video.
- **[Trakt Scrobbler](https://github.com/i3p9/iina-trakt-scrobbler)** (`i3p9/iina-trakt-scrobbler`) - Trakt.tv scrobbler plugin.
- **[VR2D](https://github.com/fetzu/iina-plugin-vr2d)** (`fetzu/iina-plugin-vr2d`) - Watch 3D VR videos (180°/360°, side-by-side or over-under) flat, with pan, zoom and automatic detection.


> 💡 **Want to build your own plugin?**
>
> Explore the existing plugins listed here to learn how they work. If you create a new plugin or improve an existing one, feel free to contribute it back to [upstream IINA](https://github.com/iina/iina), where it will reach Reel through the plugin list.
