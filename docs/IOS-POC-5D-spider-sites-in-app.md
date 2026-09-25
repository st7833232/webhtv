# IOS-POC-5D — the ported spiders reach the app UI

Stage record. Runtime contract: `docs/IOS_SPIDER_RUNTIME_SPEC.md`. Port progress:
`docs/CSP_MIGRATION_STATUS.md`.

## Why

IOS-POC-5A/5B built a CatVod spider runtime and ported three classes covering 15 sites, all
verified live. None of them were reachable from the app: `ConfigView` listed
`WebHTVConfig.supportedSites` (type-0/1/4 only) and every content call constructed `CMSClient`
directly, so a registered spider could never appear no matter how well it worked. IOS-POC-5C
recorded that gap; this stage closes it.

**Result: the app lists 45 of 167 sources instead of 30.** Listing them is not the same as all of
them working — of the 15 spider sites, 3 browse and play end to end, 7 are down or withdrawn at the
provider, and 5 stop in our own code. The per-site table under Verification is the real number.

## Design

The lazy path was already most of the way there: `SpiderSession` answers in CatVod JSON, and
`CMSResponse` / `Vod` / `Flag` / `Episode` already decode exactly that, because the ports were
written to emit the shape the app was parsing. So **no new model type was added** — the spider
branch only decodes.

`SourceClient` (`ios/Sources/WebHTVCore/SourceClient.swift`) is an enum over the two backings with
the same five methods `CMSClient` already exposed, so the four call sites swapped one type name:

| call site | before | after |
|---|---|---|
| `CMSView.listing(page:)` | `CMSClient(site:)` | `SourceClient.make(site:resolver:)` |
| `CMSView.load(search:category:)` | same | same |
| `VodView.task` (detail) | same | same |
| `VodView.play(_:flag:)` | same | same |

Rejected: a protocol with two conformances (an enum is shorter and `Sendable` without ceremony),
and any factory or DI indirection.

### Three things the spider branch must not copy from the CMS branch

1. **Home needs the type-4 fallback.** `XBPQ.homeContent` always returns an empty list and
   `XYQHiker` fills one only when its rule file sets 首页推荐链接, so a spider home would render an
   empty grid. `SourceClient.home` lists the first browsable category instead — the same thing a
   type-4 home already does. `CMSView` extends its chip-highlighting condition to `site.isCSPSpider`
   for the same reason.
2. **`episode.mediaURL` must not gate playback.** A spider episode target is frequently not a URL
   (`parse_api=…&url=…`); `playerContent` is what turns it into one. The CMS branch keeps its
   pre-check, the spider branch does not.
3. **`parse:1` is not playable here.** It means "open in a browser and sniff the media out", which
   needs a WebView sniffer this app does not have. `playbackURL` returns nil so the UI says
   「這一集沒有可播放的網址。」 rather than handing AVPlayer a web page.

### Session reuse

`SpiderSessionStore` keeps one `SpiderSession` per site key. A spider is stateful where `CMSClient`
is not: `SpiderSession` guarantees `init(extend)` runs exactly once, and that call is where a
rule-engine site downloads and parses its rule file. The app builds a client on every listing, page,
search and episode, so without the store a single XBPQ browse would re-download the rules a dozen
times. `adopt` resets the store when a configuration is replaced, so no spider survives holding a
dropped site's `ext`, cookies or rules.

### Config source threading

`HomeView`, `CMSView` and `VodView` now take a `ConfigSource`, used for nothing except letting
`CSPSourceResolver` resolve a rule-engine site's relative `ext` (`./json/农民影视.json`) against the
configuration's own directory. `restore()` reads a local variable rather than the `@State` it just
wrote, because resolving against the wrong base silently breaks those three sites.

## Xcode 27 build repair (scope expanded with explicit user approval)

The machine's toolchain moved to **Xcode 27 / Swift 6.4** during this task, and the project stopped
building at `80858655` — reproduced in a clean worktree, so it was never a defect in this change.
Swift 6 region isolation now rejects sending non-`Sendable` values across an isolation boundary:

- `JavaScriptSpiderRuntime.call` returned a `JSValue` through a continuation. Fixed by serialising
  inside the queue so **`JSValue` never leaves it** — which is what the ABI wanted anyway, since
  every `Spider.java` method is text in, text out. `call` is gone; `text` is the only path.
  `isVideoFormat` / `manualVideoCheck` read the boolean from that text, because
  `JSON.stringify(true)` is `"true"` and a second helper would have earned nothing.
