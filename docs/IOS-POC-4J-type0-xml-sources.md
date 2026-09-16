# IOS-POC-4J — type-0 MacCMS XML sources

## Recovery anchor

- Branch `ios-poc`, baseline HEAD `46a00eb4`, clean worktree, ahead 2 of `origin/ios-poc` (2026-09-16 15:40 CST).
- Objective: make the configuration's two `type` 0 sites browsable and playable, on the same path the type-1 and type-4 sources already use.
- Status: COMPLETE. A1-A5 pass offline; B1-B5 verified in the simulator against both live endpoints.
- Exactly one next action: agree the next bounded stage with the user.

## Completion sentence

`vod_蜜雪` and `魔都` appear in the source list and drive the existing grid, category rows, pagination, search, detail and player, taking the supported count from 28 to 30 of 167.

## Allowed paths

- `ios/Sources/WebHTVCore/MacCMSXML.swift` (new)
- `ios/Sources/WebHTVCore/CMSClient.swift`
- `ios/Sources/WebHTVCore/WebHTVConfig.swift`
- `ios/Tests/WebHTVCoreTests/MacCMSXMLTests.swift` (new)
- `ios/Tests/WebHTVCoreTests/ConfigSourceTests.swift` (two count assertions)
- `docs/IOS-POC-4J-type0-xml-sources.md`, `docs/current-task-state.md`, `docs/AGENT_HANDOFF.md`

Protected pre-existing dirty paths: none. Android `app/` is read-only and read for contract evidence only.

## Estimate

Agent elapsed wall-clock, from 15:40 CST.

| Phase | Estimate |
|---|---|
| XML decoder + client wiring | ~30 min |
| Offline tests | ~20 min |
| Simulator verification of both sites | ~25 min |
| Docs, Ponytail, commit, tag | ~15 min |

Total ~90 min; expected finish ~17:10 CST. If a provider stops answering mid-session, verify the other one and record the outage rather than extending the task — remote reachability has already proven volatile here.

## Evidence — read from the live endpoints and from Android

Both sites answered on 2026-09-16:

- `https://caiji.moduapi.cc/api.php/provide/vod/at/xml/` — 88 707 records, 4 436 pages.
- `http://www.mixuetv.top/api.php/provide/vod/at/xml` — 112 173 records, 5 609 pages.

**type-0 is the same MacCMS contract as type-1, carried in XML instead of JSON.** Verified against the live endpoints, not assumed:

| Form | Result |
|---|---|
| plain request | `<class><ty id="1">国产动漫</ty>…</class>` plus a brief list. The only form carrying the categories. |
| `?ac=videolist` | full records with `<pic>` and `<dl><dd flag="…">`, and **no `<class>`** — the same split type-1 has between `ac=detail` and the plain form. |
| `?ac=videolist&t=26&pg=2` | `<list page="2" pagecount="239" recordcount="4775">`, paginates normally. |
| `?ac=videolist&wd=熔城` | 1 record, with pic and `dl`. |
| `?ac=videolist&ids=89511` | one `<video>`, `<dd flag="modum3u8">` holding 13 episodes. |

Episode encoding is **identical** to type-1: `第01集$https://…m3u8`, `#` between episodes, one `<dd>` per flag. So `Vod.flags`, `Episode.parse` and the whole player path apply unchanged.

The action name differs. `SiteApi.ac(int type)` (`app/src/main/java/com/fongmi/android/tv/api/SiteApi.java:53-55`) returns **`videolist` for type 0** and `detail` for everything else, and `Result.fromType` (`bean/Result.java:129-131`) sends type 0 to `fromXml` and everything else to `fromJson`. Both live endpoints also accept `ac=detail`, but `videolist` is what Android sends and what older XML providers expect, so it is what this port sends.

### Android's poster mechanism, and why this port does not copy it

`SiteApi.fetchPic` (`:231-244`) notices an empty `pic` and issues a **second** request with `ac=…&ids=<comma-joined>`. This port already solved the same problem differently for type-1 in IOS-POC-4I: ask the listing itself for the detailed form. That keeps one request per page instead of two and is already proven, so type-0 reuses it.

## Alternatives considered

| Option | Verdict |
|---|---|
| **No change** | Rejected. The user selected this stage; 2 configured sites are unreachable without it. |
| **A second client** (`XMLCMSClient`) beside `CMSClient` | Rejected. The query building, pagination, category grouping, search, detail and playback resolution are byte-for-byte the same; a parallel client would duplicate all of it to change one decoder. |
| **A third-party XML library** | Rejected. `XMLParser` is in Foundation. No dependency earns its place here. |
| **`XMLDocument` tree parsing** | Rejected — macOS only, not available on iOS. |
| **Regex over the payload** | Rejected. CDATA, nesting and attribute quoting make it wrong in ways that fail silently on real data. |
| **Narrow adapted** — keep `CMSClient`, swap only the decoder, widen the type guards | **Chosen.** |

