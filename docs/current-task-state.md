# Current Task State

## Original Goal

Port WebHomeTV to iPhone with an Android-like UI, drive the user's own `wang-movie.json`, and offer built-in, Infuse, Fileball, SenPlayer and VidHub playback. The Google TV `csp_JPianAmns` repair is not in scope.

## Current Scope

- Branch `ios-poc`, HEAD after IOS-POC-5L. `03ba9cf0` **was pushed to `origin/ios-poc` on 2026-09-17** at the user's explicit instruction; the IOS-POC-5L commits sit on top of it and are local. **Re-check with `git log` rather than trusting any id quoted here.**
- Android `app/` is read-only for all iOS work and has never been modified: `git diff <branch-point>..HEAD -- app/` is empty, and every commit on this branch touches only `ios/`, `docs/`, `scripts/`, `AGENTS.md` and `.codex/`.
- **The input configuration lives in the scratchpad, not `/tmp`.** `/tmp/webhtv-recha-new.wprHof/` was cleared mid-session; `wang-movie.json` was re-fetched from the user's own GitLab and its SHA-256 matches the recorded baseline byte for byte. Re-fetch it from `https://gitlab.com/st7833232/recha/-/raw/main/wang-movie.json` if it is missing. `recha-main.zip` was **not** restored, so `scripts/audit_spider_jars.py` cannot be re-run without downloading it again.
- Stages through IOS-POC-4J have an annotated `recovery/<task-id>/*` tag; tags through `IOS-POC-1H` are on the remote. **Recovery tags became opt-in on 2026-09-16** (AGENTS.md §6), so IOS-POC-5A onwards are deliberately untagged.

## Non-Negotiable Constraints

- Preserve Android `main`, unrelated dirty files, and the repository's task-guard / Ponytail / research / approval gates. Do not push, sign, package or publish without user authorization.
- No jailbreak, always-on self-hosted server, or recurring infrastructure cost for the personal iPhone path.
- **ATS: superseded by explicit user decision (2026-09-15, IOS-POC-4B).** The user was offered a narrow per-domain exception, no change, or global cleartext, was told the earlier records forbid weakening ATS globally for one site, and chose global cleartext. `NSAllowsArbitraryLoads` ships. Keep it; do not broaden further — no server-trust override, no pinning bypass — without a fresh decision.
- **Do not claim iOS executes Python, JAR or DEX — it does not, and that is deliberate.** A CatVod
  spider runtime *does* exist since IOS-POC-5A, but it works by **reimplementing the CatVod Spider
  contract in JavaScript on JavaScriptCore**, never by running Android bytecode. The decompiled
  Java is a specification only. `docs/IOS_SPIDER_RUNTIME_SPEC.md` is the single source of truth for
  that boundary; an earlier version of this line read “No Spider runtime exists” and was left stale
  by the IOS-POC-5A/5B commits.
- There is still **no Python runtime and no drpy JavaScript loader.** `host.js` is written to be
  drpy-compatible (`pdfh`/`pdfa`/`pd`) and `ConfigSource` resolves `./py/` and `./drpy_libs/`
  references, but nothing loads or executes either. Locating a resource is not running it.

## Stage index

Each stage owns a durable document where one exists; the rest are recorded here and in their commit.

