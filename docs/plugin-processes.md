# Plugin subprocesses

The plugin JavaScript API exposes `exec(file, args, cwd, stdoutHook, stderrHook)` and
`execWithTimeout(file, args, timeoutSeconds)`. Both resolve with the child status and captured
stdout/stderr; `execWithTimeout` accepts values from greater than zero through 86,400 seconds.

The timeout is best effort. When the scheduled deadline check observes that the child is still
running, Reel rejects with timeout error `-4`, sends the child `TERM`, and sends `KILL` after a
500 ms grace period if it remains alive. Foundation does not expose the child's exact kernel exit
time. If the deadline check itself is delayed until after the child has exited, the process may
resolve normally even if its runtime exceeded the requested interval.

The returned stdout and stderr each retain at most 64 KiB and include a truncation marker when
larger. Live output hooks continue receiving streamed output subject to bounded callback queues.