## Design (Ponytail pre-review)

The whole stage is one new decoder plus type guards widened from `== 1` to `== 0 || == 1`:

- **Reuse over new code.** `CMSResponse`, `CMSCategory`, `Vod`, `Flag`, `Episode`, `categoryGroups`, `firstListableCategory`, `merging(newTitlesFrom:)`, `requestURL`, `playbackURL` and the entire SwiftUI surface are untouched. The XML decoder produces the *same* `CMSResponse` the JSON decoder produces, so nothing downstream can tell the difference.
- **Stdlib.** `XMLParser` (Foundation), SAX-style. ~70 lines of delegate, no dependency.
- **One action helper**, mirroring `SiteApi.ac`: `detailAction` is `"videolist"` for type 0 and `"detail"` otherwise. `listingQuery`, `search` and `detail(id:)` all route through it instead of hardcoding `"detail"`.
- **`<class>` has no parent ids**, so `categoryGroups` already renders these as childless groups — one category row, exactly as type-4 and 天涯 do today. No new UI.
- New file `MacCMSXML.swift`: the repo keeps one concern per file, and an `XMLParserDelegate` does not belong inside the model/client file.

### Memberwise initialisers, and a note on IOS-POC-2E

The decoder has to build `CMSCategory` and `Vod` from parsed strings, and both types declare `init(from decoder:)`, which suppresses the memberwise init. So each needs one.

`Vod` already gained `init(id:name:picture:)` in IOS-POC-2E, where the Ponytail review **trimmed** `remarks`, `playFrom` and `playURL` as parameters no caller passed. The XML decoder is the caller that now needs all three, so they come back. That is the intended sequence — YAGNI defers work until something needs it — not a reversal of that review.

### Deviations from Android, to be commented in code

1. Posters come from `ac=videolist` on the listing itself rather than Android's second `ids=` round trip, matching what IOS-POC-4I already does for type-1.
2. `<list>`'s `page`/`pagecount`/`recordcount` attributes are ignored, as they are for JSON: pagination stops when a page contributes no new `vod_id`.
3. Fields outside the model — `last`, `tid`, `dt`, `lang`, `area`, `year`, `state`, `actor`, `director`, `des` — are parsed past and dropped, because nothing downstream reads them.

## Acceptance criteria

Offline:

- A1. `swift test --package-path ios` passes; the two `supportedSites.count == 28` assertions become 30 and no other existing test changes meaning.
- A2. The decoder turns a real-shaped payload into the categories and the video list, with `id`, `name`, `picture` and `remarks` mapped from `<id>`, `<name>`, `<pic>`, `<note>`.
- A3. One `<dd flag="x">` becomes one `Flag` whose episodes split on `#` and `$`; two `<dd>` become two flags, matching the `$$$` encoding `Vod.flags` expects.
- A4. CDATA and plain text both decode, and a malformed payload yields an empty response rather than throwing.
- A5. `WebHTVConfig.supportedSites` includes type 0, and `CMSClient(site:)` no longer rejects it.

Simulator:

- B1. Debug build succeeds and the source list shows 30 sources.
- B2. `魔都动漫` opens a grid with real posters and a category row, and pagination loads past the first page.
- B3. A title opens its detail screen with episodes, and one episode plays in the built-in player.
- B4. `夢想網頁版` (the second type-0 site) also loads a grid.
- B5. Regression: a type-1 and a type-4 source still browse and play, and the WebHome bridge is untouched.

## Out of scope

Python, JAR/DEX, JS Spider, CarPlay, `pan.*`, the remaining WebHome methods, filters (`<class>` carries no filter data), and signing or IPA delivery. The 28 existing sources, Remote Raw Config, the LKG cache, the resource resolver and Android `main` must be untouched.

## Rollback

One commit plus a `recovery/IOS-POC-4J/*` tag. Additive: one new file, one new decoder branch, widened type guards. Reverting restores `46a00eb4` with no config or data migration.


## Verification result (2026-09-16)

### Offline — 42 of 43 pass

`WANG_MOVIE_JSON=/tmp/webhtv-recha-new.wprHof/wang-movie.json swift test --package-path ios` →
**43 tests, 42 pass**. 39 existed at `46a00eb4`; this stage adds 4.

