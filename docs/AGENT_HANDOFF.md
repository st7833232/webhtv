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

## Current recovery anchor (2026-09-17, after IOS-POC-5L)

- Objective: continue the iPhone WebHomeTV port with the user's Recha `wang-movie.json`. The Google TV `csp_JPianAmns` repair is explicitly not active.
- Active branch: `ios-poc`, HEAD after IOS-POC-5L. `03ba9cf0` and everything before it **is pushed** to `origin/ios-poc` (2026-09-17); the IOS-POC-5L commits on top of it are local. Check the actual Git state on resume; do not infer what has been pushed.
- Toolchain is **Xcode 27 / Swift 6.4** and there is no older one on the machine. It changed mid-session and broke the build at the then-current HEAD; the Swift 6 region-isolation repairs are in `docs/IOS-POC-5D-spider-sites-in-app.md`.
- **The input config is not in `/tmp` any more.** Re-fetch `wang-movie.json` from `https://gitlab.com/st7833232/recha/-/raw/main/wang-movie.json` (SHA-256 `b17576e3…897168`, 167 sites). `recha-main.zip` was not restored, so `scripts/audit_spider_jars.py` cannot be re-run until it is.
- Implemented: native Swift config/CMS core; SwiftUI iPhone shell with Android-like wallpaper and settings; AVPlayer plus Infuse, Fileball, SenPlayer and VidHub; **type-0, type-1 and type-4 sources, 30 of the 167 configured, which is what the app UI lists**; two-level category browsing and pagination; configuration from an imported file **or any HTTPS Raw URL**, with schema validation, last-known-good caching, atomic replace, last-update status, manual refresh and a retrying launch refresh; a config-relative resource resolver; and a **WebHome bridge over `WKWebView` + `WKScriptMessageHandler`** covering the network, cache, UI, navigation, information **and playback** methods. The playback half (`player.playVod`, `playVodInline`, `control`, `status`) runs on one persistent `PlaybackSession` owning a single `AVPlayer`, which is what lets a page read a live status and control playback after the player screen is closed.
- Also implemented (IOS-POC-5A/5B, extended in 5L): a **CatVod spider runtime** in `ios/Sources/WebHTVCore/Spider/` that reimplements the `Spider.java` text-in/text-out contract in JavaScript on JavaScriptCore — one `JSContext` and serial queue per site, one shared `CatVodHost` — driving **31 further sites through 7 ported classes** (`AppGet` 5, `AppQi` 6, `App99` 4, `Bili` 4, `App3Q` 2, plus the rule engines `XBPQ` 7 and `XYQHiker` 3, which serve any future site configured for them). **It never executes Android DEX or JAR bytecode**; the decompiled Java is a specification only. Contract: `docs/IOS_SPIDER_RUNTIME_SPEC.md`. **Those 31 sites are listed in the app UI**: `ConfigView` lists `drivableSites(resolvedBy:)` and every content call goes through `SourceClient`, which routes a site to either `CMSClient` or a cached `SpiderSession`. The app offers **61 of 167 sources**. **Listed is not working**: the sweep drives every listed source through the app's own path and fetches the first bytes of each resolved stream. Measured 2026-09-17: **37 playable** (26 of 30 native, 11 of 31 spider), 7 resolve media that 403s or 404s, 1 lists episodes without a URL, 1 lists titles without episodes, 15 are empty. **Almost every failure is provider state** — dead hosts, an expired VIP, a "site closed" placeholder — with one structural exception: the four `Bili` sites resolve a real MP4 that bilibili's CDN refuses without a `Referer` the player cannot send yet. Per-site tables: `docs/IOS-POC-5L-appqi-app99-app3q-bili.md` (current, 61 sources) and `docs/IOS-POC-5E-all-source-sweep.md` (the earlier 45). **Quote 37 of 61.**
- Not implemented: a Python runtime (42 sites) and a drpy JavaScript loader (5 sites); the 39 portable-but-unported `csp_*` sites; `CatVodHost` RSA and `proxy` plumbing; per-request playback headers for `AVPlayer`; `player.preloadArtwork`, `pan.*`, `app.open*`, `net.resourceUrl` proxying, `ui.setChrome`/`restoreChrome`; and the SideStore/IPA release pipeline. IOS-POC-2F drove the inline JS resolver and all seven `player.control` actions from the page, so the playback half has no unexercised paths left. A source-specific DNS or TLS error does not prove a global iOS network bug.
- **The 137 type-3 sites, as measured 2026-09-16/17 — this supersedes every earlier count.** 90 are
  `csp_*`, 42 Python, 5 drpy JavaScript. Of the 90 `csp_*`: **54 sites, spanning 26 of the 51
  distinct classes, are portable**, of which **15 sites / 3 classes are ported and live-verified**;
  **34 sites / 23 classes are blocked by a native-encrypted
  payload** in `aowu-0722.jar` and `fan-0720.jar`, whose `csp_*` classes are empty
  shims and whose real logic a native library decrypts — **that is protection, not obfuscation, and
  it must not be attacked**; and **2 sites are only missing downloads**, so their portability is
  unknown rather than impossible. An earlier version of this file called all 90 “structurally out of
  reach” because their JARs carry `classes.dex` — that inference was wrong and DEX was never the
  obstacle. The 42 Python sites are expensive but architecture-compatible (standard library plus
  `requests`/`pycryptodome`/`base`; only 1 of 38 files touches `android.`), and the 5 drpy sites are
  the most plausible of all since iOS ships JavaScriptCore. Audit: `docs/CSP_PORTABILITY_MATRIX.md`
  (re-runnable via `scripts/audit_spider_jars.py`); progress: `docs/CSP_MIGRATION_STATUS.md`;
  Python/drpy measurement: `docs/IOS-TYPE3-REACHABILITY-2026-09-16.md`, whose `csp_*` section is
  superseded.