- The WebHome bridge sent a `[String: Any]` payload into the nonisolated `handle`. Fixed by moving
  the call into a `nonisolated static func respond`, where the dictionary is built and consumed in
  one region; only JSON text in and script text out cross the boundary.

`JavaScriptSpiderRuntime.swift` was outside the declared guard scope. The user was shown the
blocker and the verified fix and approved expanding the scope, so the path was appended to the
guard's scope list; every other guard check ran unchanged.

## Verification

Config restored from the user's own GitLab after `/tmp` was cleared; SHA-256
`b17576e34eb42b4c589a818ef8b5ec2655a2c7a188d626fc427c37d628897168`, matching the recorded baseline
byte for byte, 167 sites.

- `swift test --package-path ios` with `WANG_MOVIE_JSON` → **64 tests, 62 pass** (57 before; +5 in
  `SourceClientTests`, +1 sweep, +1 lenient-JSON). **Both failures are live-network provider state,
  not regressions**, and both were reproduced at `80858655` in a clean worktree:
  `reportsLiveType4SitesFromProvidedConfig` (88看球 resolves to an HTML play page) and
  `completesLiveCMSFlowFromProvidedConfig` — `cj.rycjapi.com` now answers its first title
  一瓯春 with `vod_play_from: "rym3u8$$$ruyi"` but `vod_play_url: "$$$"`, i.e. no episode URLs at
  all. Neither touches any code this stage changed. Do not "fix" either.
- `xcodebuild … -scheme WebHTVApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
  -configuration Debug build` → **BUILD SUCCEEDED**.
- New tests in `SourceClientTests.swift`: routing (CMS vs spider vs unregistered-throws), session
  reuse and reset, the CatVod shapes the three spiders return, the `parse` envelope including its
  string-encoded form, and that the app's site list is 45 = 30 native + 15 spider with unique keys.
- `SpiderHostTests.parsesTheLenientJSONRealRuleFilesActuallyContain` covers the Gson-lenient parse:
  comments, a `//` inside a string, block comments, trailing commas, and unparseable text mapping
  to null rather than an empty object.

### Full sweep of all 15 spider sites

The first report of this stage said "15 sites work" on the strength of four hand-checked sites. The
user then sent screenshots of three broken ones, which was correct and the earlier claim was not.
`sweepsEveryPortedSpiderSiteThroughTheAppPath` now drives **every** configured spider site through
`SourceClient` — the same path the app uses — and reports where each stops:

```
SPIDER_SWEEP_CONFIG=<wang-movie.json> SPIDER_SWEEP_BASE=<its remote URL> \
  swift test --package-path ios --filter sweepsEveryPortedSpiderSite
```

Measured 2026-09-17. Counting each configured site separately: **3 of 15 browse and play end to
end, 7 fail on provider state** (including AG動漫, whose media 404s after a clean resolve), **and
5 stop somewhere in our own code.**

| site | class | classes | home | detail | play | verdict |
|---|---|---:|---:|---|---|---|
| 王子 | AppGet | 6 | 2 | 20 flags / 24 eps | m3u8 | **works** |
| 农民 (`csp_Wwys`) | XYQHiker | 5 | 12 | 2 flags / 14 eps | played in simulator | **works** |
| 果果短剧 | XBPQ | 8 | 30 | 1 flag / 1 ep | m3u8 | **works** |
| AG動漫 | XBPQ | 5 | 12 | 1 flag / 149 eps | m3u8 → **HTTP 404** | provider |
| 猎豹 | AppGet | 0 | 0 | — | — | provider, host **522** |
| 方舟动漫 | AppGet | 0 | 0 | — | — | provider, host **403** |
| 歐樂影院ORG | XBPQ | 5 | 0 | — | — | provider, host **522** |
| YLSP / 永乐影视 | XBPQ | 4 | 4 (category links, not titles) | 0 flags | — | provider, listing URL **404** |
| 天天動漫 | XBPQ | 5 | 0 | — | — | provider redirects (**301**), unconfirmed |
| **If101** | XBPQ | 4 | **0** | — | — | **ours** — the listing page answers 200 with 27 KB |
| **動漫巴士 / 巴士动漫** | XYQHiker | 4 | 8 | **0 flags** | — | **ours** — browse fixed here, detail still empty |
| **不戳** | AppGet | 8 | 3 | 1 flag / 1 ep | **two URLs concatenated** | **ours** |
| **灵虎** | AppGet | 8 | 8 | 8 flags / 24 eps | **nil** | **ours** |

