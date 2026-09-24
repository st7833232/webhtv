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
- **Branch `ios-poc`. At the start of IOS-POC-5S-2 on 2026-09-22 the base HEAD was `eba5346c`, the
  worktree was clean, and `git rev-list --left-right --count HEAD...origin/ios-poc` answered `0 0`** —
  level with the remote. The branch has been pushed several times that day, each at the user's
  explicit instruction, and the release workflow pushes `source.json` itself; no recovery tag was
  created, and recovery tags have been opt-in since 2026-09-16. The only tags on this line are the
  release ones the workflow makes.
  **Do not trust the id in this line.** It has been stale at `2a177f50`, `bb965dda`, `7653a9fb`,
  `a076ab51`, `20c4bd53` and `616e182e` before, and a handoff arriving with **`035ad0bf` as "the
  latest on GitHub" was sixteen commits behind** — that commit is the roadmap-only one, an ancestor
  rather than the tip. Run `git log` and the `rev-list` above on resume instead of reading it here.
- **Current release: `WebHTV 0.1.12 (13)`, published 2026-09-24 at the user's instruction** (run
  `35971952291`, tag `ios-v0.1.12-b13` → `4548bf7b`; `source.json` `57b32ef2`, IPA 24,877,616 bytes,
  SHA-256 `a7170a0b…`, downloaded back and verified): `0.1.11 (12)` plus the IOS-POC-17H PiP
  resolution fix `5613517a`. **No device result yet.** Record: `docs/IOS-POC-11-sidestore-release.md` 第十三次發布.
- **Previous release: `WebHTV 0.1.11 (12)`, published 2026-09-24** (run
  `35968750165`, tag `ios-v0.1.11-b12` → `aa30bc0f`; `source.json` `d681a72d`, IPA 24,877,389 bytes,
  SHA-256 `bbdbf06c…`, downloaded back and verified): `0.1.10 (11)` plus IOS-POC-17G and 17H.
  **No device result yet.** Record: `docs/IOS-POC-11-sidestore-release.md` 第十二次發布.
- **Previous release: `WebHTV 0.1.10 (11)`, published 2026-09-24** (run
  `35953397506`, tag `ios-v0.1.10-b11` → `5dadcd04`; `source.json` `d7a6e35e`, IPA 24,851,830 bytes,
  SHA-256 `01ff7bb6…`, downloaded back and verified): `0.1.9 (10)` plus IOS-POC-16B, 15D and 17F
  (the bullet below). **No device result yet.** Record: `docs/IOS-POC-11-sidestore-release.md` 第十一次發布.
- **Previous release: `WebHTV 0.1.9 (10)`, published 2026-09-23** (tag `ios-v0.1.9-b10` → `8df71c12`,
  Task-Guard `IOS-POC-18-source-identity`, run `35874971373`; `source.json` `dde455ba`, IPA
  24,767,406 bytes, GitHub asset SHA-256 `46385529…`): `0.1.8 (9)` plus **IOS-POC-18** — object-ext
  sources (e.g. 靈虎) keep their site across relaunch, watch-history entries greyed out by source-ID
  drift migrate on upgrade, sources are keyed by a stable canonical identity (Spider ext behaviour
  unchanged). Record: `docs/IOS-POC-11-sidestore-release.md` 第十次發布.
- **Previous release: `WebHTV 0.1.8 (9)`, published 2026-09-23 at the user's instruction** (run
  `35846736589`, tag `ios-v0.1.8-b9` → `0a57d545`, IPA 24,754,269 bytes, SHA-256 `e6aff904…`,
  verified by downloading it back). It carries 5S-3 and all of IOS-POC-17, **including 17E: MPV is
  offered in release builds** (user decision; device first frame unverified, guarded by the
  10-second first-frame watchdog that falls back to AVPlayer) and **the quality menu in the control
  bar**. `swift test` → **323, all pass** after 17E; measured **326／325** at `dde455ba` (after
  IOS-POC-18; the one failure is the weather test). `0.1.7 (8)` and earlier are superseded. **No
  device result has been reported for `0.1.8 (9)` or `0.1.9 (10)` yet.** Everything below that says
  MPV is release-disabled or that the release is `0.1.7 (8)` is superseded by these two lines.
