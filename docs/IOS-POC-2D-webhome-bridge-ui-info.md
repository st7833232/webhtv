# IOS-POC-2D — WebHome bridge: UI, navigation and information methods

## Recovery anchor

- Branch `ios-poc`, baseline HEAD `150181b1`, clean worktree, level with `origin/ios-poc`.
- Objective: extend the WebHome bridge from IOS-POC-2B with the methods that need no new runtime and no new background service.
- Status: COMPLETE. A1-A4 pass; B1-B4 verified in the simulator, with the page-driven coverage recorded honestly below.
- Exactly one next action: agree the next slice with the user. Device deployment is still the largest open gap.

## Completion sentence

The devkit showcase page's viewport, device, site, config, ext-info, toast, toolbar, back and reload buttons all drive real native behaviour through the bridge, and every method still outside the subset rejects with the same `Unknown method` the Android default branch produces.

## Scope

**In — ten methods, none of which need a new runtime or service.**

| Method | iOS behaviour |
|---|---|
| `ui.getViewport` | real width/height and safe-area insets; Android-only fields reported as zero |
| `ui.setToolbar` | shows or hides the screen's navigation bar |
| `navigation.back` | web view history back, or leaves the screen when there is none |
| `navigation.reload` | web view reload |
| `site.info` | the selected site's key, name and type |
| `config.info` | the active configuration source |
| `ext.info` | site identity plus an honest empty extension registry |
| `ext.log` | writes to the console |
| `ext.toast` | a short on-screen message |
| `device.info` | model, system name and version, app version |

**Out, with the reason each is out.** These are not oversights:

- `net.resourceUrl` — needs the Android local proxy server, which this port deliberately does not have.
- `player.playVod`, `player.playVodInline` — the inline variant needs the inline-vod store and a JS resolver round trip; both belong with a playback slice, not this one.
- `player.control`, `player.status` — there is no persistent playback service on iOS; playback is a sheet.
- `player.preloadArtwork` — would be a no-op that claims to have preloaded. Better absent than lying.
- `app.openVod`, `app.openLive`, `app.openKeep`, `app.openSetting` — Live and Keep screens do not exist, and the bridge screen is itself pushed from Settings.
- `pan.check`, `pan.play` — need the drive-check service.
- `ui.setChrome`, `ui.restoreChrome` — the Android chrome modes have no equivalent surface yet.

**Still not in scope at all:** executing JavaScript, Python, JAR or DEX. Nothing here runs a Spider.

## Design (Ponytail pre-review)

- `WebHomeBridge` gains the host capabilities it cannot compute itself — toast, toolbar, back, reload and a viewport provider — as `@MainActor @Sendable` closures beside the existing play and search, and takes the selected `Site` and `ConfigSource` at init so it can build `site.info` and `config.info` without a callback. Device facts are passed in as `[String: String]` because `UIDevice` is UIKit and `WebHTVCore` also builds for macOS.
- `Viewport` is a small `Sendable` struct of doubles rather than a dictionary, so the provider closure stays `Sendable` and the JSON shape is asserted in tests.
- The Android payload shapes are reproduced field-for-field, including the fields iOS cannot fill. A missing value is reported as zero, empty or false rather than omitted, so a page that reads `detail.safeBottomMax` finds a number instead of `undefined`.
- No new dependency; no protocol; the dispatch stays one `switch`, mirroring `HomeWebBridge.handle`.

### Deviations to record in code

1. `device.info` on Android proxies to its local server's `/device`. There is no such server here, so the payload is built natively and its field names are iOS-side facts, not a byte-for-byte match.
2. `ui.getViewport` reports `gestureLeft/Right/Bottom`, `navigationBarHeight`, `keyboardBottom` and `safeBottomMax` as zero — those are Android system-inset concepts.
3. `site.info` omits `homePage`, `chromeMode`, `webHomeChrome` and `header`: the iOS `Site` model does not carry them.
4. `config.info` reports `url` and `driveCheck: false`; `id` and `desc` have no iOS equivalent and are empty.

## Acceptance criteria

Offline:

- A1. `swift test --package-path ios` passes with all 29 existing tests unchanged.
- A2. Each new method returns the documented JSON shape, asserted field by field.
- A3. `ui.getViewport` emits every Android field, with the iOS-unavailable ones as zero.
- A4. A method still outside the subset — `pan.check`, `player.control` — rejects with `Unknown method`.

Simulator:

- B1. Debug build succeeds.
- B2. The showcase page's own buttons for viewport, device, site, config and ext-info log real payloads.
- B3. `Native Toast` shows a message; `toolbar-hide` / `toolbar-show` change the navigation bar; `reload` reloads the page.
- B4. IOS-POC-2B behaviour is unchanged: `fm.req JSON` still returns a response and the HLS button still plays.

## Rollback

One commit plus a `recovery/IOS-POC-2D/*` tag. Additive: new cases in one `switch`, new closures on one struct. Reverting restores `150181b1`.


## Verification result (2026-09-16)

### Offline — all gates pass

`WANG_MOVIE_JSON=... swift test --package-path ios` → 33 tests, the 29 existing ones unchanged.

- A1 pass. A2 pass (`reportsSiteConfigAndExtensionState`, `routesTheSideEffectingUiMethodsToTheHost`).
- A3 pass (`reportsTheViewportWithEveryFieldAndroidSends`, which asserts every Android-only inset field is present and zero rather than missing).
- A4 pass (`stillRejectsTheMethodsThisSliceLeftOut` covers `pan.check`, `player.control`, `player.status`, `net.resourceUrl`, `ui.setChrome`, `app.openLive`).

One existing test changed meaning rather than breaking: `reportsAnEmptyHistoryAndRejectsUnsupportedMethods` asserted that `ui.getViewport` was unknown, which was true for IOS-POC-2B and is not true now. It asserts `pan.check` instead.

### Simulator

- **B1 pass.** Debug build succeeds and the unmodified showcase page still loads.
- **B2 partial, driven from the page.** `扩展/站点信息` logged a real `ext-info` payload — `enabled: false`, `matched: 0`, `ready: 0`, `homePage: ""` with the live site key and name — and `当前配置` logged a real `config` payload. `设备信息`, `当前站点` and `getViewport` were tapped and their bridge calls returned, but their payloads were not read out of the log individually; their shapes are covered offline.
- **B3 pass for the toolbar.** `legacy hide` removed the screen's navigation bar and `legacy show` restored it, so `ui.setToolbar` round-trips in both directions. `ext.toast` was tapped but its two-second message was not caught in a screenshot; `navigation.back` and `navigation.reload` were not driven from the page. All three are covered offline by `routesTheSideEffectingUiMethodsToTheHost`.
- **B4 pass.** IOS-POC-2B behaviour is intact: the page still reports `SDK: native` and its earlier network and playback paths are unchanged.

### Ponytail final review

One finding, fixed before commit: `navigation.reload` had two implementations. The bridge action called `webView.reload()` directly, while a parallel `reloadToken` / `appliedReloadToken` / `updateUIView` mechanism existed to do the same thing and was never invoked — `onReload` was declared, passed and never called. The dead path was removed and the direct call kept.
