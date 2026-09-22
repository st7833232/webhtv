# IOS-POC-15 — Playback Buffering / Preload

- Status: **planned, not started**.
- Recorded: 2026-09-22.
- Purpose: improve AVPlayer playback resilience and next-episode transition latency using measured
  device evidence, without introducing a second playback core or a persistent media cache.
- This document is a plan only. It authorizes no functional implementation by itself.

## Placement in the roadmap

Sequence:

`5S-3
→ core real-device playback baseline
→ IOS-POC-15
→ finish core real-device acceptance
→ MPV keep/drop decision
→ IOS-POC-12 Runtime Architecture Reconciliation
→ IOS-POC-13 Runtime Hot Update`.

IOS-POC-15 stays before IOS-POC-12 because it can change the native AVPlayer item/session contract;
that contract should be settled before the Native Core/Dynamic Layer freeze. It stays after a device
baseline because "buffer more" is not a diagnosis: a slow provider/CDN cannot be fixed by requesting
a larger forward buffer.

## Baseline first — do not tune blind

On a representative real device and several source shapes (at minimum one direct HLS, one source
requiring headers, and one source reached through playerContent/sniff where available), record:

- time from selecting an episode to first rendered playback;
- playback position and available buffer-ahead over time;
- every stall/rebuffer event and whether playback recovered;
- `playbackLikelyToKeepUp`, buffer-empty/full transitions where meaningful;
- AVPlayer access-log evidence such as observed/indicated bitrate or equivalent throughput metrics;
- selected media/variant bitrate;
- next-episode transition time measured from current item finish/ending trigger to next item playback;
- whether the limiting factor is network/provider throughput, URL resolution/sniffing, or player
  buffering.

The same measurements must be repeated after each material change so the stage can show a real
before/after result.

## 15A — Bounded forward buffering

Initial candidate, to be validated rather than assumed:

- set `AVPlayerItem.preferredForwardBufferDuration` to approximately **60 seconds** for ordinary
  on-demand video;
- keep `preferredPeakBitRate = 0` unless measurements show a deliberate cap is useful; a low value
  is a bandwidth ceiling and is not a download accelerator;
- keep `AVPlayer.automaticallyWaitsToMinimizeStalling` explicit and test its effect with the existing
  startup UX;
- live/unknown-duration playback must not inherit an inappropriate large VOD buffer policy;
- do not jump straight to 120–300 seconds. Increase to 90/120 only when device measurements show
  repeated stalls that additional buffer-ahead can realistically absorb.

A "60 s" value is a preferred target, not a guarantee that AVPlayer will always hold exactly that
amount of data.

## 15B — Buffer / throughput diagnostics

Add enough diagnostics to distinguish:

1. provider/CDN is too slow;
2. network is fast enough but forward buffer is too small;
3. player startup is waiting on resolution/sniffing rather than media download;
4. a high-bitrate variant is consuming nearly all available throughput;
5. next-episode delay is resolution latency rather than AVPlayer buffering.

Diagnostics must be bounded and suitable for tests/log capture; do not turn the app into a permanent
verbose network logger.

## 15C — Next-episode PlaybackTarget pre-resolution

The current auto-advance can require:

`next episode
→ playerContent
→ optional sniff
→ media URL + request headers
→ AVPlayer item
→ playback`.

Move the expensive **resolution** work earlier, after the current item has proven playable:

`current item stable
→ resolve only the next episode in background
→ cache a NextPlaybackTarget (URL + headers + identity/quality metadata)
→ current item ends
→ validate the prefetched target is still the correct next episode
→ open it immediately`.

Constraints:

- pre-resolve **one** next episode only by default;
- do not start a second AVPlayer;
- do not download the entire next episode in the background;
- preserve request headers, selected line/quality semantics and source/config identity;
- a source/line/quality/title/config change invalidates stale prefetched state;
- failure to pre-resolve is an optimization miss, not a playback failure — normal on-demand
  resolution remains the fallback;
- short-lived URLs must not be cached so early that they expire before use; measure TTL/behaviour
  where relevant instead of guessing;
- auto-advance and opening/ending semantics must remain the same as IOS-POC-14 / 5S-2.

A later substage may evaluate lightweight AVURLAsset property preloading only if 15C shows resolution
is no longer the dominant handoff cost.

## Adaptive policy — only if evidence earns it

After 15A–15C measurements, an adaptive policy may be considered, for example:

- ordinary VOD target around 60 s;
- raise toward 90–120 s after measured stall/rebuffer evidence on a source/network where throughput
  can actually build that buffer;
- shorter/system-managed behaviour for live playback;
- do not use a large buffer merely because the device has memory available.

The policy must have deterministic bounds and tests.

## Explicitly out of scope

IOS-POC-15 does **not** include:

- persistent/offline video downloads;
- a user-managed disk cache of HLS segments;
- rewriting HLS playlists;
- concurrent full download of the next episode;
- MPV work or AVPlayer↔MPV fallback;
- source-specific CDN workarounds;
- Runtime Hot Update / IOS-POC-13;
- new server infrastructure.

If persistent/offline HLS is later desired, evaluate it as a separate stage around Apple's
AVAssetDownloadURLSession / supported VOD download path and the project's real-world headers,
short-lived URLs and sniffed sources.

## Acceptance criteria

IOS-POC-15 can close only when:

- real-device pre-change baseline exists;
- buffering policy is explicit for VOD and does not accidentally apply an unsuitable policy to live
  playback;
- no artificial low peak-bitrate cap limits media download unless justified by data;
- buffer/stall/throughput diagnostics can explain the tested cases;
- next episode can be pre-resolved to a PlaybackTarget without creating a second playback state;
- stale prefetched targets are invalidated by source/title/line/quality/config changes;
- prefetch failure falls back cleanly to the current resolution path;
- request headers and multi-quality behaviour do not regress;
- opening/ending, history/resume, auto-advance, playback speed and external-player paths do not
  regress;
- full Swift test suite passes;
- simulator build passes;
- real-device post-change measurements use the same scenarios as baseline and show whether startup,
  rebuffering and/or next-episode handoff actually improved;
- Ponytail pre-review and final-diff review are completed for the future functional implementation;
- durable docs record measured gains and any cases where provider throughput remains the bottleneck.

## Decision gate after IOS-POC-15

Do not claim that a bigger AVPlayer buffer makes a slow source faster. If measurements show the
provider cannot deliver materially faster than the selected media bitrate, record the provider/CDN as
the bottleneck rather than increasing buffer targets indefinitely.

After 15 closes, finish the remaining core device acceptance, then record the MPV keep/drop decision
before IOS-POC-12 freezes the Native Core playback boundary.
