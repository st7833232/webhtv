# WebHomeTV iOS Migration Plan & Discussion Handoff

> Date: 2026-09-13
> Repository: `st7833232/webhtv`
> Active exploration branch: `ios-poc`
> Purpose: durable handoff of the iPhone/iOS planning and repository assessment performed in the 2026-09-13 ChatGPT discussion. Future ChatGPT/Work/Codex/Claude sessions should read this file together with `AGENTS.md`, `README.md`, and `docs/AGENT_HANDOFF.md` before continuing iOS work.

## 1. Current status and scope

No functional iOS implementation has been completed yet. The work performed so far is architecture assessment, compatibility analysis, distribution/signing planning, and repository inspection.

(Corrected 2026-09-25: this was true on 2026-09-13 only. The iOS app has since been built on `ios-poc` and ships through SideStore; the latest release is `0.1.20 (21)`. Current state and next step: `docs/current-task-state.md` "Current handoff".)

The Android `main` line must remain isolated from iOS experiments. Continue iOS work on `ios-poc` or on a task branch derived from `ios-poc` unless the user explicitly changes that policy.

At the time this document was prepared, `ios-poc` was based on the Android source baseline `fc62397591701b2232ae7de4f50a032bd7742064`; the branch later received the documentation commit `816304563b0f9686bf241f7e3d84a2aa4c6f40ad` containing `docs/AGENT_HANDOFF.md`.

## 2. User requirements established during the discussion

The iPhone version is being evaluated under these constraints:

- No jailbreak.
- Prefer zero recurring cost during development/personal use.
- Avoid an always-on self-hosted server where practical.
- Preserve as much WebHomeTV / TVBox / CatVod / WebHome compatibility as technically reasonable.
- Do not perform a blind Java-to-Swift translation.
- The user wants a path that can be installed on a normal iPhone.
- For the free personal-use path, SideStore-style sideloading with on-device refresh is acceptable as the working distribution direction.
- App Store publication may be considered later, but it must be treated as a separate compliance profile rather than assuming the unrestricted personal build can be submitted unchanged.
- The user also asked about TestFlight and App Store costs; current Apple membership requirements are recorded below.

## 3. Mandatory Ponytail gate

`docs/AGENT_HANDOFF.md` establishes a mandatory Ponytail review gate for this project.

For functional implementation, architecture/dependency changes, Spider/runtime changes, player changes, packaging/signing changes, IPA generation, or release work:

1. Read `AGENTS.md`, `README.md`, `docs/AGENT_HANDOFF.md`, and this document.
2. Run Ponytail before implementation and resolve/document material findings.
3. Perform the repository-required task guard and targeted verification.
4. Run Ponytail again on the final diff before completion/commit/release.
5. Record both reviews in durable task evidence.

If Ponytail is unavailable, read-only analysis and documentation may continue, but functional implementation must stop before the first functional edit. Do not claim a Ponytail review occurred when it did not.

(Corrected 2026-09-25: this gate no longer applies. Since 2026-09-24, `ca413482`, Ponytail is an optional review aid and its absence never blocks functional edits, verification, commits, builds or an authorized release; never claim it ran when it did not. See `AGENTS.md` §4 "Optional Ponytail review". The task guard and verification rules are unchanged.)

## 4. Primary product direction

### Recommended primary architecture: Native iOS Hybrid

The current recommendation is:

- Swift / SwiftUI for the native application shell and UI.
- `WKWebView` for WebHome pages and compatibility with the existing WebHome JavaScript-facing experience.
- `WKScriptMessageHandler`-style native bridge to reproduce the existing WebHome bridge contract.
- `URLSession` for HTTP/CMS sources.
- `AVPlayer` as the first playback engine.
- `SwiftData` for initial local persistence.
- JavaScriptCore or another iOS-compatible JS runtime for a later JS Spider compatibility layer.
- Python compatibility is a later proof-of-concept and remains unresolved between an in-app approach such as Pyodide/WebView and an optional remote adapter. Do not commit to embedded CPython/Chaquopy parity without a separate assessment.
- Android DEX/JAR Spider execution is not a portable iOS runtime and must not be treated as a direct port target.

PWA remains a possible lightweight fallback, but it is not the preferred main product because native playback, PiP/AirPlay, storage, WebHome native bridge behavior, local integration, and runtime compatibility are materially better with a native/hybrid client.