| Stage | What it delivered | Record |
|---|---|---|
| 1A–1D | Config classification, type-1 MacCMS flow, SwiftUI/AVPlayer shell | commits |
| 1E | Imported-config persistence | `docs/IOS-POC-1E-config-persistence.md` |
| 1F | Local-file / remote Raw URL config sources, relative-resource resolver | `docs/IOS-POC-1F-config-sources.md` |
| 1G | Launch refresh with 2 s/5 s/15 s retry | same document |
| 1H | Invalid config URLs are reported instead of ignored | same document |
| 2A | Five selectable players | commit |
| 2B | WebHome bridge over `WKWebView` + `WKScriptMessageHandler` | `docs/IOS-POC-2B-webhome-bridge.md` |
| 2C | Debug-only CJK font fallback for the simulator | same document |
| 2D | Bridge UI, navigation and information methods | `docs/IOS-POC-2D-webhome-bridge-ui-info.md` |
| 2E | Bridge playback half on a persistent playback session | `docs/IOS-POC-2E-webhome-bridge-playback.md` |
| 2F | Drove the five playback paths 2E left unexecuted; no code change | same document |
| 3A–3C | Android-like surfaces, wallpaper, oversized-logo removal | commits |
| 3D | Uniform 2:3 poster cells | commit |
| 3E | Built-in player presented full screen | commit |
| 4A | type-4 CatVod remote API sources | `docs/IOS-POC-4A-type4-sources.md` |
| 4J | type-0 MacCMS XML sources | `docs/IOS-POC-4J-type0-xml-sources.md` |
| 4B | ATS cleartext decision | same document |
| 4E–4I | Request timeout, category browsing, two-level categories, pagination, type-1 posters | commits |
| 5A | CatVod spider runtime on JavaScriptCore + `CatVodHost` + the `AppGet` port | `docs/IOS_SPIDER_RUNTIME_SPEC.md`, `docs/CSP_PORTABILITY_MATRIX.md`, `docs/CSP_MIGRATION_STATUS.md` |
| 5B | `XBPQ` and `XYQHiker` rule engines | `docs/CSP_MIGRATION_STATUS.md` |
| 5C | Reconciled this document and the handoff with the code at `226e826c`; no functional change | this document |
| 5D | The 15 ported spider sites reach the app UI (`SourceClient`); Xcode 27 build repair | `docs/IOS-POC-5D-spider-sites-in-app.md` |
| 5E | End-to-end sweep of all 45 listed sources, with a media probe | `docs/IOS-POC-5E-all-source-sweep.md` |
| 5F | Fixed five spider/host defects the sweep found; 27 → 29 playable | `docs/IOS-POC-5F-spider-defect-fixes.md` |
| 5G | WebView media sniffer + first-bytes probe; 29 → 35 playable | `docs/IOS-POC-5G-media-sniffer.md` |
| 5H | Removed the `Task { }` race that made four bridge tests flaky | the 5G document |
| 5I | XBPQ knew only the older 苹果CMS skins; 永樂 rendered its nav as films | `docs/IOS-POC-5I-xbpq-listing-templates.md` |
| 5J | One 全部 chip instead of two; CatVod filter rows under the category row | `docs/IOS-POC-5J-category-filters.md` |
| 5K | Category rows scroll away; Top button; collapsible child rows | `docs/IOS-POC-5K-scrolling-and-collapsible-categories.md` |
| 5L | `AppQi`, `App99`, `App3Q` and `Bili` ported (+16 sites, 45 → 61 listed); IV-prefixed AES + zlib in the host; `Site.id` made unique | `docs/IOS-POC-5L-appqi-app99-app3q-bili.md` |
| 5M | 薦片 driven by `JianPian` although its configured class is a protected shim (+1 site, 62 listed) | `docs/IOS-POC-5M-jianpian.md` |
| 5N | Assessment: do the other 34 protected sites have unprotected equivalents? 7 more do | `docs/IOS-POC-5N-protected-site-equivalents.md` |
| 5O | Remote compatibility pack: spider scripts update without rebuilding the app | `docs/IOS-POC-5O-remote-compatibility-pack.md` |
| 5P | A spider's request headers reach `AVPlayer`, the probe and the sniffer | `docs/IOS-POC-5P-player-request-headers.md` |

## Important Decisions

- Input baseline: Recha `wang-movie.json`, 125,864 bytes, SHA-256 `b17576e34eb42b4c589a818ef8b5ec2655a2c7a188d626fc427c37d628897168`, 167 sites (2 type-0, 22 type-1, 137 type-3, 6 type-4). The archive itself is external, not committed.
- **SUPERSEDED 2026-09-16 (IOS-POC-5A): the 90 `csp_*` sites are not “structurally out of reach”.**
  That verdict came from observing `classes.dex`, which says nothing about portability. The full
  static audit (`scripts/audit_spider_jars.py`, re-runnable) found **54 of the 90 sites portable**,
  spanning **26 of the 51 distinct classes** (33 rows in the audit, which keys a class per JAR);
  **34 sites / 23 classes** are blocked by a **native-encrypted payload** (`aowu-0722.jar`,
  `fan-0720.jar`) whose `csp_*` classes are empty shims; **2 sites / 2 classes** are only **missing
  downloads**, which is not a technical verdict. Authoritative tables:
  `docs/CSP_PORTABILITY_MATRIX.md` (audit) and `docs/CSP_MIGRATION_STATUS.md` (progress). Do not
  attempt to defeat the native protection on those two JARs.
- **The 42 Python sites are expensive, not impossible.** Measured 2026-09-16: only 1 of the 38 present `.py` files references `android.`; the rest are standard library plus `requests`, `pycryptodome` and the host-supplied `base` module. The blocker is embedding CPython and those packages, which is architecture-compatible. An earlier record counted them among the 132 "structurally out of reach" and that was wrong. The 5 drpy JavaScript sites are the most plausible of all, since iOS ships JavaScriptCore. Evidence: `docs/IOS-TYPE3-REACHABILITY-2026-09-16.md`.
- With type-0 done (IOS-POC-4J), **every non-Spider source type in this configuration is supported**.
  Since IOS-POC-5A/5B, 15 of the 137 type-3 entries are driven too — see the coverage table below.
- **The spider runtime reimplements the CatVod contract; it does not run Android code.** Every
  `Spider.java` method is text in, text out, so a JavaScript reimplementation is indistinguishable
  from the DEX original to everything above it. One `JSContext` and one serial queue per site, one
  shared `CatVodHost`, and `host.js` is the only JS SDK — a second runtime for drpy must never be
  built. Full contract: `docs/IOS_SPIDER_RUNTIME_SPEC.md`.
- The WebHome JS SDK is injected by the app, not shipped by pages: pages only touch `window.fm` / `window.fongmi`. Porting the bridge therefore means porting `HomeWebController.getSdk()`, not designing an API from the method list.
- Core names no hosting provider. A remote config source is an HTTPS URL and nothing more; GitLab and GitHub appear only in test and verification data.

