# Command-line playback

Use the bundled `iina-cli` executable to open media from Terminal. Its `--help` output lists
the supported options.

`--headless` loads media without presenting playback windows or activating Reel. It keeps the
normal mpv and media-loading path, and mutes audio automatically. This is useful for background
diagnostics that need to exercise the same load, playlist, and thumbnail work as a visible player.
The Reel process continues running until it is quit or terminated.

Use `--mute` or `--no-mute` to control audio while retaining normal window behavior. Headless
mode always stays muted, even if `--no-mute` is also supplied.

Boolean values for `--headless` and `--mute` accept `yes/no`, `true/false`, `on/off`, or
`1/0`. Empty or unknown values exit with a usage error. The CLI also reports missing local input
files before launching the player; `--stdin` continues to read from standard input.