This is a working architecture recommendation, not evidence that all compatibility questions are solved.

## 5. Existing Android architecture findings

The repository is already structured around several useful protocol boundaries. The most important finding is that iOS should preserve the behavior/contracts, not the Android implementation.

### 5.1 Core source flow

The relevant conceptual flow is:

```text
TVBox / WebHomeTV config
        ↓
VodConfig
        ↓
Site
        ↓
SiteApi
        │
        ├─ HTTP / CMS
        ├─ Python Spider
        ├─ JS Spider
        └─ CSP / DEX JAR
        ↓
Result
        ↓
Vod
        ↓
Flag / Episode
        ↓
playerContent()
        ↓
Source / extractors
        ↓
Media3 / MPV
```

`SiteApi` is the most important iOS compatibility boundary. Different Android source implementations converge into the same functional contract:

```text
homeContent
categoryContent
detailContent
searchContent
playerContent
action
```

The iOS implementation should define a Swift protocol around this behavior rather than reproduce Android loaders.

### 5.2 Models that should become Swift protocol/data models

The Android models are portable in concept even though the current classes include Android/Room/Gson details.

Important `Site` fields include:

```text
key
name
api
ext
jar
playUrl
homePage
type
searchable
changeable
quickSearch
categories
header
style
```

Important `Result` concepts include:

```text
class/types
list
filters
url
header
subs
playUrl
flag
format
position
parse
jx
drm
```

Important `Vod` fields include the normal TVBox-style fields such as:

```text
vod_id
vod_name
vod_pic
vod_remarks
vod_content
vod_play_from
vod_play_url
```

The existing playback source/episode representation also uses the familiar `$$$` source separation and `#` episode separation conventions.

Recommended first Swift model package:

```text
WebHTVCore/
├── Config.swift
├── Site.swift
├── Result.swift
├── Vod.swift
├── Flag.swift
├── Episode.swift
├── Parse.swift
├── Filter.swift
└── MediaURL.swift
```

## 6. HTTP/CMS sources: first compatibility target

HTTP/CMS is the lowest-risk source family and should be the first end-to-end proof.

The existing Android behavior is essentially:

```text
URL + headers + parameters
        ↓
HTTP request
        ↓
JSON/XML
        ↓
Result
```

Common parameters observed in the existing contract include category (`ac`, `t`, `pg`), search (`wd`, `quick`, `pg`), and detail (`ac`, `ids`).

On iOS this should be rebuilt with `URLSession`, Codable/JSON parsing, and an XML parser only where required.

## 7. JAR / DEX compatibility conclusion

Do not attempt a universal Java/JAR-to-iOS execution layer.

Repository inspection confirmed that Android source dispatch includes Python, JavaScript, and CSP/JAR paths, and the JAR path depends on Android/Dalvik behavior such as `DexClassLoader`. Real resource inspection also found Android-oriented Spider packages containing `classes.dex`, Android API dependencies, WebView references, dynamic DEX loading, and in some cases native `.so` payloads.

Therefore browser-JVM ideas such as CheerpJ must not be considered a universal solution for WebHomeTV JAR sources.

Preferred strategy:

```text
csp_* / JAR source
        ↓
Compatibility Registry
        ↓
Equivalent HTTP / JS / Python / rule implementation available?
        │
        ├─ Yes → use replacement implementation
        │
        └─ No
             ↓
        assess source individually
             ↓
        port only if valuable and feasible
             ↓
        otherwise mark unsupported
```

The objective is useful compatibility, not a false promise of 100% arbitrary Android DEX/JAR execution on iOS.

## 8. JavaScript Spider plan

JavaScript Spider is a reasonable second-stage target.

Candidate architecture:

```text
JS Spider
   ↓
JavaScriptCore / controlled JS runtime
   ↓
Compatibility API
   ↓
SpiderAdapter
   ↓
Result
```

However, not every `.js` Spider is necessarily pure JavaScript. The Android JS loader can receive DEX/JAR-related compatibility input. Therefore classify JS sources before claiming compatibility:

- Pure JS: good candidate.
- JS + emulatable compatibility APIs: medium difficulty.
- JS that depends on Android DEX/classes/native behavior: not directly portable; requires replacement or individual porting.