- A1 pass, with one correction to the claim this plan made. Two `supportedSites.count` assertions moved 28 → 30 as expected, but a third test **did** change meaning: `validationRefusesPayloadsThatMustNotReplaceAGoodCache` built its "decodes but drives nothing" fixture out of a type-3 *and a type-0* site, which this stage makes usable, so the payload stopped being useless and the expected throw stopped happening. The test's intent is still right, so the fixture now uses a type-3 Spider and a type-2, neither of which is a native CMS at all. The plan's "no other existing test changes meaning" was wrong.
- A2 pass (`decodesTheMacCMSXMLShapeIntoTheSameResponseJSONSitesProduce`).
- A3 pass (`turnsEachDdIntoAFlagWhoseEpisodesSplitLikeTypeOne`, covering one `<dd>` and two).
- A4 pass (`readsPlainTextAsWellAsCDATAAndSurvivesAMalformedPayload`).
- A5 pass (`buildsTheTypeZeroQueriesAndroidSends`, asserting `videolist` and the query shape).

**The one failure is not from this stage.** `reportsLiveType4SitesFromProvidedConfig` is the live-network smoke test that was already failing at `588cb85a` and `e1db99d8`: `88看球` resolves an episode to an HTML page and the test asserts `isDirectMedia`. Today it resolved to `http://sports.cctv.com/H5/CCTV5/index.shtml` rather than yesterday's `play.sportsteam368.com` URL — the same defect, different live content. Provider state, out of scope.

### Build

`xcodebuild … -scheme WebHTVApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build` → **BUILD SUCCEEDED**.

### Simulator — iPhone 17 Pro, both live endpoints

- **B1 pass.** The source list carries both type-0 sites and the footer reads **"目前支援 30 個 type-0／type-1／type-4 CMS 來源"**.
- **B2 pass.** `魔都动漫` opens a grid of real posters with `<note>` badges (`更新至20260915期`, `更新至10集`, `更新至13集`) and a category row from `<class>` (全部 / 国产动漫 / 日韩动漫 / 欧美动漫 / 港台…). Scrolling loaded page 2 and beyond — 死有对证国语/粤语, 一念永恒完结季, 特战英雄榜 are all past the first 20 records.
- **B3 pass.** `熔城` opens with the `modum3u8` flag from `<dd flag>` and all **13** episodes, matching what the endpoint returns for `ids=89511`, and 第01集 **played in the built-in player** (the 「1939年6月 榕城 琅岐岛」 title card).
- **B4 pass.** `夢想網頁版` — the second type-0 site, a different provider — opens its own grid with its own categories (电影 / 电视剧 / 综艺 / 动漫 / 国产剧) and the titles the endpoint lists (惩罚者2026, 审判萨达姆, 第六感: B side, 永恒之家).
- **B5 pass.** Regression: type-1 `360` and type-4 `愛瓜` both still load grids with posters, categories and badges. The WebHome bridge was not touched by this stage.

### Ponytail

**Pre-review** is the Design section above. Its findings shaped the stage before any code: reuse `CMSClient` whole rather than add a second client, use Foundation's `XMLParser` rather than a dependency (and not `XMLDocument`, which iOS lacks), and treat the whole thing as one decoder plus widened type guards.

**Final-diff review — PASS, no material finding.** What was examined and deliberately left alone:

- `site.type == 0 || site.type == 1` now appears in two query builders. That widens a two-term condition the file already had rather than introducing new duplication, and a helper for two call sites would not pay for itself.
- `Vod.init` regained `remarks`/`playFrom`/`playURL`, which the IOS-POC-2E review had trimmed as unused. Both callers are now real, which is YAGNI working as intended rather than a reversal.
- `MacCMSXMLDecoder` is a mutable class because `XMLParserDelegate` requires one; the instance is created inside `decode` and never escapes, so nothing crosses an isolation boundary.

### Scope widened mid-task, recorded

The guard was started without `ios/WebHTVApp/Sources/WebHTVApp.swift` in scope. Adding type-0 made the Settings footer's "type-1／type-4" wording wrong — a user-visible string this stage itself invalidated — so the path was added to the guard's scope file and the label corrected. The guard does not support re-declaring scope while a task is active; the alternative was shipping a string known to be wrong or splitting one logical change across two commits. Declaring it correctly at `start` would have been better.

### Known limits

- Only the two configured type-0 endpoints were exercised. A provider sending a non-UTF-8 encoding would fail to parse and yield an empty response — the same fallback `Result.fromXml` has on Android — rather than being transcoded.
- `<class>` carries no filter data, so type-0 has no filters, the same as every other source here.
- Both endpoints also accept `ac=detail`; this port sends `videolist` because that is what `SiteApi.ac` sends.
- **Simulator only.** Still no `CODE_SIGN` or `DEVELOPMENT_TEAM`; nothing has run on a real device.
