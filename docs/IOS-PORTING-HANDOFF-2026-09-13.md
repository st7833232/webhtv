# WebHTV iPhone / iOS Porting Handoff — 2026-09-13

This document is the durable handoff for the iPhone/iOS work discussed on 2026-09-13. It is intended to let a new ChatGPT/Work/Codex session continue without reconstructing the conversation.

> Scope note: this is an assessment/architecture document only. No functional iOS code has been implemented yet. Functional implementation remains gated by Ponytail review as described in `docs/AGENT_HANDOFF.md`.

## 1. Repository, branch, and ownership

- User fork: `st7833232/webhtv`
- Upstream source: `fish2018/webhtv`
- Android/upstream-oriented branch: `main`
- iPhone/iOS exploration branch: `ios-poc`
- `ios-poc` was originally created from `fc62397591701b2232ae7de4f50a032bd7742064`.
- `docs/AGENT_HANDOFF.md` was added on `ios-poc` in commit `816304563b0f9686bf241f7e3d84a2aa4c6f40ad`.
- Do not perform experimental iOS/PWA implementation directly on `main`.

## 2. Mandatory project process: Ponytail

The user explicitly requires this project to use the Ponytail skill.

For any functional code, dependency, build, runtime, player, Spider, packaging/signing, deployment/release, or architecture implementation change:

1. Read `AGENTS.md`, `README.md`, `docs/AGENT_HANDOFF.md`, this file, and any task-specific Skill.
2. Run Ponytail before implementation against the proposed scope/design.
3. Resolve or explicitly record material findings before editing functional code.
4. Implement only the approved bounded scope.
5. Run targeted verification.
6. Run Ponytail again on the final diff.
7. Record pre-review and final-diff review evidence in the durable task document.

If Ponytail is not available in the current runtime/session, do not claim it was run. Read-only analysis and documentation may continue, but functional implementation must stop before the first functional edit.

At the time this document was created, Ponytail was searched for in the active ChatGPT environment but was not exposed as an available skill/plugin.

## 3. User goals and hard constraints

The user wants WebHomeTV usable on iPhone with the following priorities:

- no jailbreak;
- zero recurring infrastructure cost where practical;
- no always-on self-hosted server;
- no requirement to leave a PC running continuously;
- preserve as much WebHomeTV / CatVod / WebHome compatibility as practical;
- future WebHomeTV updates should be installable from the phone with minimal friction;
- do not blindly translate Java to Swift; preserve contracts/behavior and redesign platform-specific internals.

The user is willing to use sideloading rather than App Store distribution for the personal build.

## 4. iPhone signing / installation conclusion

### 4.1 Free Apple Account

The free Apple development signing path has a short provisioning/signing lifetime, commonly around 7 days. Re-signing an IPA with an already-expired provisioning profile does not solve this; a valid provisioning profile must exist for the new signing period.

Therefore the earlier idea of a ChatGPT task simply re-signing the same IPA every six days and uploading it to Drive is not a complete zero-cost solution by itself.

### 4.2 SideStore is the preferred zero-cost personal-install path

The working recommendation from the discussion is SideStore-style on-device refresh:

```text
Initial setup
PC/Mac
  -> install/configure SideStore and pairing
  -> iPhone

Normal use
WebHomeTV IPA
  -> SideStore on iPhone
  -> sign/refresh with user's Apple account
  -> install/update on iPhone
```

This avoids requiring an always-on computer for normal refreshes after initial setup. Pairing/setup may still occasionally need a computer after device reset, pairing changes, major iOS changes, etc.

When WebHomeTV itself is updated, the intended flow is:

```text
new WebHomeTV.ipa
  -> download/open on iPhone
  -> SideStore
  -> sign on phone
  -> install over existing app
```

Keep the Bundle ID stable so an updated IPA is treated as an update rather than an unrelated second app. Do not delete the old app before an update unless required, so app data has the best chance of remaining intact.

External SideStore/Apple behavior can change; re-check current official documentation before implementing release automation.

## 5. Earlier PWA evaluation and why it is no longer the primary recommendation

A PWA was evaluated because it is attractive for:

