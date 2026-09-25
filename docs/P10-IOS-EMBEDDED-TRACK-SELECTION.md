# P10 — iOS 內嵌多音軌／字幕共用選擇

## Recovery anchor

- Objective: AVPlayer 與 MPV 都能辨識、顯示並切換影片內嵌音訊軌與字幕；音訊列顯示語言/名稱、codec、Mono/Stereo/5.1/7.1。
- Branch: `ios-poc`.
- Baseline: `882e6993b43535ea042c002d6e9c1a810182447d`.
- Scope: `ios/Sources/WebHTVCore/PlaybackMediaSelection.swift`, `ios/Sources/WebHTVCore/PlaybackEngine.swift`, `ios/WebHTVApp/Sources/WebHTVApp.swift`, `ios/WebHTVApp/Sources/MPVEngine.swift`, `ios/Tests/WebHTVCoreTests/PlaybackEngineTests.swift`, this document and the assessment index.
- Exclusions: external audio URL, Dolby Atmos/passthrough, AirPlay Audio, lock screen / Control Center.
- Rollback: revert the single P10 atomic commit. (Corrected 2026-09-25: implemented in `637d3597` with a follow-up compile fix `7acb5db1`, so a rollback reverts both. Released in `0.1.16 (17)`; no pre-release verification is recorded, and its track-switching device check is still listed as owed in `docs/current-task-state.md`. See `docs/IOS-POC-11-sidestore-release.md`, 第十七次發布.)
- Ponytail: optional / skipped.
- Task guard: unavailable in the current connected-GitHub runtime because no local workspace is mounted; equivalent branch/HEAD/scope checks are performed before the atomic Git commit.

## Decision

### Existing implementation

- AVPlayer already uses `.audible` / `.legible` media-selection groups and `select(_:in:)`. Preserve that selection mechanism.
- The player UI already owns one audio/subtitle panel. Before P10 it stores AVFoundation objects directly, so MPV cannot use it.
- MPV playback is already stable enough to load/play/seek and exposes libmpv through `MPVPlayerCore`; track selection is the missing parity stage.

### Evidence reviewed (2026-09-24)

| Evidence | Grade | Finding | Decision impact |
| --- | --- | --- | --- |
| Apple AVMediaSelectionOption docs | A | `displayName`, locale/language and `mediaSubTypes` are the public media-option metadata API. | Keep AVPlayer selection unchanged and adapt metadata only. |
| Apple AVAssetTrack async-property docs | A | `formatDescriptions`, `extendedLanguageTag`, `languageCode` are asynchronously loadable. | Use format descriptions for AV audio codec/channel diagnostics. |
| mpv manual, track-list | A | `track-list/N/id` is exactly the ID used by `aid`/`sid`; entries expose title, lang, codec, selected, demux-channel-count and demux-channels. | Build the MPV adapter directly from `track-list`. |
| mpv manual, aid/sid/audio-channels | A | `aid` selects audio, `sid` selects subtitle, `sid=no` disables subtitles; forcing `audio-channels=stereo` would explicitly downmix. | Use aid/sid only; do not add a stereo/downmix policy. |
| IINA MPVController (develop, reviewed 2026-09-24) | B | A mature libmpv UI observes track-list plus aid/sid as separate properties and moves UI-facing updates off the mpv queue. | Observe selection/list changes and publish an immutable shared snapshot. |
| VLC iOS localization/UI strings | B | Mature iOS media UI distinguishes audio/subtitle tracks and Mono/Stereo/channel-count labels. | Channel description belongs in the track row, not a separate playback policy. |

Primary URLs:
- https://developer.apple.com/documentation/avfoundation/avmediaselectionoption
- https://developer.apple.com/documentation/avfoundation/avassettrack
- https://mpv.io/manual/master/
- https://github.com/iina/iina/blob/develop/iina/MPVController.swift
- https://github.com/videolan/vlc-ios

Academic papers: not applicable. This stage is API adaptation/metadata presentation, not a novel codec, DSP, scheduling or algorithmic change.
Benchmarks: not applicable. No decoder, renderer, buffer, native binary or audio DSP path changes.

### Alternatives

1. No change: preserves AVPlayer only, leaves MPV panel disabled and gives no channel diagnostics. Rejected.
2. Expose AVFoundation/libmpv objects directly to SwiftUI: minimal code but couples the shared UI to both engines and makes stale IDs/options easy after handoff. Rejected.
3. Shared immutable WebHTV track model + per-engine adapters: selected. It preserves each engine's native selection semantics and keeps engine IDs opaque to the UI.

## Acceptance criteria

- AVPlayer still switches embedded audio/subtitles with its existing media-selection group API.
- AVPlayer audio rows include codec and channel presentation when metadata can be resolved.
- MPV reads embedded audio/subtitle entries from `track-list`, selects with `aid`/`sid`, and supports subtitle Off with `sid=no`.
- Both engines feed the same SwiftUI panel using `PlaybackMediaSelection`.
- Typical rows render like `日語 · AAC · Stereo` and `國語 · E-AC-3 · 5.1`.
- Mono/Stereo/5.1/7.1 derive from source metadata; no P10 setting forces downmix.
- Diagnostics log engine, selected track, language, codec, channel count and raw/normalized layout.
- `PlaybackEngineCapabilities.trackSelection` for MPV is true only in the same atomic implementation.
- Existing URL resolution, playback, buffering, seek, speed, PiP and player switching logic remain unchanged.

## Implementation notes

- AVFoundation mapping is deliberately conservative: when option-to-physical-track metadata cannot be matched safely, the UI keeps the option name/codec and leaves channel information unknown rather than attaching another language's channel layout.
- mpv's `demux-channel-count` / `demux-channels` are container hints; diagnostics preserve the raw layout and do not claim they prove the final hardware route output.
- Actual iPhone speaker, AirPods, Bluetooth, HDMI and AirPlay output verification remains a device diagnostics task. P10 records source/selected-track facts needed for that later validation.