- **After `0.1.9 (10)` — pushed and shipped in `0.1.10 (11)` on 2026-09-24:**
  **IOS-POC-16B** `a5f2678e` — the control bar's seven second-level choices (speed, quality, engine,
  subtitles, audio, opening, ending) open panels the bar owns instead of SwiftUI `Menu`
  (`docs/IOS-POC-16-custom-player-controls.md` 第十之一節); **IOS-POC-15D** `6416c4d4` — the
  IOS-POC-15 buffering/prefetch contract checked line by line, with `os.Logger` `[playback]`
  measurements (`docs/IOS-POC-15-playback-buffering-preload.md` 第十二節); **IOS-POC-17F**
  `b37751d2` — network/unclassified failures and a start that has not come after 20 seconds now try
  the other engine once per attempt; offline and source failures never switch
  (`docs/IOS-POC-17-dual-internal-player.md` 第十二之二節). `swift test`: 335／334 after 16B,
  340／339 after 15D, **344／344 after 17F** (the only failure ever is the weather test). **None of
  the three has run on a device.** The MPV parity roadmap (P1 device baseline → P2 cache parity →
  P3 tracks → P4 external/ASS subtitles → P5 background audio/Now Playing → P6 PiP bridge → P7
  AirPlay Audio) is IOS-POC-17 第十四節.
- **After `0.1.10 (11)` — shipped in `0.1.11 (12)` on 2026-09-24:** **IOS-POC-17G**
  `257553f2` — MPV redraws at the new size after a rotation (IOS-POC-17 第十二之三節); **IOS-POC-17H** `8824c8ee` —
  MPV Picture in Picture (= parity P6): inline stays on Metal, and only while the PiP window is open
  mpv's `vo` switches to the libmpv software renderer, whose frames go into a sample buffer layer
  (`docs/IOS-POC-17H-mpv-picture-in-picture.md`). The simulator's sample-buffer PiP window is always
  black (a textbook minimal sample-buffer PiP is black too, AVPlayerLayer PiP is not), so **the PiP
  picture, automatic PiP and the PiP controls are device-unverified.**
- **IOS-POC-17 — the app plays with its own two engines (2026-09-23, user decision).** Started at
  `2a46c3fb` (= `origin/ios-poc`, `0 0`, clean); commits `ecb0c4d0` 17A, `cf076e79` 9G, `7d679d68`
  17B, `a1750b8c` 17C, then 17D docs — all pushed since (on `origin/ios-poc`, released in `0.1.8 (9)`). External players are gone (17A). **MPV's
  black screen was our probe**: it drained mpv's events inside the wakeup callback, which
  `client.h` forbids and which deadlocks on the playloop at `FILE_LOADED`; fixed as MPVKit's demo
  does it, and **both Metal and OpenGL draw on the simulator** (9G). **Device: not re-run.** Core now
  has `PlaybackEngine` / `PlayerRouter` / `PlaybackEngineSelection` / `PlaybackFailure`;
  `AVPlayerEngine` is a thin adapter over the unchanged AVPlayer code (IOS-POC-15's policy runs only
  on AVPlayer), `MPVEngine` is the demo's Metal path; 「預設播放器」 in settings; the control bar
  shows the engine actually playing and switches it for the session; only engine-capability
  failures fall back, once per attempt, either way (17B). An episode opens the player directly
  (17C). **Release builds offer AVPlayer only** until MPV's device first frame; Debug builds offer
  both. **322 tests, all pass**; simulator build succeeds. VLCKit only after the MPV stop condition,
  never a third engine. `docs/IOS-POC-17-dual-internal-player.md`.
- **Core real-device acceptance is prepared (IOS-POC-8L, 2026-09-23), not performed.** HEAD was
  `f0495b8b` = `origin/ios-poc`, `0 0`, clean; everything after `63040bb3` is docs-only, so the
  measurement below still describes the functional tree and was **cited, not re-run**. The
  matrix — 已驗證／這輪要驗／延後驗證／不適用, with the source, steps and report format for each
  of the 14 user-run items — is `docs/IOS-POC-8L-core-real-device-acceptance.md`. Read its §4–§5
  before judging 5S on a phone: `wang-movie.json` has no source reaching either `script` rule host
  or its one ad host, and the sniffer web view and all `print` diagnostics are invisible on a
  SideStore Release install.
- **Superseded by 17E (323), `dde455ba` (326／325) and 17F (344／344) — IOS-POC-17B on 2026-09-23:** `swift test` → **322 tests, all pass**;
  simulator Debug build → **BUILD SUCCEEDED**. The 297/296 line below is superseded.