- zero Apple developer fee;
- no App Store review;
- install from Safari/Add to Home Screen;
- server-side/static updates without re-signing;
- good baseline HLS/MP4 playback.

A possible zero-cost PWA architecture considered was:

```text
PWA / Safari
  -> direct HTTP/CMS sources
  -> browser JS runtime
  -> Pyodide for Python where feasible
  -> optional Cloudflare Free gateway for CORS/header/cookie issues
  -> direct media playback on the iPhone
```

However, after reading the actual WebHTV Android contracts and WebHome bridge, the preferred direction shifted to **Native iOS + WKWebView hybrid** because native iOS better preserves:

- WebHome native bridge behavior;
- AVPlayer/PiP/AirPlay/media integration;
- local persistence;
- cookie/header handling;
- room for future media fallback engines;
- app-level navigation/control APIs;
- local compatibility adapters.

PWA remains a possible lightweight/fallback product, not the primary porting target.

## 6. Resource archive evaluated during planning

A user-provided archive named `recha-main.zip` was retrieved from the user's connected Google Drive during the session. The Drive share URL is intentionally **not** written into this public repository. The archive itself is also not committed here.

The archive contained a large TVBox/WebHome-style resource collection, including approximately:

- 492 JSON files;
- 366 Python files;
- 108 JAR-named packages;
- 66 JavaScript files.

The key configuration inspected was `wang-movie.json`.

### 6.1 `wang-movie.json` site distribution observed

The inspected copy contained 208 configured sites:

| Runtime/source type | Count | Approx. share |
| --- | ---: | ---: |
| `csp_*` / Android JAR-style Spider | 136 | 65.4% |
| Python Spider | 37 | 17.8% |
| HTTP/CMS API | 30 | 14.4% |
| JavaScript Spider | 5 | 2.4% |

These are observations from the inspected archive, not permanent repository facts. Re-scan the current resource set if exact numbers matter later.

### 6.2 Important JAR finding: these are often Android DEX packages, not JVM JARs

A critical correction to the initial CheerpJ idea was made after actual archive inspection.

Many `.jar` files were containers with Android payloads such as:

```text
classes.dex
Android API references
DexClassLoader
WebView dependencies
native .so payloads
```

Examples observed in the resource set included packages with names such as:

- `399640384_3_1788121085146.jar`, which contained `classes.dex` and `FishGuard` native `.so` payloads;
- `aowu-0901.jar`, which used dynamic DEX loading and included an additional binary payload;
- `fan-0720.jar`, which also involved native protection/runtime payloads;
- other packages with WebView/Android/CatVod-specific dependencies.

Therefore browser JVM solutions such as CheerpJ **must not be treated as a universal drop-in JAR runtime** for this ecosystem. WebHTV itself confirms the same architecture through direct use of `dalvik.system.DexClassLoader` in the Android loader path.

### 6.3 Correct JAR strategy

Do not start by reverse engineering all 136 CSP sites.

Use this decision path:

```text
csp_xxx site
  -> search resource collection for equivalent HTTP / JSON rule / JS / Python implementation
  -> if equivalent exists: use the portable alternative
  -> if no equivalent exists and site is valuable: inspect the DEX/native requirements individually
  -> if strongly Android/native/protected: mark unsupported/deferred
```

Initial name/API matching during the session found roughly 67 CSP sites with possible Python/JS alternatives in the same collection. That figure was an initial candidate count, not a verified compatibility count.

Examples of apparent alternative families found included variants related to:

- Jpys / 金牌;
- Uvod;
- Jianpian / 荐片;
- Bili/Bilibili;
- 农民影视;
- 永乐;
- CZ;
- 骚火;
- 短剧聚合;
- 七猫;
- 西瓜动漫/卡通.

These candidates must be verified behaviorally before being declared replacements.

## 7. Python compatibility conclusion

The inspected `wang-movie.json` used 37 Python sites. Many Python implementations were close to ordinary HTTP/HTML scraping and commonly used packages/APIs such as:

- `base.spider`;
- `requests`;
- `hashlib`;
- `base64`;
- `Crypto`;
- BeautifulSoup;
- `lxml`.

