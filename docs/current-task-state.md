# Current Task State

## Original Goal

- Port WebHomeTV to iPhone/iOS with an Android-like UI, use the newest user-provided `wang-movie.json`, and offer built-in, Infuse, Fileball, SenPlayer, and VidHub playback choices. The Google TV `csp_JPianAmns` repair is not in scope.
- Completed this session: IOS-POC-4A (type-4 CatVod remote API sources), IOS-POC-4B (ATS cleartext decision), IOS-POC-4E (bounded request timeout), IOS-POC-4F (category browsing), IOS-POC-4G (two-level categories).

## Current Scope

- Branch `ios-poc`, HEAD `326b70d2` before this closure commit. Three commits from this session are unpushed: `84213fd4` (type-4), `10967eae` (ATS), `326b70d2` (handoff refresh).
- `origin/ios-poc` currently resolves to `2c1c2a35`, this session's starting point. Nothing was pushed or fetched here, so treat the real remote state as unconfirmed and re-check on resume.
- Recovery tags this session: `recovery/IOS-POC-4A/20260915160547-84213fd4cef7`, `recovery/IOS-POC-4B/20260915162727-10967eae5cbc`, `recovery/IOS-POC-4C/20260915162834-326b70d2b992`.

## Non-Negotiable Constraints

- Preserve Android `main`, unrelated/dirty user files, and the repository's task-guard/Ponytail/research/approval gates. Do not push, sign, package, or publish without user authorization.
- No jailbreak, always-on self-hosted server, or recurring infrastructure cost for the personal iPhone path. No unapproved DEX/JAR, Python, or type-3 support claim.
- **ATS: superseded by explicit user decision.** The earlier "do not weaken TLS/ATS globally" rule was put to the user on 2026-09-15 with a recommended narrow alternative; the user chose global cleartext, so `NSAllowsArbitraryLoads` is now shipped. Keep it, but do not broaden further (no server-trust override, no certificate pinning bypass) without a fresh decision.

## Important Decisions

- Input is the replacement Recha `wang-movie.json`: 125,864 bytes, SHA-256 `b17576e34eb42b4c589a818ef8b5ec2655a2c7a188d626fc427c37d628897168`, 167 sites (2 type-0, 22 type-1, 137 type-3, 6 type-4). The archive is external, not committed.
- The user chose type-4 source coverage over a WebHome bridge proof, because the current JSON contains no WebHome entry and a bridge would have added zero usable sources from it.
- Type-4 support extends `CMSClient` rather than adding a second client. Its only structural difference from type-1 is that a type-4 home returns categories, so the first category is fetched to fill the poster grid.

## Files Modified This Session

- `ios/Sources/WebHTVCore/WebHTVConfig.swift`, `ios/Sources/WebHTVCore/CMSClient.swift`, `ios/WebHTVApp/Sources/WebHTVApp.swift`, `ios/Tests/WebHTVCoreTests/CMSClientTests.swift`, `ios/Tests/WebHTVCoreTests/ConfigLoaderTests.swift` (IOS-POC-4A).
- `ios/Sources/WebHTVCore/ConfigLoader.swift`, `ios/Sources/WebHTVCore/CMSClient.swift`, `ios/Tests/WebHTVCoreTests/CMSClientTests.swift` (IOS-POC-4E).
- `ios/Sources/WebHTVCore/CMSClient.swift`, `ios/WebHTVApp/Sources/WebHTVApp.swift`, `ios/Tests/WebHTVCoreTests/CMSClientTests.swift` (IOS-POC-4F and IOS-POC-4G).
- `ios/WebHTVApp/Info.plist` (new), `ios/WebHTVApp/WebHTVApp.xcodeproj/project.pbxproj` (IOS-POC-4B).
- `docs/IOS-POC-4A-type4-sources.md` (new, holds the full plan and evidence), `docs/AGENT_HANDOFF.md`, this file.

## Completed Work

- Category browsing: a parent chip row plus a child row when the selected parent has children, driven by one `category(id:page:)` call that both type-1 and type-4 accept with the same `t=` / `pg=` contract. Type-1 also gets a 全部 chip for its default home listing; type-4 has none because its home is already its first category. An empty-but-successful response renders a "沒有內容" state instead of a blank screen.

- The app now exposes 28 sources from the 167-site config: 22 type-1 plus 6 type-4. Persistence, wallpaper, player choices and the POC-3C Logo removal are unchanged.
- Type-4 home fetches categories then the first category; web-page episodes resolve through `?play=&flag=` before reaching the player, so an HTML page is never handed to AVPlayer; `Site.ext` decodes leniently because its string and numeric forms would otherwise throw.
- Root-cause fix in the shared `Vod` decoder: `vod_id` and `vod_name` are no longer required. `爱瓜TV` answers `ac=detail` without them, which previously discarded the whole record and left an empty episode list with no error.

## Build / Test / Verification Status

