# iOS PiP bug — returning to WebHTV does not restore the normal player

- Status: **code fix implemented / device verification pending**.
- Reported: 2026-09-22.
- Area: AVKit / Picture in Picture / playback presentation lifecycle.
- This record documents the bug only; it does not authorize a functional fix by itself.

## Reproduction

1. Start playback in WebHTV's built-in iOS player.
2. Enter Picture in Picture.
3. Leave the app while playback continues in PiP.
4. Return to WebHTV.

## Actual behavior

- PiP remains active after WebHTV is back in the foreground.
- The normal in-app player surface is not restored as the primary presentation.

## Expected behavior

When WebHTV returns to the foreground while its own playback session is still active:

- stop/dismiss PiP;
- restore the normal in-app player presentation;
- preserve the same `AVPlayer` / `PlaybackSession`;
- preserve current item, playback position, selected line/quality, playback rate, and playing/paused
  state;
- do not restart the media;
- do not create a second player or duplicate audio;
- do not disturb WatchHistory, opening/ending skip, auto-advance, or playback-speed state.

## Implemented code fix

- `PlayerSurface.Coordinator` keeps a weak reference to its existing `AVPlayerViewController` and
  observes `UIApplication.didBecomeActiveNotification` for the lifetime of that Coordinator.
- A foreground event is consumed only while the existing `pictureInPicture` binding is true, and
  only once per active PiP session.
- Because `AVPlayerViewController` has no public `stopPictureInPicture()`, the Coordinator briefly
  sets `allowsPictureInPicturePlayback` to `false`, then restores it to `true` on the next main
  runloop. AVKit's existing `playerViewControllerDidStopPictureInPicture` callback clears the
  binding.
- The observer is removed when the Coordinator is released. The controller reference is weak, so
  neither the observer nor the workaround retains a retired player surface.
- No playback command is issued: the same `PlaybackSession.shared.player`, current item, position,
  rate, playing/paused state, line/quality and history state remain untouched.
- A pure-state seam covers non-PiP foreground, one request for an active PiP foreground, and two
  repeated PiP cycles without accumulated restore state.

## Verification state

- Ponytail pre-review: `Lean already. Ship.`
- Ponytail final-diff review: `Lean already. Ship.` (`net: -0 lines possible.`)
- Three focused Swift tests were added for the lifecycle gate.
- ~~`swift test` and the Simulator Debug build still need a macOS/Swift toolchain.~~
  **Run on macOS on 2026-09-23 at `61f2d6fd`, which was the environment blocker and is now closed:**
  `swift test --package-path ios` → **228 tests, 227 pass**, and the Simulator Debug build
  (`id=7B4E9557-4774-4EB9-B408-BB544DCC8657`) → **BUILD SUCCEEDED**. The three lifecycle-gate tests
  compile and pass. **The one failure is not this fix**: `reportsLiveType4SitesFromProvidedConfig`
  (`CMSClientTests.swift:212`, `isDirectMedia(resolved)`) is the live-provider case the durable
  records already classify as weather rather than a gate — it has failed and passed on the same day
  before, and it is not to be "fixed".
- **This closes the toolchain gap only, not the defect.** Everything here is still
  simulator-and-unit evidence; the acceptance below is unchanged and still requires a real device.
- No package, publish, SideStore release, or device install was performed.

## Fix constraints

- Treat this as an AVKit/PiP presentation-lifecycle problem first.
- Do not introduce a second playback state or second AVPlayer to solve it.
- External-player paths are out of scope.
- Do not mark fixed from simulator-only evidence; the defect is specifically about real-device PiP
  presentation behavior.

## Acceptance

This bug closes only when all of the following pass on a real device:

- built-in player → PiP → return to WebHTV dismisses PiP and restores the normal player;
- playback continues at the same position without duplicate audio;
- playing PiP returns playing, and paused PiP returns paused unless AVKit requires a documented
  system transition;
- current title/episode/line/quality and playback rate are preserved;
- repeated PiP → app → PiP cycles do not accumulate presentation/state errors;
- closing the restored player still follows the existing PlaybackSession/history semantics;
- opening/ending skip and auto-advance remain correct;
- external-player behavior is unchanged.
