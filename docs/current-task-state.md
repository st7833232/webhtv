# Current Task State

## Original Goal

Port WebHomeTV to iPhone with an Android-like UI, drive the user's own `wang-movie.json`, and offer built-in, Infuse, Fileball, SenPlayer and VidHub playback. The Google TV `csp_JPianAmns` repair is not in scope.

## Current Scope

- Branch `ios-poc`. **Verified 2026-09-18 at HEAD `261b5c03` (IOS-POC-5R): 2 commits ahead of
  `origin/ios-poc`, 0 behind, worktree clean.** The two local commits are IOS-POC-5Q (`0ab06a3c`)
  and IOS-POC-5R (`261b5c03`); everything through `d571f3a7` is pushed. **Re-check with `git log`
  rather than trusting any id quoted here** — an earlier revision of this line still said "HEAD
  after IOS-POC-5L".
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
| 5Q | `playerContent`'s `url` reads all three CatVod shapes; `Bili` offers one line per quality; a quality menu in the player picker | `docs/IOS-POC-5Q-playback-quality.md` |
| 5R | Watch history, resume, the 記錄 tab, the detail screen's last-episode mark, and `app.history` answering real data | `docs/IOS-POC-5R-watch-history.md` |
| 5U | Reconciliation: the live handoff documents rewritten against the actual HEAD and test run | this document |
| 5V | Debug-only simulator display fix for the font set the runtime is missing; no behaviour change | this document |

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

#### Source coverage at HEAD `261b5c03`

Counted directly from the 167-site `wang-movie.json` by
`listsThePortedSpiderSitesAlongsideTheNativeCMSSites`, which asserts every number in this table and
passes at this HEAD. Earlier revisions of this section said 45 and 61; both are stale.

| group | sites | status |
|---|---:|---|
| type-0 MacCMS XML | 2 | listed |
| type-1 MacCMS JSON | 22 | listed |
| type-4 CatVod remote API | 6 | listed |
| type-3 `csp_*` spiders | 90 | **32 listed** through 8 ported classes |
| type-3 Python (`./py/*.py`) | 42 | not implemented — no Python runtime |
| type-3 drpy JavaScript (`./drpy_libs/*.js`, `./json/4k.js`) | 5 | not implemented — no drpy loader |
| **total** | **167** | **62 listed** (30 native + 32 spider) |

**Listing is not working, and the playable count is currently unmeasured.** The last coherent
sweep was **37 of 61 playable on 2026-09-17** (26 of 30 native, 11 of 31 spider), and it predates
three stages that change the answer: IOS-POC-5M added 薦片, IOS-POC-5P gave the player the request
headers the four `Bili` sites were failing without, and IOS-POC-5Q changed how `Bili` reports its
episodes. **Do not quote 37 of 61 as current** — quote 62 listed, and say the playable count has not
been re-measured since 5L. Per-site tables, both historical:
`docs/IOS-POC-5L-appqi-app99-app3q-bili.md` (61 sources) and
`docs/IOS-POC-5E-all-source-sweep.md` (the earlier 45).

**Provider state moves by the hour and a bad sweep is not a regression.** A run the same afternoon
as the 37/61 one collapsed to 10 playable with 9 TLS certificate failures that `curl` reproduced;
2026-09-17 and 2026-09-18 both had windows like that. Re-measure before calling anything broken.

**IOS-POC-5D closed the routing gap that used to sit here.** `ConfigView` lists
`drivableSites(resolvedBy:)` and every content call goes through `SourceClient`, which routes a
site to either `CMSClient` or a cached `SpiderSession`. The caption reads 「目前支援 62 個來源」.

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

### Watch history (IOS-POC-5R)

- `WatchHistory` + `WatchHistoryStore` in `ios/Sources/WebHTVCore/WatchHistory.swift`: one JSON file
  in Application Support, written with `Data.write(options: .atomic)`, read behind an actor, pruned
  to 60 days (`Constant.HISTORY_TIME`) and 500 records. A corrupt file costs the history, not the
  launch.
- Fields follow `History.java` so `app.history` is a reproduction rather than an extension, and the
  formulas are Android's: `canSave()`, and `isNearEnding()` as one percent of runtime clamped to
  5–30 s. **The key is `Site.id`, not `siteKey`** — the configuration has four duplicate keys, and
  keying on the key alone would merge two providers into one record. `androidKey` (`siteKey@@@vodId`)
  is the only form that leaves the app, because a page splits it.