- `WANG_MOVIE_JSON=/tmp/webhtv-recha-new.wprHof/wang-movie.json swift test --package-path ios` → 13 tests pass, including the pre-existing 5 and a type-1 request-shape regression test.
- `xcodebuild -project ios/WebHTVApp/WebHTVApp.xcodeproj -scheme WebHTVApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build` → BUILD SUCCEEDED.
- Simulator, verified end to end: `爱瓜TV` poster grid → 莲花楼 detail with 41 episodes → episode 01 plays video in the built-in player. Type-1 `如意` and `360` grids load.
- Category browsing verified in the simulator across all three shapes: `如意` 电影片 opens a child row and 动作片 lists titles; `如意` 电影解说, a childless parent, hides the child row and lists by its own id; type-4 `爱瓜TV` stays a single row with no 全部 chip. `drpyS_听友[听]` renders its row and the empty state explains the blank result.
- Live protocol run over all 6 type-4 sites, second pass at 16:5x when every host was up: `爱瓜TV`, `采集集合`, `drpyS_枫林影视` and `88看球` all resolved to direct `.m3u8`. `drpyS_枫林影视` is the live confirmation of the `?play=&flag=` resolution path. `php_无水印资源` answered with no categories, and `drpyS_听友[听]` returned 43 categories whose first one is empty.
- Request timeout measured directly against a non-routable address: 10.0 s with the configured session versus 60.0 s on `URLSession.shared`. The same live sweep fell from about 150 s to 19.9 s, though that run also benefited from every host being reachable.

## Risks / Unverified

- **Not measured: that HTTPS certificate validation is still enforced.** It is reasoned from the code — no `URLSessionDelegate`, no `serverTrust` handling anywhere, so `URLSession.shared` keeps default system trust evaluation — but no test against a known-bad certificate was run. The intended candidate turned out to present an acceptable chain and the `360` before/after comparison collapsed when that site recovered.
- Remote reachability is highly volatile; `itv666.cc` went from HTTP 200 to DNS failure within ten minutes. Never treat one site's failure as a global app defect.
- `URLSession.webHTV` in `ConfigLoader.swift` caps request inactivity at 10 s for every WebHTV API call. A type-4 home issues two sequential requests, so its worst case is about 20 s. This is an inactivity timeout, not a total-transfer cap; `timeoutIntervalForResource` was left at its default because no observed source trickles data slowly. AVPlayer playback is unaffected — it does not use this session.
- Category browsing has a parent row and a child row. `categoryGroups` pairs each `type_pid == 0` entry with its children; a source with no `type_pid` at all becomes childless groups and renders as one row. Probed 2026-09-15: no orphan children, no third level, and childless parents such as `360zy` 伦理片 (1641 titles) and `如意` 电影解说 (13836) do list by their own id, which is why a parent chip targets its first child when it has one and itself otherwise. `天涯` is a flat type-1 source, so flatness is not a type-4-only shape.
- `drpyS_听友[听]` returns an empty list for every one of its 43 categories when probed directly with the correct numeric ids, so its blankness is the provider's own state, not a browsing defect.
- The direct-media test is a path-extension heuristic, marked with a `ponytail:` comment in `CMSClient.swift`.
- `php_无水印资源` returns an empty grid; over a system-trust client the endpoint completes TLS and answers HTTP 403, so this is the provider's own response.
- Still not implemented: type-0 XML (2 sites), type-3 Spider/Python/DEX (137 sites), WKWebView/WebHome bridge, SideStore/IPA delivery.

## Next Recommended Step

- Agree one bounded stage with the user. Ranked candidates:
  1. **Device deployment.** The Xcode project has no `CODE_SIGN`/`DEVELOPMENT_TEAM` settings at all, so nothing has ever run on the user's iPhone; everything to date is simulator-only. Needs the user's Apple ID and device, and the free-provisioning 7-day expiry versus a paid account versus SideStore is still an open question.
  2. **Pagination.** Every category shows only page 1. `category(id:page:)` already takes a page, so only the view needs it.
  3. type-0 XML (2 sites, needs an XML parser; both endpoints answered HTTP 200 on 2026-09-15).
- Type-3 is mostly unreachable, not merely unimplemented: of 137 sites, 90 are `csp_` DEX/JAR and 42 are Python, both needing an Android runtime. Only 5 are drpy JavaScript, which iOS JavaScriptCore could plausibly host. Do not describe all 137 as pending work.

## Resume Prompt

> Continue the WebHomeTV iPhone port in `/Users/chengchenchih/GIT/webhtv` on the actual `ios-poc` Git state; check `git log` and `git status` first rather than trusting any commit id quoted here. Three commits from the 2026-09-15 Claude session (`84213fd4`, `10967eae`, `326b70d2`) plus a closure commit were left unpushed, and the remote state was never fetched. Read `AGENTS.md`, `docs/AGENT_HANDOFF.md`, this file, and `docs/IOS-POC-4A-type4-sources.md` for the type-4 stage evidence. The app now exposes 28 of the 167 configured sources (22 type-1 + 6 type-4), persists the imported JSON and selected source, offers built-in/Infuse/Fileball/SenPlayer/VidHub players, and ships `NSAllowsArbitraryLoads` because the user explicitly chose global cleartext on 2026-09-15 after being offered a narrower per-domain option — keep that, and do not broaden transport security further without a fresh decision. Do not resume the Google TV `csp_JPianAmns` repair. Type-0 XML, type-3 Spider, and the WebHome bridge are not implemented, and this JSON contains no WebHome entry. Confirm the next bounded stage with the user before any functional edit. Preserve dirty files, Android `main`, and the task-guard/Ponytail gates. Site reachability is volatile — verify per site and never generalise one failure into a global app defect.
