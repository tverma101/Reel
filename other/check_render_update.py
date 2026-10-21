#!/usr/bin/env python3
"""Run the production render scheduler against burst and in-flight redraw regressions."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "iina/ViewLayer.swift").read_text()
start = source.index("  func update(force: Bool = false) {")
end = source.index("\n  private func framebufferSnapshot", start)
method = source[start:end]

HARNESS = r'''import Foundation
final class RenderHarness {
  let mpvGLQueue = DispatchQueue(label: "render-check", autoreleaseFrequency: .workItem)
  let renderUpdateGate = CoalescedNotificationGate()
  @Atomic var queuedForceDraw = false
  var forceDraw = false
  var needsFlip = false
  var draws: [Bool] = []
  var duringDraw: (() -> Void)?
  func display() {
    draws.append(forceDraw)
    forceDraw = false
    let callback = duringDraw
    duringDraw = nil
    callback?()
  }
__METHOD__
}
func check(_ condition: Bool, _ message: String) {
  if !condition { print("FAIL: \(message)"); exit(1) }
}
let layer = RenderHarness()
let started = DispatchSemaphore(value: 0)
let release = DispatchSemaphore(value: 0)
layer.mpvGLQueue.async { started.signal(); release.wait() }
started.wait()
for index in 0..<10_000 { layer.update(force: index == 5_000) }
release.signal()
layer.mpvGLQueue.sync {}
check(layer.draws.count == 1, "burst queued obsolete draws")
check(layer.draws == [true], "coalescing lost a forced redraw")
layer.mpvGLQueue.sync {
  layer.duringDraw = {
    for index in 0..<10_000 { layer.update(force: index == 9_999) }
  }
}
layer.update()
layer.mpvGLQueue.sync {}
layer.mpvGLQueue.sync {}
check(layer.draws == [true, false, true], "in-flight update or forced successor was lost")
layer.update()
layer.mpvGLQueue.sync {}
check(layer.draws.count == 4, "subsequent playback update was suppressed")
print("PASS: render bursts coalesce; forced and in-flight successor draws survive")
'''

with tempfile.TemporaryDirectory(prefix="reel-render-check-") as folder:
    folder = Path(folder)
    main, binary = folder / "main.swift", folder / "check"
    for candidate, expected_failure in [
        (method, None),
        (method.replace("renderUpdateGate.schedule(on: mpvGLQueue)", "mpvGLQueue.async"),
         "burst queued obsolete draws"),
        (method.replace("if force { queuedForceDraw = true }", ""),
         "coalescing lost a forced redraw"),
    ]:
        main.write_text(HARNESS.replace("__METHOD__", candidate))
        compiled = subprocess.run([
            "swiftc", str(ROOT / "iina/Lock.swift"), str(ROOT / "iina/Atomic.swift"),
            str(ROOT / "iina/BoundedLogBuffer.swift"), str(main), "-o", str(binary),
        ], capture_output=True, text=True)
        assert compiled.returncode == 0, compiled.stdout + compiled.stderr
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
        if expected_failure:
            assert result.returncode != 0 and expected_failure in result.stdout, result.stdout + result.stderr
        else:
            assert result.returncode == 0, result.stdout + result.stderr
            print(result.stdout.strip())
print("PASS: uncoalesced and lost-force negative controls were detected")