The iOS JS compatibility layer will likely need controlled equivalents for networking, local storage, crypto/base64, console/logging, proxy/fetch behavior, and other APIs actually used by selected proof sources.

## 9. Python Spider plan

Android uses Chaquopy for Python integration. Chaquopy is not an iOS portability strategy.

Do not make embedded CPython + `lxml` + arbitrary native wheels the first target because it creates substantial binary-size, native-dependency, signing/runtime, and App Store review complexity.

For the personal/no-server goal, a later Pyodide/WebView compatibility proof is worth evaluating for a deliberately simple Python Spider. If this is insufficient, an optional Remote Spider Adapter can be evaluated separately, but that conflicts with the user's preference to avoid always-on infrastructure and therefore must not become a hidden hard dependency.

Python is not part of POC-1.

## 10. WebHome is a high-value direct migration target

The existing `HomeWebBridge` is already organized as an RPC-like bridge:

```text
invoke(requestId, method, payload)
```

Observed method families include:

```text
net.request
net.resourceUrl

player.playUrl
player.playVod
player.playVodInline
player.preloadArtwork
player.control
player.status

app.search
app.openVod
app.openLive
app.openKeep
app.openSetting
app.history

pan.check
pan.play

cache.get
cache.set
cache.del

device.info
site.info
config.info
ext.info / ext.log / ext.toast

ui.setToolbar
ui.setChrome
ui.restoreChrome
ui.getViewport

navigation.back
navigation.reload
```

This is one of the strongest reasons to prefer the native hybrid design. On iOS, rebuild the native side of the contract with `WKWebView` + `WKScriptMessageHandler` so existing WebHome pages can continue calling the expected JS-facing API (`fm.play`, `fm.search`, `fm.req`, etc.) with minimal page-side change.

Do not start by rewriting WebHome pages in SwiftUI.

## 11. Player migration strategy

The Android `Source` layer currently performs much more than playback. It contains special extractors/resolvers such as Force, JianPian, Push, Strm, Thunder, TVBus, Video, YouTube, DASH/MPD handling, and then feeds Android player stacks.

POC-1 should deliberately avoid reproducing this entire layer.

First playback path:

```text
Result
   ↓
PlaybackResolver
   ↓
Direct media URL available?
   │
   ├─ Yes → AVPlayer
   └─ No  → unsupported / later resolver
```

First accepted media scope should prioritize direct HTTP(S) HLS (`.m3u8`) and MP4 plus other formats proven to work natively with AVFoundation.

Later phases can add:

- custom headers/cookies/referrer handling;
- subtitles/audio-track controls;
- PiP;
- AirPlay;
- playback speed/history restoration;
- VLC/VLCKit fallback for formats AVPlayer cannot handle;
- selected YouTube/DASH/special-source resolvers only after separate compatibility/legal review.

Do not attempt MPV parity in the first implementation.

## 12. Persistence migration

The Android database currently includes entities such as:

```text
Keep
Site
Live
Track
Config
Device
History
PlaybackDeleteTombstone
```

The first iOS build does not need all of them.

Recommended initial SwiftData scope:

```text
Config
Site preferences
History
Keep / Favorites
```

History should preserve the semantic information already used by Android, including site/vod identity, artwork, title, source/episode, episode URL, position, duration, speed, and related playback state. The existing Android key convention uses a `siteKey@@@vodId`-style identity; preserving compatible semantic identity will help later migration/sync work.

## 13. Android UI should not be ported

The repository already separates common/main code from `mobile` and `leanback` variants. That is further evidence that Android Activity/Fragment/View code is not the product contract.

The iOS client should build a native SwiftUI interface around shared models/services. Preserve behavior and data contracts, not Android UI classes.

## 14. Recommended target module layout

```text
WebHomeTV iOS
│
├── WebHTVCore
│   ├── Config
│   ├── Site
│   ├── Result
│   ├── Vod
│   ├── Flag
│   └── Episode
│
├── SourceKit
│   ├── HTTPSource
│   ├── JSRuntime        # phase 2+
│   ├── PythonRuntime    # experimental phase 2+
│   └── CspRegistry      # replacement/compatibility registry
│
├── WebHomeKit
│   ├── WKWebView
│   ├── NativeBridge
│   ├── Cookie
│   └── Cache
│
├── PlayerKit
│   ├── AVPlayer
│   └── VLC fallback     # later
│
├── StorageKit
│   ├── Config
│   ├── History
│   └── Keep
│
└── SwiftUI App
```