- **Earlier — macOS at `63040bb3` (IOS-POC-5S-3) on 2026-09-23:**
  `swift test --package-path ios` → **297 tests, 296 pass, 1 fails**, and the simulator Debug build
  (`id=7B4E9557-4774-4EB9-B408-BB544DCC8657`) → **BUILD SUCCEEDED**. The failure is the same
  provider-weather test named below. **266, 228, 225, 203 and 197 are all superseded** — this list is
  newest-first, so read this line and not the ones under it.
- **Superseded, kept for the trajectory — at `ecebeaa3` + IOS-POC-15 on 2026-09-23:**
  `swift test --package-path ios`
  → **266 tests, 265 pass, 1 fails**, and the simulator Debug build
  (`id=7B4E9557-4774-4EB9-B408-BB544DCC8657`) → **BUILD SUCCEEDED**. The one failure is
  `reportsLiveType4SitesFromProvidedConfig`, which the bullet below classifies as weather rather
  than a gate — it failed the same way at `61f2d6fd` earlier the same day, and `88看球` was observed
  resolving to `http://nba.toutiaozb.com/qq/qq-kbs.html?…`, an HTML page. **228, 225, 203 and 197
  are all superseded.**
  The input configuration was re-fetched from the user's own GitLab for this run and its SHA-256
  matches the recorded baseline `b17576e3…` byte for byte.
  **The earlier 228-test line is kept in spirit below because its lesson stands:**
  **This run closed a real gap**: the session that wrote the PiP foreground-restore fix and its
  three tests ran on a **Linux host with neither `swift` nor `xcodebuild`**, so that code was
  committed — and `0.1.5 (6)` published from it — without ever being compiled or tested locally.
  It compiles and its tests pass; the **defect itself is still open** and still needs the device
  acceptance in `docs/bugs/IOS-PIP-foreground-restore.md`.
- **Measured at `eba5346c` on 2026-09-22 (IOS-POC-5S-2):** `swift test --package-path ios` →
  **225 tests, all pass**, and the simulator Debug build succeeds. The 22 new ones are 5S-2's.
- **Measured earlier the same day at `616e182e` (IOS-POC-11F):**
  `swift test --package-path ios` → **203 tests, all pass**. `xcodebuild … -scheme WebHTVApp
  -destination 'platform=iOS Simulator,id=7B4E9557-4774-4EB9-B408-BB544DCC8657' -configuration Debug
  build` → **BUILD SUCCEEDED**. **No device build**: the iPhone 18 Pro reported `unavailable`, and
  the user installs through SideStore now, so a build reaches the phone as a published IPA.
  **The destination must be an id**: an iOS 27.0 runtime appeared on this machine, so
  `name=iPhone 17 Pro` matches two devices and xcodebuild refuses to choose.
  **Two live tests are weather, not gates.** `reportsLiveType4SitesFromProvidedConfig` and
  `completesLiveCMSFlowFromProvidedConfig` have each failed and passed on the same day — one of them
  with a TLS error `curl` could not reproduce a minute later. **Neither is to be "fixed."**
  Earlier revisions of this line read "151 tests, all pass", "185 tests, one failing" and
  "188 tests, one failing"; all are superseded.
- **Superseded by the release bullets above — pre-`0.1.8` record:** the release was `WebHTV 0.1.7 (8)`, tag `ios-v0.1.7-b8`, built unsigned by the workflow
  from `add58007` on 2026-09-23 and re-signed on the device by SideStore
  (`WebHTV-0.1.7-8.ipa`, 24,689,841 bytes, SHA-256 `338a4943...`, run `35827470170`, verified by
  downloading it back). **It carries IOS-POC-15** — so the device performance pass that stage owes
  is now actually possible; the user asked for this build in order to run it. It also carries the
  2.5×/3× audio fix and the seek-time buffered-bar fix. The binary was checked to contain all five
  IOS-POC-15 types and the four AVPlayer setters, not just a bumped version number.
  **`0.1 (1)` through `0.1.6 (7)` are all superseded.**
  The Xcode project carries `MARKETING_VERSION = 0.1.7` and `CURRENT_PROJECT_VERSION = 8`
  (re-read 2026-09-23; this line said `0.1.6`/`7` and was left stale by `add58007`), so the
  workflow's blank-input default resolves to the version actually published.
  **`0.1.7 (8)` does not contain 5S-3** (`63040bb3` is not an ancestor of `add58007`). **The next
  acceptance release candidate is `0.1.8 (9)`** — planned, pre-flight `iphoneos` Release build
  succeeded with the version overridden on the command line, **not published**; the publish
  sequence and release-notes draft are in `docs/IOS-POC-8L-core-real-device-acceptance.md` §3. **Do not install to the device directly** — produce an IPA, or trigger
  `ios-sidestore-release.yml` once the user authorises it.
