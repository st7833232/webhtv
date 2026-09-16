# IOS-POC-2E — WebHome bridge: the playback half

## Recovery anchor

- Branch `ios-poc`, baseline HEAD `e1db99d8`, clean worktree, level with `origin/ios-poc` (2026-09-16 13:50 CST).
- Objective: complete the playback half of the WebHome contract — `player.playVod`, `player.playVodInline`, `player.control`, `player.status` — on a minimal persistent playback session.
- Status: COMPLETE. A1-A6 pass offline; B1-B6 verified in the simulator. The one failing test is pre-existing and reproduced at baseline; the inline JS resolver is the one path this stage added that remains unexercised.
- Exactly one next action: agree the next bounded stage with the user.

## Completion sentence

The unmodified devkit showcase page's own `fm.vod`, `vodInline`, `fm.ctrl` and `fm.stat` buttons drive real native playback through the bridge, backed by one persistent `AVPlayer` session that outlives the player screen, so a page can start a vod, close the player, read a live `player.status` and change playback with `player.control`.

## Allowed paths

- `ios/Sources/WebHTVCore/WebHomeBridge.swift`
- `ios/Sources/WebHTVCore/CMSClient.swift` (a public memberwise `Vod` init only)
- `ios/WebHTVApp/Sources/WebHTVApp.swift`
- `ios/Tests/WebHTVCoreTests/WebHomeBridgeTests.swift`
- `docs/IOS-POC-2E-webhome-bridge-playback.md`, `docs/current-task-state.md`, `docs/AGENT_HANDOFF.md`

Protected pre-existing dirty paths: none — the worktree is clean. Android `app/` is read-only and is read for contract evidence only.

## Estimate

Agent elapsed wall-clock in this workspace, from 13:50 CST.

| Phase | Estimate |
|---|---|
| Playback session + bridge dispatch | ~35 min |
| App wiring (playVod screen, inline player, resolver) | ~30 min |
| Offline tests | ~20 min |
| Simulator end-to-end + regression | ~35 min |
| Docs, Ponytail final, commit, tag | ~15 min |

Total ~135 min; expected finish ~16:05 CST. If the inline JS resolver round trip fights `callAsyncJavaScript`, drop it to direct-URL episodes only, record it as a known limit, and keep the rest of the stage.

## Evidence — the contract, read from Android source

`app/src/main/java/com/fongmi/android/tv/web/HomeWebBridge.java`:

1. **`player.playVod`** (`:168-177`) reads `siteKey`, `vodId`, `title`, `pic`, `wallPic`, `content` and calls `VideoActivity.start(activity, siteKey, vodId, …)`. Returns `{}`. It opens the app's own vod screen for a configured site; it does not carry a URL.
2. **`player.playVodInline`** (`:179-199`) puts the whole payload in `WebHomeInlineVodStore` (`KEY = "webhome_inline"`, `WebHomeInlineVodStore.java:23`) under a generated `vodId`, opens `VideoActivity` with that pseudo-site, and **returns `{"siteKey":"webhome_inline","vodId":…}`** — the only playback method with a non-empty result. `title` falls back to `vod_name`, `pic` to `vod_pic`, `content` to `vod_content`/`desc`/`description` (`:216-222`).
3. **Inline episode resolution** (`:225-280`): an episode the page marked for resolution is resolved by evaluating JS that calls `window.__fmWebHomeInlineResolver` (or `window.__fmYmvidResolveEpisode`) and returns `{url, format}`. Android needs an `inlineResult` callback plus a `CompletableFuture` because its `evaluateJavaScript` cannot await a Promise.
4. **`player.control`** (`:281-295`) maps `action` to `play`, `pause`, `stop`, `prev`, `next`, `loop`, `replay` on the `PlaybackService`, and **returns `{}` even when no service exists**.
5. **`player.status`** (`:119`) is `WebCall.request(statusPayload())` against the local server's `/media`, with `responseType: "json"`. So the page receives the **full `net.request` envelope** — `{ok,status,url,headers,cookies,body}` — whose `body` is `server/process/Media.java:43-57`: `{state,speed,duration,position,url,title,artist,artwork}`, with `state` 3 playing / 6 buffering / 2 ready / 1 otherwise (`Media.java:59-65`), and `{}` when nothing is playing.