## 15. Migration matrix

| Android capability | Proposed iOS implementation | Difficulty | POC-1 |
| --- | --- | --- | --- |
| Config JSON | Codable | Low | Yes |
| Site | Swift model | Low | Yes |
| Result | Codable + XML where needed | Low | Yes |
| Vod / Flag / Episode | Swift models | Low | Yes |
| HTTP CMS | URLSession | Low | Yes |
| Search | Site service | Low | Yes |
| Detail | Site service | Low | Yes |
| Category | Site service | Low | Yes |
| Direct playback | AVPlayer | Low-Medium | Yes |
| HTTP headers/cookies | URLSession / AVURLAsset strategy | Medium | Yes, minimal |
| History | SwiftData | Low | Yes or immediately after core playback |
| Keep/Favorites | SwiftData | Low | Yes or immediately after core playback |
| WebHome | WKWebView | Medium | Phase 1/2 |
| WebHome native bridge | WKScriptMessageHandler | Medium | Phase 1/2 |
| JS Spider | JavaScriptCore compatibility layer | Medium-High | No |
| Python Spider | Pyodide/WebView POC or optional remote adapter | High | No |
| JAR / DEX | replacement/individual port/unsupported | Very High | No |
| MPV special formats | VLC/other fallback | High | No |
| Thunder / TVBus | individual assessment | High | No |
| DLNA | native iOS alternative | Medium | Later |
| Local HTTP/proxy service | embedded local service if needed | Medium | Later |
| Room | SwiftData | Low | Yes |

## 16. POC sequence

### POC-1: prove the iOS skeleton

This is the first functional implementation task once Ponytail is available and implementation is authorized:

```text
enter/import config URL
        ↓
parse config
        ↓
list sites
        ↓
choose one pure HTTP/CMS site
        ↓
home/category/search
        ↓
detail
        ↓
episode/source
        ↓
playerContent
        ↓
direct HLS/MP4 URL
        ↓
AVPlayer
```

POC-1 explicitly excludes JAR, JS Spider, Python Spider, Thunder, TVBus, broad extractor parity, and App Store release work.

Success criteria:

- real config parses without Android runtime;
- at least one HTTP/CMS source completes search/detail/episode flow;
- a direct playable stream opens in AVPlayer;
- headers/cookies required by the selected proof source are handled;
- errors are surfaced clearly instead of silently falling through;
- architecture keeps source runtime, WebHome, playback, and storage separated.

### POC-2: WebHome bridge

Prove an existing WebHome page can call the iOS native bridge for a controlled subset such as `net.request`, `player.playUrl`, `app.search`, `app.history`, and cache operations.

### POC-3: pure JS Spider

Choose one simple, known pure-JS Spider and implement only the compatibility APIs it actually requires. Measure compatibility rather than assuming all JS sources work.

### POC-4: simple Python Spider

Choose one deliberately simple Python source and evaluate whether a no-server Pyodide/WebView approach is viable. Stop if the dependency/runtime cost becomes disproportionate.

### POC-5: compatibility registry

Classify high-value `csp_*` sources into equivalent HTTP/JS/Python implementations, individual ports, or unsupported sources. Do not build a universal DEX executor.

## 17. Resource-set assessment already performed

A user-provided `recha-main.zip` / `wang-movie.json` set was inspected during planning. At that time the observed configuration contained:

- 208 configured sites;
- 136 `csp_*` / Android JAR-style Spider sites;
- 37 Python Spider sites;
- 30 HTTP/CMS API sites;
- 5 JavaScript Spider sites.

Many JAR-backed sites appeared to have Python/JS/rule-based alternatives in the same collection. This supports a replacement-first compatibility strategy.

These counts are evidence from that inspected archive, not a permanent truth. Recheck the actual resource set whenever exact current coverage matters.

## 18. Installation and testing without jailbreak

### Free personal testing

A paid Apple Developer Program membership is not required to develop an iOS app and install/test it on the developer's own device using Xcode. Apple describes this as personal-device testing with a free Apple Account / Personal Team.