- **An episode that ends starts the next one since IOS-POC-14, and the user confirmed it on the
  device.** `PlaybackSession.finished()` always advanced; the app's own path opens one resolved
  address, so there was never a next item to reach — while the WebHome bridge's inline playlist did
  advance. A season cannot be resolved up front, so the detail screen keeps the list and the player
  asks. The playback speed carries **within one title** (14A/14B), keyed on `WatchHistory.key`, so
  switching source resets it — a decision the user took rather than a gap (14C). Subtitle and audio
  tracks are deliberately not carried. `docs/IOS-POC-14-autoplay-next-episode.md`.
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
  Referer → 206, everything else → 403). (External players could never be told about headers — one of the
  reasons they were removed; superseded by dual internal-player decision, 2026-09-23.) `AVURLAssetHTTPHeaderFieldsKey` is undocumented;
  `avURLAssetSendsTheHeadersItWasGiven` observes it working against a real socket.
- **`playerContent`'s `url` reads all three CatVod shapes since IOS-POC-5Q.** `PlayURL` is the only
  decoder for it on **both** the spider and the CMS path — reading it as a `String` used to throw on
  one and be swallowed into 「這一集沒有可播放的網址」 on the other. The player sheet shows a quality
  menu when a source offers more than one, defaulting to the highest unless a remembered choice says
  otherwise. `Bili` expresses its qualities as **one line per quality**, because every `qn` costs its
  own `playurl` call. No configured source returns a `url` array, so the menu has never been
  triggered by real data. `docs/IOS-POC-5Q-playback-quality.md`.
- **The viewer can set an opening and an ending since IOS-POC-5S-2.** They are `History.opening` /
  `History.ending` — **millisecond offsets the viewer sets themselves, not anything in the
  configuration**: IOS-POC-5S measured `ads` and `rules` and neither carries an intro or an outro,
  and the nine m3u8 ad-stripping regexes in `wang-sex.json` have no consumer in the Android app at
  all. They live on the existing `WatchHistory` as **optional** `Double` milliseconds, because the
  synthesized `Codable` throws `keyNotFound` on a missing non-optional and the store reads a throw as
  "no history" — the same `?` `sourceID` carries, and the reason nobody's records are lost. Playback
  starts at `max(opening, resume)`, and `ending + position >= duration` hands off through the
  **existing** `finished()` path on the **existing** five-second sampler, so there is no second
  playback state and no second ended pipeline. One record covers a whole title, so the setting
  follows the viewer across episodes and lines and cannot cross a title, a site or a configuration.
  `app.history` now carries both — Android declares the fields, so this fills them in rather than
  exposing anything iOS invented. The controls are two `Menu`s on the player's trailing edge
  (設為目前位置 / +1 秒 / −1 秒 / 清除). **Not device-verified.**
  **AVKit's transport bar genuinely cannot be extended on iOS**, confirmed against the iOS 27 SDK
  header on 2026-09-23: `transportBarCustomMenuItems`, `customOverlayViewController`,
  `contextualActions` and `infoViewActions` are every one of them `API_UNAVAILABLE(ios)`. What *is*
  **Nor can iOS observe when AVKit's controls are showing.** The real delegate method is
  `willTransitionToVisibilityOfTransportBar` and it is `API_UNAVAILABLE(ios)` as well. IOS-POC-10A
  recorded `...VisibilityOfPlaybackControls` as "a public API" and it **is not a method of
  `AVPlayerViewControllerDelegate` at all** — every member of that protocol is ObjC-optional, so an
  unrelated method on a conforming type compiles silently and is never called. A deliberately
  nonsense method name typechecks identically; that was measured. So `chromeVisible` stayed `true`
  forever and **the close button sat on the video permanently**, which is what the user reported on
  2026-09-23 and the real reason 10H removed it. **Do not trust a delegate method because Swift
  compiled it** — check the header for protocol membership and platform.
  The consequence is **IOS-POC-16**: the control bar has to be ours. It is implemented — AVKit
  draws nothing and `PlayerControlBar` draws the lot, owning its own five-second auto-hide.
  **Confirmed on the simulator**: AVKit's controls are gone, the video is clean while the bar is
  hidden, and the bar renders complete and correctly laid out. **Not confirmed: any individual
  control, including the close button — which is now the only way out of the player**, because
  AVKit's X went with its bar and IOS-POC-10I had already deleted the swipe-to-dismiss. The
  simulator tooling's round-trip is longer than the auto-hide, so "summon the bar, then press
  something" can never land; the user took the UI testing on 2026-09-23.
  **A trap that invalidated a whole session of simulator observation, 2026-09-23:** `xcodebuild`
  writes to `~/Library/Developer/Xcode/DerivedData/WebHTVApp-*/Build/Products/…`, while
  `ios/.build/out/Build/Products/Debug-iphonesimulator/WebHTVApp.app` is a **stale artifact from
  2026-09-21**. Installing that one reports success and runs two-day-old code, `BUILD SUCCEEDED`
  and all. Before trusting anything seen on the simulator, check that
  `xcrun simctl get_app_container <udid> <bundle-id>` and the path from
  `xcodebuild -showBuildSettings | grep BUILT_PRODUCTS_DIR` hold the **same** binary.
  `docs/IOS-POC-5S-ads-and-skip.md`, `docs/IOS-POC-16-custom-player-controls.md`.
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
  wallpaper and settings; AVPlayer and MPV as the app's own two engines (Infuse, Fileball, SenPlayer and VidHub were
  removed on 2026-09-23); type-0, type-1 and
  type-4 sources; two-level category browsing, CatVod filter rows, scrolling category rows, a Top
  button and collapsible child rows; pagination; configuration from an imported file **or any HTTPS
  Raw URL** with schema validation, last-known-good caching, atomic replace, last-update status,
  manual refresh and a retrying launch refresh; a config-relative resource resolver; and a **WebHome
  bridge over `WKWebView` + `WKScriptMessageHandler`** covering the network, cache, UI, navigation,
  information and playback methods on one persistent `PlaybackSession`.
