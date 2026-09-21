# Current Task State

## Original Goal

Port WebHomeTV to iPhone with an Android-like UI, drive the user's own `wang-movie.json`, and offer built-in, Infuse, Fileball, SenPlayer and VidHub playback. The Google TV `csp_JPianAmns` repair is not in scope.

## Current Scope

- Branch `ios-poc`. **Verified 2026-09-21 at IOS-POC-7R: HEAD `7653a9fb` (IOS-POC-7Q), worktree
  clean, and `git rev-list --left-right --count origin/ios-poc...ios-poc` answered `0 0`** — level
  with the remote, which was pushed at the user's explicit instruction on 2026-09-21.
  **Re-check with `git log` rather than trusting any id quoted here** — this one line has carried
  five different stale ids in turn (`261b5c03`, "HEAD after IOS-POC-5L", `a087dd50`, `2a177f50` and
  `bb965dda` in the handoff), each wrong by the time it was read.
- Android `app/` is read-only for all iOS work and has never been modified: `git diff <branch-point>..HEAD -- app/` is empty, and every commit on this branch touches only `ios/`, `docs/`, `scripts/`, `AGENTS.md` and `.codex/`.
- **The input configuration lives in the scratchpad, not `/tmp`.** `/tmp/webhtv-recha-new.wprHof/` was cleared mid-session; `wang-movie.json` was re-fetched from the user's own GitLab and its SHA-256 matches the recorded baseline byte for byte. Re-fetch it from `https://gitlab.com/st7833232/recha/-/raw/main/wang-movie.json` if it is missing. `recha-main.zip` was **not** restored, so `scripts/audit_spider_jars.py` cannot be re-run without downloading it again.
- Stages through IOS-POC-4J have an annotated `recovery/<task-id>/*` tag; tags through `IOS-POC-1H` are on the remote. **Recovery tags became opt-in on 2026-09-16** (AGENTS.md §6), so IOS-POC-5A onwards are deliberately untagged.

## Where the roadmap actually stands (2026-09-21, IOS-POC-8L)

| Milestone | State |
|---|---|
| IOS-POC-5Q multi-quality | **Done and verified** (Q1–Q3) |
| IOS-POC-5R WatchHistory / resume | **Done and verified** (R1–R6; R7 intro/outro skipping deferred with 5S) |
| drpy loader | **Done and verified** (IOS-POC-6A/6B) |
| 4 drpy sources end to end | **Done** — all four reached real media bytes |
| Python feasibility / P1 | **Done** — measured, not implemented (`docs/IOS-POC-7A-python-runtime.md`) |
| Python P2–P5 | **Done, 2026-09-21** — `docs/IOS-POC-7A-python-runtime.md` carries all of it |
| Python `requests` vendoring (IOS-POC-7P) | **Done** — 6 of 42 sites now reach media bytes, 14 execute |
| MPV feasibility — licence/provenance (IOS-POC-9A) | **Done, 2026-09-21** — no licensing blocker, conditional on pinning MPVKit ≥1.0.0 non-GPL; `docs/IOS-POC-9A-mpv-license-provenance.md` |
| MPV feasibility — technical spike (IOS-POC-9B/9C/9D) | **Blocked on a device run, 2026-09-21.** Both renderers tried — Metal/gpu-next/MoltenVK and OpenGL/libmpv — and both stay black on the simulator, failing at different stages. mpv reports the simulator as a software renderer in so many words. `docs/IOS-POC-9B-mpv-playback-core.md` |
| Real-device baseline (IOS-POC-8) | **Partly done, and the rest deferred by the user on 2026-09-21** |

The device baseline is **not** finished, and nothing here should be read as saying it is. The user
**deferred the remaining acceptance on 2026-09-21** and sent the main line back to Python P2–P5.
What already ran on hardware stands and is not to be rolled back; what is listed as unverified
stays unverified until a later device pass, which is now scheduled after the MPV stage.

- **Verified on hardware:** a fresh install accepts a remote configuration; the remote configuration
  lists 67 sources; CJK and the source names' emoji render correctly; the app icon ships from the
  asset catalog and installs; IOS-POC-8F and 8G (search field, wallpaper) were confirmed by the user.
- **Still unverified on hardware:** the AVKit close button in its new position; browsing and playback
  on a CMS source; a `csp_*` spider source; a drpy source; **Bili's `Referer` + browser `User-Agent`
  actually playing through `AVPlayer`**; whether `AVURLAssetHTTPHeaderFieldsKey` works on a device at
  all; WatchHistory position and resume; opening Infuse / Fileball / SenPlayer / VidHub.
- **The header question is the sharp one.** `avURLAssetSendsTheHeadersItWasGiven` stands a real
  `NWListener` and asserts on real bytes, but **it runs on macOS**, so it is not evidence about the
  device. The key is undocumented; a simulator or socket result must not be recorded as device-verified.
- On 2026-09-21 the user moved to a **new iPhone 18 Pro** (`00008160-00124C8200214036`); the
  iPhone 16 Pro of the earlier runs now reports `unavailable`. `bb965dda` is signed and installed on
  the new device, so the next device pass starts from an installed build rather than from nothing.
