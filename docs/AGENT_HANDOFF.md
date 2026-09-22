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

The preferred architecture is Native iOS + SwiftUI, with WKWebView as the WebHome compatibility layer. The HTTP/CMS-to-AVPlayer POC and the WKWebView WebHome bridge are both implemented and verified (IOS-POC-2B through 2F); an earlier version of this sentence said the bridge was not yet implemented. **SideStore is the installation path and its packaging workflow is complete** (IOS-POC-11): `.github/workflows/ios-sidestore-release.yml` builds an unsigned device IPA on a GitHub runner, publishes a Release and updates `source.json` on this branch, and the user installs from that source. This sentence read "not a completed packaging workflow" until IOS-POC-11B. PWA remains a fallback/lightweight option.

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

## Current recovery anchor (2026-09-21, after IOS-POC-7Q)

This section was rewritten wholesale on 2026-09-18 against the actual HEAD and an actual test run,
because it had accumulated contradictions — a stale branch state, work listed as future that had
shipped, and three different source counts. **It went stale again by 2026-09-21**: it still carried
`bb965dda`, 143 tests, 67 sources and "a Python runtime is assessed, not built", all of which the
IOS-POC-7E–7P commits had already overtaken. The reconciled bullets below were re-measured at the
actual HEAD on 2026-09-21 (IOS-POC-7R). Detailed status: `docs/current-task-state.md`.

- Objective: continue the iPhone WebHomeTV port with the user's Recha `wang-movie.json`. The Google
  TV `csp_JPianAmns` repair is explicitly not active.
- **Branch `ios-poc`, HEAD `20c4bd53`, worktree clean, and `git rev-list --left-right --count
  origin/ios-poc...ios-poc` answered `0 0` on 2026-09-22** — level with the remote. The branch was
  pushed twice that day at the user's explicit instruction, and the release workflow pushed
  `source.json` itself; no recovery tag was created, and recovery tags have been opt-in since
  2026-09-16. The only tags on this line are the release ones the workflow makes.
  **Do not trust the id in this line.** It has been stale at `2a177f50`, `bb965dda`, `7653a9fb` and
  `a076ab51` before; run `git log` and the `rev-list` above on resume instead of reading it here.
- **Re-measured at `20c4bd53` on 2026-09-22 (IOS-POC-11B), every number taken in that session:**
  `swift test --package-path ios` → **188 tests, one failing**. `xcodebuild … -scheme WebHTVApp
  -destination 'platform=iOS Simulator,id=7B4E9557-4774-4EB9-B408-BB544DCC8657' -configuration Debug
  build` → **BUILD SUCCEEDED**, and so did the iPhone 18 Pro (`00008160-00124C8200214036`) with
  `DEVELOPMENT_TEAM=764SVXY2B7 CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates`.
  **The destination must be an id now**: an iOS 27.0 runtime appeared on this machine, so
  `name=iPhone 17 Pro` matches two devices and xcodebuild refuses to choose.
  **The failing one is `reportsLiveType4SitesFromProvidedConfig`, and it is not to be "fixed"** —
  it depends on 88看球's state, which today answers with an embed page rather than a media address.
  Confirmed pre-existing by stashing the day's changes and re-running at an earlier HEAD; it also
  passed earlier the same day. Earlier revisions of this line read "151 tests, all pass" and then
  "185 tests, one failing"; both are superseded.
- **The current release is `WebHTV 0.1.1 (2)`**, tag `ios-v0.1.1-b2`, built unsigned by the workflow
  and re-signed on the device by SideStore. **`0.1 (1)` is not current.** The Xcode project carries
  `MARKETING_VERSION = 0.1.1` and `CURRENT_PROJECT_VERSION = 2`, so the workflow's blank-input
  default resolves to the version actually published.
