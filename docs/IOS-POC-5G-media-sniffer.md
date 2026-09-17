# IOS-POC-5G — the WebView media sniffer

Stage record. Sweep method: `docs/IOS-POC-5E-all-source-sweep.md`. Runtime contract:
`docs/IOS_SPIDER_RUNTIME_SPEC.md`.

## Result

**Playable sources: 29 → 35 of 45.** Every remaining failure is provider state; none is a defect in
this app.

| | 5F | 5G |
|---|---:|---:|
| PLAYABLE | 29 | **35** |
| DEAD-MEDIA | 5 | 1 |
| NO-PLAY | 2 | 0 |
| NO-EPISODE | 2 | 2 |
| EMPTY | 7 | 7 |

Recovered: `vod_优酷`, `非凡采集资源`, `量子采集资源`, `88看球` (all handed back a player page
instead of a stream) and `csp_動漫巴士` / `巴士动漫` (their rule file has no play-page extraction at
all and expects a sniffer).

| | listed | playable |
|---|---:|---:|
| native CMS (type-0/1/4) | 30 | **28** |
| ported `csp_*` spider | 15 | **7** |

## Why a JavaScript hook and not request interception

Android's sniffer overrides `WebViewClient.shouldInterceptRequest`, which sees every subresource
request a page makes. **`WKWebView` has no equivalent.** `WKNavigationDelegate` only reports
navigations, not the XHR or media requests a player issues, and `WKURLSchemeHandler` cannot be
registered for `http`/`https`. There is no supported way to observe a WKWebView's subresource
traffic from Swift.

So the sniffer injects JavaScript at document start into every frame and hooks the APIs a player
actually uses:

- `XMLHttpRequest.prototype.open` — how hls.js and every 苹果CMS player skin fetch a playlist
- `window.fetch` — the same, for newer players
- the `src` property on `HTMLVideoElement` / `HTMLAudioElement` / `HTMLSourceElement` — a native
  player assigns the stream rather than requesting it in a way a hook could see
- a `MutationObserver` on `src` attributes, plus a scan of existing nodes, for markup that was
  never touched by script

Candidates are posted to Swift, which does the keyword matching — so the JavaScript is identical
for every site and rule set.

**This is best effort, not a guarantee.** A player that obtains its stream inside a Worker, through
WASM, or by a route none of the above covers will not be caught. The sniffer returns nil in that
case so the caller falls back rather than hangs.

## The probe, and why it has to exist

The obvious wiring — "if it does not look like media, sniff it" — would have been a regression. The
extension heuristic cuts both ways:

- `…/share/<id>` is a player page with no extension
- `…/play/e0R98E7b` is a real stream with no extension (`vod_极速` serves this and always worked)

Sniffing the second costs a web view and several seconds on a source that was already fine. So
`MediaProbe.classify` fetches the first 1 KB with a `Range` request and decides from the
`Content-Type` and the leading bytes. Only a `page` is sniffed; `media` passes straight through and
`unknown` is let through untouched rather than blocked.

`SourceClient.resolveMedia` is the whole policy:

```
isDirectMedia(url)            -> use it, no probe
probe(url) != .page           -> use it
sniff(url) ?? url             -> improved if caught, unchanged if not
```

A spider's `parse: 1` skips the probe, because that flag is the spider saying outright that the URL
is a page.

**A sniff miss returns the original URL, not nil.** Failing to improve something must not make it
worse than before this stage.

## Verification

- `swift test --package-path ios` with `WANG_MOVIE_JSON` → **74 tests**. One stable failure, the
  pre-existing live-network `reportsLiveType4SitesFromProvidedConfig` (88看球) — note this stage
  makes that site playable through `SourceClient`, but the test drives `CMSClient` directly, which
  has no sniffer hop.
- `xcodebuild … -scheme WebHTVApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
  -configuration Debug build` → **BUILD SUCCEEDED**.
- Seven offline tests in `MediaSnifferTests.swift` prove each hook path independently: XHR, `fetch`,
  a scripted `video.src`, a `<source>` in static markup, first-match-wins, that a page of
  stylesheets and posters yields nothing, and that an unreachable host returns nil instead of
  running to the timeout.
- **Simulator, end to end (iPhone 17 Pro, iOS 26.3):** 優酷 → 车轮下的真相 → the **`ukyun`** line,
  whose episodes are `…/share/<id>` player pages → the episode grid disabled while the sniff ran →
  player picker → built-in player **played, the picture advancing from the sponsor caption into the
  title card**. This is the path that was DEAD-MEDIA before this stage.
- Full 45-source sweep re-run; no previously working source regressed.

## Known limits

- **Sniffing is timing-sensitive.** In one sweep run `非凡采集资源` and `量子采集资源` missed and in
  the next both succeeded; they are the first two sources that trigger a sniff, so the first web
  view pays WebKit's start-up cost. The 12-second timeout absorbs this most of the time. Treat a
  single sweep row as a sample, not a verdict.
- **Headers still do not reach `AVPlayer`.** The web view sends a correct `Referer` while sniffing,
  and then the resolved URL is handed to `AVPlayer` without one, because `PlayerView` does not
  thread `AVURLAsset` options through. A CDN that checks `Referer` on the stream itself will still
  fail.
- The sniffer adds a web view and up to 12 seconds to the playback path **only** for URLs the probe
  classifies as a page.
- `csp_AG動漫` is still DEAD-MEDIA: its media 404s, which no sniffer can fix.
- `csp_YLSP` / `永乐影视` are still NO-EPISODE — the provider's listing URL 404s.

## Pre-existing test flakiness this stage exposed

`WebHomeBridgeTests` records bridge callbacks with `actions.playVod = { … Task { await opened.add(…) } }`
and then reads `opened` immediately, without waiting for that `Task`. It passed while the suite was
fast; the seven new `@MainActor` sniffer tests hold the main actor long enough that the write
sometimes lands after the read. Two tests now fail intermittently —
`buildsAnInlinePlaylistAndAnswersWithTheStoreKey` and
`opensAConfiguredSiteForPlayVodAndRejectsAnyOtherKey` — always one or neither, never reproducibly.

**This is a defect in those tests, not in the bridge**, and `WebHomeBridgeTests.swift` was outside
this stage's declared scope, so it is reported rather than fixed. It should be fixed before the next
stage, because flaky tests corrupt every later verification.

## Files

| file | change |
|---|---|
| `Sources/WebHTVCore/MediaSniffer.swift` | new — `MediaProbe`, `MediaSniffer`, the injected hook |
| `Sources/WebHTVCore/SourceClient.swift` | `resolveMedia` policy on both branches |
| `Tests/WebHTVCoreTests/MediaSnifferTests.swift` | new — 7 offline tests + 1 gated live probe |
| `Tests/WebHTVCoreTests/SourceClientTests.swift` | sweep reuses `MediaProbe` instead of its own copy |