- Today's live evidence that the Bili path itself is healthy, so a future device failure is not
  misread as a spider fault: `CSP_GOLDEN_SITE='{"key":"bili",…,"api":"csp_Bili"}' swift test
  --filter biliOffersMultipleQualityLines` **passed on 2026-09-21**, resolving 480P and 360P lines
  and probing the best one to `.media` with headers, on an `akamaized.net` mirror.

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
- There is still **no Python runtime** — that is the next milestone, not a property of the design.
  **A drpy loader does exist**, since IOS-POC-6A/6B: `DrpyEngine` fetches the engine and its nine
  libraries from the configuration's own origin, hash-pins and verifies them before evaluation, and
  runs them on the existing `JavaScriptSpiderRuntime`; **four drpy sources were driven end to end to
  real media bytes.** `ConfigSource` still resolves `./py/` references and nothing loads or executes
  them — locating a resource is not running it. An earlier revision of this line said no drpy loader
  existed and was left stale by the IOS-POC-6A/6B commits.

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
| 7A/7C | Assessment and P1 measurement for a Python runtime: what it would cost, measured rather than estimated | `docs/IOS-POC-7A-python-runtime.md` |
| 7B | Xcode's per-user state is ignored, after it blocked three commits in one session | `.gitignore` |
| 8A | **The first real-device run**, and the defect it found: a fresh install could not accept a remote configuration URL | this document |
| 8B | Two more device findings: a black band under the tab bar, and the player's close button in AVKit's corner | this document |
| 8C | An app icon, and the asset catalog the project never had | this document |
| 8D | Reverted 8B's wallpaper change, which had relayouted every screen; the black band it chased is left alone | this document |
| 8E | The three device-reported UI defects re-tested on the clean build: two were the 8B regression and are gone, the third was real and is fixed — the search field no longer vanishes after a source switch | this document |
| 8F | The search field goes back to hiding on scroll, at the user's request: the `.id` moves up to the whole `NavigationStack`, after three other ways of making the bar give the field back were measured and failed | this document |
| 8G | The black band behind the tab bar is gone on every tab — `scaledToFill` never filled, so `.ignoresSafeArea()` had nothing to expand | this document |
| 8H | 8F and 8G confirmed on the iPhone 16 Pro by the user; the second device run this project has had | this document |
| 8I | No synthetic 全部 anywhere — the category row and the filter rows show only what the source sends; the episode picker splits a long line into 100-episode blocks | this document |
| 8J | The episode blocks split on the printed episode number, not on position, so `1-100` ends at 第100集 on a line whose entries merge episodes | this document |
| 8K | Pull to refresh on the listing, and the source picker opens on the source in use instead of at the top of 67 | this document |
| 6C | The sniffer unwraps a wrapper page that carries the stream in its own query string; one shared candidate test for both sniff paths | `docs/IOS-POC-6A-drpy-loader.md` |
| 7E | The CPython payload arrives by `scripts/fetch_python_ios.sh` + `third_party/python-ios-lock.json`, not by commit | `docs/IOS-POC-7A-python-runtime.md` |
| 7F | **CPython 3.13.15 starts inside the app** on the simulator; Python links into the app target only, so `WebHTVCore` still builds and tests on macOS | same document |
| 7G | `base/spider.py` shim + `PythonSpiderRuntime`; a hard-coded spider drives all 13 ABI methods and errors propagate | same document |
| 7H | **P3 routing**: `Site.isPythonSpider`, `PythonSpiderSupport` seam, and drpy's own same-origin/HTTPS/size/fail-closed implementations reused. Sources listed went 67 → 109 | same document |
| 7I | The shell-app/XPTV shape recorded as the product; the five ways a spider's code reaches the app | `docs/IOS_SPIDER_RUNTIME_SPEC.md` |
| 7J | `PythonLiveCheck` drives a real Python source through the app's own path; found the `requests` gap and a URL-encoding defect | `docs/IOS-POC-7A-python-runtime.md` |
| 7K | **P4 done**: `皮皮虾.py` runs `init → home → category → detail → search → player` and `MediaProbe` returns `.media`. The shim now percent-encodes before urllib sees a URL | same document |
| 7L/7M | **P5 done**: `scripts/audit_python_spiders.py` (static, 42 sites) and the runtime survey, reconciled | same document |
| 7N | A Python traceback goes to the log; one readable line goes to the screen | same document |
| 7P | `requests` + `urllib3` + `certifi` + `idna` + `charset-normalizer` vendored as pinned pure-Python wheels; sites reaching media bytes went 1 → 6, executing 4 → 14 | same document |
| 10A–10E | **All five user-reported items done.** Close button follows AVKit's control-visibility delegate (the first attempt guessed with a timer and came out inverted); filter rows get Chinese labels from a closed table; the last source is remembered — `UserDefaults` had been truncating `Site.id` at its NUL; configuration sources are saved by name, switchable, each with its own cache; watch history binds to the configuration it was watched on | `docs/IOS-POC-10-plan-ux-and-sources.md` |
| 10 | Plan for five user-reported UI/data items, two of them decided by the user on the spot. **MPV paused**: on device, Metal + software decode reaches `FILE_LOADED` and still never fires `VIDEO_RECONFIG`, which rules out both the simulator and the network | `docs/IOS-POC-10-plan-ux-and-sources.md` |
| 9F | Installed on the iPhone 18 Pro. **libmpv initialises on real hardware, and so does CPython — `皮皮虾.py` runs the whole chain to real media bytes on device**, which closes the Python line's largest unverified gap. MPV rendering still needs the user to tap through the probe | `docs/IOS-POC-9B-mpv-playback-core.md` |
| 9E | Re-test. It overturned 9D's reading that Metal reliably reaches `FILE_LOADED` — it does not, run to run — and measured two MPVKit capability facts: its FFmpeg has no `lavfi` input and no PNG decoder | `docs/IOS-POC-9B-mpv-playback-core.md` |
| 9D | The OpenGL fallback, tried beside Metal rather than instead of it. It builds its render context and mpv reports the simulator as a software renderer, but it never reaches `FILE_LOADED`. **Both paths black; the simulator line is exhausted** | `docs/IOS-POC-9B-mpv-playback-core.md` |
| 9C | MPV rendering probe: libmpv draws through `CAMetalLayer`/`gpu-next`/MoltenVK. Vulkan device, HLS load and software decode all succeed on the simulator; **no frame ever reached the layer**, so the question moves to the device | `docs/IOS-POC-9B-mpv-playback-core.md` |
| 9B | MPV first unit: MPVKit 1.0.0 (non-GPL) wired into the App target and libmpv initialising inside the app. Static linking confirmed by symbol table, not just by configure flags | `docs/IOS-POC-9B-mpv-playback-core.md` |
| 9A | MPV second playback core: licence and provenance review. No blocker, conditional on MPVKit ≥1.0.0 non-GPL — every release before it carried `--enable-nonfree` | `docs/IOS-POC-9A-mpv-license-provenance.md` |
| 7R | Reconciliation: the handoff anchor and the spider spec rewritten against the actual HEAD and a fresh test/build run; no functional change | this document |
| 6A/6B | **drpy JavaScript loader**: the engine and its nine libraries fetched from the configuration's own origin, hash-pinned and verified before evaluation, running on the existing `JavaScriptSpiderRuntime` | `docs/IOS-POC-6A-drpy-loader.md` |

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

