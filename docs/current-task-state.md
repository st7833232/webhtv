# Current Task State

## Original Goal

Port WebHomeTV to iPhone with an Android-like UI, drive the user's own `wang-movie.json`, and offer built-in, Infuse, Fileball, SenPlayer and VidHub playback. The Google TV `csp_JPianAmns` repair is not in scope.

## Current Scope

- Branch `ios-poc`, baseline HEAD `e1db99d8` before the IOS-POC-2E commit, level with `origin/ios-poc` at that point. Re-check with `git log` rather than trusting these ids.
- Android `app/` is read-only for all iOS work and has never been modified.
- Every stage below has an annotated `recovery/<task-id>/*` tag. Tags through `IOS-POC-1H` are on the remote.

## Non-Negotiable Constraints

- Preserve Android `main`, unrelated dirty files, and the repository's task-guard / Ponytail / research / approval gates. Do not push, sign, package or publish without user authorization.
- No jailbreak, always-on self-hosted server, or recurring infrastructure cost for the personal iPhone path.
- **ATS: superseded by explicit user decision (2026-09-15, IOS-POC-4B).** The user was offered a narrow per-domain exception, no change, or global cleartext, was told the earlier records forbid weakening ATS globally for one site, and chose global cleartext. `NSAllowsArbitraryLoads` ships. Keep it; do not broaden further — no server-trust override, no pinning bypass — without a fresh decision.
- Do not claim iOS can execute Python, JAR/DEX or JS. No Spider runtime exists.

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

## Important Decisions

- Input baseline: Recha `wang-movie.json`, 125,864 bytes, SHA-256 `b17576e34eb42b4c589a818ef8b5ec2655a2c7a188d626fc427c37d628897168`, 167 sites (2 type-0, 22 type-1, 137 type-3, 6 type-4). The archive itself is external, not committed.
- **Of the 137 type-3 sites, 132 are structurally out of reach on iOS**, not merely unimplemented: 90 are `csp_*` DEX/JAR and 42 are Python. Only 5 are drpy JavaScript, which iOS JavaScriptCore could plausibly host. Never describe all 137 as pending work.
- With type-0 done (IOS-POC-4J), **every non-Spider source type in this configuration is supported**. The only remaining unsupported sites are the 137 type-3 entries.
- The WebHome JS SDK is injected by the app, not shipped by pages: pages only touch `window.fm` / `window.fongmi`. Porting the bridge therefore means porting `HomeWebController.getSdk()`, not designing an API from the method list.
- Core names no hosting provider. A remote config source is an HTTPS URL and nothing more; GitLab and GitHub appear only in test and verification data.

## Completed Work

### Sources and browsing

- **30 of the 167 configured sources are usable: 2 type-0, 22 type-1 and 6 type-4.**
- type-0 is the same MacCMS contract as type-1 carried in XML, so it reuses `CMSClient` whole and changes only the decoder. `MacCMSXMLDecoder` (Foundation `XMLParser`, no dependency) turns `<class><ty>` into the categories and `<video>` into `Vod`, with `<dd flag>` becoming the flags through the same `$$$` encoding. The one query difference is `ac=videolist` instead of `ac=detail`, matching `SiteApi.ac(int)`. `XMLDocument` is macOS-only and is not an option on iOS. Type-4 extends `CMSClient` rather than adding a second client; its only structural difference is that its home returns categories, so the first browsable category fills the grid.
- Web-page episodes resolve through `?play=&flag=` before reaching the player, so an HTML page is never handed to AVPlayer.
- Category browsing has a parent row and a child row. `categoryGroups` pairs each `type_pid == 0` entry with its children; a source without `type_pid` becomes childless groups and renders as one row. A parent chip targets its first child when it has one and its own id otherwise, because childless parents do list content that way.
- Pagination loads the next page when the last card appears, for home, category and search. It stops when a page contributes no new `vod_id` rather than trusting page metadata, which also ends the loop for a source that ignores `pg`.
- Type-1 listings request `ac=detail`, the only form that carries `vod_pic`. That form drops `class`, so a type-1 home issues the plain and detail requests concurrently.
- Root-cause fix in the shared `Vod` decoder: `vod_id` and `vod_name` are optional, because `爱瓜TV` answers `ac=detail` without them and requiring them discarded the whole record.

### Playback