## Completed Work

### Sources and browsing

#### Source coverage, measured at HEAD `3e8a7a84`

Counted directly from the 167-site `wang-movie.json`, not carried over from an earlier record.

| group | sites | status |
|---|---:|---|
| type-0 MacCMS XML | 2 | listed; **2 play** |
| type-1 MacCMS JSON | 22 | listed; **20 play** on 2026-09-17 — the three `/share/` player pages are sniffed since 5G; the two `如意` hosts served dead media that day |
| type-4 CatVod remote API | 6 | listed; **4 play**, 2 return nothing (403 host, and 43 empty categories) |
| type-3 `csp_*` spiders | 90 | **32 listed** since IOS-POC-5M; the rest blocked on provider state or the missing player headers |
| type-3 Python (`./py/*.py`) | 42 | not implemented — no Python runtime |
| type-3 drpy JavaScript (`./drpy_libs/*.js`, `./json/4k.js`) | 5 | not implemented — no drpy loader |
| **total** | **167** | **61 listed; 37 measured playable** (26 native + 11 spider) |

**IOS-POC-5D closed the routing gap that used to sit here.** `ConfigView` lists
`drivableSites(resolvedBy:)` and every content call goes through `SourceClient`, which routes a
site to either `CMSClient` or a cached `SpiderSession`. The caption counts `drivableSites`, so it
now reads 「目前支援 62 個來源」.

**Listing is not working.** Every listed source is swept through the app's own path and then the
**first bytes of every resolved stream are fetched**, because a URL resolving and the media existing
are different things. Last coherent aggregate, 2026-09-17 after IOS-POC-5L: **37 of 61 playable**, 7 resolve media
that 403s or 404s, 1 gives episodes but no URL, 1 gives titles but no episodes, 15 are empty.
Native is 26 of 30, spiders 11 of 31. Almost every failure is provider state — dead or 504-ing
hosts, an expired VIP account, a provider serving its own 「site closed」 clip — with one structural
exception: the four `Bili` sites resolve a genuine progressive MP4 that bilibili's CDN refuses
without a `Referer`, which `AVPlayer` cannot send until per-request headers are threaded through
`PlayerView`. Per-site tables: `docs/IOS-POC-5L-appqi-app99-app3q-bili.md` (current) and
`docs/IOS-POC-5E-all-source-sweep.md` (the earlier 45-source run). IOS-POC-5M adds 薦片 (verified
playable on its own, three ways) for 62 listed. **Provider state moves by the hour and repeated
sweeps degrade it** — a later run the same afternoon collapsed to 10 playable with 9 TLS
certificate failures that `curl` reproduced, which is a measurement of the network, not a
regression. Re-measure before calling anything broken. **Quote 37 of 61, not 61.**

#### The 90 `csp_*` sites

| bucket | classes | sites |
|---|---:|---:|
| portable (audit categories A–C) | 26 | 54 |
|  of which ported | 8 | **32** |
|  of which portable but not yet ported | 19 | 23 |
| blocked by native-encrypted payload (category H) | 23 | 34 |
| missing resource — JAR never downloaded, portability unknown | 2 | 2 |
| **total** | **51** | **90** |

Class counts above are **distinct class names**, so they sum to 51. The audit table in
`docs/CSP_PORTABILITY_MATRIX.md` keys a class per JAR and therefore shows 58 rows (33 portable);
a class shipped in two JARs still costs only one port. See `docs/CSP_MIGRATION_STATUS.md`.

Ported classes: `AppGet` (5 sites), `AppQi` (6), `App99` (4), `App3Q` (2) — four dialects of the
苹果CMS App-API — `Bili` (4, the public bilibili API), `JianPian` (1 — registered under the blocked
`JPianAmns` name the config uses), `XBPQ` (7, rule engine) and `XYQHiker` (3, rule engine). All are live-verified except `AppQi`, whose six sites resolve to four hosts that
were all dead on 2026-09-17; its `init`, decrypt, home and category are proven from one short
window in which one host answered, its detail and player are not. The two rule engines serve any future site configured for them
without further code, which is why they are worth more than their site counts suggest.

#### Native CMS notes

- type-0 is the same MacCMS contract as type-1 carried in XML, so it reuses `CMSClient` whole and changes only the decoder. `MacCMSXMLDecoder` (Foundation `XMLParser`, no dependency) turns `<class><ty>` into the categories and `<video>` into `Vod`, with `<dd flag>` becoming the flags through the same `$$$` encoding. The one query difference is `ac=videolist` instead of `ac=detail`, matching `SiteApi.ac(int)`. `XMLDocument` is macOS-only and is not an option on iOS. Type-4 extends `CMSClient` rather than adding a second client; its only structural difference is that its home returns categories, so the first browsable category fills the grid.
- Web-page episodes resolve through `?play=&flag=` before reaching the player, so an HTML page is never handed to AVPlayer.
- Category browsing has a parent row and a child row. `categoryGroups` pairs each `type_pid == 0` entry with its children; a source without `type_pid` becomes childless groups and renders as one row. A parent chip targets its first child when it has one and its own id otherwise, because childless parents do list content that way.
- Pagination loads the next page when the last card appears, for home, category and search. It stops when a page contributes no new `vod_id` rather than trusting page metadata, which also ends the loop for a source that ignores `pg`.
- Type-1 listings request `ac=detail`, the only form that carries `vod_pic`. That form drops `class`, so a type-1 home issues the plain and detail requests concurrently.
- Root-cause fix in the shared `Vod` decoder: `vod_id` and `vod_name` are optional, because `爱瓜TV` answers `ac=detail` without them and requiring them discarded the whole record.