#### Source coverage, counted at HEAD `261b5c03` (before the drpy sites)

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
| type-3 drpy JavaScript | 5 | **listed and driven since IOS-POC-6B — but only under a remote configuration**, because the engine must come from the configuration's own origin |
| **total** | **167** | **62 listed from an imported file, 67 from a remote URL** |

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

**Latest, re-measured 2026-09-21 at `7653a9fb` (IOS-POC-7R), which is the actual HEAD:**

- `swift test --package-path ios` → **168 tests, all pass**. The trajectory since: 151 at
  IOS-POC-7H, +4 `SiteSelectionTests` (10C), +4 `FilterNameTests` (10B), +7 `SavedSourceTests`
  (10D), +2 `WatchHistorySourceBindingTests` (10E).
- `xcodebuild … -destination 'platform=iOS Simulator,id=7B4E9557-4774-4EB9-B408-BB544DCC8657'`
  → **BUILD SUCCEEDED**. Device build for `platform=iOS,id=00008160-00124C8200214036` succeeded and
  installed at `bb965dda` earlier on 2026-09-21; **nothing since then has been built for a device.**
- `third_party/python-ios/` is present (78 MB) with the five vendored wheels in `site-packages`, so
  the Python path is buildable on this machine without a re-fetch.
- **The iPhone 18 Pro `00008160-00124C8200214036` reports `available (paired)` to `devicectl`**, so
  the deferred device pass is blocked only by the user's decision, not by the hardware. The
  iPhone 16 Pro still reports `unavailable`.
- Simulator, from the app's own launch path:
  `[python] boot running(version: "3.13.15")`,
  `[python] selfcheck 13/13 methods OK, errors propagate`,
  `[python] live OK [🏆｜銅牌｜高清] init → home(5) → category(21) → detail → search(1) → player → probe(media)`,
  `[python] survey driven 1/42`.
- `scripts/audit_python_spiders.py --config <the user's GitLab URL>` → 42 sites classified.
- **Not run:** any device verification of the Python runtime. Everything Python is simulator-only.


Everything in this section is from **HEAD `261b5c03`** unless it names another stage or date; the
test and build lines below were re-measured at **`bb965dda` on 2026-09-21**. The three
conflicting test counts that used to sit here (77/76, 96/95, 110/109, each from a different HEAD)
have been collapsed into the first bullet.

- **143 tests** — `WANG_MOVIE_JSON=<config> swift test --package-path ios`, measured 2026-09-18 and
  **re-run three times on 2026-09-21 at `f34ae805`, `67e72604` and `bb965dda`: 143 passed each time.**
  **Either 142 or 143 pass**, and which one is not a property of this code: the only test that ever
  fails is the live-network `reportsLiveType4SitesFromProvidedConfig` in the next bullet, which went
  fail, fail, pass, fail, pass across five runs on the same day. The trajectory: 96 at `d571f3a7`,
  110 after IOS-POC-5Q, 124 after IOS-POC-5R, 140 after the drpy loader, 143 after the sniffer's
  wrapper handling.