The consumer already exists: `webhome-devkit/templates/homepages/app-capabilities-showcase.html` has `data-action="vod"` (with editable siteKey/vodId fields, `:1248`), `data-action="vod-inline"` (four episodes, three direct and one needing the resolver, `:1164-1186`), `data-action="stat"` and seven `data-ctrl` buttons (`:464-470`). No test page is written; the page is used unmodified.

## The real constraint this stage exists to fix

`player.control` and `player.status` are meaningless without playback that outlives the player screen. Today `PlayerView` creates its own `AVPlayer` in `init` and it dies with the full-screen cover, so the page — which is only reachable *after* the player is dismissed — would always see "nothing playing". Android's equivalent is a process-wide `PlaybackService` reached through `Server.get().getService()`.

## Alternatives considered

| Option | Verdict |
|---|---|
| **No change** | Rejected. It is the approved stage, and the roadmap's remaining bridge half. |
| **Unmodified upstream** — a background `PlaybackService`, a media session, a local HTTP server exposing `/media`, and `status` fetched over HTTP through `net.request` | Rejected. The local server is exactly what this port deliberately avoids, and an HTTP hop to read our own player's position is cost with no behavioural gain. The **envelope** the page parses is reproduced instead of the transport that produced it. |
| **Narrow adapted** — one `@MainActor` `PlaybackSession` singleton owning a single `AVPlayer`, a playlist and an index; `status` built natively into the Android envelope; `control` mapped straight onto `AVPlayer` | **Chosen.** |

## Design (Ponytail pre-review)

Rung 2 — reuse what is already here — decides most of this:

- **`playVod` reuses `VodView`.** Android opens its vod screen; iOS already has one that loads detail, lists flags and episodes, resolves `?play=` and reaches the player. `playVod` therefore resolves `siteKey` against the already-loaded `[Site]` and presents the existing `VodView`. No second detail path.
- **`PlaybackSession` is one class, not a service layer.** `AVPlayer` already provides play, pause, rate, `currentTime`, `duration` and end-of-item notification. The session adds only what AVPlayer has no concept of: the playlist, the index, the title/artwork the page supplied, and the repeat flag. No protocol, no delegate, no state machine — `status` is computed from `AVPlayer` on demand, exactly as Android computes it from its player on demand.
- **`status`/`control` reach the app through closures on the existing `Actions` struct**, like `viewport` already does, so the bridge stays testable with no UI and `WebHTVCore` keeps building for macOS.
- **`PlaybackStatus` is a small `Sendable` struct** beside `Viewport`, for the same reason: the JSON shape gets asserted in tests instead of being a dictionary built at the call site.
- **Rung 4, native platform feature:** the inline resolver uses `WKWebView.callAsyncJavaScript`, which awaits a JS Promise directly. Android's `inlineResult` + `CompletableFuture` + UUID-keyed map exists only because its bridge cannot. None of that machinery is ported.
- **`PlayerView` stops creating an `AVPlayer`** and renders the session's. That single change is what makes the CMS path, `playUrl`, `playVod` and `playVodInline` all observable through one `status`.

New code: one `PlaybackSession` class and four `switch` cases. No new dependency; `AVFoundation` is already imported.

### Deviations from Android, each to be commented in code

1. **`player.status` has no HTTP hop.** The envelope is built natively with `ok: true`, `status: 200`, empty `url` (Android reports its local server address), empty `headers`, empty `cookies`. `body` matches `/media` field for field, and is `{}` when nothing has been played — the same thing Android returns with no service.
2. **`playVodInline` goes straight to the built-in player, not the player picker.** An inline vod carries a playlist and `control` semantics that an external player cannot honour. `playUrl` keeps its picker.
3. **`playVod` opens the detail screen and the user taps an episode**; Android's `VideoActivity` auto-plays. Making `VodView` auto-play would change behaviour verified in earlier stages for the ordinary browsing path.
4. **`control("stop")` pauses and clears the item** rather than stopping a foreground service, and `loop` toggles a repeat flag the session applies at end-of-item. `prev`/`next` move within the inline playlist and are no-ops for a single item — Android's are no-ops without a service too.
5. **`player.preloadArtwork` stays rejected.** `AsyncImage` has no preload hook; implementing it would be a no-op that claims success.
6. **An unknown or empty `siteKey` rejects** with `Unknown site: <key>` instead of opening a screen that fails later. The showcase page's `siteKey` field is empty by default, so this is a path a page reaches immediately.

## Acceptance criteria

Offline, deterministic:

- A1. `swift test --package-path ios` passes with all 33 existing tests unchanged in meaning except the one asserting `player.control`/`player.status` are unknown, which this stage makes untrue.
- A2. `player.playVod` resolves a configured `siteKey` and hands the host that site plus a `Vod` carrying `vodId`, `title` and `pic`; an unknown key rejects with `Unknown site:`.
- A3. `player.playVodInline` returns `{"siteKey":"webhome_inline","vodId":…}`, builds the playlist from `episodes`, starts at `mark` when it names one, and falls back `title`→`vod_name`, `pic`→`vod_pic`.
- A4. `player.control` forwards all seven actions and returns `{}`, including for an unknown action.
- A5. `player.status` returns the Android envelope, with `body` carrying `state`, `speed`, `duration`, `position`, `url`, `title`, `artist`, `artwork`, and an empty `body` when nothing is playing.
- A6. `player.preloadArtwork`, `pan.check`, `net.resourceUrl`, `ui.setChrome` and `app.openLive` still reject with `Unknown method`.

Simulator — the stage proof:

- B1. Debug build succeeds and the unmodified showcase page still loads and reports `SDK: native`.
- B2. `vodInline 多集` starts real playback of the inline playlist.
- B3. With the player closed, `播放状态` returns a live envelope whose `body.position` and `body.duration` are real numbers.
- B4. `fm.ctrl pause` / `play` / `next` change playback, each confirmed by a following `播放状态`.
- B5. `调用 fm.vod` with a real configured `siteKey` + `vodId` opens the native detail screen and an episode plays.
- B6. Regression: the CMS grid → detail → episode → built-in player path still plays, and `fm.req JSON` plus the HLS `play` button still behave as in IOS-POC-2B/2D.

## Out of scope

Python, JAR/DEX, JS Spider, type-0 XML, CarPlay, any large UI restructure, `pan.*`, `net.resourceUrl` proxying, a local HTTP server, `ui.setChrome`/`restoreChrome`, `app.open*`, background audio, a media session / lock-screen controls, watch history, and signing or IPA delivery. The 28 usable sources, Remote Raw Config, the relative resource resolver, the LKG cache and Android `main` must be untouched.

## Rollback

One commit on `ios-poc` plus a `recovery/IOS-POC-2E/*` tag. Additive apart from `PlayerView`'s player ownership; reverting restores `e1db99d8` with no data migration and no config change.


## Verification result (2026-09-16)

### Offline — 38 of 39 pass; the one failure is pre-existing

`WANG_MOVIE_JSON=/tmp/webhtv-recha-new.wprHof/wang-movie.json swift test --package-path ios` → **39 tests, 38 pass**. 35 existed at `e1db99d8`; this stage adds 4.

- A1 pass. A2 pass (`opensAConfiguredSiteForPlayVodAndRejectsAnyOtherKey`, which also covers the empty and unknown key and a missing `vodId`).
- A3 pass (`buildsAnInlinePlaylistAndAnswersWithTheStoreKey`, asserting the `{siteKey,vodId}` reply, the `mark` start index, the `vod_name`/`vod_pic` fallbacks and the kept resolver payload).
- A4 pass (`forwardsEveryControlActionAndNeverFails`, all seven actions plus an unknown one).
- A5 pass (`reportsPlaybackStatusInTheEnvelopePagesParse`, envelope and body field by field, plus the idle `{}`).
- A6 pass (`stillRejectsTheMethodsThisSliceLeftOut`, now covering `player.preloadArtwork` and no longer `player.control`/`player.status`).

**The single failure is not from this stage.** `reportsLiveType4SitesFromProvidedConfig` is a live-network smoke test; `88看球` resolved episode `国内线路④` to `http://play.sportsteam368.com/play/wen/?id=…`, an HTML play page, and the test asserts `isDirectMedia`. Confirmed pre-existing by checking out `e1db99d8` into a throwaway worktree and running that test alone: identical URL, identical failure. Provider state, out of this stage's scope, not fixed here.

### Build

`xcodebuild -project ios/WebHTVApp/WebHTVApp.xcodeproj -scheme WebHTVApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build` → **BUILD SUCCEEDED**.

### Simulator — the stage proof, iPhone 17 Pro, unmodified devkit showcase page