- **The app lists 62 of 167 sources from an imported file and 109 from a remote URL.** The 62 are
  30 native (2 type-0, 22 type-1, 6 type-4) and 32 `csp_*` spider. A remote configuration adds the
  5 drpy sources, which need the configuration's own origin to load their engine from, and — since
  IOS-POC-7H — the 42 Python sources, which need it to load their script from: 62 + 5 + 42 = 109.
  Asserted by a passing test. **This line said 67 until 2026-09-21 and was left stale by 7H.**
  **The playable count has not been re-measured since IOS-POC-5L**; the last coherent sweep was
  37 of 61 on 2026-09-17, which predates 5M, 5P and 5Q. Quote the listed counts and say the playable
  figure is stale — do not quote 37 of 61 as current. The Python sites are the exception, because
  IOS-POC-7P measured them end to end: **14 of 42 execute and 6 reach media bytes.**
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
- **drpy JavaScript sources run since IOS-POC-6B.** Their `api` is an engine
  (`./drpy_libs/drpy2.min.js`) and their `ext` is the site's own rule script — the engine/rule split
  `XBPQ` and `XYQHiker` already have, except the engine arrives from the configuration. It is **not
  a second runtime**: `DrpyEngine` is a loader that fetches drpy2 and its nine libraries, rewrites
  the four that are ES modules into plain script, and hands the result to the existing
  `JavaScriptSpiderRuntime`. **Nothing is evaluated unverified** — same origin as the configuration,
  HTTPS only, per-file and whole-bundle size ceilings checked while the body streams, and a SHA-256
  compiled into the build that must match or the site is refused. No warn-and-continue path. The
  **engine is pinned and a rule script is not**, which is the `host.js` line IOS-POC-5O already
  drew. All four same-origin drpy sources reach real media bytes. Contract:
  `docs/IOS-POC-6A-drpy-loader.md`.
- **The sniffer unwraps a wrapper page since IOS-POC-6C.** A candidate like
  `…/vip/?url=…/index.m3u8` passed the keyword test on the strength of the address inside it, so the
  player got HTML. `MediaSniffer.isCandidate` is now the one test both sniff paths use, an accepted
  candidate is unwrapped one level, and a page whose own query names the stream skips the web view.
- **The Python runtime is built and measured (IOS-POC-7E–7P), not merely assessed.** This bullet
  said "assessed and measured, not built" until 2026-09-21 and was left stale by those commits.
  **CPython 3.13.15 starts inside the app**, `PythonSpiderRuntime` implements the same
  `SpiderRuntime` contract every other spider uses, and routing is the existing `CSPSourceResolver`
  with one extra branch — so `SourceClient`, history and the UI never learn that a source is Python.
  The payload is **not committed**: `scripts/fetch_python_ios.sh` downloads and verifies it against
  `third_party/python-ios-lock.json` (the Xcode `Prepare Python` phase calls the script, so an
  ordinary build does this by itself). `requests`, `urllib3`, `certifi`, `idna` and
  `charset-normalizer` are vendored as pinned pure-Python wheels (IOS-POC-7P) — no compilation.
  **Python lives in the App target only**, behind the `PythonSpiderSupport.makeRuntime` seam, so
  `WebHTVCore` still builds and tests on macOS where the XCFramework has no slice.
  **What it actually buys, measured on the simulator: 14 of 42 sites execute and 6 reach media
  bytes** (4 and 1 before vendoring). **Do not quote the larger numbers from the P1 assessment.**
  24 sites are still blocked on a dependency — `Crypto` 17, `lxml` 3, `pyquery` 2, `bs4` 2 — and
  4 are refused by the same-origin/HTTPS policy. `bs4` is pure Python and would go the way
  `requests` did; `Crypto` is the largest block and `CatVodHost` already has AES, DES, MD5, SHA and
  HMAC to shim over. **Neither was started, and neither should start without the user asking.**
  **It has run on a device.** This bullet read "Nothing Python has ever run on a device" until
  IOS-POC-11B, contradicting `docs/IOS-POC-7A-python-runtime.md`, which had already recorded the
  opposite: on the iPhone 18 Pro (IOS-POC-9F) CPython 3.13.15 starts, the 13-method selfcheck passes
  with its deliberate negative case, `皮皮虾.py` runs `init → home → category → detail → search →
  player → probe(media)` to **real media bytes**, and the 42-site survey ran there too with the same
  dependency and policy counts as the simulator. Full record:
  `docs/IOS-POC-7A-python-runtime.md`.