The Android runtime uses Chaquopy, and some Python scripts bridge back into Android/CatVod APIs such as `com.github.catvod.Proxy` or Chaquopy-specific objects.

The important reusable contract is still the Spider shape:

```text
init
homeContent
homeVideoContent
categoryContent
detailContent
searchContent
playerContent
proxy/localProxy-style behavior
```

### Preferred iOS experiment for Python

Do not attempt to port Chaquopy itself.

The preferred proof is a compatibility layer around a portable Python runtime (Pyodide was the leading option discussed), with a `base.spider` compatibility implementation mapping:

- HTTP requests -> browser/native networking bridge;
- cache -> app storage/IndexedDB-style equivalent depending on runtime location;
- CatVod proxy APIs -> iOS/native bridge equivalents;
- local paths -> app sandbox abstractions.

Python is a second-phase compatibility target, not part of the first native POC.

## 8. JavaScript compatibility conclusion

The inspected resource set included 5 JS sites.

One notable issue found in the inspected configuration was a path mismatch where a site referenced something like `./json/4k.js` while the archive contained the script under a JS directory. This is a resource/config quality issue, not an iOS runtime problem.

Some scripts exposed simple async functions such as init/home/category/search and are good candidates for a portable JS proof.

Android WebHTV uses `JsLoader` + QuickJS and can optionally supply DEX/JAR context into the JS loader. Therefore classify JS implementations as:

- pure JS: good iOS candidate;
- JS + small compatibility API: likely portable;
- JS + Android DEX/class dependency: not directly portable.

For a native iOS implementation, JavaScriptCore is the preferred first runtime to investigate for pure JS Spider compatibility.

## 9. WebHTV Android architecture inventory completed in this session

### 9.1 Config entry point: `VodConfig`

Relevant file:

`app/src/main/java/com/fongmi/android/tv/api/config/VodConfig.java`

Observed responsibilities:

- fetch/decode config JSON;
- process depot/URL lists;
- parse `sites`;
- parse global `spider` JAR reference;
- parse `parses`;
- load headers/proxy/rules/DoH/flags/ads/hosts;
- synchronize live/wallpaper config;
- configure WebHome extensions;
- choose current home site and parse provider.

This is a strong indicator that iOS should preserve the config schema/behavior, not the Java implementation.

### 9.2 Site model: `Site`

Relevant file:

`app/src/main/java/com/fongmi/android/tv/bean/Site.java`

Important portable fields include:

```text
key
name
api
ext
jar
click
playUrl
homePage
chromeMode
webHomeChrome
extensions
type
hide
indexs
timeout
searchable
changeable
quickSearch
categories
header
style
```

Android-only concerns mixed into this class include Parcelable, Room, TextUtils, and Android persistence. On iOS the model should be a clean Codable/value model plus separate persistence/service layers.

### 9.3 Core protocol boundary: `SiteApi`

Relevant file:

`app/src/main/java/com/fongmi/android/tv/api/SiteApi.java`

This is the most important contract boundary found in the session.

Regardless of source runtime, the application converges on the same operations:

```text
homeContent
categoryContent
detailContent
searchContent
playerContent
action
```

For `type == 3`, the calls are delegated to a Spider. For HTTP/CMS types, SiteApi builds the expected query/body, performs HTTP, and decodes JSON/XML into the same `Result` model.

**iOS should reproduce this behavioral contract, not clone Android loader internals.**

### 9.4 Spider contract

Relevant file:

`catvod/src/main/java/com/github/catvod/crawler/Spider.java`

Observed interface/behavior surface:

```text
init(context[, extend])
homeContent(filter)
homeVideoContent()
categoryContent(tid, pg, filter, extend)
detailContent(ids)
searchContent(key, quick[, pg])
playerContent(flag, id, vipFlags)
liveContent(url)
manualVideoCheck()
isVideoFormat(url)
proxy(params)
action(action)
destroy()
```

The iOS compatibility architecture should model this as a protocol/adapter interface independent of implementation runtime.

### 9.5 Runtime dispatcher: `BaseLoader`