### Playback

- The built-in player is a full-screen cover with its own close control, not a push inside the picker sheet. A page sheet is inset and rounded, so the player used to inherit those bounds and the app wallpaper showed around the video. Letterbox bars for a 16:9 video in a portrait screen are correct aspect-ratio behaviour and are left alone; the player now draws them on its own black background.

### Configuration

- The configuration comes from an imported file or any HTTPS Raw URL. `ConfigSource.resourceURL(for:)` resolves `./jar/…`, `./py/…`, `./json/…`, `./drpy_libs/…` against the config's own directory, drops the `;md5;<hash>` suffix, passes absolute references through, and refuses anything that is not a relative path so `csp_*` class names are never mistaken for resources. **This locates resources; it does not download, verify or execute them.**
- A failed remote load keeps the last known good cache. Validation requires at least one usable source, so a payload that parses but drives nothing cannot replace a working cache.
- Every launch re-fetches a remote source, retrying at 2 s, 5 s and 15 s, and stays silent on failure because the cached configuration is already on screen and the 上次更新 row shows its age. A manual refresh reports errors and does not retry.

### WebHome bridge

- `WKWebView` + `WKScriptMessageHandler` reproducing the Android string-RPC contract. Implemented: `net.request`, `player.playUrl`, **`player.playVod`, `player.playVodInline`, `player.control`, `player.status`**, `app.search`, `app.history`, `cache.get/set/del`, `ui.getViewport`, `ui.setToolbar`, `navigation.back`, `navigation.reload`, `site.info`, `config.info`, `ext.info`, `ext.log`, `ext.toast`, `device.info`.
- Android payload shapes are reproduced field for field including the fields iOS cannot fill; a missing value is zero, empty or false rather than omitted, so a page never reads `undefined`.
- Deviations, each commented in code: `net.resourceUrl` returns the raw URL (no local proxy server); results are never chunked, so the synchronous `resultLength`/`resultChunk` accessors are unnecessary; `app.history` returns `[]` until a history store exists; `device.info` is built natively; Android-only gesture and system-bar insets are zero; `site.info` omits `homePage`, `chromeMode`, `webHomeChrome`, `header`; `config.info` has no `id` or `desc`.
- Still outside the bridge, each for a stated reason: `net.resourceUrl` proxying (no local server), `player.preloadArtwork` (`AsyncImage` has no preload hook, so it would be a no-op claiming success), `app.open*` (no Live or Keep screen), `pan.*` (no drive-check service), `ui.setChrome` / `restoreChrome` (no equivalent surface). All reject with the same `Unknown method` the Android default branch produces.

### Playback session (IOS-POC-2E)

- One `@MainActor` `PlaybackSession.shared` in the app target owns a single `AVPlayer` for the app's lifetime and swaps items into it, so no view observes a changing player object. It adds only what `AVPlayer` has no concept of: the inline playlist and index, the page-supplied title and artwork, and the repeat flag. Android's equivalent is the process-wide `PlaybackService` behind `Server.get().getService()`.
- `PlayerView` no longer creates its own player; closing it pauses rather than tears down, which is what lets a WebHome page read a live `player.status` and resume with `player.control` — the page is only on screen once the player is gone.
- Every playback path now feeds that one session: the CMS grid, `player.playUrl`, `player.playVod` (which resolves `siteKey` against the loaded config and opens the existing `VodView`) and `player.playVodInline` (which goes straight to the built-in player, since a playlist and `control` semantics are things an external player cannot honour).
- `player.status` reproduces Android's **`net.request` envelope**, because Android fetches `/media` over its own local HTTP server; the envelope is reproduced field for field and the HTTP hop is not. Durations and positions are milliseconds, as Media3 reports them.
- An unknown or empty `siteKey` rejects with `Unknown site: <key>` instead of opening a screen that fails later — the showcase page ships that field empty, so a page reaches it immediately.

### Spider runtime (IOS-POC-5A / 5B)

- `ios/Sources/WebHTVCore/Spider/` holds the 13-method `SpiderRuntime` ABI mirroring `Spider.java`,
  `SpiderRegistry` (class name → script + audit metadata), `SpiderSession` (the actor that guarantees
  `init` runs exactly once before any content call), `CSPSourceResolver` (the routing change: the
  question became “is this class registered?” instead of “is this type 3?”) and
  `JavaScriptSpiderRuntime` (one `JSContext` and one serial `DispatchQueue` per site).
