# WebHTV Agent Handoff

## Repository and active branch

- Repository: `st7833232/webhtv`
- Upstream source: `fish2018/webhtv`
- Android mainline branch: `main`
- iPhone / iOS / PWA exploration branch: `ios-poc`
- `ios-poc` was created from commit `fc62397591701b2232ae7de4f50a032bd7742064`.
- Do not make experimental iOS/PWA changes directly on `main`.

## Required detailed iOS handoff

For any iPhone/iOS/WebHome portability work, **read `docs/current-task-state.md` and `docs/IOS-PORTING-HANDOFF-2026-09-13.md` after this file before doing new analysis or implementation**. Reconcile those records with current Git state; the older planning sections below are historical.

That document is the durable record of the 2026-09-13 session and contains:

- user constraints and installation/signing decisions;
- SideStore/update strategy;
- PWA vs Native iOS conclusions;
- the inspected `recha-main.zip` / `wang-movie.json` compatibility findings;
- JAR/DEX/native `.so` conclusions;
- Python and JavaScript compatibility direction;
- the Android `VodConfig -> Site -> SiteApi -> Spider -> Result/Vod -> player` contract inventory;
- WebHome bridge mapping to WKWebView;
- AVPlayer-first playback scope;
- persistence mapping;
- the migration matrix;
- POC-1 scope, success criteria, exclusions, phase order, and recovery anchor.

Do not restart the broad architecture investigation unless the repository or resource set has materially changed. Continue from the documented recovery anchor.

## Mandatory Ponytail review gate

This project **must use the Ponytail skill for implementation work**. This is a project requirement, not an optional recommendation.

For every functional code change, architecture change, dependency/build change, native/runtime change, Spider compatibility change, player change, packaging/signing change, or deployment/release change:

1. Read `AGENTS.md`, `README.md`, this handoff document, `docs/IOS-PORTING-HANDOFF-2026-09-13.md` when the task concerns iOS, and any task/domain-specific Skill before editing.
2. **Before implementation, run Ponytail** against the proposed scope/design and resolve or explicitly document every material finding before changing functional code.
3. Use the repository task guard and verification workflow required by `AGENTS.md` for the selected lane.
4. After implementation and targeted verification, **run Ponytail again on the final diff** before considering the change complete, committing/pushing it, producing an IPA, or publishing an artifact.
5. Record the Ponytail pre-review and final-diff review result in the durable task document or handoff evidence for the task.

If Ponytail is not available in the current agent/runtime, **do not claim that Ponytail review was performed**. Read-only assessment and documentation may continue, but functional implementation must stop before the first functional edit and the missing Ponytail capability must be reported as the blocker.

## Current iPhone/iOS objective

The current goal is to make WebHomeTV usable on iPhone while keeping the user's preferred operating constraints:

- no jailbreak;
- zero recurring infrastructure cost where practical;
- no always-on self-hosted server;
- no requirement to leave a PC running continuously;
- updates should be installable/refreshable from the phone where possible;
- preserve as much WebHomeTV/CatVod/WebHome compatibility as practical rather than performing a blind Java-to-Swift rewrite.

The preferred architecture is Native iOS + SwiftUI, with WKWebView as the WebHome compatibility layer. The HTTP/CMS-to-AVPlayer POC and the WKWebView WebHome bridge are both implemented and verified (IOS-POC-2B through 2F); an earlier version of this sentence said the bridge was not yet implemented. SideStore remains the preferred zero-cost personal installation/refresh direction, not a completed packaging workflow. PWA remains a fallback/lightweight option.

## Existing architecture facts that matter to the iOS work

The Android project currently depends on several Android-specific/runtime-specific layers, including:

- `catvod` for the Spider/CatVod ecosystem;
- `chaquo` for Python/Chaquopy integration;
- `quickjs` for JavaScript Spider execution;
- Android WebView/native bridges used by WebHome and extensions;
- Android playback/native stacks such as Media3/MPV and related native binaries;
- local HTTP/proxy/server features used by Spider, WebHome, playback, sync, and management functions.