- **Nothing has ever run on a real device.** The Xcode project carries no `CODE_SIGN` or `DEVELOPMENT_TEAM` setting; every verification to date is simulator-only.
- **ATS policy changed by explicit user decision on 2026-09-15 (IOS-POC-4B).** Most configured sources are cleartext `http`, so the user was offered a narrow per-domain exception, no change, or global cleartext, was told that the earlier records forbid weakening ATS globally for one site, and chose global cleartext. `ios/WebHTVApp/Info.plist` sets `NSAllowsArbitraryLoads`. The earlier "do not weaken TLS/ATS globally" instruction is superseded for this personal POC only and still applies to any future broadening. No server-trust override was added, so HTTPS certificate evaluation remains the system default — but that was reasoned from the code, not measured.
- Detailed status, the stage index and every unverified case: `docs/current-task-state.md`. Per-stage records: `docs/IOS-POC-1E-config-persistence.md`, `docs/IOS-POC-1F-config-sources.md`, `docs/IOS-POC-2B-webhome-bridge.md`, `docs/IOS-POC-2D-webhome-bridge-ui-info.md`, `docs/IOS-POC-2E-webhome-bridge-playback.md`, `docs/IOS-POC-4A-type4-sources.md`, `docs/IOS-POC-4J-type0-xml-sources.md`, and `docs/IOS-PORTING-HANDOFF-2026-09-13.md` for the original architecture assessment (written against an older 208-site resource set; its 136 `csp_*` figure is historical). **For the spider work, the three live documents are `docs/IOS_SPIDER_RUNTIME_SPEC.md` (runtime and ABI — anything contradicting it is a bug in that thing), `docs/CSP_PORTABILITY_MATRIX.md` (the 51-class static audit) and `docs/CSP_MIGRATION_STATUS.md` (what is ported, blocked or waiting on a file).** `docs/IOS-TYPE3-REACHABILITY-2026-09-16.md` remains valid only for its Python and drpy measurements; its `csp_*` verdict is superseded.
- **Verified 2026-09-17 at this HEAD (IOS-POC-5L):** `swift test --package-path ios` with `WANG_MOVIE_JSON` → **78 tests, all pass**. `reportsLiveType4SitesFromProvidedConfig` is a live-network case that depends on `88看球`'s state and has failed before; it is not to be “fixed” when it does. `xcodebuild … -scheme WebHTVApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build` → BUILD SUCCEEDED. All three ported spiders re-verified live, each ending in `parse:0` direct media.
- Category **filter rows** (類型/地區/語言/年代/排序) exist since IOS-POC-5J, driven by CatVod's `filters` contract. `AppGet` and `AppQi` sites publish them (and `Bili` sites inherit whatever their own JSON declares) — MacCMS has no filter protocol and the rule engines do not expose one — so the rows are absent elsewhere by design. See `docs/IOS-POC-5J-category-filters.md`.
- **UI state after IOS-POC-5J/5K:** the category rows scroll away with the grid instead of pinning, a Top button returns to the top, a parent category folds its child row away, and `AppGet` sites show 類型/地區/語言/年代/排序 filter rows driven by CatVod's `filters` contract. Only `AppGet` publishes rows — MacCMS has no filter protocol and neither rule engine exposes one.
- Exactly one next action for Claude: agree the next bounded stage with the user, do not pick one alone. Ranked: **(1) `aowu-0722.jar` compatibility recovery**, which the user asked for — but its first step is blocked, because the 9 `AppV7Amns` sites' `ext` is itself an encrypted hex blob so the site identity is unknown and there is no equivalent to search for; the order must invert to observe-then-compare, and the cheapest probe is `adb logcat` for `SpiderDebug.log` before building an APK and a proxy. (2) batch-porting `AppQi`/`App99`/`App3Q`/`Bili` (+16 sites; the `AppQi` static reading is already recorded in `docs/CSP_MIGRATION_STATUS.md`; `AppDrama` needs RSA first). (3) per-request playback headers for `AVPlayer`. (4) device deployment, which needs the user's Apple ID and hardware. Full reasoning and the ready-to-paste resume prompt are in `docs/current-task-state.md`.