Relevant file:

`app/src/main/java/com/fongmi/android/tv/api/loader/BaseLoader.java`

Dispatch behavior observed:

```text
api contains .py -> PyLoader
api contains .js -> JsLoader
api starts csp_  -> JarLoader
otherwise        -> SpiderNull
```

`BaseLoader` imports `dalvik.system.DexClassLoader`, confirming that the current JAR/CSP implementation is Android runtime specific.

### 9.6 `PyLoader`

Relevant file:

`app/src/main/java/com/fongmi/android/tv/api/loader/PyLoader.java`

Uses `com.fongmi.chaquo.Loader`, initializes a Spider, sets the site key, normalizes ext, and exposes proxy behavior. This should not be directly ported; preserve the Spider result contract and build a new runtime adapter later.

### 9.7 `JsLoader`

Relevant file:

`app/src/main/java/com/fongmi/android/tv/api/loader/JsLoader.java`

Uses the QuickJS loader, initializes a Spider, and may receive a DEX/JAR loader context. This again argues for a clean runtime adapter on iOS rather than mirroring Java classes.

## 10. Result/VOD protocol data that should be preserved

### 10.1 `Result`

Relevant file:

`app/src/main/java/com/fongmi/android/tv/bean/Result.java`

Important fields include:

```text
class/types
list
filters
url
header
msg
danmaku
subs
playUrl
artwork
jxFrom
flag
desc
format
click
key
position
pagecount
parse
code
jx
drm
```

It handles both JSON and XML-style CMS responses. iOS should preserve enough of this schema to remain TVBox/CatVod compatible.

### 10.2 `Vod`

Relevant file:

`app/src/main/java/com/fongmi/android/tv/bean/Vod.java`

Core fields include:

```text
vod_id
vod_name
type_name
vod_pic
vod_remarks
vod_year
vod_area
vod_director
vod_actor
vod_content
vod_play_from
vod_play_url
vod_tag
action
```

The existing parser converts `vod_play_from` and `vod_play_url` into Flag/Episode structures. Preserve the delimiter semantics and output behavior in iOS.

## 11. WebHome is a strong candidate for direct behavioral compatibility on iOS

Relevant files include:

- `app/src/main/java/com/fongmi/android/tv/web/HomeWebBridge.java`
- `HomeWebController.java`
- `WebCall.java`
- `CookieBridge.java`
- related WebHome extension/raw/viewport classes.

The current Android bridge already presents a string-RPC-style API:

```text
invoke(requestId, method, payload)
```

Observed method names include:

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
ext.info
ext.log
ext.toast
ui.setToolbar
ui.setChrome
ui.restoreChrome
ui.getViewport
navigation.back
navigation.reload
```

This is one of the strongest reasons to choose a native hybrid architecture. On iOS, reproduce the same method contract using:

```text
WKWebView
  -> WKScriptMessageHandler
  -> WebHomeBridge.swift
  -> native services/player/storage/navigation
```

The goal is to let existing WebHome pages/scripts continue using the expected bridge semantics with minimal or no content-side changes.

## 12. Playback architecture finding

Relevant file:

`app/src/main/java/com/fongmi/android/tv/player/Source.java`

Android separates two concerns:

1. `SiteApi.playerContent()` obtains/normalizes a `Result`.
2. `Source` then performs extractor/resolver work for special source forms before the actual player consumes the result.

Observed extractors/handlers include families such as:

- Force;
- JianPian;
- Push;
- Strm;
- Thunder;
- TVBus;
- Video;
- YouTube;
- DASH/MPD sanitation/resolution logic.

Do not port all of this into POC-1.

### POC-1 playback rule

Accept only direct media that iOS can play natively, primarily:

```text
HTTP(S) direct media
HLS (.m3u8)
MP4 / AVFoundation-supported media
```

Proposed first player stack:

```text
Result
  -> PlaybackResolver
  -> direct playable URL?
       yes -> AVPlayer
       no  -> unsupported/deferred resolver