For the user's preferred no-recurring-fee workflow, SideStore is a practical personal sideloading option. Current SideStore documentation states that it uses a personal development certificate and refreshes apps to prevent the normal 7-day development period from expiring. Initial setup requires a computer; later refreshes are intended to be performed from the device with SideStore's local VPN mechanism.

With a free Apple Account, SideStore currently documents limits including three installed apps at a time (including SideStore) and ten App IDs in a seven-day period. Treat these as current third-party tool constraints and recheck SideStore documentation before relying on them.

SideStore documentation: https://docs.sidestore.io/docs/installation/install
SideStore FAQ: https://docs.sidestore.io/docs/faq

### Xcode free path

Apple official program overview: https://developer.apple.com/help/account/membership/programs-overview
Taiwan enrollment help: https://developer.apple.com/tw/help/account/membership/program-enrollment

The free path is appropriate for POC and personal use, but provisioning must be renewed periodically.

## 19. TestFlight and App Store cost conclusions

As checked on 2026-09-13:

- Testing directly on a personal device with Xcode does not require Apple Developer Program membership.
- TestFlight is a membership resource and therefore requires Apple Developer Program membership.
- App Store distribution requires Apple Developer Program membership.
- Apple currently lists the Apple Developer Program at US$99 per membership year (or local currency where available).
- This is a membership fee, not a separate fee per app submission.

Official references:

- https://developer.apple.com/programs/
- https://developer.apple.com/programs/whats-included/
- https://developer.apple.com/help/account/membership/programs-overview
- https://developer.apple.com/tw/help/account/membership/program-enrollment

Recheck Apple pricing and membership terms before an actual enrollment/release because policies can change.

## 20. App Store compliance strategy

Do not assume the unrestricted personal build can be submitted unchanged.

Important Apple App Review areas identified during the discussion include:

- Guideline 2.5.2: apps are generally expected to be self-contained and may not download/install/execute code that introduces or changes app functionality.
- Guideline 4.7: certain HTML5/JavaScript mini-app/plugin models are permitted under specific rules, but native platform APIs/technologies must not simply be exposed to downloaded software without the required permission/compliance.
- Guideline 5.2.2: access to third-party services/content must be specifically permitted under the applicable terms.
- Guideline 5.2.3: unauthorized downloading/conversion/saving of third-party media is a review risk, and even streaming may violate service terms.

Current guidelines: https://developer.apple.com/app-store/review/guidelines/

Recommended long-term product split:

### `WebHomeTV Personal`

For personal/sideloaded development and compatibility research. This can be the broader compatibility target, subject to iOS platform/security constraints. Potential later capabilities include controlled JS Spider support, experimental Python compatibility, broader WebHome bridge behavior, and optional remote adapters.

### `WebHomeTV Store`

A constrained App Store profile. Position it as a general media player / user-owned media-source manager rather than a bundled third-party scraping or unauthorized-stream aggregation client.

Likely Store-safe direction includes:

- native SwiftUI UI;
- AVPlayer/VLC playback;
- user-owned/local media;
- user-entered lawful URLs;
- data-oriented config import;
- authorized CMS APIs;
- favorites/history;
- PiP/AirPlay;
- iCloud/CloudKit only if intentionally added and membership/capability requirements are accepted;
- controlled/bundled WebHome behavior;
- no arbitrary downloaded JAR/Python/JS code execution that changes app functionality;
- no bundled unlicensed media sources or unauthorized download/extraction features.

An Unlisted App is not a policy bypass; it still goes through App Review.

The Store/Personal split should share most core models, networking, UI, storage, and player code, with capability differences enforced through explicit build configuration rather than runtime ambiguity.

## 21. Licensing

The WebHomeTV/WebHTV source lineage being assessed is GPLv3. Direct copying/translation of GPL-covered implementation code can carry GPL obligations.

The iOS effort should therefore distinguish:

- protocol/behavior compatibility learned from the Android implementation;
- clean Swift reimplementation of contracts;
- any source code actually copied or translated;
- third-party libraries such as VLC and their own licenses;
- resource/Spider implementations and their provenance.

Do not silently copy third-party Spider/resource implementations into the iOS project. Preserve provenance and assess license implications before inclusion/distribution.

## 22. Repository files inspected during the architecture assessment