- **Not implemented:** the 23 portable-but-unported `csp_*` sites, the `Crypto`/`lxml`/`pyquery`/
  `bs4` shims the remaining 24 Python sites need, `CatVodHost` RSA and `proxy` plumbing,
  `player.preloadArtwork`, `pan.*`, `app.open*`, `net.resourceUrl` proxying, and
  `ui.setChrome`/`restoreChrome`. **The configuration's `ads` host blocking came off this list
  in IOS-POC-5S-1**: it is implemented with a sniffer-only `WKContentRuleList`. **IOS-POC-5S-2
  opening/ending came off it too**, and **IOS-POC-5S-3 config `rules` integration came off it on
  2026-09-23** (`63040bb3`) — this line listed all three as missing and every one of those readings
  is superseded. **No part of IOS-POC-5S is still open in code**; what is open is its device
  acceptance.
  **Three things came off this list and must not be written back onto it.** The Python runtime left
  on 2026-09-21 (IOS-POC-7E–7P). **The SideStore/IPA release pipeline left on 2026-09-22**
  (IOS-POC-11): the workflow and `source.json` exist and have published ten releases, through `0.1.9 (10)`.
  **MPV is not on this list either** — it ships as the second engine since `0.1.8 (9)` (IOS-POC-17),
  device first frame still owed; see the IOS-POC-17 bullet above. A source-specific DNS or TLS error does not prove a global iOS network bug.