```

Possible later additions:

- custom request headers/cookies;
- subtitles;
- DASH handling where viable;
- VLC/mobile-compatible fallback for formats AVPlayer cannot handle;
- individually justified source extractors.

## 13. Persistence/history mapping

Relevant Android files:

- `app/src/main/java/com/fongmi/android/tv/bean/History.java`
- `app/src/main/java/com/fongmi/android/tv/db/AppDatabase.java`
- `app/src/main/java/com/fongmi/android/tv/bean/Config.java`

The current Room database includes entities such as:

- Keep;
- Site;
- Live;
- Track;
- Config;
- Device;
- History;
- PlaybackDeleteTombstone.

History stores data such as site/vod key, artwork, title, source/flag, episode URL/name, current position, duration, speed, scale and config id. Keys use the existing `@@@` separator convention for site/vod identity.

Preferred iOS persistence direction: SwiftData (or a similarly simple native persistence layer). POC-1 only needs the smallest useful subset, likely Config + basic History, with Keep/Favorites shortly after.

## 14. Android UI should not be ported literally

The repository already separates Android variants under source sets such as:

```text
app/src/main
app/src/mobile
app/src/leanback
```

This supports the architectural decision to port shared behavior/contracts, not Android Activities/Fragments/layouts.

The iPhone UI should be native SwiftUI/UIKit as appropriate, consuming the same normalized Site/Result/Vod/Flag/Episode services.

## 15. Current recommended iOS architecture

The current preferred architecture after the read-only inventory is:

```text
WebHomeTV iOS
|
|-- WebHTVCore
|   |-- Config
|   |-- Site
|   |-- Result
|   |-- Vod
|   |-- Flag
|   |-- Episode
|   `-- Parse/Filter/MediaURL models
|
|-- SourceKit
|   |-- HTTPSource / CMS adapter       [POC-1]
|   |-- JSRuntime                      [phase 2]
|   |-- PythonRuntime                  [phase 2]
|   `-- CspReplacementRegistry         [phase 3]
|
|-- WebHomeKit
|   |-- WKWebView
|   |-- Native bridge
|   |-- Cookie/header handling
|   `-- Cache/storage bridge
|
|-- PlayerKit
|   |-- AVPlayer                       [POC-1]
|   `-- optional fallback engine       [later]
|
|-- StorageKit
|   |-- Config persistence
|   |-- History
|   `-- Keep/Favorites
|
`-- SwiftUI application shell
```

This is a **Native iOS + WKWebView hybrid** architecture.

It is the preferred direction, but implementation should still prove the core assumptions with POC-1 before treating every later phase as committed scope.

## 16. Migration matrix

| Android/WebHTV capability | Preferred iOS mapping | Difficulty | Phase |
| --- | --- | --- | --- |
| Config JSON | Codable + config service | Low | POC-1 |
| Site model | Swift value/Codable model | Low | POC-1 |
| Result JSON/XML | Codable/XML adapter | Low-Med | POC-1 |
| Vod/Flag/Episode | Swift models | Low | POC-1 |
| HTTP/CMS sites | URLSession | Low | POC-1 |
| Search/category/detail | SiteService/SiteApi-equivalent | Low | POC-1 |
| Direct HLS/MP4 playback | AVPlayer | Low-Med | POC-1 |
| Basic headers/cookies | URLSession/AVFoundation handling | Medium | POC-1 |
| Config/history persistence | SwiftData | Low | POC-1/early |
| Keep/Favorites | SwiftData | Low | Early |
| WebHome | WKWebView | Medium | Early |
| WebHome native bridge | WKScriptMessageHandler | Medium | Early |
| Pure JS Spider | JavaScriptCore adapter | Medium-High | Phase 2 |
| Python Spider | portable Python/Pyodide-style adapter | High | Phase 2 |
| JAR/CSP DEX | replacement registry / individual port | Very High | Phase 3 |
| MPV-only/special media | fallback player/resolver | High | Later |
| Thunder/TVBus/special schemes | individual assessment | High | Later |
| DLNA | iOS-native alternative | Medium | Later |
| Local HTTP/proxy service | redesign only if required | Medium | Later |

## 17. POC-1 — the first functional implementation task

Do not begin with JAR/DEX, Python, JS, MPV, DLNA, cloud drives, or broad UI work.

The first functional proof should be:

```text
enter/load config URL
  -> parse config
  -> show/select one pure HTTP/CMS Site
  -> home/category
  -> search
  -> detail
  -> parse Flag/Episode
  -> playerContent/direct URL
  -> AVPlayer HLS/MP4 playback
