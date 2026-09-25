# IOS-POC-2B — WebHome bridge proof (WKWebView + WKScriptMessageHandler)

## Recovery anchor

- Branch `ios-poc`, baseline HEAD `14bad772`, clean worktree, level with `origin/ios-poc` at plan time (2026-09-16 10:22 CST).
- Objective: prove an existing WebHome page can call an iOS native bridge and complete a real request and playback flow, using a controlled subset of the established RPC contract.
- Status: IMPLEMENTED. Offline gates A1-A5 pass; B1-B3 verified in the simulator; B4 partial and B5 not exercised live, as recorded below.
- Exactly one next action: agree the following POC-2 slice with the user. Device deployment and the remaining bridge methods are both open. (Corrected 2026-09-25: both have moved since. IOS-POC-2D (`6d926ebd`) added the UI, navigation and info methods, IOS-POC-2E (`588cb85a`) the playback methods, verified further in IOS-POC-2F (`46a00eb4`), and the IOS-POC-11 SideStore pipeline has published device builds since 2026-09-22. `net.resourceUrl`, `pan.*`, `app.open*`, `ui.setChrome`, `ui.restoreChrome` and `player.preloadArtwork` still reject through the `default` branch, `ios/Sources/WebHTVCore/WebHomeBridge.swift:305-396`.)

## Completion sentence

The iPhone app opens the repository's existing WebHome showcase page in a `WKWebView`, and that unmodified page's own buttons drive `net.request`, `player.playUrl`, `app.search`, `app.history` and `cache.get/set/del` through a native Swift bridge, with at least one live HTTP request and one real playback started from the page.

## Allowed paths

- `ios/Sources/WebHTVCore/WebHomeBridge.swift` (new)
- `ios/WebHTVApp/Sources/WebHTVApp.swift`
- `ios/WebHTVApp/WebHTVApp.xcodeproj/project.pbxproj` (resource reference only)
- `ios/Tests/WebHTVCoreTests/WebHomeBridgeTests.swift` (new)
- `docs/IOS-POC-2B-webhome-bridge.md`, `docs/current-task-state.md`

Protected pre-existing dirty paths: none. Android sources under `app/` are read-only for this task.

## Estimate

Agent elapsed wall-clock in this workspace.

| Phase | Estimate |
|---|---|
| Bridge core + SDK injection | ~30 min |
| App surface and Xcode resource wiring | ~20 min |
| Offline tests | ~15 min |
| Simulator verification of the page's own buttons | ~25 min |
| Docs, commit, tag | ~10 min |

Total ~100 min; expected finish ~12:05 CST. If the Xcode resource reference fights the hand-written `project.pbxproj`, fall back to copying the page into `Resources/` and record the duplication rather than extending the task.

## Evidence — the contract, read from source

Read at `app/src/main/java/com/fongmi/android/tv/web/`:

1. **Transport.** `HomeWebController.java:54` names the injected object `fongmiBridge`; `HomeWebController.java:119` installs it. JS calls `fongmiBridge.invoke(requestId, method, payloadJson)` (`HomeWebBridge.java:61`). Native replies by evaluating `window.fongmiNative.resolve(<id>, <json>)` or `.reject(<id>, "<message>")` (`HomeWebBridge.java:454-467`).
2. **The JS SDK is injected by the app, not shipped by the page.** `HomeWebController.getSdk()` (`:761-880`) defines `window.fongmiNative`, `window.fongmi` and the short alias `window.fm`. Pages only ever touch `fm.*` / `fongmi.*`. **Porting the bridge therefore means porting this script text, not inventing an API.**
3. **Subset semantics.**
   - `net.request` → `WebCall.request` (`WebCall.java:38`). Success returns `{ok,status,url,headers,cookies,body}`; `responseType` of `base64` or `json` changes only `body` (`WebCall.java:137-151`). Failure returns `{ok:false,status:500,body:"",error,headers:{}}` (`:210-218`).
   - `player.playUrl` → payload `{url,title,pic,wallPic,content}`, starts playback, returns `{}` (`HomeWebBridge.java:151-166`).
   - `app.search` → payload `{keyword,pic,wallPic,direct}`, opens search, returns `{}` (`:293-303`).
   - `app.history` → `gson.toJson(History.get())`, a JSON array (`:325-327`).
   - `cache.get/set/del` → `Prefers` under the key `"cache_" + (rule.isEmpty ? "" : rule + "_") + key` (`:359-372`). `cache.get` returns a **JSON string**, the other two return `{}`.
4. **The proof page already exists in this repository.** `webhome-devkit/templates/homepages/app-capabilities-showcase.html` carries live buttons whose `data-action` values cover the whole approved subset: `req-json`, `req-text`, `play-hls`, `app-search`, `history`, `cache-get`, `cache-set`, `cache-del`. No test page needs to be written, and the page is used unmodified.