- **Superseded 2026-09-23 by IOS-POC-9G/17 — see the IOS-POC-17 bullet above.** The rest of this
  bullet is the pre-9G record: **MPV: started, implemented in part, rendering unresolved and paused.** MPVKit 1.0.0 (non-GPL) is
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
  from a SideStore install of `0.1.1 (2)`, and **an episode that ends starting the next one** from a
  `0.1.2 (3)` install (IOS-POC-14). The device reports `unavailable` between sessions, which is
  normal now that the user installs through SideStore rather than over a cable.
  **Still owed before this can be called an acceptance:** CMS browsing and playback, a `csp_*`
  source, a drpy source, Bili's `Referer` + browser `User-Agent` through `AVPlayer`, whether
  `AVURLAssetHTTPHeaderFieldsKey` works on a device at all, WatchHistory and resume, and MPV on a
  device (first frame, switching, fallback — 8L ⑱⑲). ~~Opening Infuse / Fileball / SenPlayer /
  VidHub~~ is superseded: they were removed on 2026-09-23.
  **Picture in Picture foreground restore has a code fix and still needs device verification.**
  `PlayerSurface.Coordinator` now consumes one foreground request per active PiP session and uses
  the smallest public AVKit workaround: disable `allowsPictureInPicturePlayback`, then restore it on
  the next main runloop. It keeps a weak controller reference, removes its lifecycle observer, and
  does not touch the shared player or playback state. The current Linux execution host could not run
  the Swift suite or Simulator build, so do not treat this as device closure. The required repeated
  real-device acceptance remains in `docs/bugs/IOS-PIP-foreground-restore.md`.
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
  pipeline~~ **done** (11). ~~IOS-POC-5S-1 ads blocking~~ **done** and released.
  ~~IOS-POC-14 auto-advance~~ **done, and confirmed on the device by the user**, with the playback
  speed carried within one title (14A/14B).
  ~~**The next functional unit is IOS-POC-5S-2 opening/ending**~~ **done**, ~~followed by **5S-3 config
  `rules` → sniffer**~~ **also done on 2026-09-23, so IOS-POC-5S is code complete** — see its own
  bullet below; it is *not* device-accepted. **IOS-POC-15's code landed out of this order on
  2026-09-23 at the user's explicit instruction** — do not re-plan it; see its own bullet for what it
  built and what it still owes. Two things the 5S-1 measurement settled and that 5S-2/5S-3 must not
  re-litigate: **the m3u8 ad-stripping rules in the configuration have no consumer in this Android
  app at all** — `Rule.getRegex/getExclude/getScript` is read only by `Sniffer` — so there is no
  contract to port and inventing one is forbidden; and **opening/ending are not in the configuration**
  but in `History` as user-set millisecond offsets, consumed in exactly two places
  (`position = max(opening, position)` and `ending + position >= duration → checkEnded`). After 5S, close the core real-device acceptance sufficiently to freeze the
  product contracts, then — ~~record the MPV keep/drop decision~~ (**made 2026-09-23: MPV is kept**, and its
  device first frame is now part of core acceptance, IOS-POC-17) — only then begin **IOS-POC-12 Runtime Architecture
  Reconciliation**, a behaviour-preserving refactor/contract-freeze stage, followed by
  **IOS-POC-13 Runtime Hot Update**. IOS-POC-13 owns manifest/version/hash/authenticity checks,
  staging, atomic activation, rollback/LKG and runtime-generation isolation; it does **not** replace
  signed Swift/native code. The detailed boundary and entry gates are in
  `docs/IOS-POC-12-13-runtime-update-roadmap.md`. **Do not prioritise XueLuo, QimaoDJ, AppDrama or
  any further `csp_*` class**, the Python `Crypto`/`bs4`/`lxml`/`pyquery` shims, `CatVodHost`
  RSA/`proxy`, CarPlay, ~~an automatic AVPlayer↔MPV fallback~~ (implemented in IOS-POC-17B, widened in 17F), or a new release version ahead of this
  sequence unless the user explicitly changes priorities.
  **The Official/XPTV shape stopped being hypothetical on 2026-09-21**: the user settled it as the
  product — a shell that bundles no sources and takes the user's own configuration. The app already
  bundles none. What remains is a build profile, not a fork: see
  `docs/analysis/ios-app-store-readiness-research.md` for distribution and submission, and
  `docs/IOS_SPIDER_RUNTIME_SPEC.md` for which spider delivery mechanisms are code and which are data.
- **Post-core refactor / in-app runtime update is now an explicit future roadmap, not current work.**
  IOS-POC-12 freezes the Native Core/Dynamic Layer boundary and removes avoidable hard-coded
  volatility from Swift without changing behaviour. IOS-POC-13 then adds the runtime updater.
  Intended hot-update content includes compatibility packs, JS/Python source scripts, drpy/rules,
  mappings, ads/rules data and resources; schema/data-driven UI may update only within renderers the
  installed App already knows. Swift/SwiftUI executable behaviour, native playback/runtime code,
  MPV/FFmpeg, CPython XCFramework/native dependencies, entitlements and Info.plist capabilities
  still require an IPA. SideStore remains the native-App update path.