- `Spider/Host/` is the native half of `CatVodHost`: HTTP with a per-host cookie jar, AES/DES,
  MD5/SHA/HMAC, and per-site namespaced storage. `Resources/Spiders/host.js` is the JavaScript half:
  `pdfh`/`pdfa`/`pd` selectors, `host.cut` text slicing, and the CatVod result builders.
- A spider that re-implements HTTP, crypto or parsing is a bug — the primitive belongs in
  `CatVodHost`. `RSA`, WebView sniffing and `proxy` host plumbing are **not implemented**;
  `csp_AppDrama` needs RSA before it can be ported.
- `XBPQ`'s 331 rule keys were recovered by decoding the decompiled `merge/xbpq/HaB.d` string table
  (hex + XOR `"wxEesU"`). That is ordinary bytecode inspection, unrelated to the native-protected
  JARs, which are left alone.

## Build / Test / Verification Status

- **At HEAD `3e8a7a84`: 77 tests, 76 pass.** The single failure is
  `reportsLiveType4SitesFromProvidedConfig`, a **pre-existing live-network** check: 88看球 resolves
  an episode to `https://embed.st/embed/…`, an HTML page, and the test asserts direct media through
  `CMSClient`, which has no sniffer hop. It failed identically at earlier HEADs. **Do not "fix" it.**
  The 45-source sweep independently classifies that site as playable *through `SourceClient`*, which
  is the path the app uses — the test and the sweep disagree because they drive different layers.
- **The suite is stable across runs since IOS-POC-5H.** Four bridge tests used to fail
  intermittently; they recorded callbacks through a detached `Task` and read the result immediately.
  Four consecutive full runs now end with exactly the one failure above.
- Gated live checks stay off by default: `WANG_MOVIE_URL` (remote config), `CSP_GOLDEN_SITE` (spider
  goldens), `SWEEP_CONFIG` + `SWEEP_BASE` (the 45-source sweep).
- **Toolchain: Xcode 27 / Swift 6.4.** It changed mid-session and the project stopped building at the
  then-current HEAD; the Swift 6 region-isolation repairs are recorded in the IOS-POC-5D document.
  There is no older Xcode on this machine.
- **Spider goldens re-run live 2026-09-17, all three ported classes, each ending in `parse:0`:**
  `AppGet` (王子) home 6 classes → category 30 items → detail 5 flags → search 20 →
  `https://vv.jisuzyv.com/play/…/index.m3u8`; `XBPQ` (果果短剧) 8 classes → 30 items →
  `https://vodcnd17.uvjtih.cn/…/index.m3u8`; `XYQHiker` (农民影视) 5 classes → 30 items → flags
  `[线路①, 线路②]` → search 20 → `https://1853039965.cdn.123clouddisk.com/….m3u8`. No regression.
- `xcodebuild -project ios/WebHTVApp/WebHTVApp.xcodeproj -scheme WebHTVApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build` → BUILD SUCCEEDED.
- Remote config, against the real GitLab Raw URL (measured at IOS-POC-1F, when 28 sites were supported): 125,864 bytes, 167 sites, cached SHA-256 identical to the remote, resolved `jar/fm.jar` HTTP 200. An unreachable URL left the sources and cache intact. Launch retry proven with a local server armed to fail twice — exactly three requests, adopted on the third.
- Simulator, end to end: `爱瓜TV` grid → 莲花楼 detail with 41 episodes → episode 01 plays in the built-in player. Type-1 `如意` and `360` grids load with real posters and both category rows. Pagination scrolls past the first page on both types.
- WebHome bridge in the simulator with the unmodified devkit showcase page: badge reads `SDK: native`; `fm.req JSON` logged `req-json ok (799ms)` with the full contract shape; the HLS button played the stream; `cache-set ok`; `ext-info` and `config` logged real payloads; `legacy hide`/`show` removed and restored the navigation bar.
- **IOS-POC-2E end to end, from the page:** `vodInline 多集` played the inline MP4; with the player closed, `播放状态` returned a live envelope (`duration 90080`, `position 28136`, `state 2`); `fm.ctrl play` advanced it to `state 3`, `position 41502`; `fm.ctrl next` switched the reported url and title to the HLS episode (`speed 1`, `position 10511`); `fm.ctrl pause` returned `{}` and the next status read `speed 0`. `调用 fm.vod` with `vod_360` / `101020` logged `vod ok (229ms)`, opened the native detail screen with ten live episodes and played episode 1, and a following status reported that stream.

## Risks / Unverified