- **B1 pass.** The page renders and its badge reads `SDK: native`.
- **B2 pass.** `vodInline 多集` played the inline playlist's MP4 in the full-screen built-in player; the page logged `vod-inline ok (33ms)`.
- **B3 pass.** With the player closed, `播放状态` returned a live envelope — `ok:true`, `status:200`, `url:""`, `headers:{}`, `cookies:[]` — whose body read `duration: 90080`, `position: 28136`, `state: 2`, `speed: 0`, `title: "WebHome SDK Showcase MP4"`. **This is the whole point of the stage: the page can only ask once the player screen is gone.**
- **B4 pass, all three commands confirmed by a following status.**
  - `fm.ctrl play` → next status `state: 3`, `position: 41502`, i.e. resumed and advanced from 28136.
  - `fm.ctrl next` → status `url` changed to the HLS episode and `title` to `"WebHome SDK Showcase HLS"`, `speed: 1`, `position: 10511`.
  - `fm.ctrl pause` → returned `{}` and the next status read `speed: 0`.
- **B5 pass.** `调用 fm.vod` with `siteKey=vod_360`, `vodId=101020` logged `vod ok (229ms)` returning `{}`, opened the native detail screen carrying the page's own title and poster with the `| 360 |` badge and **ten episodes fetched live from 360zy for that id**, and episode 1 played (新攻壳机动队, Kodansha card on screen). A following `播放状态` reported that episode's real stream, so one status covers every playback path.
- **B6 regression pass.** The 愛瓜 grid, its category row, posters and remark badges are unchanged; 莲花楼 → episode 01 → 內建播放器 still plays; the picker still lists all five players; `fm.req JSON` and the HLS `play` button behave as in IOS-POC-2B/2D.

### Ponytail

**Pre-review, against the design** — three findings, all applied before the first line of code, each shrinking the diff:

1. Drop Android's `format` from the inline episode. AVPlayer infers the container; carrying it would be a field nothing reads.
2. No `ObservableObject`. Keeping one `AVPlayer` instance for the app's lifetime and swapping items means no view observes a changing player, so the whole observation layer disappears.
3. Plain `AVPlayer`, not `AVQueuePlayer`. The queue player's native `advanceToNextItem` looks like the lazy answer, but it cannot express `prev` and cannot hold an episode whose URL the page resolves lazily, so its advantage does not hold here.

**Final-diff review** — three findings, all fixed before commit:

1. **A real bug, visible in the stage's own evidence.** `status.title` was reported twice on the single-URL path — the log read `莲花楼 01 莲花楼 01` — because `open(url:title:)` stored the title *and* an item whose name was that same title, and `status()` concatenates the two. Fixed at the root: a single-URL item now carries no name, and `status()` joins only the non-empty parts, which keeps the inline case (`"WebHome SDK Showcase" + "MP4"`) correct. Re-verified in the simulator: the same read now returns `莲花楼 01`.
2. `playableURL(episode)` was parsed twice for every inline episode. Bound once.
3. `Vod`'s new init carried `remarks`, `playFrom` and `playURL` as defaulted parameters no caller passes. Trimmed to the three fields `player.playVod` actually supplies.

Result after fixes: **PASS, no material finding outstanding.**

### Known limits, recorded rather than implied

- **The inline JS resolver is implemented but never exercised live.** The showcase playlist's fourth episode, `Resolver HLS`, is the only one that needs `window.__fmWebHomeInlineResolver`, and `next` was driven only as far as the third. `Coordinator.resolveInlineEpisode` and its `callAsyncJavaScript` round trip are therefore **unverified**, offline and on device.
- `player.playUrl` reports an empty `artwork`, because `Actions.play` carries only a URL and a title. `playVod`, `playVodInline` and the CMS path all report the real poster. Widening the `playUrl` closure was left to whoever needs it.
- `player.preloadArtwork` still rejects with `Unknown method`.
- `prev`/`next`/`loop` are only meaningful for an inline playlist; for a single item they are no-ops, as they are on Android without a service.
- No background audio, media session or lock-screen controls. Closing the player pauses.
- **Nothing ran on a real device.** Still no `CODE_SIGN` or `DEVELOPMENT_TEAM` in the project.
- Verification ergonomics: the simulator's keyboard capitalised the first character of the page's `siteKey` field, which made `vod_360` arrive as `Vod_360` and reject. Worked around by turning **Auto-Capitalization off in the simulator device's own preferences** and relaunching. That is a device setting, not an app or repository change, and nothing in the app was modified for it.