- The built-in player is a full-screen cover with its own close control, not a push inside the picker sheet. A page sheet is inset and rounded, so the player used to inherit those bounds and the app wallpaper showed around the video. Letterbox bars for a 16:9 video in a portrait screen are correct aspect-ratio behaviour and are left alone; the player now draws them on its own black background.

### Configuration

- The configuration comes from an imported file or any HTTPS Raw URL. `ConfigSource.resourceURL(for:)` resolves `./jar/…`, `./py/…`, `./json/…`, `./drpy_libs/…` against the config's own directory, drops the `;md5;<hash>` suffix, passes absolute references through, and refuses anything that is not a relative path so `csp_*` class names are never mistaken for resources. **This locates resources; it does not download, verify or execute them.**
- A failed remote load keeps the last known good cache. Validation requires at least one usable source, so a payload that parses but drives nothing cannot replace a working cache.
- Every launch re-fetches a remote source, retrying at 2 s, 5 s and 15 s, and stays silent on failure because the cached configuration is already on screen and the 上次更新 row shows its age. A manual refresh reports errors and does not retry.

### WebHome bridge

- `WKWebView` + `WKScriptMessageHandler` reproducing the Android string-RPC contract. Implemented: `net.request`, `player.playUrl`, **`player.playVod`, `player.playVodInline`, `player.control`, `player.status`**, `app.search`, `app.history`, `cache.get/set/del`, `ui.getViewport`, `ui.setToolbar`, `navigation.back`, `navigation.reload`, `site.info`, `config.info`, `ext.info`, `ext.log`, `ext.toast`, `device.info`.
- Android payload shapes are reproduced field for field including the fields iOS cannot fill; a missing value is zero, empty or false rather than omitted, so a page never reads `undefined`.
- Deviations, each commented in code: `net.resourceUrl` returns the raw URL (no local proxy server); results are never chunked, so the synchronous `resultLength`/`resultChunk` accessors are unnecessary; `app.history` returns `[]` until a history store exists; `device.info` is built natively; Android-only gesture and system-bar insets are zero; `site.info` omits `homePage`, `chromeMode`, `webHomeChrome`, `header`; `config.info` has no `id` or `desc`.
- Still outside the bridge, each for a stated reason: `net.resourceUrl` proxying (no local server), `player.preloadArtwork` (`AsyncImage` has no preload hook, so it would be a no-op claiming success), `app.open*` (no Live or Keep screen), `pan.*` (no drive-check service), `ui.setChrome` / `restoreChrome` (no equivalent surface). All reject with the same `Unknown method` the Android default branch produces.

### Playback session (IOS-POC-2E)

- One `@MainActor` `PlaybackSession.shared` in the app target owns a single `AVPlayer` for the app's lifetime and swaps items into it, so no view observes a changing player object. It adds only what `AVPlayer` has no concept of: the inline playlist and index, the page-supplied title and artwork, and the repeat flag. Android's equivalent is the process-wide `PlaybackService` behind `Server.get().getService()`.
- `PlayerView` no longer creates its own player; closing it pauses rather than tears down, which is what lets a WebHome page read a live `player.status` and resume with `player.control` — the page is only on screen once the player is gone.
- Every playback path now feeds that one session: the CMS grid, `player.playUrl`, `player.playVod` (which resolves `siteKey` against the loaded config and opens the existing `VodView`) and `player.playVodInline` (which goes straight to the built-in player, since a playlist and `control` semantics are things an external player cannot honour).
- `player.status` reproduces Android's **`net.request` envelope**, because Android fetches `/media` over its own local HTTP server; the envelope is reproduced field for field and the HTTP hop is not. Durations and positions are milliseconds, as Media3 reports them.
- An unknown or empty `siteKey` rejects with `Unknown site: <key>` instead of opening a screen that fails later — the showcase page ships that field empty, so a page reaches it immediately.

## Build / Test / Verification Status