## Platform constraint that shapes the design

Android's `@JavascriptInterface` methods are **synchronous and return values**. `WKScriptMessageHandler` is one-way and asynchronous. Three contract members depend on synchronous returns:

- `resultLength` / `resultChunk` / `clearResult`, used by the SDK's `hydrate()` when a result exceeds 12000 characters (`HomeWebBridge.java:41,84-99`).
- `resourceUrl`, which returns a URL on the Android app's local HTTP server (`HomeWebBridge.java:74-81`).

## Alternatives considered

| Option | Verdict |
|---|---|
| **No change** | Rejected. The roadmap's POC-2 is the approved next stage and nothing else proves hybrid feasibility. |
| **Unmodified upstream** — reproduce every method, a local HTTP server for `resourceUrl`, and synchronous chunking via `WKScriptMessageHandlerWithReply` | Rejected for this stage. It requires an embedded HTTP server, which the project's constraints explicitly avoid, and `WKScriptMessageHandlerWithReply` would change the SDK text that existing pages depend on. Both belong to a later full-bridge stage. |
| **Narrow adapted** — port the SDK text as-is, route `invoke` over `postMessage`, implement only the approved subset, and avoid the synchronous members entirely | **Chosen.** |

The chosen option avoids the synchronous members rather than emulating them: the native side simply never emits `__fmResultId`, so `hydrate()` passes results through untouched, and `evaluateJavaScript` carries large payloads directly. This is why no local server and no reply-handler variant are needed.

## Design (Ponytail pre-review)

Reuse over new code:

- `URLSession.webHTV` already carries the 10 s timeout policy; `net.request` uses it rather than a second session.
- `PlayerPickerView`, `ExternalPlayer` and `PlayerView` already exist; `player.playUrl` presents the existing picker instead of a second player path.
- `Episode.mediaURL`'s scheme guard is reused for `player.playUrl` validation.
- No new dependency; `WebKit` is a system framework.

New code is one file, `WebHomeBridge.swift`, holding the injected SDK text, the message decoding, the subset dispatch and the reply encoding. No protocol, no registry, no per-method type — the dispatch is one `switch`, mirroring `HomeWebBridge.handle`.

### Deliberate deviations from Android, to be recorded in code comments

1. `net.resourceUrl` returns the raw URL instead of a local proxy address. No local HTTP server exists on this path and the method is out of subset; the showcase's `res-image` / `res-video` buttons will therefore show unproxied media.
2. Results are never chunked, as explained above.
3. `app.history` returns `[]` because the iOS app has no watch-history store yet. That is the honest current state, not a stub pretending to succeed.
4. Methods outside the subset reject with `Unknown method: <name>`, exactly as `HomeWebBridge.handle`'s `default` branch does. An existing page that calls, say, `ui.getViewport` degrades the same way it would on an older Android build.

## Acceptance criteria

Offline, deterministic — these gate the stage:

- A1. `swift test --package-path ios` passes, including all 16 existing tests unchanged.
- A2. The cache key builder produces `cache_key` with no rule and `cache_rule_key` with one, matching `HomeWebBridge.cacheKey`.
- A3. A `net.request` success response encodes `ok`, `status`, `url`, `headers`, `body`, and honours `responseType` of `json` and `base64`; a failure encodes `{ok:false,status:500,error}`.
- A4. Message decoding rejects a payload that is not an object, and an unknown method produces a reject rather than a crash.
- A5. The injected SDK text contains `window.fm`, `window.fongmi` and `window.fongmiNative` and routes `invoke` through `webkit.messageHandlers`.

Live, in the simulator — the actual stage proof:

- B1. Xcode Debug build succeeds and the unmodified showcase page renders in the app.
- B2. `fm.req JSON` returns a real HTTP response to the page and the page displays it.
- B3. `play-hls` starts actual playback through the existing player picker.
- B4. `cache-set` then `cache-get` returns the stored value across a page reload; `cache-del` clears it.
- B5. `app-search` and `history` return without error; `history` returning `[]` is recorded as expected, not as a failure.

## Out of scope

Type-0 XML, JS Spider, Python, DEX/JAR, CarPlay, any UI restructure, `pan.*`, `ui.*`, `device/site/config/ext.*`, `player.playVod*`, `net.resourceUrl` proxying, a local HTTP server, WebHome sites in `wang-movie.json`, and signing or IPA delivery. The existing 28 usable sources and the Android `main` line must be untouched.

## Rollback

One commit on `ios-poc` plus a `recovery/IOS-POC-2B/*` tag. The bridge is additive: a new file plus one new screen reachable from Settings. Reverting restores `14bad772` behaviour with no data migration and no change to the CMS path.


## Verification result (2026-09-16)

### Offline gates — all pass

`WANG_MOVIE_JSON=... swift test --package-path ios` → 23 tests, the 16 existing ones unchanged.

