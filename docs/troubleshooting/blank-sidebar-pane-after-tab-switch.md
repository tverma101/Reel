# Blank sidebar pane after switching tabs

## Symptom

The `VIDEO`, `AUDIO`, and `SUBTITLES` sidebar tab bar remains visible while the pane below it
occasionally becomes blank. The failure has been intermittent, so a source fix alone does not prove
that every occurrence is gone.

## What the source shows

A local synthetic-video check exposed another startup failure. `windowDidLoad` eagerly constructed
all three sidebar controllers while mpv was still loading the file. Several pane constructors made
synchronous `mpv_get_property` calls. A process sample caught the main thread blocked first in
`SpeedView.update()` and, after that read was removed, in the playlist loop-status read. In both
cases the call originated from the eager `windowDidLoad` preload, leaving the UI unable to finish
drawing the sidebar. This is a directly observed hang, separate from the animation defect below.

`SidebarTabViewController.transition(from:to:options:completionHandler:)` added a custom
`CATransition` to the tab container under `kCATransition`, then called AppKit's view-controller
transition with no animation options. A later cleanup compared `layer.animation(forKey:)` with the
original `CATransition` using `===`. That cleanup cannot succeed: [Apple documents that a layer
copies an animation when it is added](https://developer.apple.com/documentation/quartzcore/calayer/add(_:forkey:)).
The custom animation could therefore remain attached to the container and affect a later layout
change. The code also assigned both `.slideLeft` and `.slideRight` to `transitionOptions`, although
[AppKit calls those options mutually exclusive](https://developer.apple.com/documentation/appkit/nsviewcontroller/transitionoptions).

An earlier version of this record called the custom transition an implicit animation and claimed a
degenerate-bounds mechanism as the proven root cause. Those statements were stronger than the
evidence. The copied-animation identity check is a definite defect; whether it explains every
reported blank pane still needs repeated runtime observation.

## Fix

Sidebar controllers now load when shown, after window setup. The quick setting pane uses playback
state and preference values already held by Reel for its initial controls, rather than synchronous
mpv reads while constructing the pane. Later property notifications refresh the playback state.

The override now asks AppKit to transition the child views using one supported slide option,
selected from tab direction. It uses no animation for the first switch, when Reel's animation
setting is disabled, or when macOS Reduce Motion is enabled. There is no custom layer animation or
cleanup timer to survive into a later resize.

## Validation

The arm64 Release build compiles. Process sampling reproduced and localized the startup hang on a
synthetic local video. In the installed build, the Video, Audio, and Subtitles pane bodies remained
visible through six rapid tab switches and a window zoom and restore. That one playback session does
not prove that every intermittent blank pane is gone; hiding and showing the sidebar was not checked.