```

### POC-1 success criteria

A new session should consider POC-1 successful only if one representative HTTP/CMS source proves the complete vertical contract:

1. config loads successfully;
2. at least one site is decoded correctly;
3. home/category response maps to Result/Vod correctly;
4. search works;
5. detail returns playable episode metadata;
6. episode selection preserves flag/url semantics;
7. player resolution produces a direct HLS/MP4 URL;
8. AVPlayer starts playback;
9. required headers/cookies for that representative source are handled if needed;
10. the implementation stays isolated from Android `main` behavior.

### POC-1 exclusions

Explicitly out of scope unless later approved:

- arbitrary CSP/JAR/DEX execution;
- protected/native `.so` payloads;
- Python runtime;
- JS Spider runtime;
- MPV/VLC fallback;
- Thunder/TVBus;
- full WebHome bridge;
- DLNA;
- cloud-drive-specific features;
- App Store distribution;
- production release automation.

## 18. Recommended phase sequence after POC-1

If POC-1 succeeds, proceed in this order:

1. **WebHome bridge proof** — WKWebView + a small subset such as `net.request`, `player.playUrl`, `app.search`, `cache.*`, `site.info`.
2. **JS Spider proof** — choose one pure JS Spider from the resource set and prove search/detail/player contract.
3. **Python Spider proof** — choose one simple Python Spider with ordinary HTTP/HTML logic and minimal Android dependencies.
4. **Replacement registry** — map CSP keys to verified HTTP/JS/Python alternatives where available.
5. **Selective DEX assessment** — only for high-value sources with no alternative.
6. **Player expansion** — special headers, subtitles, format fallbacks, selected extractors.
7. **Persistence/features** — Keep/Favorites, history polish, WebHome state, settings.
8. **Packaging/update pipeline** — unsigned/build IPA output + SideStore-friendly update delivery.

## 19. Distribution/build automation direction

Long-term personal-build flow discussed:

```text
code update
  -> GitHub build/CI produces iOS IPA or installable artifact
  -> host artifact (GitHub Release or another stable location)
  -> iPhone downloads update
  -> SideStore signs/installs on phone
  -> SideStore handles periodic refresh
