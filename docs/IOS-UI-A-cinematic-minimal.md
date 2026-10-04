# IOS-UI-A — Cinematic Minimal

Date: 2026-10-04
Branch: `ios-poc`
Release target: `0.1.60 (61)`

## Goal

Apply the user's selected A visual direction to the existing WebHTV iOS product without changing playback, source, favourite, history, subtitle or offline-download behavior.

## Visual changes

- Replace the decorative global wallpaper with a near-black / midnight-blue cinematic gradient.
- Primary accent becomes a saturated iOS-like blue; the main `立即播放` CTA uses a white label.
- Navigation and tab bars use visible ultra-thin material to keep controls legible over content.
- Home/search poster cards keep the existing 2:3 content model but use 16pt rounding, a subtle stroke and depth shadow; the home grid gets slightly more breathing room.
- Detail poster grows from 240pt to 300pt, with 18pt rounding, stroke and depth shadow.
- Favourite poster cards follow the same visual language; a selected favourite heart remains pink as a distinct semantic state.
- History, downloads, source lists and Settings use a raised dark surface instead of flat or translucent black rows.
- Player layout and engine UI are deliberately not redesigned in this pass; its black low-distraction presentation remains intact.

## Non-goals

No changes to AVPlayer/MPV routing, playback controls, source parsing, favourite identity/storage, WatchHistory ownership, offline download queueing, subtitle behavior, download deletion rules or completion detection.

## Integration note

The first A trial commit lived on `ios-poc-ui-a-cinematic` from an older base. While the user was reviewing it, `ios-poc` advanced with IOS-POC-50 and the 0.1.60 (61) version bump. The visual patch was therefore reapplied to the current `ios-poc` rather than merging the stale file wholesale, preserving the concurrent-download changes.

## Verification / release policy

The user explicitly requested no separate CI run. Do not start the macOS verification workflow. The existing SideStore release workflow's unsigned Release device build is the only compile check required for this trial release. Real-device visual acceptance remains with the user after SideStore installation.