- **Nothing has ever run on a real device.** The Xcode project has no `CODE_SIGN` or `DEVELOPMENT_TEAM` setting. Every result above is from the iPhone 17 Pro simulator.
- **Not measured: that HTTPS certificate validation is still enforced.** It is reasoned from the code — no `URLSessionDelegate`, no `serverTrust` handling anywhere — but no test against a known-bad certificate was run.
- Not driven from the WebHome page, covered only by offline tests: `cache.get`, `cache.del`, `app.search`, `app.history`, `device.info`, `site.info`, `ui.getViewport`, `ext.toast`, `navigation.back`, `navigation.reload`.
- **IOS-POC-2F closed the playback gaps.** All seven `player.control` actions and the inline JS resolver have now been driven from the page; see the IOS-POC-2F section of the 2E document for the evidence. No code changed.
- `player.status.position` is the media's own playhead. A reading taken after a control tap includes the delay between the two taps — an earlier reading of `6000` right after `replay` was misread as an HLS timeline origin offset, and the normalisation written for it was measured, disproved and reverted.
- `player.playUrl` reports an empty `artwork` because `Actions.play` carries only a URL and a title; `playVod`, `playVodInline` and the CMS path all report the real poster.
- Playback has no background audio, media session or lock-screen controls. Closing the player pauses it; the session keeps the item so `player.status` still answers.
- Remote reachability is highly volatile. `itv666.cc` went from HTTP 200 to DNS failure within ten minutes, and the GitLab Raw host was unreachable for about a minute mid-session. Never treat one site's failure as a global app defect.
- `URLSession.webHTV` caps request inactivity at 10 s. A type-4 home issues two sequential requests, so its worst case is about 20 s. This is an inactivity timeout, not a total-transfer cap. AVPlayer playback does not use this session.
- A failed next page stops pagination silently, because the error surface only renders when the grid is empty.
- The direct-media test is a path-extension heuristic, marked `ponytail:` in `CMSClient.swift`.
- The `ac=detail` form costs bandwidth: a 20-title page on `360zy` grew from 6.5 KB to 49 KB.
- `drpyS_听友[听]` returns an empty list for all 43 of its categories, and `php_无水印资源` answers HTTP 403. Both are provider state, not app defects.
- The Debug-only CJK font fallback does not fix the log panel's `[上午…]` prefix, and says nothing about a real device.
- **A spider play result's `header` is dropped.** `AVPlayer` takes request headers only through
  `AVURLAsset` options, which `PlayerView` does not thread through, so a CDN that checks Referer
  will fail to play — visibly, not silently. No configured site has been observed needing it.
- **The sniffer is best effort and timing-sensitive.** `MediaSniffer` hooks `XMLHttpRequest`,
  `fetch` and media `src` — `WKWebView` has no `shouldInterceptRequest`, so there is no way to see
  every subresource. A stream fetched inside a Worker or through WASM is not caught. It is also
  slower on the first web view of a process: in one sweep run the first two sniffs missed and the
  next run caught both. **Treat a single sweep row as a sample, not a verdict.**
- ~~A site whose own category list contains 「全部」 renders two chips~~ **Fixed in IOS-POC-5J**: the
  app's own 全部 is suppressed when the provider's first category is already an “all” entry.
- **All remaining source failures are provider state**, each confirmed with `curl` against the URL
  the spider builds — 522/403 hosts, a withdrawn media file, or the site itself answering
  「暂无数据」. **None is a defect in this app.** Per-site table:
  `docs/IOS-POC-5E-all-source-sweep.md`.
- **I mis-assigned blame twice, and both corrections are recorded.** `csp_If101` was filed as our
  parse failure when the site answers 「暂无数据」; `永乐影视` was filed as a provider 404 because I
  checked `ylsp.tv` and applied the verdict to `ylys.tv`, which answers 200. A screenshot from the
  user exposed the second one. **Check the actual host for the actual site key before assigning a
  verdict.**
- **The 3 `XYQHiker` sites need a remote config to work at all.** Their `ext` is a relative path
  (`./json/农民影视.json`), and `ConfigSource.importedFile` has no `baseURL`, so `resourceURL` returns
  nil and `resolvedExtend` hands the spider an unfetchable `./json/…` string. The 2026-09-17 golden
  run passed only because the absolute GitLab Raw URL was substituted by hand. Confirmed in the
  app at IOS-POC-5D: 农民 resolved and played correctly **because the configuration came from a
  remote URL**. `XBPQ`'s 7 sites and `AppGet`'s 5 carry inline `ext` objects and are unaffected.
- Still not implemented: a Python runtime (42 sites), a drpy JavaScript loader (5 sites), the 36
  portable-but-unported `csp_*` sites, `CatVodHost` RSA and `proxy` plumbing, **per-request playback
  headers for `AVPlayer`**, WebHome sites in `wang-movie.json` (this config has none), and
  SideStore/IPA delivery.
- **Filter rows exist only where the source publishes them.** MacCMS has no filter protocol and
  neither rule engine exposes one, so only `AppGet` sites show 類型/地區/語言/年代/排序. That is
  correct behaviour, not a missing feature.
- 34 `csp_*` sites are blocked by the native-encrypted payload in `aowu-0722.jar` and
  `fan-0720.jar`. **Do not attempt to defeat that protection.** If such a site matters, the routes
  are an `XBPQ`/`XYQHiker` rule equivalent or a direct HTTP/CMS entry.
- The `csp_*` audit is a **static** audit. “Portable” means nothing in the class prevents a
  reimplementation — it is not a promise that the site is reachable or that the port is cheap.
- 2 `csp_*` classes (`JPianAmns`, `AppV6`) were never downloaded, so their portability is
  **unknown**. Do not record a missing file as a technical verdict.