Do not assume an Android `.jar` used by TVBox/WebHomeTV is a normal JVM JAR. Resource inspection performed during the iOS assessment found real-world Spider packages containing `classes.dex`, Android API dependencies, dynamic DEX loading, WebView references, and in some cases native `.so` payloads. Browser JVM approaches such as CheerpJ therefore cannot be treated as a universal drop-in solution.

## Historical resource compatibility assessment

An earlier user-provided `recha-main.zip` / `wang-movie.json` resource set was inspected during planning. Its historical counts were:

- 208 configured sites were observed;
- 136 were `csp_*` / Android JAR-style Spider sites;
- 37 were Python Spider sites;
- 30 were HTTP/CMS API sites;
- 5 were JavaScript Spider sites;
- many JAR-backed sites appeared to have Python/JS/rule-based alternatives in the same resource collection.

Therefore the preferred compatibility strategy is **not** to promise 100% execution of arbitrary Android JARs on iOS. First prefer direct HTTP/CMS, JavaScript, Python compatibility, or equivalent rule implementations. Investigate DEX/native-only sources individually only when they remain valuable and have no viable equivalent.

The current replacement JSON has 167 sites: 2 type-0, 22 type-1, 137 type-3, and 6 type-4. The resource archive itself is not part of this Git repository. Do not infer that any external endpoint is currently reachable from its presence in the JSON.

## Historical first implementation unit

Ponytail became available in later sessions, and the first HTTP/CMS-to-AVPlayer unit below was implemented. Do not repeat it as new work.

The first approved-style proof should be POC-1 as documented in `docs/IOS-PORTING-HANDOFF-2026-09-13.md`:

`config -> one HTTP/CMS source -> home/category -> search -> detail -> Flag/Episode -> direct HLS/MP4 playerContent -> AVPlayer`

Do not begin with protected/obfuscated DEX JARs, Python, JS runtime, MPV/VLC fallback, DLNA, cloud-drive special handling, or release automation.

## Branch and upstream discipline

- Preserve `main` as the Android/upstream-oriented line unless the user explicitly changes that policy.
- Keep iOS/PWA experiments isolated on `ios-poc` or a task branch derived from it.
- Before importing upstream Android changes, assess whether they touch shared contracts used by the iOS/PWA work.
- Do not silently copy third-party source/resource implementations into the repository; preserve license/provenance and review compatibility/legal implications where applicable.

## Current recovery anchor (2026-09-18, after IOS-POC-5R)

This section was rewritten wholesale on 2026-09-18 against the actual HEAD and an actual test run,
because it had accumulated contradictions — a stale branch state, work listed as future that had
shipped, and three different source counts. Detailed status: `docs/current-task-state.md`.

- Objective: continue the iPhone WebHomeTV port with the user's Recha `wang-movie.json`. The Google
  TV `csp_JPianAmns` repair is explicitly not active.
- **Branch `ios-poc`, HEAD `261b5c03` (IOS-POC-5R), 2 ahead of `origin/ios-poc`, 0 behind, worktree
  clean — verified 2026-09-18.** The two local commits are IOS-POC-5Q (`0ab06a3c`) and IOS-POC-5R
  (`261b5c03`). Check the actual Git state on resume; do not infer what has been pushed.
- **Verified at this HEAD, 2026-09-18:** `WANG_MOVIE_JSON=<config> swift test --package-path ios`
  → **124 tests, all pass**. `reportsLiveType4SitesFromProvidedConfig` is a live-network case that
  depends on 88看球's state — it failed twice and passed once on the same day — and is **not to be
  "fixed"**. `xcodebuild … -scheme WebHTVApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
  -configuration Debug build` → BUILD SUCCEEDED.
- **The app lists 62 of 167 sources: 30 native (2 type-0, 22 type-1, 6 type-4) and 32 spider**,
  asserted by a passing test. **The playable count has not been re-measured since IOS-POC-5L**; the
  last coherent sweep was 37 of 61 on 2026-09-17, which predates 5M, 5P and 5Q. Quote 62 listed and
  say the playable figure is stale — do not quote 37 of 61 as current.
