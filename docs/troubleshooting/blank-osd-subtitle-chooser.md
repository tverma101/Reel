# Blank panel where the online subtitle chooser should be

## Symptom

After an online subtitle search returns more than one result, the chooser that IINA shows on the
OSD sometimes appears as a large empty panel. The OSD stays up (`isShowingPersistentOSD` is true)
and the surrounding message is correct, but the result table is gone.

## Root causes

Two independent defects in the OSD accessory-view plumbing. The chooser view is presented as an
`accessoryView` on the OSD, and each provider's `Fetcher` owns one `SubChooseViewController`, so
these accumulate over a session.

1. **Constraints leaked on every presentation.** `MainWindowController.displayOSD` created a
   `height >= 300` constraint on the accessory view each time and never deactivated it, and
   `OSDView.addAccessoryView` did the same with an unstored
   `width >= 240` constraint. Repeated presentations piled conflicting constraints onto the view,
   distorting the panel.

2. **A retained, detached accessory view.** `OSDView.removeAccessoryView()` removed the arranged
   subview but never cleared `OSDView.accessoryView`. That property is the OSD's only strong
   reference to the accessory view, and the chooser holds a reference back to the fetcher that owns
   it, so a detached chooser and its fetcher were kept alive.

## Also fixed: the dismiss path truncated the fade

`SubChooseViewController`'s action calls `PlayerCore.active.hideOSD()`, and the `.ensure` of the
search that presented it calls `player.hideOSD()` as well — two hides on consecutive main-queue
turns. Starting a second `animator()` animation of the same property cancels the first animation
group and invokes its completion immediately, so the OSD was hidden roughly 46 ms into a 500 ms
fade instead of fading out. `hideOSD()` now returns early when a hide is already under way.

## An earlier theory that measurement disproved

A generation counter was first added to `hideOSD()` so that a slow fade-out racing a new
`displayOSD` could not strip the accessory view off the newly shown OSD. Instrumenting the real
state machine showed this guard could not prevent anything: `displayOSD` sets
`osdAnimationState = .shown` *before* touching the accessory view, and both `displayOSD` and the
animation completion run on the main thread, so no interleaving can leave `.willHide` set while a
new accessory view is attached. The existing `osdAnimationState == .willHide` gate already covered
it. Worse, the counter's only reachable effect was to *suppress* a correct teardown in one ordering.
The counter and its guard were removed rather than kept as false reassurance.

## Fix

- Track the height constraint in `MainWindowController.osdAccessoryHeightConstraint`; deactivate
  the previous one before installing a new one, and release it in `teardownOSDAccessoryView()`.
- Track the width constraint in `OSDView.accessoryWidthConstraint` and release it in
  `removeAccessoryView()`; `addAccessoryView()` installs a fresh one each time, which is safe
  because the previous one is always released first.
- `OSDView.removeAccessoryView()` now clears `accessoryView`.
- `MainWindowController.hideOSD()` is idempotent while a hide is in flight.

## Validation

The arm64 Release build succeeds, with no new warnings in the chooser code. A live manual OpenSubtitles search displayed
50 populated chooser rows in the installed build. The chooser was cancelled without downloading a
subtitle. Repeated searches and fade timing were not checked in that session.

## The search flag is handled elsewhere

`CommonError.canceled` and `isSearchingOnlineSubtitle` are not touched by this fix. The related
hazard — the chooser being destroyed without a click, leaving the search promise pending and the flag
stuck, which makes every later search return early — is fixed in
[auto-select-matching-online-subtitle.md](auto-select-matching-online-subtitle.md).