- **IOS-POC-5S is code complete since 2026-09-23, and device-accepted in no part.** 5S-3 wired the
  configuration's `rules` into the sniffer. Base HEAD was `60a9241e`.
  **Ported from `Sniffer.java` itself, not from a summary of it**, which corrected two things a
  paraphrase gets wrong. First, `getRule` joins the direct host and the `url=` query parameter's host
  into **one comma-separated string** and searches that, so **neither has precedence over the other**
  — precedence is at the rule level: configuration order, first match wins. Second, `isVideoFormat`
  runs **two passes per list**, every entry as a literal substring and then every entry as a regular
  expression, so a literal hit on a later entry beats a pattern hit on an earlier one; folding them
  into one pass per entry would change which entry decides. `exclude` outranks `regex`, both outrank
  the built-in candidate test, and **when no rule matches the behaviour is byte-for-byte what it was**.
  `Util.containOrMatch` is `contains || matches` (Java `matches` = whole string) **inside a
  try/catch returning false**, so a bad *host* pattern failing safe is parity, not a narrowing.
  **The one deliberate iOS narrowing:** `isVideoFormat` compiles `regex`/`exclude` outside any
  try/catch, so Android throws on a malformed pattern. There is no fallback to port; iOS treats an
  uncompilable pattern as non-matching and logs **once per adopted configuration**, never per URL.
  `script` is evaluated with **`evaluateJavaScript` on `didFinish`, deliberately not `WKUserScript`**
  — a user script persists on the content controller and would re-run and stack up on every
  navigation. It is selected by the **page's** host, while accept/reject is selected by the
  **candidate's**; the two are not interchangeable.
  **The rules reach the sniffer's web view and nothing else, structurally**: the whole iOS tree
  constructs exactly two `WKWebView`s — `MediaSniffer.Collector` and the WebHome bridge — and the
  rule set is read only inside `Collector`. Three tests stand a real socket and a real `WKWebView` to
  prove the script actually runs there, that a page whose host no rule names gets nothing, and that
  a nil rule set behaves as before.
  **The 9 playlist-shaped regexes stay inert and no playlist is ever opened.** `Rule.getRegex/
  getExclude/getScript` is read only by `Sniffer`, which sees URL strings — there is no HLS consumer
  anywhere in the Android repository, so there is no contract to port and inventing one is
  forbidden. A test pins it.
  **One honest risk, kept because Android has it:** a `regex` hit accepts outright, bypassing the
  keyword test, so on a host a rule names a non-media URL can be taken as the stream. Bounded to the
  hosts the 10 measured rules name, and not narrowed — the configuration's author tuned `exclude`
  against exactly this behaviour.
  **Measured 2026-09-23:** `swift test --package-path ios` → **297 tests, 296 pass** (+31), the one
  failure being the standing `reportsLiveType4SitesFromProvidedConfig` weather test; **no new
  failures**. Simulator Debug build → **BUILD SUCCEEDED**. One pre-existing warning on
  `WebHTVConfig.swift`'s `ads` line was reported and deliberately not fixed (AGENTS.md §2).
  **Nothing in 5S — ads blocking, opening/ending, or rules — has been watched working on a device.**
  `docs/IOS-POC-5S-ads-and-skip.md`.
