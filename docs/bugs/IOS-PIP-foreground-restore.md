# iOS PiP bug — returning to WebHTV does not restore the normal player

- Status: **open / confirmed on real device**.
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

## Constraints for the future fix

- Treat this as an AVKit/PiP presentation-lifecycle problem first.
- Do not introduce a second playback state or second AVPlayer to solve it.
- External-player paths are out of scope.
- Do not mark fixed from simulator-only evidence; the defect is specifically about real-device PiP
  presentation behavior.

## Acceptance

A future fix closes this bug only when all of the following pass on a real device:

- built-in player → PiP → return to WebHTV dismisses PiP and restores the normal player;
- playback continues at the same position without duplicate audio;
- playing PiP returns playing, and paused PiP returns paused unless AVKit requires a documented
  system transition;
- current title/episode/line/quality and playback rate are preserved;
- repeated PiP → app → PiP cycles do not accumulate presentation/state errors;
- closing the restored player still follows the existing PlaybackSession/history semantics;
- opening/ending skip and auto-advance remain correct;
- external-player behavior is unchanged.