Future sessions should use these as starting points rather than rediscovering the architecture from scratch:

```text
app/src/main/java/com/fongmi/android/tv/api/SiteApi.java
app/src/main/java/com/fongmi/android/tv/api/config/VodConfig.java
app/src/main/java/com/fongmi/android/tv/bean/Site.java
app/src/main/java/com/fongmi/android/tv/bean/Result.java
app/src/main/java/com/fongmi/android/tv/bean/Vod.java
app/src/main/java/com/fongmi/android/tv/bean/History.java
app/src/main/java/com/fongmi/android/tv/bean/Config.java
app/src/main/java/com/fongmi/android/tv/player/Source.java
app/src/main/java/com/fongmi/android/tv/web/HomeWebBridge.java
app/src/main/java/com/fongmi/android/tv/db/AppDatabase.java
app/src/main/java/com/fongmi/android/tv/api/loader/BaseLoader.java
app/src/main/java/com/fongmi/android/tv/api/loader/JsLoader.java
app/src/main/java/com/fongmi/android/tv/api/loader/PyLoader.java
app/src/mobile/
app/src/leanback/
catvod/
chaquo/
quickjs/
webhome-devkit/
```

The exact paths should be revalidated if upstream changes reorganize the repository.

(Corrected 2026-09-25: the three loader paths read `.../tv/spider/loader/`, which has never existed in this repository; the files are in `.../tv/api/loader/`.)

## 23. Decisions future agents should not reopen without new evidence

Do not spend another planning cycle on these unless new technical evidence materially changes the conclusion:

- Do not perform a literal Java-to-Swift port of the whole Android app.
- Do not treat arbitrary Android JAR/DEX execution as a realistic first-class iOS feature.
- Do not use CheerpJ as the assumed universal JAR solution.
- Do not begin with MPV/Media3 parity.
- Do not port Android Activity/Fragment UI directly.
- Do not require an always-on remote server for the basic app.
- Do not make App Store compliance constraints dictate the personal POC architecture; use explicit Personal vs Store capability profiles.
- Do not begin broad UI work before the config → source → detail → playback path is proven.

## 24. Open questions that still require proof

The following are intentionally unresolved:

- Exact percentage of the user's real source set that can be covered without Android JAR/DEX.
- Which JS Spiders are pure JS versus Android-dependent.
- Whether Pyodide is sufficient for useful Python Spider compatibility on current iOS hardware.
- Exact AVPlayer compatibility for the selected real sources, especially custom headers/cookies/redirects/DASH.
- Whether VLCKit is needed in the first usable beta or can wait.
- Which WebHome bridge methods are required for the user's real homepage/extensions versus merely available in Android.
- Whether a local embedded HTTP/proxy server is required for selected WebHome/player flows.
- App Store viability of the final feature set; this must be reassessed against then-current App Review Guidelines before submission.

## 25. Next action for another window

(Corrected 2026-09-25: this next action is done and superseded. POC-1 was implemented as IOS-POC-1A–1E on 2026-09-15, and the Ponytail condition no longer applies (see §3). Do not start from the steps below; take the next step from `docs/current-task-state.md` "Current handoff".)

If the next session has Ponytail available and the user authorizes implementation, the recommended next task is POC-1 only:

1. Sync/read `ios-poc`.
2. Read `AGENTS.md`, `README.md`, `docs/AGENT_HANDOFF.md`, and this file.
3. Run Ponytail pre-review on the POC-1 design.
4. Create the minimal Swift/iOS project structure without touching Android `main`.
5. Implement `Config/Site/Result/Vod/Flag/Episode` models and HTTP/CMS `SiteApi` equivalent.
6. Select one known direct HTTP/CMS source.
7. Prove search → detail → episode → `playerContent` → AVPlayer.
8. Add targeted tests/fixtures for config/result parsing.
9. Run the repository verification required by `AGENTS.md`.
10. Run Ponytail final-diff review before commit/IPA/release.

If Ponytail is still unavailable, continue only with read-only fixture/specification work and do not begin functional Swift implementation.

---

This file is the durable summary of the 2026-09-13 iOS planning discussion. When it conflicts with newer verified repository state, newer explicit user instructions, current Apple policy, or later dated project decision documents, the newer authoritative evidence wins.