- **IOS-POC-15 Playback Buffering / Preload: the code is implemented and the real-device
  performance verification is still owed.** This bullet read "planned, not started" until
  2026-09-23. Base HEAD was `ecebeaa3`. **Do not record it as closed** — every number behind it is a
  unit test or a simulator build, and the user asked for it before a device baseline existed.
  **User decision 2026-09-23:** defer the IOS-POC-15 real-device performance pass until later; keep it
  pending rather than closed, but do **not** hold the roadmap here. That decision named IOS-POC-5S-3
  as the next functional unit, and **5S-3 shipped the same day** (`63040bb3`), so the unit that
  follows is **core real-device acceptance**, not another pass at 15.
  What is built: a `good/normal/risk/poor` model in `ios/Sources/WebHTVCore/PlaybackNetworkPolicy.swift`
  over buffer-ahead, `isPlaybackLikelyToKeepUp`, `isPlaybackBufferEmpty`, `timeControlStatus`,
  stalls and `AVPlayerItemAccessLog`'s observed/indicated bitrate. **No single sample may move the
  state** — two consecutive readings to step down, six to step **one** rung up, and only an actual
  stall or an empty buffer bypasses that. It sets `preferredForwardBufferDuration` to **60/90/120 s**
  for VOD, leaves **live and unknown-duration playback system-managed (0)**, and caps
  `preferredMaximumResolution` to **1080p/720p only when `AVURLAsset.variants` reports more than
  one** — a direct MP4 and a single-variant HLS are never capped. **`preferredPeakBitRate` is 0 in
  every state and `noStateEverCapsPeakBitRate` asserts it**: it is a download ceiling, not an
  accelerator. The policy type holds **no URL and no quality**, so it cannot move the viewer off a
  line they chose (IOS-POC-5Q); AVPlayer only ever picks within the one HLS asset's own variants.
  **Thresholds are all in `PlaybackNetworkThresholds` and nothing compares against a number declared
  elsewhere.**
  **It added no timer**: the policy rides the five-second sampler `PlaybackSession` already runs, and
  that loop's `record != nil` guard is gone so bridge and bare-URL playback get the policy too.
  **15C pre-resolves exactly one next episode**, through the **same `SourceClient.playbackURL`**
  pipeline (so playerContent/CSP/Python/drpy/sniff/headers/quality are reused, not reimplemented),
  and only once playback is stable (≥20 s, state ≥ `normal`) **and the handoff is within 90 s** —
  which is the whole defence against short-lived addresses, since **no source here publishes a TTL**.
  A 5-minute `maximumAge` is the second layer for a long pause. Any change of configuration, site,
  title, line, episode or quality invalidates it, and `take` consumes it either way. **A prefetch
  failure is an optimization miss**: `playNext` resolves normally, so auto-advance cannot fail
  because of it. Diagnostics name which of four things is limiting playback — slow source
  resolution, too little forward buffer, CDN throughput, or too high a selected variant — and log
  **only the first policy application and subsequent state transitions**, which the hysteresis
  itself throttles. No telemetry server, no media cache, no playlist rewrite, no second player.
  **Also fixed in the same change, and deliberately not part of 15's charter:** the viewer's report
  that **2.5× and 3× play silently**. `AVAudioTimePitchAlgorithmLowQualityZeroLatency` supports
  exactly 0.5/0.666/0.8/1/1.25/1.5/2 and **drops audio at every other rate** — precisely the two
  speeds IOS-POC-16 added. One line: `item.audioTimePitchAlgorithm = .timeDomain`. **Nobody has
  heard it on a device.** The companion 「畫面會跳轉」 is only half addressed: the cushion is measured
  in **playback** seconds (`bufferAhead / rate`), so 3× pushes the state down by itself and raises
  the buffer target — whether that is enough is a device question.
  **Measured 2026-09-23 on macOS:** `swift test --package-path ios` → **266 tests, 265 pass** (+38
  new), the one failure being the standing `reportsLiveType4SitesFromProvidedConfig` weather test
  (88看球 resolved to `qq-kbs.html`), which **cannot** be affected by this change because
  `swift test` never compiles `WebHTVApp.swift`. Simulator Debug build → **BUILD SUCCEEDED**, and the
  seven `WebHTVApp.swift` warnings in that log were **measured to be pre-existing** by rebuilding the
  file at base HEAD. Persistent/offline HLS downloading remains a later, separate decision.
  **Still owed, and the only thing that can close this stage** — on one device, same source, same
  episode, before and after: startup latency to first frame; buffer-ahead at 30 s and 60 s;
  stall/rebuffer count over 5–10 minutes; weak-network recovery without flapping; HLS quality step
  down and back up; next-episode time from the ending to actual playback; and whether 2.5×/3× now
  have sound. Record: `docs/IOS-POC-15-playback-buffering-preload.md` §8.
- Per-stage records: `docs/IOS-POC-1E-config-persistence.md`, `docs/IOS-POC-1F-config-sources.md`,
  `docs/IOS-POC-2B-webhome-bridge.md`, `docs/IOS-POC-2D-webhome-bridge-ui-info.md`,
  `docs/IOS-POC-2E-webhome-bridge-playback.md`, `docs/IOS-POC-4A-type4-sources.md`,
  `docs/IOS-POC-4J-type0-xml-sources.md`, `docs/IOS-POC-5D` through `docs/IOS-POC-5R-*.md`, and
  `docs/IOS-PORTING-HANDOFF-2026-09-13.md` for the original architecture assessment (written against
  an older 208-site resource set; its 136 `csp_*` figure is historical).