- **`reportsLiveType4SitesFromProvidedConfig` passed this run, and that is not a change in the
  code.** It is a live-network check: 88看球 resolves an episode to an HTML page, and the test
  asserts direct media through `CMSClient`, which has no sniffer hop. It failed twice earlier on
  2026-09-18 and passed on the third run, which is exactly what a provider-state check looks like.
  **Do not "fix" it when it fails.** The sweep classifies that site as playable *through
  `SourceClient`*, the path the app actually uses; the two disagree because they drive different
  layers.
- **The suite is stable across runs since IOS-POC-5H.** Four bridge tests used to fail
  intermittently; they recorded callbacks through a detached `Task` and read the result immediately.
- `xcodebuild -project ios/WebHTVApp/WebHTVApp.xcodeproj -scheme WebHTVApp -destination 'platform=iOS Simulator,id=7B4E9557-4774-4EB9-B408-BB544DCC8657' -configuration Debug build` → **BUILD SUCCEEDED**.
  **The destination must now be an id, not a name.** An iOS 27.0 runtime appeared on this machine on
  2026-09-18, so `name=iPhone 17 Pro` matches two devices (26.0 and 26.3) and xcodebuild refuses to
  choose. That UDID is the iOS 26.3 device every simulator result in this document came from.
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

- **IOS-POC-8K, 2026-09-21.** Two requests.
  - **The source picker opens on the source in use.** It was a `Menu`, which is a `UIMenu` and
    cannot be scrolled to an item, so with 67 sources it always opened at the first one. It is now
    a sheet holding a `List` inside a `ScrollViewReader`, and `onAppear` scrolls the selected id to
    centre. **Confirmed:** with 王子 selected — 40-odd rows down — the sheet opens with 王子 and its
    checkmark in the middle of the screen, not at 無水.
  - **Pull to refresh on the listing.** `.refreshable` on `CMSView`'s `ScrollView`, calling the same
    `load` the category chips use: the search results while searching, otherwise the listed
    category, otherwise the home listing. `load` already resets `page` and `canLoadMore`, so a
    refresh also drops paging back to page one.
  - **Partly verified.** The modifier is on the `ScrollView` and the gesture leaves the screen
    correct, but the spinner is transient and no screenshot caught it, so the refresh was not
    watched happening. One pull on the device settles it.

- **IOS-POC-8J, 2026-09-21.** 8I's blocks were cut by **position**, and the user caught it on the
  device: the block labelled `1-100` ran to 第109集. The cause is that a source may merge episodes
  into one entry — 稀有祖宗 carries `第1-8集`, `第9-10集`, `第95-96集`, `第115-117集` — so the 100th
  *entry* is not 第100集. The split now reads the number the source printed (first run of digits,
  which also survives the malformed `-第98集`) and breaks on it; the chip is labelled from the
  numbers actually inside the block, so it cannot disagree with the grid beneath it. A line that
  prints no numbers at all still falls back to fixed blocks of 100 entries.
  **Confirmed on 稀有祖宗 (王子, `csp_AppGet`, 119 episodes over two lines):** the chips read
  `1-100` / `101-119` (was `1-100` / `101-108`), the first block ends at 第100集 (was 第109集) and
  the second begins at 第101集 (was 第110集).

- **IOS-POC-8I, 2026-09-21.** Two user requests, both confirmed on the simulator against live sources.
  - **No synthetic 全部.** The app used to prepend its own 全部 in three places: the category row
    (`parentChips`) and the filter rows built by `AppGet.js` and `AppQi.js`. All three are gone, so
    the row is the source's own list. Confirmed on 紅果短劇 (`csp_JPianAmns`), whose `CLASSES` holds
    exactly 电影/电视剧/动漫/综艺/短剧 — the row now shows those six categories and no 全部, where the
    user's own device screenshot of 荐片 had shown an extra one. A source that **does** send its own
    "all" entry keeps it: 王子 (`csp_AppGet`) still leads with 全部 (`type_id: 0`), and its 排序 row —
    the one row whose API sends no 全部 — now correctly starts at 最新.
  - **100-episode blocks.** 稀有祖宗 on 王子 has 108 episodes per line. The picker shows `1-100` and
    `101-108` above the grid; selecting the second lists 第110集–第119集 only. The blocks are per
    line, verified by `JS线路` sitting on `101-108` while `SB线路` stayed on `1-100`. A line with
    ≤100 episodes gets no chip row at all, and the default block is the one holding the remembered
    episode.
  - Not covered: `AppQi.js` carries the identical edit but no live AppQi source was exercised; three
    type-1 CMS sources (愛瓜, 菠菜, 360) were unreachable this session — one timeout, two invalid
    certificates — which is a source-side fault, not a regression.
  - Known consequence, accepted by the user: the removed chip was also the only way back to the
    unfiltered `home()` listing. Sources whose home returns a distinct recommendation list can no
    longer return to it after a category is picked. 荐片 is unaffected because an empty home already
    fell back to the first category, which is what its 全部 chip had been re-listing.

- **Confirmed on the real device, 2026-09-18 (IOS-POC-8H).** The iPhone 16 Pro run of `feeb1407`
  was signed and installed with the command line settings as before, and **the user confirmed both
  fixes on hardware: no black band, and the search field behaving.** That is the **second** device
  run this project has had, and the first that verified a change rather than finding defects. It
  covers IOS-POC-8F and 8G only — everything else in this document is still simulator-only, and the
  three items below remain unchecked on hardware.