```

Do not prematurely build this automation before the iOS runtime POC works.

The user initially asked for re-signing and automatic upload to Google Drive. The final conclusion was that Drive-based periodic re-signing is less appropriate than SideStore on-device refresh for a free Apple account. Google Drive may still be used as optional artifact storage, but should not be the core provisioning mechanism.

## 20. Security and credential handling

Do not ask the user to provide or persist Apple ID password or 2FA secrets for unattended signing.

If certificate-based signing is ever used, treat `.p12` private keys and passwords as sensitive. Prefer a dedicated development signing identity rather than the user's only long-lived distribution key.

Do not commit credentials, provisioning profiles, private signing keys, Apple session tokens, or private Drive links into this public repository.

## 21. Licensing/provenance note

The upstream WebHTV codebase is GPLv3. Do not casually assume that a translated or derived implementation can be distributed under unrelated licensing terms.

For compatibility work, preserve provenance and review the licensing implications before copying third-party Spider implementations, scripts, protected resources, or source code into the repository.

Prefer behavior/protocol compatibility and clean platform-native implementation where appropriate, while respecting the source project's GPL obligations.

## 22. What a new window should read first

A fresh session should recover in this order:

1. `AGENTS.md`
2. `README.md`
3. `docs/AGENT_HANDOFF.md`
4. `docs/IOS-PORTING-HANDOFF-2026-09-13.md` (this file)
5. exact source files relevant to the current phase only

Do not restart the broad architecture search unless repository code or the external resource set has materially changed.

## 23. Key source files already inspected

Do not repeat these reads unless needed for a concrete implementation question:

- `app/src/main/java/com/fongmi/android/tv/api/config/VodConfig.java`
- `app/src/main/java/com/fongmi/android/tv/api/SiteApi.java`
- `app/src/main/java/com/fongmi/android/tv/api/loader/BaseLoader.java`
- `app/src/main/java/com/fongmi/android/tv/api/loader/JsLoader.java`
- `app/src/main/java/com/fongmi/android/tv/api/loader/PyLoader.java`
- `app/src/main/java/com/fongmi/android/tv/bean/Site.java`
- `app/src/main/java/com/fongmi/android/tv/bean/Result.java`
- `app/src/main/java/com/fongmi/android/tv/bean/Vod.java`
- `catvod/src/main/java/com/github/catvod/crawler/Spider.java`
- `app/src/main/java/com/fongmi/android/tv/web/HomeWebBridge.java`
- `app/src/main/java/com/fongmi/android/tv/player/Source.java`
- `app/src/main/java/com/fongmi/android/tv/bean/History.java`
- `app/src/main/java/com/fongmi/android/tv/bean/Config.java`
- `app/src/main/java/com/fongmi/android/tv/db/AppDatabase.java`
- Android source-set structure under `app/src/main`, `app/src/mobile`, and `app/src/leanback`.

## 24. Current recovery anchor

### 2026-09-15 task correction and POC-1A

- Current task: build the WebHomeTV iOS client and make it consume the user's actual `wang-movie.json`; the earlier Google TV `csp_JPianAmns` repair is no longer active.
- Input: `recha-main.zip` from the user-provided Google Drive file, modified 2026-09-15; extracted `recha-main/wang-movie.json` is 93,660 bytes with SHA-256 `1b0a3227c84937658a816e992a58e6aad2e2aeb839ea65b4744fdaf8582913c1`.
- Observed config: 208 sites; type counts are 2 type-0, 22 type-1, 178 type-3, and 6 type-4 sites. POC-1A supports only the 24 native HTTP/CMS type-0/type-1 sites.
- Design: use native `JSONDecoder` and `URLSession`, preserve default TLS/ATS validation, and add no dependency. Android DEX/JAR, JS, Python, CarPlay, special schemes, and broad ATS exceptions remain outside this slice.
- Representative next network source: the configured Sony CMS endpoint passed system TLS and returned a MacCMS-style JSON response. Full home/search/detail/player verification remains for POC-1B.
- POC-1A acceptance: the reusable Swift core parses the complete supplied config and deterministically identifies all 24 native CMS sites.
- Verification: `WANG_MOVIE_JSON=<extracted path> swift test --package-path ios` built successfully with Swift 6.2.4; both tests passed with no failures, including the complete supplied config.
- Ponytail final review: removed the unused public initializer and three fields not consumed by this slice; no third-party dependency or speculative runtime layer remains.
- Rollback: revert the single `IOS-POC-1A` commit; Android paths are untouched.

- Objective: create a usable iPhone version of WebHomeTV while preserving the portable CatVod/WebHome behavioral contracts and avoiding an always-on server or jailbreak.
- Preferred architecture: Native iOS + SwiftUI + WKWebView hybrid.
- Installation strategy for personal zero-cost use: SideStore/on-device refresh after initial setup.
- Active branch: `ios-poc`.
- Android `main` must remain unaffected by experimental iOS work.
- Functional iOS code implemented so far: none.
- Resource evidence: `recha-main.zip` / `wang-movie.json` was inspected externally; the archive is not in this repo.
- JAR conclusion: many CSP packages are Android DEX/native packages and are not a generic JVM portability path.
- Runtime priority: HTTP/CMS first, then WebHome/JS, then Python, then selective CSP replacement/porting.
- Ponytail: mandatory before and after every functional implementation; unavailable in the session that produced this document.
- Exactly one next functional action: **in a runtime where Ponytail is available, perform Ponytail pre-review for POC-1, then implement the minimal HTTP/CMS -> detail -> direct HLS/MP4 -> AVPlayer vertical slice on an iOS task branch derived from `ios-poc`.**