- **Also implemented:** native Swift config/CMS core; SwiftUI iPhone shell with Android-like
  wallpaper and settings; AVPlayer plus Infuse, Fileball, SenPlayer and VidHub; type-0, type-1 and
  type-4 sources; two-level category browsing, CatVod filter rows, scrolling category rows, a Top
  button and collapsible child rows; pagination; configuration from an imported file **or any HTTPS
  Raw URL** with schema validation, last-known-good caching, atomic replace, last-update status,
  manual refresh and a retrying launch refresh; a config-relative resource resolver; and a **WebHome
  bridge over `WKWebView` + `WKScriptMessageHandler`** covering the network, cache, UI, navigation,
  information and playback methods on one persistent `PlaybackSession`.
- **Not implemented:** the 23 portable-but-unported `csp_*` sites, the `Crypto`/`lxml`/`pyquery`/
  `bs4` shims the remaining 24 Python sites need, `CatVodHost` RSA and `proxy` plumbing, the
  configuration's `ads`/`rules` and the rest of IOS-POC-5S including opening/ending skip,
  `player.preloadArtwork`, `pan.*`, `app.open*`, `net.resourceUrl` proxying, and
  `ui.setChrome`/`restoreChrome`.
  **Three things came off this list and must not be written back onto it.** The Python runtime left
  on 2026-09-21 (IOS-POC-7E–7P). **The SideStore/IPA release pipeline left on 2026-09-22**
  (IOS-POC-11): the workflow, `source.json` and two published releases exist.
  **MPV is not on this list either, and is not finished** — it is started and paused; see the MPV
  bullet below. A source-specific DNS or TLS error does not prove a global iOS network bug.
- **MPV: started, implemented in part, rendering unresolved and paused.** MPVKit 1.0.0 (non-GPL) is
  wired into the App target, static linking is confirmed by symbol table rather than by configure
  flags, and **libmpv initialises on the simulator and on the iPhone 18 Pro** (IOS-POC-9B/9C/9D/9F).
  **Rendering does not work.** On the device, Metal + software decode reaches `FILE_LOADED` and
  **`VIDEO_RECONFIG` never fires; the picture stays black** — which rules out both the simulator's
  software MoltenVK and the network, because the device has a real GPU and `FILE_LOADED` proves the
  media arrived. **There is no second playback core**: `PlayerRouter`/`MPVEngine` was the design, not
  the state, and nothing routes playback away from `AVPlayer`. When the user resumes it, continue
  from the `FILE_LOADED → VIDEO_RECONFIG` gap — the untried **OpenGL on device** cell is the
  cheapest discriminator — not from MPVKit installation, and do not redo the 9A licence review
  unless MPVKit or its dependencies change. `docs/IOS-POC-9B-mpv-playback-core.md`.
- **The CatVod JS spider contract runs since IOS-POC-10T, and is confirmed on the device (10V).**
  TVBox carries two JavaScript contracts sharing the `.js` extension: a drpy rule exposes a `rule`
  object, a JS spider defines `__jsEvalReturn()` returning
  `{init, home, homeVod, category, detail, play, search}`. **It is not a third runtime** — same
  `JSContext`, same `CatVodHost`, no new native primitive, and no drpy engine downloaded because a
  JS spider does not use one. The blocker was never the entry point but **`async`**: drpy2 contains
  no `async` at all, so `JavaScriptSpiderRuntime` had never needed to settle a promise, and every
  method was arriving as `{}` with no error. `麻豆(js)` is listed and plays on the iPhone 18 Pro.
  `docs/IOS_SPIDER_RUNTIME_SPEC.md`.
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
- **It has run on real hardware, and the device acceptance is PARTIAL — never record it as
  complete.** Two runs on an iPhone 16 Pro on 2026-09-18 (IOS-POC-8A found three defects, 8H
  confirmed two fixes); on 2026-09-21 the user moved to a **new iPhone 18 Pro**
  (`00008160-00124C8200214036`), where IOS-POC-9F started CPython and libmpv; and on 2026-09-22 the
  user confirmed **麻豆(js) listed and playing** (10V) and **荐片's filter rows on a cold start**
  from a SideStore install of `0.1.1 (2)`. The earlier device now reports `unavailable`.
  **Still owed before this can be called an acceptance:** CMS browsing and playback, a `csp_*`
  source, a drpy source, Bili's `Referer` + browser `User-Agent` through `AVPlayer`, whether
  `AVURLAssetHTTPHeaderFieldsKey` works on a device at all, WatchHistory and resume, opening
  Infuse / Fileball / SenPlayer / VidHub, Picture in Picture, and MPV rendering if it is fixed.
  **麻豆 playing settles none of the header question**: its only header is a `User-Agent` and that
  stream answers `HTTP 200` with or without one, measured with `curl` both ways.
  **The user installs through SideStore since 2026-09-22**, so a build reaches the phone as a
  published IPA — do not install to the device directly.
  **The Xcode project still carries no `CODE_SIGN` or `DEVELOPMENT_TEAM`** — signing is passed on the
  command line (`DEVELOPMENT_TEAM=764SVXY2B7 CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates`,
  free personal team, profile expires seven days after issue), so nothing personal is committed.
  **Everything except the items listed in `docs/current-task-state.md` under "Where the roadmap
  actually stands" is still simulator-only**, including the whole playback path and, most sharply,
  whether `AVURLAssetHTTPHeaderFieldsKey` works on a device — the `NWListener` test that proves the
  key runs on macOS, not on the phone. An earlier revision of this line read "Nothing has ever run on
  a real device" and was left stale by the IOS-POC-8A commits.
