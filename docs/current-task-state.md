# Current Task State

## Original Goal

Port WebHomeTV to iPhone with an Android-like UI, drive the user's own `wang-movie.json`, and offer built-in, Infuse, Fileball, SenPlayer and VidHub playback. The Google TV `csp_JPianAmns` repair is not in scope.

## Current Scope

- Branch `ios-poc`, HEAD `226e826c` after IOS-POC-5B, level with `origin/ios-poc`. **Re-check with `git log` rather than trusting any id quoted here.**
- Android `app/` is read-only for all iOS work and has never been modified: `git diff <branch-point>..HEAD -- app/` is empty, and the 42 commits on this branch touch only `ios/`, `docs/`, `scripts/`, `AGENTS.md` and `.codex/`.
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

#### Source coverage, recounted from the config at HEAD `226e826c`

Counted directly from the 167-site `wang-movie.json`, not carried over from an earlier record.

| group | sites | status |
|---|---:|---|
| type-0 MacCMS XML | 2 | listed; **2 play** |
| type-1 MacCMS JSON | 22 | listed; **19 play**, 3 hand back a web player page |
| type-4 CatVod remote API | 6 | listed; **3 play**, 1 is an HTML page, 2 return nothing |
| type-3 `csp_*` spiders | 90 | **15 listed** since IOS-POC-5D; **3 play**, 12 stop earlier |
| type-3 Python (`./py/*.py`) | 42 | not implemented — no Python runtime |
| type-3 drpy JavaScript (`./drpy_libs/*.js`, `./json/4k.js`) | 5 | not implemented — no drpy loader |
| **total** | **167** | **45 listed; 27 measured playable** (24 native + 3 spider) |

**IOS-POC-5D closed the routing gap that used to sit here.** `ConfigView` lists
`drivableSites(resolvedBy:)` and every content call goes through `SourceClient`, which routes a
site to either `CMSClient` or a cached `SpiderSession`. The settings caption reads
「目前支援 45 個來源」.

**Listing is not working.** IOS-POC-5E swept all 45 listed sources through the app's own path and
then **fetched the first bytes of every resolved stream**, because a URL resolving and the media
existing are different things. Measured 2026-09-17: **27 playable**, 6 resolve a URL whose media is
a 404 or an HTML page, 1 resolves nothing, 4 list titles but no flags, 7 are empty. Native sources
are 24 of 30; spiders are 3 of 15. Per-site table and the ranked open defects:
`docs/IOS-POC-5E-all-source-sweep.md`. **Quote 27 of 45, not 45.**

#### The 90 `csp_*` sites

| bucket | classes | sites |
|---|---:|---:|
| portable (audit categories A–C) | 26 | 54 |
|  of which ported **and live-verified** | 3 | **15** |
|  of which portable but not yet ported | 23 | 39 |
| blocked by native-encrypted payload (category H) | 23 | 34 |
| missing resource — JAR never downloaded, portability unknown | 2 | 2 |
| **total** | **51** | **90** |

Class counts above are **distinct class names**, so they sum to 51. The audit table in
`docs/CSP_PORTABILITY_MATRIX.md` keys a class per JAR and therefore shows 58 rows (33 portable);
a class shipped in two JARs still costs only one port. See `docs/CSP_MIGRATION_STATUS.md`.

Verified classes: `AppGet` (5 sites, 苹果CMS App-API + AES-CBC), `XBPQ` (7 sites, rule engine),
`XYQHiker` (3 sites, rule engine). The two rule engines serve any future site configured for them
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

- **IOS-POC-5D, 2026-09-17: 64 tests, 62 pass.** Two live-network failures, both provider state and
  both reproduced at the previous HEAD in a clean worktree: `reportsLiveType4SitesFromProvidedConfig`
  (88看球) and `completesLiveCMSFlowFromProvidedConfig` (`cj.rycjapi.com` now returns
  `vod_play_url: "$$$"`, no episode URLs). `xcodebuild … iPhone 17 Pro Debug` → BUILD SUCCEEDED.
  **The toolchain moved to Xcode 27 / Swift 6.4 during this task and the project stopped building at
  the previous HEAD**; the region-isolation repairs are recorded in the 5D document.
