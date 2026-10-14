# Logging and memory

The pending queue and in-app log viewer each keep a rolling recent window capped at 4,096 entries and an estimated 4 MiB of retained log data. A single entry larger than the 512 KiB per-entry estimate is omitted from the in-memory viewer. Reel sends UI update notifications only while the log viewer is visible; opening or uncovering it flushes the bounded pending queue.

When file logging is enabled, complete accepted entries continue to be written to the session log on disk, including entries omitted from the in-memory viewer. Use that file when a full-session diagnostic log is needed.

While the log window is visible, bursts of new entries coalesce into one queued UI notification.