- type-0 was verified only against the two configured endpoints. A provider sending a non-UTF-8 encoding would parse to an empty response rather than being transcoded.

## Next Recommended Step

Agree exactly one bounded stage with the user first.

1. **`aowu-0722.jar` compatibility recovery — the user asked for this and it is blocked on one
   thing.** The method they specified is right: never try to get logic out of the 18 empty shim
   classes, work per class family, start with `AppV7Amns` (9 sites), look for a portable equivalent
   of the same site first, and only then treat the Spider as a black box on Android to record the
   real HTTP contract. **But the first step cannot run yet**: those 9 sites' `ext` is itself an
   encrypted hex blob (all nine share the middle `5714a2413f05151fea6864509533510f`), so the site
   identity is unknown and there is nothing to search for an equivalent of. The order has to invert
   — observe first, then compare.
   *Environment:* `adb`, `emulator` and a `Pixel_8` AVD exist; **no mitmproxy/Charles**, and no
   WebHomeTV APK yet (it would have to be built from `app/`, which has native dependencies).
   *Cheapest first probe, ~10 minutes:* Android's `SpiderDebug.log` writes spider requests to
   logcat, so `adb logcat` may reveal the URLs with no proxy and no CA install. Try that before
   committing to the full 1.5–2 h environment build.
   Mark each family `portable` / `needs host primitive` / `protected-only` / `provider-dead`, and
   put any missing AES/MD5/header/token/JSON/HTML helper in `CatVodHost`, never in one spider.
2. **Batch-port the 苹果CMS App-API family:** `AppQi` (6 sites), `App99` (4), `App3Q` (2), then
   `Bili` (4, public API, no crypto). Lowest cost per site, because they share `AppGet`'s shape —
   and `AppGet` is now the best-understood port. **The `AppQi` static reading is already done** and
   recorded in `docs/CSP_MIGRATION_STATUS.md`, including the two things that must not be copied from
   `AppGet.js`. `AppDrama` (4) needs RSA in `CatVodHost` first.
3. **Per-request playback headers.** The sniffer sends a correct `Referer` and then hands the URL to
   `AVPlayer` without one, because `PlayerView` does not thread `AVURLAsset` options through. This
   is the last known playback gap that is ours rather than a provider's.
4. **Device deployment.** Needs the user's Apple ID and hardware. Free provisioning's 7-day expiry
   versus a paid account versus SideStore is still open.

Lower priority: drive the remaining offline-only bridge methods from a page (`cache.get`/`del`,
`app.search`, `app.history`, `device.info`, `site.info`, `ui.getViewport`, `ext.toast`,
`navigation.back`/`reload`), and a watch-history store that would turn `app.history` from an honest
`[]` into real data and give the home screen a 繼續觀看 row.

## Resume Prompt

Paste this into a new session:

> 接手 `/Users/chengchenchih/GIT/webhtv` 的 `ios-poc` 分支，透過本機終端操作，不要每步停下來問我確認。用台灣繁體中文回報。
>
> **先確認實際狀態，不要相信以下引用的任何 ID**：預期 HEAD 在 `3e8a7a84`，**領先 `origin/ios-poc` 9 個 commit 且尚未 push**，worktree clean。未經我明確授權不得 push。
>
> 動手前必讀：`AGENTS.md`、`docs/AGENT_HANDOFF.md`、`docs/current-task-state.md`，以及 `docs/IOS_SPIDER_RUNTIME_SPEC.md`（runtime/ABI 唯一真實來源）、`docs/CSP_PORTABILITY_MATRIX.md`（51 class 靜態審計）、`docs/CSP_MIGRATION_STATUS.md`（移植進度）、`docs/IOS-POC-5E-all-source-sweep.md`（45 站逐站狀態表）。要動哪個階段就讀那個階段的 `docs/IOS-POC-5*.md`。
>
> **這個 App 現在能做什麼**：iPhone 版 WebHomeTV。**App UI 列出 167 個設定來源中的 45 個**（2 type-0 + 22 type-1 + 6 type-4 + 15 個已移植 `csp_*` spider），其中 **36 個經實測可端到端播放**——**回報時引用 36，不要引用 45**。兩層分類、分頁、搜尋、詳情、五種播放器（內建 AVPlayer + Infuse/Fileball/SenPlayer/VidHub）、匯入檔或 HTTPS Raw URL 設定（schema 驗證 + LKG 快取 + 啟動重試）、config 相對資源解析器、WebHome bridge over WKWebView（全部方法都已實站驗證）。分類列會隨內容捲走、右下角有 Top 鍵、父分類可收合子分類、`AppGet` 站有類型/地區/語言/年代/排序篩選列。
>
> **Spider 架構的核心原則**：不在 iOS 執行 Android DEX/JAR，而是用 JavaScriptCore 重現 `Spider.java` 的 text-in/text-out 契約。反編譯的 Java 只當規格書。共用 `CatVodHost`（native 半邊在 `Spider/Host/*.swift`，JS 半邊在 `Resources/Spiders/host.js`），drpy 未來共用同一套，**不要做第二套 runtime**。已移植 3 個 class：`AppGet`（5 站）、`XBPQ`（7 站，規則引擎）、`XYQHiker`（3 站，規則引擎）。`SourceClient` 負責把每個站路由到 `CMSClient` 或快取的 `SpiderSession`。
>
> **90 個 `csp_*` 的真實分布**：54 站可移植（51 個相異 class 中的 26 個）、34 站被 `aowu-0722.jar` 與 `fan-0720.jar` 的 **native 加密 payload** 擋住（class 全是空殼，**不要嘗試破解那層保護**）、2 站只是 JAR 沒下載。42 個 Python 與 5 個 drpy JavaScript 站尚未實作但架構上可行，**不可稱為不可能**。
>
> **驗證方式**：`WANG_MOVIE_JSON=<config> swift test --package-path ios` → 77 測試、76 通過。唯一失敗 `reportsLiveType4SitesFromProvidedConfig` 是既有的即時網路案例（88看球 走 `CMSClient`，該路徑沒有嗅探那一跳），**不要去修**。全站掃描：`SWEEP_CONFIG=<config> SWEEP_BASE=<remote url> swift test --package-path ios --filter sweepsEveryDrivableSource`。`xcodebuild -project ios/WebHTVApp/WebHTVApp.xcodeproj -scheme WebHTVApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build` 通過。工具鏈是 **Xcode 27 / Swift 6.4**，機器上沒有舊版。
>
> **設定檔不在 `/tmp`**：`/tmp/webhtv-recha-new.wprHof/` 已被清空。`wang-movie.json` 要從 `https://gitlab.com/st7833232/recha/-/raw/main/wang-movie.json` 重新取得（SHA-256 應為 `b17576e34eb42b4c589a818ef8b5ec2655a2c7a188d626fc427c37d628897168`，167 站）。`recha-main.zip` 沒有還原，所以 `scripts/audit_spider_jars.py` 目前無法重跑。
>
> **踩過的坑，不要重犯**：① HTML parser 的 tag regex 曾要求屬性間有空白；② `select()` 曾先用逗號切 selector group；③ 直連嗅探 regex 曾允許 `$`/`#`；④ `JavaScriptSpiderRuntime` 必須用 `invokeMethod` 派送；⑤ `player.status.position` 是媒體自身播放頭，不是時間軸偏移；⑥ **`ScrollView` 不是 lazy 容器**，marker 的 `onDisappear` 永遠不觸發，要判斷捲動位置請用 `LazyVGrid` cell 的生命週期；⑦ **測試不要用 `Task { }` 記錄再立刻讀**，那是競爭條件（`Actions` closure 都是 `@MainActor` 且 `handle` 會 await，直接同步記錄）；⑧ **站方的分類與篩選選項第一項通常已經是「全部」**，再加一個就會出現兩個；⑨ **判斷某站是我方 bug 還是站方問題前，一定要對那個 site key 的實際 host 發請求**——我曾把 `ylsp.tv` 的 404 誤套到 `ylys.tv`。
>
> **規範**：每次功能變更前後各跑一次 Ponytail（改動前對設計、改動後對 final diff），結果寫進該階段 durable 文件；改動前 `bash .codex/scripts/task_guard.sh start --id <id> --mode <lane> --scope <path>...`，**scope 一次宣告齊全**（guard 不支援中途重新宣告，本次 session 因此擴了三次）；結束用 `finish ... --no-tag`。commit message 用檔案傳入（`-F`），不要直接放反引號進 shell。
>
> **禁止事項**：不要改 Android `main` 或 `app/`（只讀，供比對契約）；未經我明確授權不得 push；commit 不要打 recovery tag；不要嘗試解密 aowu/fan 的 native payload；不要碰 Python/JAR-DEX 直接執行、CarPlay；不要恢復 Google TV `csp_JPianAmns` 修復；保留 `NSAllowsArbitraryLoads`（2026-09-15 我明確決定）但不得再放寬傳輸安全。
>
> **實機從未驗證**：專案沒有任何 `CODE_SIGN` / `DEVELOPMENT_TEAM`，所有結果都來自 iPhone 17 Pro 模擬器，不得把模擬器結果說成實機可用。
>
> **下一步**：先跟我確認要做哪一個，不要自己選。候選依序是 (1) `aowu-0722.jar` 的 compatibility recovery——我要求過，但第一步「找同站的 portable equivalent」目前做不到，因為那 9 個 `AppV7Amns` 站的 `ext` 本身是加密的，站點身分未知，必須先在 Android 上黑箱觀察；先試 `adb logcat` 的 `SpiderDebug.log`（約 10 分鐘），不行再評估建 APK + 抓包環境（1.5–2 小時）。(2) 批次移植 `AppQi`/`App99`/`App3Q`/`Bili`（+16 站，`AppQi` 的靜態解讀已完成並記在 `CSP_MIGRATION_STATUS.md`）。(3) 補 `AVPlayer` 的 per-request headers。(4) 實機部署（需要我的 Apple ID 與硬體）。