- `quality` is an iOS-only field: Android expresses every quality as a line, and since IOS-POC-5Q one
  line can carry several. It is deliberately absent from the `app.history` payload.
- Playback carries the site and title identity it never had. Position is sampled every five seconds
  **only while actually playing**, and written again on player close, on entering the background, at
  the end of an item, and on `control("stop")`.
- Reopening a title resumes it when the stored position is past ten seconds and not inside the
  near-end window; the detail screen marks the last episode; the 記錄 tab lists everything with
  「看到 m:ss / m:ss」. Only the built-in player is recorded — a URL scheme gives an external player
  no way back.

### Configuration

- The configuration comes from an imported file or any HTTPS Raw URL. `ConfigSource.resourceURL(for:)` resolves `./jar/…`, `./py/…`, `./json/…`, `./drpy_libs/…` against the config's own directory, drops the `;md5;<hash>` suffix, passes absolute references through, and refuses anything that is not a relative path so `csp_*` class names are never mistaken for resources. **This locates resources; it does not download, verify or execute them.**
- A failed remote load keeps the last known good cache. Validation requires at least one usable source, so a payload that parses but drives nothing cannot replace a working cache.
- Every launch re-fetches a remote source, retrying at 2 s, 5 s and 15 s, and stays silent on failure because the cached configuration is already on screen and the 上次更新 row shows its age. A manual refresh reports errors and does not retry.

### WebHome bridge

- `WKWebView` + `WKScriptMessageHandler` reproducing the Android string-RPC contract. Implemented: `net.request`, `player.playUrl`, **`player.playVod`, `player.playVodInline`, `player.control`, `player.status`**, `app.search`, `app.history`, `cache.get/set/del`, `ui.getViewport`, `ui.setToolbar`, `navigation.back`, `navigation.reload`, `site.info`, `config.info`, `ext.info`, `ext.log`, `ext.toast`, `device.info`.
- Android payload shapes are reproduced field for field including the fields iOS cannot fill; a missing value is zero, empty or false rather than omitted, so a page never reads `undefined`.
- Deviations, each commented in code: `net.resourceUrl` returns the raw URL (no local proxy server); results are never chunked, so the synchronous `resultLength`/`resultChunk` accessors are unnecessary; `app.history` **answered `[]` until IOS-POC-5R and now returns the real store** in Android's field shape, minus `quality`, which has no Android counterpart; `device.info` is built natively; Android-only gesture and system-bar insets are zero; `site.info` omits `homePage`, `chromeMode`, `webHomeChrome`, `header`; `config.info` has no `id` or `desc`.
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
  `CatVodHost`. `RSA` and `proxy` host plumbing are **not implemented**; `csp_AppDrama` needs RSA
  before it can be ported. **WebView sniffing is implemented** — `MediaSniffer` since IOS-POC-5G —
  but natively, above the spider, not as a `host.*` primitive; an earlier revision of this line
  listed it as missing, contradicting `docs/IOS_SPIDER_RUNTIME_SPEC.md`, which is the authority.
- `XBPQ`'s 331 rule keys were recovered by decoding the decompiled `merge/xbpq/HaB.d` string table
  (hex + XOR `"wxEesU"`). That is ordinary bytecode inspection, unrelated to the native-protected
  JARs, which are left alone.

## Build / Test / Verification Status

Everything in this section is from **HEAD `261b5c03`** unless it names an earlier stage. The three
conflicting test counts that used to sit here (77/76, 96/95, 110/109, each from a different HEAD)
have been collapsed into the first bullet.

- **124 tests, all 124 pass** — `WANG_MOVIE_JSON=<config> swift test --package-path ios`, measured
  2026-09-18. The trajectory: 96 at `d571f3a7`, 110 after IOS-POC-5Q, 124 after IOS-POC-5R.
- **`reportsLiveType4SitesFromProvidedConfig` passed this run, and that is not a change in the
  code.** It is a live-network check: 88看球 resolves an episode to an HTML page, and the test
  asserts direct media through `CMSClient`, which has no sniffer hop. It failed twice earlier on
  2026-09-18 and passed on the third run, which is exactly what a provider-state check looks like.
  **Do not "fix" it when it fails.** The sweep classifies that site as playable *through
  `SourceClient`*, the path the app actually uses; the two disagree because they drive different
  layers.