- **The CatVod spider runtime** in `ios/Sources/WebHTVCore/Spider/` reimplements the `Spider.java`
  text-in/text-out contract in JavaScript on JavaScriptCore — one `JSContext` and serial queue per
  site, one shared `CatVodHost`. **It never executes Android DEX or JAR bytecode**; the decompiled
  Java is a specification only. **8 ported classes drive 32 sites**: `AppGet` 5, `AppQi` 6, `App99`
  4, `Bili` 4, `App3Q` 2, `JianPian` 1, plus the rule engines `XBPQ` 7 and `XYQHiker` 3, which serve
  any future site configured for them. **A blocked class is not always a blocked site**: 薦片's
  configured class `csp_JPianAmns` is an empty shim over an encrypted payload and is driven anyway
  because river-fman's unprotected `JianPian` serves the same API, mapped by `SpiderRegistry.aliases`
  so the shared config needs no edit and Android is unaffected. Contract:
  `docs/IOS_SPIDER_RUNTIME_SPEC.md`; progress: `docs/CSP_MIGRATION_STATUS.md`.
- **Spider scripts update without an app release since IOS-POC-5O.** A compatibility pack —
  `./spiders/manifest.json` beside the configuration, HTTPS only, every script verified against a
  SHA-256 — replaces or adds scripts at runtime; resolution order is verified pack → bundled →
  unsupported, and a failed pack can never take away the working one. `host.js` is not packable.
  Build and check packs with `scripts/spider_pack.py`.
- **Playback carries the source's request headers since IOS-POC-5P.** `SourceClient.playbackURL`
  returns a `PlaybackTarget`; the probe, the sniffer and `AVURLAsset` all use them. bilibili's CDN
  requires **both** a `Referer` and a browser `User-Agent` (measured 2026-09-18: browser UA +
  Referer → 206, everything else → 403). External players still cannot be told about headers — a URL
  scheme is their whole interface. `AVURLAssetHTTPHeaderFieldsKey` is undocumented;
  `avURLAssetSendsTheHeadersItWasGiven` observes it working against a real socket.
- **`playerContent`'s `url` reads all three CatVod shapes since IOS-POC-5Q.** `PlayURL` is the only
  decoder for it on **both** the spider and the CMS path — reading it as a `String` used to throw on
  one and be swallowed into 「這一集沒有可播放的網址」 on the other. The player sheet shows a quality
  menu when a source offers more than one, defaulting to the highest unless a remembered choice says
  otherwise. `Bili` expresses its qualities as **one line per quality**, because every `qn` costs its
  own `playurl` call. No configured source returns a `url` array, so the menu has never been
  triggered by real data. `docs/IOS-POC-5Q-playback-quality.md`.
- **The app remembers what was watched since IOS-POC-5R.** `WatchHistory` follows Android's
  `History.java` field for field, including `isNearEnding()`'s formula, and is keyed on **`Site.id`
  rather than `siteKey`** because this configuration has four duplicate keys. One JSON file in
  Application Support, written atomically, pruned to 60 days and 500 records. Playback samples every
  five seconds while playing and writes again on close, background and end; reopening a title
  resumes it; the detail screen marks the last episode; a 記錄 tab lists everything; and
  **`app.history` answers real data** in Android's exact field shape. Only the built-in player is
  recorded — a URL scheme has no way back. `docs/IOS-POC-5R-watch-history.md`.
- **Also implemented:** native Swift config/CMS core; SwiftUI iPhone shell with Android-like
  wallpaper and settings; AVPlayer plus Infuse, Fileball, SenPlayer and VidHub; type-0, type-1 and
  type-4 sources; two-level category browsing, CatVod filter rows, scrolling category rows, a Top
  button and collapsible child rows; pagination; configuration from an imported file **or any HTTPS
  Raw URL** with schema validation, last-known-good caching, atomic replace, last-update status,
  manual refresh and a retrying launch refresh; a config-relative resource resolver; and a **WebHome
  bridge over `WKWebView` + `WKScriptMessageHandler`** covering the network, cache, UI, navigation,
  information and playback methods on one persistent `PlaybackSession`.