Provider verdicts were confirmed with `curl` against the exact URL the spider builds, not inferred
from an empty screen.

#### Fixed here: rule files are not strict JSON

`巴士动漫.json` and `動漫巴士.json` comment keys out with `//`. The Android originals parse rule
files with Gson, which tolerates comments and trailing commas; `JSON.parse` does not, so both sites
silently became `rule = {}` — zero categories, an empty screen indistinguishable from a dead host.
`host.parseJSON` is now Gson-lenient (strips `//` and `/* */` outside strings, drops trailing
commas, returns null rather than `{}` when the text is genuinely not JSON) and both engines use it.
Those two sites went from 0 categories to 4 categories and 8 titles. Their **detail** still returns
no flags, which is a separate unfixed issue. (Corrected 2026-09-25: fixed in IOS-POC-5F, which took
both to a detail page with 158 episodes, and IOS-POC-5G's sniffer made both playable — see
`docs/IOS-POC-5F-spider-defect-fixes.md` and `docs/IOS-POC-5G-media-sniffer.md`.)

### Simulator, end to end (iPhone 17 Pro, iOS 26.3)

| what | result |
|---|---|
| Settings caption | 「目前支援 45 個來源」 |
| Site picker | the 15 spider sites appear after the 30 native ones |
| **农民 (XYQHiker)** | 6 categories → real posters → 交锋 detail, 2 flags × 24 episodes → **第01集 played, picture advanced from title card to scene** |
| **AG動漫 (XBPQ)** | 5 categories → real posters → 金田一少年事件簿, 149 episodes → player opened, no picture (the 404 above) |
| **王子 (AppGet)** | 6 categories → real posters, home carries its own list (no fallback path) |
| 方舟动漫 (AppGet) | 「沒有內容」, matching its 403 |

**This also proves the XYQHiker caveat is only a caveat**: 农民's `ext` is the relative
`./json/农民影视.json`, and it resolved correctly in the app because the configuration came from a
remote URL. With an imported local file those three sites still cannot resolve their rule file.

## Known limits and follow-ups

- **`header` from a spider play result is dropped.** `AVPlayer` takes request headers only through
  `AVURLAsset` options, which `PlayerView` does not thread through. A CDN that checks Referer will
  fail to play, visibly. No configured site has been observed needing it yet — AG動漫's failure is a
  404, not a header rejection. (Corrected 2026-09-25: no longer dropped — IOS-POC-5P (`0414c032`)
  carries the play result's headers into `AVURLAsset`; see `docs/IOS-POC-5P-player-request-headers.md`.)
- **A site whose own category list contains 「全部」 shows two 「全部」 chips** (王子 does). The app adds
  its own, and `categoryGroups` keeps the provider's. This is pre-existing rendering behaviour that
  only became visible now that spider sites are listed; it is not introduced here and is left alone.
  (Corrected 2026-09-25: fixed in IOS-POC-5J (`d786c627`), and since `f34ae805` the app adds no
  「全部」 of its own, so a provider's own entry is the only one shown — see
  `docs/IOS-POC-5J-category-filters.md`.)
- `parse:1` and the `proxy` ABI remain unimplemented, as does `CatVodHost` RSA — `csp_AppDrama`
  still needs it. (Corrected 2026-09-25: a `parse:1` result is now sniffed by the IOS-POC-5G
  `MediaSniffer` — `ios/Sources/WebHTVCore/SourceClient.swift:116`. The `proxy` ABI and `CatVodHost`
  RSA remain unimplemented.)
- Still simulator-only. The project has no `CODE_SIGN` or `DEVELOPMENT_TEAM`; nothing here says
  anything about a real device. (Corrected 2026-09-25: the app first ran on a real device on
  2026-09-18 (`ed3f2709`) and now ships through SideStore — `docs/IOS-POC-11-sidestore-release.md`.
  The project still carries no `CODE_SIGN` or `DEVELOPMENT_TEAM`.)

## Files

| file | change |
|---|---|
| `ios/Sources/WebHTVCore/SourceClient.swift` | new — the enum, the play envelope, the session store |
| `ios/Sources/WebHTVCore/Spider/JavaScriptSpiderRuntime.swift` | Xcode 27 repair: `JSValue` stays on the queue |
| `ios/WebHTVApp/Sources/WebHTVApp.swift` | site list, 4 call sites, `ConfigSource` threading, caption, bridge isolation |
| `ios/Tests/WebHTVCoreTests/SourceClientTests.swift` | new — 5 tests |