- **ATS policy changed by explicit user decision on 2026-09-15 (IOS-POC-4B).** Most configured
  sources are cleartext `http`; the user was offered a narrow per-domain exception, no change, or
  global cleartext, was told the earlier records forbid weakening ATS globally for one site, and
  chose global cleartext. `ios/WebHTVApp/Info.plist` sets `NSAllowsArbitraryLoads`. Do not broaden
  transport security further. No server-trust override was added, so HTTPS certificate evaluation
  remains the system default — reasoned from the code, not measured.
- **The next stages, restated by the user on 2026-09-22.** ~~Python P2–P5~~ **done**
  (IOS-POC-7E–7P). ~~The CatVod JS spider contract~~ **done** (10T/10V). ~~The SideStore release
  pipeline~~ **done** (11). **MPV is started and paused with rendering unresolved** — it is neither
  a future stage nor a finished one, and it resumes only when the user says so, from the
  `FILE_LOADED → VIDEO_RECONFIG` gap. **The next functional stage is IOS-POC-5S** — ads, opening and
  ending — **and it has not started**; its first action is to measure the real shape of the
  configuration's `ads`/`rules` and any opening/ending data against the Android contract rather than
  guessing a schema, and the user's constraints for it are recorded in
  `docs/current-task-state.md`. The **full real-device acceptance** remains owed. **Do not
  prioritise XueLuo, QimaoDJ, AppDrama or any further `csp_*` class**, the Python `Crypto`/`bs4`/
  `lxml`/`pyquery` shims, `CatVodHost` RSA/`proxy`, CarPlay, an automatic AVPlayer↔MPV fallback, or
  any new release version; all of those stay in the backlog until the user asks.
  **The Official/XPTV shape stopped being hypothetical on 2026-09-21**: the user settled it as the
  product — a shell that bundles no sources and takes the user's own configuration. The app already
  bundles none. What remains is a build profile, not a fork: see
  `docs/analysis/ios-app-store-readiness-research.md` for distribution and submission, and
  `docs/IOS_SPIDER_RUNTIME_SPEC.md` for which spider delivery mechanisms are code and which are data.
- Per-stage records: `docs/IOS-POC-1E-config-persistence.md`, `docs/IOS-POC-1F-config-sources.md`,
  `docs/IOS-POC-2B-webhome-bridge.md`, `docs/IOS-POC-2D-webhome-bridge-ui-info.md`,
  `docs/IOS-POC-2E-webhome-bridge-playback.md`, `docs/IOS-POC-4A-type4-sources.md`,
  `docs/IOS-POC-4J-type0-xml-sources.md`, `docs/IOS-POC-5D` through `docs/IOS-POC-5R-*.md`, and
  `docs/IOS-PORTING-HANDOFF-2026-09-13.md` for the original architecture assessment (written against
  an older 208-site resource set; its 136 `csp_*` figure is historical).