- **The suite is stable across runs since IOS-POC-5H.** Four bridge tests used to fail
  intermittently; they recorded callbacks through a detached `Task` and read the result immediately.
- `xcodebuild -project ios/WebHTVApp/WebHTVApp.xcodeproj -scheme WebHTVApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build` → **BUILD SUCCEEDED**.
- Gated live checks stay off by default: `WANG_MOVIE_URL` (remote config), `CSP_GOLDEN_SITE` (spider
  goldens, including IOS-POC-5Q's own `biliOffersMultipleQualityLines`), `SWEEP_CONFIG` +
  `SWEEP_BASE` (the whole-configuration sweep).
- **Toolchain: Xcode 27 / Swift 6.4.** It changed mid-session and the project stopped building at the
  then-current HEAD; the Swift 6 region-isolation repairs are recorded in the IOS-POC-5D document.
  There is no older Xcode on this machine.

### Live golden runs

- **2026-09-18 (IOS-POC-5Q).** `biliOffersMultipleQualityLines` — a bilibili title returned
  `B站 清晰 480P` and `B站 流畅 360P`, distinct `qn`, best first, and the best line's stream probed
  as `.media`. Only 480P/360P were on offer because `qn > 80` needs a SESSDATA the configured sites'
  2025 cookies cannot supply: that measures the account, not the port.
  `appGetDrivesTheWholeCatVodFlowAgainstTheLiveSite` passed unchanged, which is what proves the
  single-string `url` path did not move.
- **2026-09-17, all three then-ported classes, each ending in `parse:0`:** `AppGet` (王子) home 6
  classes → category 30 items → detail 5 flags → search 20 → `…/index.m3u8`; `XBPQ` (果果短剧) 8
  classes → 30 items → `…/index.m3u8`; `XYQHiker` (农民影视) 5 classes → 30 items → flags
  `[线路①, 线路②]` → search 20 → `….m3u8`.

### Simulator runs (iPhone 17 Pro)

- **IOS-POC-5R end to end, 2026-09-18** — the fullest one on record. `愛瓜 PHP` → `莲花楼` →
  普快线路 01 → the player sheet showed **no quality section**, which is the correct behaviour for a
  single-URL source and the reverse check on IOS-POC-5Q. Sixteen seconds in, the app container held
  a record keyed on `Site.id` with `position 28261`, `duration 2796399`, flag `普快线路`, episode
  `01`. Closing the player advanced it to `44292`. The detail screen came back with episode 01
  marked. The 記錄 tab listed 「莲花楼 / 愛瓜｜PHP · 普快线路 · 01 / 看到 0:44 / 46:36」. Replaying
  from that list read `53487` after seven seconds — it **resumed rather than restarted**.
- **IOS-POC-5Q, 2026-09-18.** `bilbil合集` browses, filters and renders its grid. The detail screen
  was not reached that day: taps on the grid cells did nothing. **That did not reproduce in the 5R
  run above**, where grid cells and episode buttons both responded, so the earlier failure was more
  likely coordinate mis-mapping than the known synthetic-tap defect. Neither confirms nor clears it.
- Earlier: `爱瓜TV` grid → 莲花楼 detail with 41 episodes → episode 01 plays. Type-1 `如意` and `360`
  grids load with posters and both category rows. Pagination scrolls past the first page.
- WebHome bridge with the unmodified devkit showcase page: badge reads `SDK: native`; `fm.req JSON`
  logged `req-json ok (799ms)`; the HLS button played; `cache-set ok`; `ext-info` and `config` logged
  real payloads; `legacy hide`/`show` removed and restored the navigation bar.
- **IOS-POC-2E/2F from the page:** `vodInline 多集` played the inline MP4; with the player closed,
  `播放状态` returned a live envelope (`duration 90080`, `position 28136`, `state 2`); `fm.ctrl play`
  advanced it to `state 3`; `next` switched url and title; `pause` returned `{}` and the next status
  read `speed 0`. `fm.vod` with `vod_360` / `101020` opened the native detail screen and played
  episode 1.
- Remote config against the real GitLab Raw URL (measured at IOS-POC-1F): 125,864 bytes, 167 sites,
  cached SHA-256 identical to the remote, resolved `jar/fm.jar` HTTP 200. An unreachable URL left the
  sources and cache intact. Launch retry proven with a local server armed to fail twice.

## Risks / Unverified

- **Nothing has ever run on a real device.** The Xcode project has no `CODE_SIGN` or `DEVELOPMENT_TEAM` setting. Every result above is from the iPhone 17 Pro simulator.
- **Not measured: that HTTPS certificate validation is still enforced.** It is reasoned from the code — no `URLSessionDelegate`, no `serverTrust` handling anywhere — but no test against a known-bad certificate was run.
- Not driven from the WebHome page, covered only by offline tests: `cache.get`, `cache.del`,
  `app.search`, `app.history`, `device.info`, `site.info`, `ui.getViewport`, `ext.toast`,
  `navigation.back`, `navigation.reload`. **`app.history` answers real data since IOS-POC-5R** — it
  is on this list because no page has asked it for that data yet, not because it is still a stub.
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
- **The simulator's font set is incomplete, and that is not an app defect (IOS-POC-5V).** Every site
  name in this configuration starts with an emoji, and the iOS 26.3 simulator runtime draws all of
  them as `.notdef` boxes. Measured 2026-09-18: the runtime ships **no PingFang** — only Hiragino and
  Kohinoor — and although `AppleColorEmoji-160px.ttc` (136 MB) sits in
  `System/Library/Fonts/CoreAddition/` it is never picked up. **Safari on the same simulator renders
  🎡, 蓮花樓 and even the fullwidth ｜ as boxes**, which is what proves the gap belongs to the
  runtime; the app's own CJK survives only because SwiftUI falls back to Hiragino. A real device has
  the full set. `String.displayName` in the app target drops the undrawable characters **only in a
  Debug simulator build** so screenshots are legible; Release and device builds show the name
  verbatim, and the stored, bridged and searched name is always the real one. This is the same shape
  as IOS-POC-2C's Debug-only web-view fallback, added for the same underlying reason.
  **Delete it when the simulator ships a complete font set.**
- ~~**A spider play result's `header` is dropped.**~~ **Fixed in IOS-POC-5P**: `SourceClient`
  answers a `PlaybackTarget` carrying the headers, and the probe, the sniffer and `AVURLAsset` all
  send them. bilibili's CDN needs both a `Referer` and a browser `User-Agent`.
- **Only the default quality is resolved (IOS-POC-5Q).** When a source answers a multi-value `url`,
  `SourceClient.target(from:…)` runs the probe/sniff hop on the default entry alone; picking another
  entry in the player sheet opens that URL exactly as the source gave it. Marked `ponytail:` in
  `SourceClient.swift` and `WebHTVApp.swift`. **No source in this configuration returns a `url`
  array**, so the quality menu has never been triggered by real data — its gate is a unit test.
- **Watch history is local and built-in-player only (IOS-POC-5R).** An external player is opened
  through a URL scheme, which has no way back, so nothing watched in Infuse, Fileball, SenPlayer or
  VidHub is ever recorded (K6). There is no cross-device sync: Android has its own local HTTP server
  for that and iOS has no equivalent. The store rewrites the whole JSON file on every save, at most
  every five seconds and only while actually playing — marked `ponytail:` with the upgrade path.
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
- **Still not implemented, as of `261b5c03`:** a Python runtime (42 sites), a drpy JavaScript
  loader (5 sites), the 23 portable-but-unported `csp_*` sites, `CatVodHost` RSA and `proxy`
  plumbing, the configuration's `ads`/`rules` (`WebHTVConfig` decodes only `sites`) and everything
  else in IOS-POC-5S including opening/ending skip, `player.preloadArtwork`, `pan.*`, `app.open*`,
  `net.resourceUrl` proxying, `ui.setChrome`/`restoreChrome`, WebHome sites in `wang-movie.json`
  (this config has none), device signing, and SideStore/IPA delivery.
  **Landed and no longer future work:** the `AppQi`/`App99`/`App3Q`/`Bili` ports (IOS-POC-5L),
  `JianPian` for 薦片 (5M), the compatibility pack (5O), per-request playback headers (5P),
  multi-quality `url` handling (5Q), and the watch-history store with resume and `app.history`
  (5R). Earlier revisions of this line listed several of those as missing.
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

**The order below was fixed by the user on 2026-09-18 and supersedes every earlier ranking in this
document.** The previous list recommended `aowu-0722.jar` recovery, the App-API batch port and
per-request headers; the last two are done and the first is explicitly deprioritised.

1. **POC-3 — the drpy JavaScript loader.** The next bounded functional stage, covering the 5
   `./drpy_libs/*.js` + `./json/4k.js` sources. Hard constraints from the user: reuse the existing
   JavaScriptCore runtime, `CatVodHost` and `host.js` (which already exposes the drpy-compatible
   `pdfh`/`pdfa`/`pd`); **never build a second JavaScript runtime**; `ConfigSource` already resolves
   `./drpy_libs/`, so the work is load + execute + `SourceClient` routing, not a new ABI. Do one
   minimal drpy source end to end with a golden first, then widen to all 5. A primitive a drpy script
   needs goes into the shared `CatVodHost`, never into one site's script.
2. **POC-4 — a minimum-viable Python runtime POC** for the 42 Python sites. **They must not be
   called impossible**: measured 2026-09-16, only 1 of 38 files touches `android.`. Scope is one
   source through `home → category → detail → search → player`, plus an assessment of an acceptable
   iOS CPython embedding, the minimum `base` host contract, an HTTP/`requests` strategy and the
   necessary slice of `pycryptodome`. No Android DEX/JAR execution. App Store distribution risk is
   not a reason to reject a Personal/SideStore runtime.
3. **The first real-device verification — a milestone in its own right.** Signing and
   `DEVELOPMENT_TEAM`, then remote config, CMS, spider, WKWebView/WebHome, AVPlayer headers, external
   players and persistence all re-checked on hardware. SideStore/TestFlight/App Store distribution
   can be decided later; the first device run cannot keep being deferred.
4. **Then IOS-POC-5S** (config `ads` blocking, `rules.script` injection, opening/ending skip) and
   only then more `csp_*` ports.

**Explicitly not next**, by the user's instruction: XueLuo, QimaoDJ, AppDrama or any further `csp_*`
class. The IOS-POC-5N candidates (XueLuo, QimaoDJ, Duboku, HaokanDJ) stay in the backlog until the
drpy, Python and device milestones are done.

**Unchanged boundary:** `aowu-0722.jar`, `aowu.jar` and `fan-0720.jar` keep their native-encrypted
payload and **must not be attacked**. `JPianAmns → JianPian` — an alias to a class proven to serve
the same API — is the correct pattern for anything behind them.

**Recorded, not to be built now:** a future Official/XPTV-style build would ship 0 sources, have the
user import their own playlist, not bundle `wang-movie.json`, and could disable the remote executable
compatibility pack, while the Personal/SideStore build keeps the full spider pack. That is an
architecture boundary to remember, not a second product to fork.

## Resume Prompt

Paste this into a new session:

> 接手 `/Users/chengchenchih/GIT/webhtv` 的 `ios-poc` 分支，透過本機終端操作，不要每步停下來問我確認。用台灣繁體中文回報。
>
> **先確認實際狀態，不要相信以下引用的任何 ID**：預期 HEAD 在 `261b5c03`（IOS-POC-5R），**領先 `origin/ios-poc` 2 個 commit 且尚未 push**，worktree clean。未經我明確授權不得 push。
>
> 動手前必讀：`AGENTS.md`、`docs/AGENT_HANDOFF.md`、`docs/current-task-state.md`、`docs/IOS_SPIDER_RUNTIME_SPEC.md`（runtime/ABI 唯一真實來源，含 compatibility pack 契約）、`docs/CSP_MIGRATION_STATUS.md`（移植進度）。要動哪個既有階段就讀那個階段的 `docs/IOS-POC-5*.md`。
>
> **這個 App 現在能做什麼**：iPhone 版 WebHomeTV。列出 167 個設定來源中的 **62 個**（30 native + 32 spider），**可播數量自 IOS-POC-5L 之後沒有重新量過**——上一次是 2026-09-17 的 37/61，那是 5M／5P／5Q 之前的數字，不要當成現況引用。兩層分類、篩選列、分頁、搜尋、詳情、五種播放器、匯入檔或 HTTPS Raw URL 設定（schema 驗證 + LKG 快取 + 啟動重試）、WebHome bridge over WKWebView、spider compatibility pack 熱更新、播放帶來源要求的 request headers、`playerContent.url` 三形狀 + 畫質選單、以及**播放記錄／續播／記錄分頁／`app.history` 真資料**。
>
> **Spider 架構核心**：不在 iOS 執行 Android DEX/JAR，而是用 JavaScriptCore 重現 `Spider.java` 的 text-in/text-out 契約；反編譯的 Java 只當規格書。已移植 8 個 class（`AppGet` 5 站、`AppQi` 6、`App99` 4、`App3Q` 2、`Bili` 4、`JianPian` 1、規則引擎 `XBPQ` 7 與 `XYQHiker` 3）。共用 `CatVodHost`，**不要做第二套 runtime**。
>
> **下一步照這個順序，不要自己改**：(1) **POC-3 drpy JavaScript loader**（5 個來源；共用既有 JavaScriptCore／`CatVodHost`／`host.js`，`ConfigSource` 已能 resolve `./drpy_libs/`，要補的是 load + execute + `SourceClient` routing，先一個來源 end-to-end golden 再擴到 5 個）→ (2) **POC-4 Python runtime 最小可行性驗證**（42 站，不得標為 impossible）→ (3) **第一次真機驗證**（signing／DEVELOPMENT_TEAM 起） → (4) IOS-POC-5S 廣告與片頭跳過，之後才是更多 CSP。**不要優先新增 XueLuo／QimaoDJ／AppDrama。**
>
> **驗證方式**：`WANG_MOVIE_JSON=<config> swift test --package-path ios` → **124 測試、124 全過**。`reportsLiveType4SitesFromProvidedConfig` 是即時網路案例（88看球），會因 provider 狀態時好時壞，**失敗時不要去修**。`xcodebuild -project ios/WebHTVApp/WebHTVApp.xcodeproj -scheme WebHTVApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build` 通過。工具鏈是 **Xcode 27 / Swift 6.4**。
>
> **設定檔**從 `https://gitlab.com/st7833232/recha/-/raw/main/wang-movie.json` 取得（SHA-256 `b17576e34eb42b4c589a818ef8b5ec2655a2c7a188d626fc427c37d628897168`，167 站）。`recha-main.zip` 沒有還原，`scripts/audit_spider_jars.py` 目前無法重跑。
>
> **踩過的坑**：① `decodeIfPresent` 對型別不符是 throw 不是回 nil；② `ScrollView` 不是 lazy 容器，判斷捲動位置要用 `LazyVGrid` cell 的生命週期；③ 測試不要用 `Task { }` 記錄再立刻讀；④ 站方的分類／篩選第一項通常已經是「全部」；⑤ **判斷某站是我方 bug 還是站方問題前，一定要對那個 site key 的實際 host 發請求**；⑥ 設定檔有 4 組重複 site key，`Site.id` 是 key+ext 不是 key——播放記錄就是靠這個才不會把兩站混在一起；⑦ `.gitignore:30` 的 `plans/` 會把 `docs/plans/` 一起忽略，task guard 的 `git add` 沒有 `-f`，所以計畫檔放 `docs/`。
>
> **規範**：每次功能變更前後各跑一次 Ponytail，結果寫進該階段 durable 文件；改動前 `bash .codex/scripts/task_guard.sh start --id <id> --mode <lane> --scope <path>...`（scope 一次宣告齊全），結束用 `finish ... --no-tag`；commit message 用檔案傳入，並以 `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>` 結尾。
>
> **禁止**：改 Android `main` 或 `app/`（唯讀，供比對契約）；未經我明確授權不得 push；commit 不打 recovery tag；不要嘗試解密 `aowu-0722.jar`／`aowu.jar`／`fan-0720.jar` 的 native payload；不要碰 Python/JAR-DEX 直接執行、CarPlay；保留 `NSAllowsArbitraryLoads` 但不得再放寬傳輸安全。
>
> **實機從未驗證**：專案沒有任何 `CODE_SIGN` / `DEVELOPMENT_TEAM`，所有結果都來自 iPhone 17 Pro 模擬器。