- **Superseded by the line above — kept for the IOS-POC-5C reconciliation record.**
  `WANG_MOVIE_JSON=/tmp/webhtv-recha-new.wprHof/wang-movie.json swift test --package-path ios`
  → **57 tests, 56 pass**. The one failure, `reportsLiveType4SitesFromProvidedConfig`, is the same
  **pre-existing live-network** check: `88看球` resolved `纽约大都会 vs 巴尔的摩金莺` to
  `https://embed.st/embed/admin/ppv-baltimore-orioles-vs-new-york-mets/1`, an HTML play page, and
  the test asserts direct media. It failed identically at earlier HEADs, so it is provider state,
  not a regression — **do not “fix” it.** Gated live checks stay off by default: `WANG_MOVIE_URL`
  for the remote config, and `CSP_GOLDEN_SITE` for the spider goldens.
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
- **`parse:1` is not playable.** It means “open in a browser and sniff the media”, and no WebView
  sniffer exists. `SourceClient.playbackURL` returns nil so the UI reports an unplayable episode
  rather than handing AVPlayer a web page.
- **A site whose own category list contains 「全部」 renders two 「全部」 chips** (王子 does). The app
  adds its own and `categoryGroups` keeps the provider's. Pre-existing rendering behaviour that
  only became visible once spider sites were listed; not introduced by IOS-POC-5D.
- **2 of the 15 spider sites currently fail on provider state, not app defects** (confirmed with
  `curl`, 2026-09-17): AG動漫's episode m3u8 answers HTTP 404 with or without `Referer`/UA, and
  方舟动漫's host answers HTTP 403 while the sibling AppGet site 王子 answers 200.
- **The 3 `XYQHiker` sites need a remote config to work at all.** Their `ext` is a relative path
  (`./json/农民影视.json`), and `ConfigSource.importedFile` has no `baseURL`, so `resourceURL` returns
  nil and `resolvedExtend` hands the spider an unfetchable `./json/…` string. The 2026-09-17 golden
  run passed only because the absolute GitLab Raw URL was substituted by hand. Confirmed in the
  app at IOS-POC-5D: 农民 resolved and played correctly **because the configuration came from a
  remote URL**. `XBPQ`'s 7 sites and `AppGet`'s 5 carry inline `ext` objects and are unaffected.
- Still not implemented: a Python runtime (42 sites), a drpy JavaScript loader (5 sites), the 39
  portable-but-unported `csp_*` sites, `CatVodHost` RSA / WebView-sniffing / `proxy` plumbing,
  per-request playback headers,
  WebHome sites in `wang-movie.json` (this config has none), and SideStore/IPA delivery.
- 34 `csp_*` sites are blocked by the native-encrypted payload in `aowu-0722.jar` and
  `fan-0720.jar`. **Do not attempt to defeat that protection.** If such a site matters, the routes
  are an `XBPQ`/`XYQHiker` rule equivalent or a direct HTTP/CMS entry.
- The `csp_*` audit is a **static** audit. “Portable” means nothing in the class prevents a
  reimplementation — it is not a promise that the site is reachable or that the port is cheap.
- 2 `csp_*` classes (`JPianAmns`, `AppV6`) were never downloaded, so their portability is
  **unknown**. Do not record a missing file as a technical verdict.
- type-0 was verified only against the two configured endpoints. A provider sending a non-UTF-8 encoding would parse to an empty response rather than being transcoded.

## Next Recommended Step

Agree exactly one bounded stage with the user first. Ranked, at most three:

1. ~~Surface the 15 ported spider sites in the app UI.~~ **Done in IOS-POC-5D.**
2. **Fix the five measured defects before porting more.** IOS-POC-5E ranked them: `csp_If101`
   parsing 0 titles from a 200 page (and probably `csp_天天動漫` with it), 動漫巴士/巴士动漫 detail
   returning no flags, and the two AppGet playback faults (`灵虎` → nil, `不戳` → two URLs
   concatenated). That is up to 5 sources recovered from code already written, and each one is a
   class of bug the next batch of ports would inherit.