A1 pass. A2 pass (`buildsTheSameCacheKeyAsTheAndroidBridge`, `storesAndClearsCacheEntriesThroughTheContract`). A3 pass (`encodesTheNetRequestShapeWebHomePagesParse`). A4 pass (`decodesTheInvokeTripleAndRejectsMalformedMessages`, `reportsAnEmptyHistoryAndRejectsUnsupportedMethods`). A5 pass (`injectsTheSameSdkSurfaceExistingPagesExpect`, which also asserts the Android-only synchronous accessors are absent).

### Simulator — the stage proof

The unmodified `webhome-devkit/templates/homepages/app-capabilities-showcase.html` is referenced into the app bundle from its devkit location, not copied, and opens from Settings → 開發者 → WebHome 橋接驗證.

- **B1 pass.** Debug build succeeds; the page renders and its own status badge reads **`SDK: native`**, so the page detected `window.fm` and took its native path.
- **B2 pass.** The page's `fm.req JSON` button logged `req-json ok (799ms)` with the full contract shape — `ok`, `status`, `url`, `headers` (`Server: nginx/1.20.1`, `Content-Length: 253`), `body`, `cookies`. The remote answered 400 for its own reasons; the round trip is what this proves.
- **B3 pass.** The page's HLS play button opened the existing player picker and the stream **played in the built-in player**, completing `page → fm.play() → postMessage → WKScriptMessageHandler → WebHomeBridge → PlayerPickerView → AVPlayer`.
- **B4 partial.** `cache-set ok (12ms)` is confirmed live. The `cache.get` read-back and `cache.del` were **not** exercised in the page; they are covered only by the offline round-trip test.
- **B5 not exercised live.** `app.search` and `app.history` were not driven from the page; both are covered only by offline tests. Nothing suggests they fail — they were simply not reached.

The page is long and its buttons carry emoji labels that the simulator renders as replacement glyphs, which made locating specific controls slow. That is a verification-ergonomics limitation, not an app defect.

### Notes on fidelity, beyond the four approved deviations

- `URLSession` merges repeated response headers into one comma-joined value, so `headers` never contains an array as Android's can, and `cookies` is reported as a single-entry list rather than one entry per `Set-Cookie`.
- The page's badge shows `mode: unknown`; `window.fongmiClient.mode` is set to `mobile`, so the page derives that label from something else. Cosmetic, not investigated.

### Out-of-scope defect observed

Settings still reads "目前支援 28 個 type-1 JSON CMS 來源。" The count is right but the label has been stale since type-4 support landed in IOS-POC-4A. Not touched here. (Corrected 2026-09-25: the footer was rewritten in IOS-POC-1F, see `docs/IOS-POC-1F-config-sources.md`.)


## IOS-POC-2C — Debug-only CJK fallback for the simulator (2026-09-16)

Every CJK glyph in the WebHome page rendered as tofu while Latin rendered normally, which made the page's controls unidentifiable and is the direct reason B4 and B5 above were left incomplete.

### Diagnosis

Not encoding and not the bridge. The page declares `<meta charset="utf-8">`, and its only non-ASCII content is CJK, CJK punctuation, fullwidth forms and five middle dots — **zero non-BMP characters, so no emoji are involved**. The same app's SwiftUI chrome renders Chinese correctly, so the gap is inside the web content process only. The clincher: the log's `[上午HH:MM:SS]` prefix from `toLocaleTimeString()` also failed, and 上/午 are the most basic shared Han characters, so this is a wholesale fallback failure rather than a coverage gap.

The simulator's public font path carries Hiragino (Japanese) but no PingFang; its only PingFang is `PrivateFrameworks/FontServices.framework/CorePrivate/PingFangUI.ttc`, a system-UI copy UIKit can use and the sandboxed web content process cannot.

### Fix

A `WKUserScript` at document end appends one stylesheet naming `"PingFang SC", "PingFang TC", "Hiragino Sans", "Hiragino Kaku Gothic ProN"`. Wrapped in `#if DEBUG` on purpose: a release build must render WebHome pages exactly as Android does, and a development convenience must not become a product behaviour difference.

Verified: the page now renders `能力测试台`, `真实资源与 App SDK 调用样例`, `原生播放`, `缓存`, `App 入口` and every control label correctly.

### Known limits

- The log panel's `[上午…]` prefix is still tofu. The `pre, code, .log` rule lists the CJK families after the monospace ones and the fallback does not reach them. Cosmetic only — the log's own content is ASCII — so it was left alone rather than tuned by guesswork.
- Naming a font proves the simulator *can* reach a CJK face; it does not prove anything about a real device. The device path remains unverified until deployment exists.
- B4 and B5 are still offline-only. Two further attempts to drive `cache.get` and `app.history` from the page did not register, because the page's scroll momentum moves the controls between screenshot and tap. That is an interaction-timing problem, not a font or bridge problem.