- **Not implemented:** a Python runtime (42 sites), a drpy JavaScript loader (5 sites), the 23
  portable-but-unported `csp_*` sites, `CatVodHost` RSA and `proxy` plumbing, the configuration's
  `ads`/`rules` and the rest of IOS-POC-5S including opening/ending skip, `player.preloadArtwork`,
  `pan.*`, `app.open*`, `net.resourceUrl` proxying, `ui.setChrome`/`restoreChrome`, device signing,
  and the SideStore/IPA release pipeline. A source-specific DNS or TLS error does not prove a global
  iOS network bug.
- **The 137 type-3 sites, as measured 2026-09-16/17.** 90 are `csp_*`, 42 Python, 5 drpy JavaScript.
  Of the 90 `csp_*`: **54 sites over 26 of the 51 distinct classes are portable**, of which **32
  sites / 8 classes are ported**; **34 sites / 23 classes are blocked by a native-encrypted
  payload** in `aowu-0722.jar` and `fan-0720.jar`, whose `csp_*` classes are empty shims — **that is
  protection, not obfuscation, and it must not be attacked**; and **2 sites** are only missing
  downloads, so their portability is unknown rather than impossible. The 42 Python sites are
  expensive but architecture-compatible (standard library plus `requests`/`pycryptodome`/`base`; only
  1 of 38 files touches `android.`), and the 5 drpy sites are the most plausible of all since iOS
  ships JavaScriptCore. **Neither group may be called impossible.** Audit:
  `docs/CSP_PORTABILITY_MATRIX.md`; progress: `docs/CSP_MIGRATION_STATUS.md`; Python/drpy
  measurement: `docs/IOS-TYPE3-REACHABILITY-2026-09-16.md`, whose `csp_*` section is superseded.
- **Nothing has ever run on a real device.** The Xcode project carries no `CODE_SIGN` or
  `DEVELOPMENT_TEAM` setting; every verification to date is simulator-only, on an iPhone 17 Pro.
- **ATS policy changed by explicit user decision on 2026-09-15 (IOS-POC-4B).** Most configured
  sources are cleartext `http`; the user was offered a narrow per-domain exception, no change, or
  global cleartext, was told the earlier records forbid weakening ATS globally for one site, and
  chose global cleartext. `ios/WebHTVApp/Info.plist` sets `NSAllowsArbitraryLoads`. Do not broaden
  transport security further. No server-trust override was added, so HTTPS certificate evaluation
  remains the system default — reasoned from the code, not measured.
- **The next stages are fixed, by the user on 2026-09-18**, and this replaces every earlier ranking:
  **(1) POC-3, the drpy JavaScript loader** for the 5 `./drpy_libs/*.js` + `./json/4k.js` sources —
  reuse the existing JavaScriptCore runtime, `CatVodHost` and `host.js`, **never build a second
  JavaScript runtime**, and treat it as load + execute + `SourceClient` routing rather than a new
  ABI; one minimal source end to end with a golden first, then all 5. **(2) POC-4**, a
  minimum-viable Python runtime POC. **(3) the first real-device verification**, as a milestone in
  its own right. **(4) IOS-POC-5S** and only then more `csp_*` ports. **Do not prioritise XueLuo,
  QimaoDJ, AppDrama or any further `csp_*` class**; the IOS-POC-5N candidates stay in the backlog.
  A future Official/XPTV-style build (0 bundled sources, user-imported config, pack disabled) is an
  architecture boundary to remember, **not** something to fork the runtime for now.
- Per-stage records: `docs/IOS-POC-1E-config-persistence.md`, `docs/IOS-POC-1F-config-sources.md`,
  `docs/IOS-POC-2B-webhome-bridge.md`, `docs/IOS-POC-2D-webhome-bridge-ui-info.md`,
  `docs/IOS-POC-2E-webhome-bridge-playback.md`, `docs/IOS-POC-4A-type4-sources.md`,
  `docs/IOS-POC-4J-type0-xml-sources.md`, `docs/IOS-POC-5D` through `docs/IOS-POC-5R-*.md`, and
  `docs/IOS-PORTING-HANDOFF-2026-09-13.md` for the original architecture assessment (written against
  an older 208-site resource set; its 136 `csp_*` figure is historical).