- `WANG_MOVIE_JSON=/tmp/webhtv-recha-new.wprHof/wang-movie.json swift test --package-path ios` → **43 tests, 42 pass**. The one failure, `reportsLiveType4SitesFromProvidedConfig`, is a **live-network** check that is **pre-existing**: `88看球` resolves an episode to an HTML play page and the test asserts direct media. Reproduced identically at `e1db99d8` in a throwaway worktree, so it is provider state, not a regression. Two live checks are gated on their own variables: `WANG_MOVIE_URL` for the remote config, and the type-4 sweep.
- `xcodebuild -project ios/WebHTVApp/WebHTVApp.xcodeproj -scheme WebHTVApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build` → BUILD SUCCEEDED.
- Remote config, against the real GitLab Raw URL: 125,864 bytes, 167 sites, 28 supported, cached SHA-256 identical to the remote, resolved `jar/fm.jar` HTTP 200. An unreachable URL left the sources and cache intact. Launch retry proven with a local server armed to fail twice — exactly three requests, adopted on the third.
- Simulator, end to end: `爱瓜TV` grid → 莲花楼 detail with 41 episodes → episode 01 plays in the built-in player. Type-1 `如意` and `360` grids load with real posters and both category rows. Pagination scrolls past the first page on both types.
- WebHome bridge in the simulator with the unmodified devkit showcase page: badge reads `SDK: native`; `fm.req JSON` logged `req-json ok (799ms)` with the full contract shape; the HLS button played the stream; `cache-set ok`; `ext-info` and `config` logged real payloads; `legacy hide`/`show` removed and restored the navigation bar.
- **IOS-POC-2E end to end, from the page:** `vodInline 多集` played the inline MP4; with the player closed, `播放状态` returned a live envelope (`duration 90080`, `position 28136`, `state 2`); `fm.ctrl play` advanced it to `state 3`, `position 41502`; `fm.ctrl next` switched the reported url and title to the HLS episode (`speed 1`, `position 10511`); `fm.ctrl pause` returned `{}` and the next status read `speed 0`. `调用 fm.vod` with `vod_360` / `101020` logged `vod ok (229ms)`, opened the native detail screen with ten live episodes and played episode 1, and a following status reported that stream.

## Risks / Unverified

- **Nothing has ever run on a real device.** The Xcode project has no `CODE_SIGN` or `DEVELOPMENT_TEAM` setting. Every result above is from the iPhone 17 Pro simulator.
- **Not measured: that HTTPS certificate validation is still enforced.** It is reasoned from the code — no `URLSessionDelegate`, no `serverTrust` handling anywhere — but no test against a known-bad certificate was run.
- Not driven from the WebHome page, covered only by offline tests: `cache.get`, `cache.del`, `app.search`, `app.history`, `device.info`, `site.info`, `ui.getViewport`, `ext.toast`, `navigation.back`, `navigation.reload`.
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
- Still not implemented: type-3 Spider/Python/DEX, WebHome sites in `wang-movie.json` (this config has none), and SideStore/IPA delivery.
- type-0 was verified only against the two configured endpoints. A provider sending a non-UTF-8 encoding would parse to an empty response rather than being transcoded.

## Next Recommended Step

Agree one bounded stage with the user. Ranked:

1. **Device deployment.** The largest gap and the only one that needs the user's Apple ID and hardware. Free provisioning's 7-day expiry versus a paid account versus SideStore is still an open question.
2. Drive the remaining offline-only bridge methods from a page (`cache.get`/`del`, `app.search`, `app.history`, `device.info`, `site.info`, `ui.getViewport`, `ext.toast`, `navigation.back`/`reload`) — the last block of the contract never exercised live.
3. A watch-history store, which would turn `app.history` from an honest `[]` into real data and give the home screen a 繼續觀看 row.

## Resume Prompt

> Continue the WebHomeTV iPhone port in `/Users/chengchenchih/GIT/webhtv` on the actual `ios-poc` Git state; check `git log` and `git status` first rather than trusting any commit id quoted here. Read `AGENTS.md`, `docs/AGENT_HANDOFF.md`, this file, and the stage document for whatever you touch. The app exposes 30 of 167 configured sources (2 type-0 + 22 type-1 + 6 type-4) with category browsing, pagination, five players, imported-file or remote-Raw-URL configuration with last-known-good caching and launch refresh, and a WebHome bridge over WKWebView covering the network, cache, UI, navigation, information **and playback** methods — `player.playVod`, `playVodInline`, `control` and `status` run on one persistent `PlaybackSession` that outlives the player screen. IOS-POC-2F then drove all seven `player.control` actions and the inline JS resolver from the page, so the playback half is fully exercised. It ships `NSAllowsArbitraryLoads` because the user explicitly chose global cleartext on 2026-09-15 — keep it and do not broaden transport security further without a fresh decision. Do not resume the Google TV `csp_JPianAmns` repair. Of the 137 type-3 sites 132 are structurally unreachable on iOS, so do not plan them as work. Nothing has ever run on a real device: there is no signing configuration at all. Confirm the next bounded stage with the user before any functional edit, follow the task-guard and Ponytail gates, and preserve Android `main`.