- **IOS-POC-8G, 2026-09-18.** All three tabs (首頁／記錄／設定) screenshotted with no black band; the
  wallpaper runs under the floating glass tab bar. 荐片 re-checked for the IOS-POC-8B relayout tells
  and shows none, and a detail screen renders normally.
- **IOS-POC-8F, 2026-09-18.** 愛瓜 loaded and scrolled down until the search field hid → source menu
  → 菠菜 lists from the top **with the search field back**, and it still hides on the next scroll.
  The three failed attempts above were each driven through this same sequence and each left the
  field gone, which is what makes them worth recording rather than re-trying.
- **IOS-POC-8E, 2026-09-18, on the remote configuration (67 sources).** Before the fix: 愛瓜 scrolled
  down → source menu → 菠菜 listed from the top **with no search field**, and it came back only on an
  over-scroll. After the fix the same sequence keeps the field, and so does 荐片 → 愛瓜. 荐片 renders
  its category row and all four filter rows clear of the field at rest, while scrolled, and with the
  field focused; the grid keeps its 12 pt margin. Search itself still submits: on 360 高清,
  `the` returned `X The League`, `Happy Together`, `The One Shot`, `The Scout`. **A source answering
  「暂不支持搜索」 looks identical to a search that did not fire** — 菠菜 does exactly that
  (`curl` confirms the provider, not the app), and because the error surface only renders on an empty
  grid the old list simply stays. That is the known error-surface limitation, not a defect found here.
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

**Python, added 2026-09-21:**

- ~~**Nothing Python has run on a device.**~~ **Superseded 2026-09-21 (IOS-POC-9F):** on the
  iPhone 18 Pro the interpreter boots, the 13-method self-check passes, and `皮皮虾.py` runs
  `init → home → category → detail → search → player → probe(media)` end to end on device. The
  42-site survey ran on hardware too: **driven 5/42**, against 6/42 on the simulator, and the
  dependency and policy tallies are **identical** — `Crypto` 17, `lxml` 3, `pyquery` 2, `bs4` 2,
  policy-refused 4. The one-site difference sits in the content layer, which is provider state.
- **The payload is not in the repository.** `third_party/python-ios/` is ignored; a fresh clone must
  run `scripts/fetch_python_ios.sh` (the Xcode "Prepare Python" phase calls it, so a build does this
  by itself — but an offline machine cannot build until it has run once).
- **`Prepare Python` rewrites a file under `third_party/python-ios/` on every build** (the module map
  clang needs). Idempotent and untracked, but its proper home is the fetch script.
- **What the Python line buys is measured, and still modest**: after IOS-POC-7P vendored `requests`,
  **14 of 42 sites execute and 6 reach media bytes** (it was 4 and 1 before). Do not quote a larger
  number from the P1 assessment, which estimated before any of it ran.
- **Still blocked on a dependency: 24 sites** — `Crypto` 17, `lxml` 3, `pyquery` 2, `bs4` 2. `bs4` is
  pure Python and would go the same way `requests` did; `Crypto` is the big one and `CatVodHost`
  already has AES, DES, MD5, SHA and HMAC to shim over. **Neither was started.**
- **`麒麟影视.py` counts as executing only until something calls the method its `import requests`
  hides in.** It is not a Tier-1 site in any durable sense.
- **The survey hammers the configuration origin** — one script fetch per site. Running it twice after
  the audit made GitLab stop answering entirely, which read as "driven 0/42" and was false. It now
  paces at 400 ms; do not remove that.


- **It has now run on a real device — once, on 2026-09-18 (IOS-POC-8A).** An iPhone 16 Pro, signed
  with the personal Apple ID `st7833232@gmail.com`, team `764SVXY2B7`. **The project file still has
  no `CODE_SIGN` or `DEVELOPMENT_TEAM`**: the settings were passed to `xcodebuild` on the command
  line so nothing personal was committed —
  `DEVELOPMENT_TEAM=764SVXY2B7 CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates` with
  `-destination 'platform=iOS,id=<device udid>'`, then `xcrun devicectl device install app`.
  **The provisioning profile is a free-tier one and expires seven days after issue**, so the app
  stops launching and must be reinstalled; a paid account or SideStore is the way out of that.
  **Everything else in this document is still simulator-only** — one device run is not a device
  verification pass.