3. **Batch-port the 苹果CMS App-API family:** `AppQi` (6 sites), `App99` (4), `App3Q` (2). Same shape
   as the verified `AppGet`, so cost per site is lowest here. Static reading done 2026-09-17 confirms
   `AppQi` differs from `AppGet` only in the `/qijiappapi.index/` prefix, configurable `init`/`search`
   method names, a home filter list, a slider-verification retry on `code 1001`, and a `vodParse`
   POST signed with `base64(AES(timestamp))`. Then `Bili` (4 sites, public API, no crypto) → 31 sites
   total. `AppDrama` (4) needs RSA in `CatVodHost` first.
4. **Device deployment.** The largest gap, and the only one needing the user's Apple ID and hardware.
   Free provisioning's 7-day expiry versus a paid account versus SideStore is still an open question.
5. **A WebView sniffer** would recover the three type-1 `/share/` sources, `88看球`, and every
   `parse:1` spider — the largest single gain, and the largest piece of work.

Still open, lower priority: drive the remaining offline-only bridge methods from a page
(`cache.get`/`del`, `app.search`, `app.history`, `device.info`, `site.info`, `ui.getViewport`,
`ext.toast`, `navigation.back`/`reload`), and a watch-history store that would turn `app.history`
from an honest `[]` into real data and give the home screen a 繼續觀看 row.

## Resume Prompt

> Continue the WebHomeTV iPhone port in `/Users/chengchenchih/GIT/webhtv` on the actual `ios-poc` Git state; check `git log` and `git status` first rather than trusting any commit id quoted here. Read `AGENTS.md`, `docs/AGENT_HANDOFF.md`, this file, `docs/IOS_SPIDER_RUNTIME_SPEC.md` (runtime/ABI source of truth), `docs/CSP_PORTABILITY_MATRIX.md` (audit) and `docs/CSP_MIGRATION_STATUS.md` (port progress), plus the stage document for whatever you touch. **The app UI lists 45 of 167 configured sources** (2 type-0 + 22 type-1 + 6 type-4 + 15 `csp_*` spider), of which **27 were measured end-to-end playable** on 2026-09-17 — quote 27, not 45 with category browsing, pagination, five players, imported-file or remote-Raw-URL configuration with last-known-good caching and launch refresh, and a WebHome bridge over WKWebView covering the network, cache, UI, navigation, information and playback methods — `player.playVod`, `playVodInline`, `control` and `status` run on one persistent `PlaybackSession` that outlives the player screen, and IOS-POC-2F drove all seven `control` actions and the inline JS resolver from the page. **A CatVod spider runtime also exists** (IOS-POC-5A/5B): it reimplements the `Spider.java` text-in/text-out contract in JavaScript on JavaScriptCore — it never runs Android DEX — and drives 15 more sites through 3 ported classes (`AppGet` 5, `XBPQ` 7, `XYQHiker` 3, the last two being rule engines). IOS-POC-5D wired those 15 into the app UI through `SourceClient`, which routes each site to either `CMSClient` or a cached `SpiderSession`; 农民 played an episode end to end in the simulator. Of the 90 `csp_*` sites, 54 are portable (26 of the 51 distinct classes), 34 are blocked by a native-encrypted payload in `aowu-0722.jar`/`fan-0720.jar` — **do not try to break that protection** — and 2 are simply missing downloads; the earlier “90 permanently unreachable” verdict is superseded. The 42 Python and 5 drpy JavaScript sites are unimplemented but architecturally possible and must not be called impossible. It ships `NSAllowsArbitraryLoads` because the user explicitly chose global cleartext on 2026-09-15 — keep it and do not broaden transport security further without a fresh decision. Do not resume the Google TV `csp_JPianAmns` repair. Nothing has ever run on a real device: there is no signing configuration at all. Confirm the next bounded stage with the user before any functional edit, follow the task-guard and Ponytail gates, commit with `--no-tag`, and preserve Android `main`.