- **Confirmed on that device run:** Chinese and the site names' emoji render correctly, which
  settles that the simulator's `.notdef` boxes are the runtime's missing font set and not this app
  (IOS-POC-5V's Debug-only workaround is therefore correctly scoped). A remote configuration loaded
  and the app listed **67 sources**, which is only reachable through the remote path and so also
  confirms the five drpy sites route correctly on device.
- **Found by the device run and fixed the same day — three defects, each hidden for a different
  reason.**
  1. **A fresh install could only ever import a file.** The remote-URL entry lives in the settings
     page, the settings page lives in the tab bar, and the tab bar only exists once a configuration
     has loaded, so the one screen a new install shows was missing half its purpose. **The simulator
     could not have caught it**: it always had a configuration cached by an earlier session, so the
     empty state was never exercised. It now offers both ways in, calling the `useRemote`
     `ConfigView` already had.
  2. **A black band sat under the tab bar on every screen.** `appWallpaper()` was a `.background`,
     and a background is bounded by the view it decorates: on a `TabView` it stops at the content
     area, so hiding the tab bar's own background revealed the window rather than the wallpaper. It
     is a `ZStack` now, the image behind as a sibling that nothing clips. **This one did reproduce
     in the simulator** and is visible in every screenshot this project has taken — it took a real
     phone for anyone to name it.
  3. **The wallpaper fix in 2 was wrong and is reverted (IOS-POC-8D).** Making `appWallpaper()` a
     `ZStack` put every screen inside a container whose other child ignores the safe area, so
     content laid out against the window instead: row labels clipped at the left edge, posters
     bleeding to the screen edge, and the grid running under the navigation bar so the search field
     covered the category and filter rows. **Two ways of covering the tab bar were tried and both
     relayouted content**, so the black band — which predates today and is cosmetic — is left alone,
     with the attempts recorded in the code so nobody repeats them.
  4. **The player's close button sat in AVKit's corner.** iOS puts its video-output control top-left
     and mute top-right; the custom close button crowded the first. Moved below that row rather than
     to another corner, because AVKit owns both top corners and the bottom. **Only the simulator's
     different AVKit layout hid this.**
- **The three UI defects the user reported from the device were re-tested on a clean build
  (IOS-POC-8E, 2026-09-18), and only one of them was real.** The build they saw carried the 8B
  wallpaper regression, so the first job was to see which complaints survived its revert. Driven in
  the simulator against the remote configuration, on 荐片 because it publishes a category row plus
  four filter rows:
  1. ~~**「海報沒有留外圍的邊」**~~ **did not reproduce.** The grid keeps its 12 pt padding on all
     four sides and the cells sit level with the category chips. This was 8B's
     「posters bleeding past the screen edge」.
  2. ~~**「搜尋框會擋住分類跟篩選列」**~~ **did not reproduce** at rest, while scrolled, or with the
     field focused: the category row and all four filter rows stayed clear. This was 8B's
     「the grid running under the navigation bar」.
  3. **「切換內容來源之後搜尋框會不見」 did reproduce, and is fixed.** It needs one precondition the
     report did not mention, which is why it looked intermittent: **the previous source must be
     scrolled down when the menu is opened.** The search field hides on scroll, that hidden state
     belongs to the navigation bar rather than to the grid, and `HomeView` rebuilds `CMSView` under
     a new `.id` on every switch — so the new grid starts at the top while the bar keeps the
     collapse it learned from the destroyed one. The field stayed gone until the user over-scrolled.
     Fixed by `placement: .navigationBarDrawer(displayMode: .always)`, UIKit's
     `hidesSearchBarWhenScrolling = false`: a field that never collapses has no state to carry
     across the swap. **The cost is that the field now occupies its row permanently**, and content
     scrolls underneath it.
- **8E's always-visible search field was replaced at the user's request (IOS-POC-8F, 2026-09-18).**
  They asked for the field to hide on scroll again, which meant fixing the navigation bar's stale
  collapse rather than removing the collapse. **Three pure-SwiftUI attempts were built and measured,
  and none of them worked:**
  1. **Hoisting `.searchable` above the grid's `.id`**, into a shell view that a source switch never
     replaces, so the search controller itself survives. No effect — the replacement `ScrollView` is
     born at offset 0 and never raises a scroll event, so the bar has nothing to re-evaluate on.
  2. **Resetting the listing in place**, dropping the `.id` entirely so the scroll view is never
     replaced at all, plus `proxy.scrollTo(topAnchor)`. No effect: scrolling a view already at the
     top is not a scroll.
  3. **Scrolling the old listing to the top first**, while it was still tall enough for that to be a
     real offset change, and swapping the content on the next turn. No effect either.
  **What worked is moving the `.id` up to the whole `NavigationStack`.** A new stack is a new
  navigation bar, and a new bar has no collapse to remember. The functional diff is one modifier
  moved one level up and `placement:` deleted; the three failures are recorded in the code so nobody
  repeats them. **The bleed-through note below is now historical** — with the field hiding on scroll
  again it is only ever over the wallpaper, not over the grid.

  **Dropping `appNavigationBar()` on `CMSView` to put a material behind that pinned field was tried
  and reverted — it changed nothing on screen.** iOS 26 draws this navigation bar as per-control
  glass, not as a full-width background, so there is no material to opt into; scrolling content
  shows through the search field either way, exactly as it already showed through the status bar and
  the source chip before this change. **That bleed-through is pre-existing chrome behaviour, not
  new**, and the attempt is recorded in the code the way 8D's were. Restructuring so the field hides
  on scroll again — hoisting `query` and `.searchable` out of the `.id()` into `HomeView` — was
  weighed and rejected: about twenty lines across two views plus a second search path for the
  WebHome bridge sheet, to buy back a transient cosmetic overlap.
  **Ponytail, before:** the ladder stops at the native-platform rung — `SearchFieldPlacement` already
  expresses this, so no state, no restructuring and no new view. **Ponytail, after:** the functional
  diff is one line in one file; nothing was abstracted, and the one addition that earned nothing was
  taken back out. Two of the three reported defects were closed by reproducing them rather than by
  writing code.
- **The black band behind the tab bar is fixed (IOS-POC-8G, 2026-09-18), and the diagnosis it had
  carried since IOS-POC-8B was wrong.** That record said the bar sits outside the content view's
  frame and that nothing reachable from a background modifier draws there, so the band was written
  off as permanent and cosmetic. Both halves were false. **`appWallpaper()`'s image was
  `scaledToFill`, which sizes the image to its own aspect-filled bounds rather than filling its
  container — so `.ignoresSafeArea()` had nothing to expand and the wallpaper stopped at the safe
  area.** Wrapping it in a `Color.clear` that does fill, and moving `.ignoresSafeArea()` onto that,
  runs the wallpaper to the bottom of the window on all three tabs. It is still a `.background`, so
  the IOS-POC-8B relayout trap is untouched: 荐片 was re-checked and its filter labels are unclipped,
  the poster grid keeps its 12 pt margin, and the detail screen is unchanged.
  **Four heavier things were built and measured first, and all four failed.** Colouring
  `UIWindow.appearance()` and `UITabBar.appearance()` — neither ever appeared, which is what ruled
  out the window and the tab bar as the painter. Then a probe walking up to the tab bar controller
  and inserting a wallpaper image view at the bottom of its container — installed correctly,
  confirmed in a logged view hierarchy, and invisible because every hosting view above it paints an
  opaque `systemBackground`. Then clearing those backgrounds — SwiftUI re-applies them on its next
  layout pass. **The lesson is recorded in the code: do not reach into UIKit for this.** The view
  hierarchy dump that settled it is worth re-deriving rather than guessing if this ever regresses.
- **The app has an icon and an asset catalog since IOS-POC-8C.** The project had neither: its images
  were loose files read through `Bundle.main.path(forResource:)`, which cannot supply an app icon —
  iOS needs a compiled `Assets.car` and `CFBundleIconName`. A single 1024×1024 entry is enough on
  iOS 17+. The source art was a rounded square on white, so it is cropped past its own corner radius
  (~22%) until the gradient reaches all four edges; leaving it would have shown white slivers
  wherever iOS's mask radius disagreed with the artwork's.
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
- **The drpy loader works, and all four sources are verified end to end.** Each runs
  `home → category → detail → search → player` against its live provider with all ten dependencies
  hash-verified, and each ends in real media bytes. Two answer `parse:0` directly; two answer
  `parse:1` and are sniffed. The encoded rule scripts — one base64, one not — are decoded by drpy2
  itself, so nothing was reverse-engineered. `bubutv`'s `./json/4k.js` is a 404 in the repository
  and is still listed, because listing goes by shape; it fails with a named error when opened.
- **A wrapper page is unwrapped since IOS-POC-6C.** A sniffed candidate like
  `…/vip/?url=…/index.m3u8` matched the keyword test only because of the address inside it, and the
  player was handed a page. `MediaSniffer.isCandidate` is now the single test both sniff paths use,
  and an accepted candidate is unwrapped one level. A page whose own query names the stream skips
  the web view entirely.
- **The Python runtime is assessed but not built (IOS-POC-7A).** Measured 2026-09-18 across the 31
  same-origin scripts: **zero Android dependencies** — the five files mentioning "android" all do so
  in a User-Agent or a query parameter. 30 need the host's `base` module, whose Android original is
  in this repository at `chaquo/src/main/python/base/spider.py`; `requests` (23 files) is pure
  Python; and **4 scripts need nothing but `base` and the standard library**, which is what makes a
  minimum POC possible with no C extension at all. 15 of 31 need one (`Crypto` 10, `pyquery` 4,
  `lxml` 3) and are deliberately out of that POC. Three of the 42 sites point at cross-origin,
  mostly plain-HTTP script URLs and would be refused under the rule IOS-POC-6B set.
  **Embedding CPython is a binary and packaging decision and is not taken yet.**
- **Still not implemented:** a Python runtime (42 sites), the 23 portable-but-unported `csp_*` sites, `CatVodHost` RSA and `proxy`
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

**Do not start anything below without the user saying so.** The order was set by the user and the
first two items are finished.

1. ~~**POC-3 — the drpy JavaScript loader.**~~ **Done (IOS-POC-6A/6B/6C).**
2. ~~**POC-4 — the Python runtime, P2–P5.**~~ **Done (IOS-POC-7E–7P).** What it actually buys is
   modest and measured: **14 of 42 configured Python sites execute and 6 reach media bytes** (it was
   4 and 1 before IOS-POC-7P vendored `requests`; this paragraph quoted those pre-vendoring numbers
   until 2026-09-21). **24 are still blocked on a dependency** — `Crypto` 17, `lxml` 3, `pyquery` 2,
   `bs4` 2 — and 4 are refused by the same-origin/HTTPS policy. `bs4` is pure Python and would go
   the way `requests` did; a `Crypto.Cipher` shim over the AES, DES, MD5, SHA and HMAC `CatVodHost`
   already has would address the largest block, 17 sites.
   **Neither was done, and neither should start without the user asking.**
3. **MPV feasibility.** ~~The licence/provenance review comes first.~~ **Done — IOS-POC-9A,
   2026-09-21: there is no licensing blocker**, conditional on pinning **MPVKit 1.0.0 or newer,
   non-GPL variant** (every earlier release built its "LGPL" FFmpeg with `--enable-nonfree`, which
   is not redistributable at all). mpv's own LGPL mode costs iOS nothing, because everything it
   disables is a Linux/Windows desktop feature. Static linking is an obligation, not a blocker,
   because this repository already publishes its whole source under GPLv3. Full record and the five
   open gates: `docs/IOS-POC-9A-mpv-license-provenance.md`.
   **What remains is IOS-POC-9B, the technical spike, and it is waiting on the user's instruction.**
   A second built-in playback core, `PlaybackTarget → PlayerRouter → AVPlayerEngine / MPVEngine`,
   sharing the existing `PlaybackSession`, headers, history, resume and quality. Do not rebuild
   `SourceClient`. Do not take a framework out of Infuse, Fileball, SenPlayer or VidHub; only an SDK
   whose licence permits embedding. `.codex/skills/upstream-integration-governor/SKILL.md` governs it.
4. **The real-device acceptance**, deferred by the user on 2026-09-21 with the partial baseline kept.
5. **IOS-POC-5S**, and only then more `csp_*` ports.

**Not to be started early:** 5S ads/intro-outro, XueLuo, QimaoDJ, further `csp_*`, CarPlay,
Official/XPTV as a separate fork.

## Resume Prompt

Paste this into a new session:

> 接手 `/Users/chengchenchih/GIT/webhtv` 的 `ios-poc`，透過本機終端操作，不要每步停下來問我確認。用台灣繁體中文回報。
>
> **先確認實際狀態，不要相信這段文字裡的任何 SHA**：最後一次驗證是 2026-09-21 的 IOS-POC-7R（文件對帳），在它之前 HEAD 是 `7653a9fb`（IOS-POC-7Q），**7Q 以前的 commit 已依我的指示 push 到 `origin/ios-poc`**，worktree clean。**IOS-POC-7R 本身尚未 push。** 用 `git log` 與 `git rev-list --left-right --count origin/ios-poc...ios-poc` 覆蓋這一行。**未經我明確授權不得 push、tag、package、publish。**
>
> 動手前必讀：`AGENTS.md`、`README.md`、`docs/AGENT_HANDOFF.md`、`docs/current-task-state.md`、`docs/IOS_SPIDER_RUNTIME_SPEC.md`（runtime/ABI 唯一真相，含 spider 程式碼投遞的五種方式）、`docs/IOS-POC-7A-python-runtime.md`（Python 全部階段）、`docs/analysis/ios-app-store-readiness-research.md`（發行）。
>
> **產品定位（2026-09-21 確認）**：一個**不內建任何來源的空殼 App**，使用者自帶設定檔，走 XPTV 路線。App 已經滿足前半——沒有任何內建設定檔。上架版與個人側載版的差別是 **build profile，不是分叉**。
>
> **現在能做什麼**：iPhone 版 WebHomeTV。遠端設定列出 **109 個來源**（62 native+csp、5 drpy、42 Python）。兩層分類、篩選列、分頁、搜尋、詳情、五種播放器、下拉重整、來源選單定位、播放記錄／續播、WebHome bridge、request headers、畫質選單、每 100 集一個選集區段。
>
> **Python 剛完成（IOS-POC-7E–7P），而且要知道它到底買到什麼**：CPython 3.13.15 在 App 內啟動，`PythonSpiderRuntime` 走既有 `SpiderRuntime` 契約，routing 沿用 `CSPSourceResolver`，`requests` 等五個純 Python 套件已 vendored。**實測 42 站裡 14 站跑得動、6 站拿得到媒體位元組**（vendoring 前是 4 與 1）。剩下 24 站被相依性擋住：`Crypto` 17、`lxml` 3、`pyquery` 2、`bs4` 2；4 站被同源/HTTPS 政策拒絕。**不要引用 P1 評估裡比較大的數字。** `bs4` 純 Python、走 `requests` 同一條路即可；`Crypto` 是最大宗且 `CatVodHost` 已有 AES/DES/MD5/SHA/HMAC 可蓋層——**兩者都沒做，也不要自行開始**。
>
> **下一階段是 MPV feasibility——它現在是隊列第一順位，但必須等我的指令才能開始。** 方向：`PlaybackTarget → PlayerRouter → AVPlayerEngine / MPVEngine`，共用既有 `PlaybackSession`、headers、history、resume、quality；不重造 `SourceClient`；**不得**從 Infuse/Fileball/SenPlayer/VidHub 拆 framework，只能整合授權允許嵌入的 SDK；整合前先做 license/provenance review，並遵守 `.codex/skills/upstream-integration-governor/SKILL.md`。外部播放器全部保留。
>
> **不要提前做**：5S 廣告/片頭片尾、XueLuo、QimaoDJ、更多 `csp_*`、CarPlay、把 Official/XPTV 另外分叉。完整真機 acceptance 已由我延後。
>
> **流程**：功能性修改前跑 Ponytail pre-review，使用 `bash .codex/scripts/task_guard.sh start`，完成 targeted verification 後跑 Ponytail final-diff review，結果寫進 durable 文件，收尾用 `finish ... --no-tag`。Android `main/` 與 `app/`、`chaquo/` 只讀。
>
> **驗證現況**：`swift test --package-path ios` 151 條全過；模擬器 build 成功。**Python 完全沒在真機上跑過。** 模擬器上 `[python] live OK [🏆｜銅牌｜高清] … → probe(media)`。
