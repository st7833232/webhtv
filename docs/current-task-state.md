# Current Task State

## Original Goal

Port WebHomeTV to iPhone with an Android-like UI, drive the user's own `wang-movie.json`, and offer built-in, Infuse, Fileball, SenPlayer and VidHub playback. The Google TV `csp_JPianAmns` repair is not in scope.

## Current Scope

- Branch `ios-poc`, HEAD `6d926ebd` before this documentation commit. `origin/ios-poc` is at `150181b1`, so one functional commit (`6d926ebd`, IOS-POC-2D) plus this one are unpushed. Re-check with `git log` rather than trusting these ids.
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
| 3A–3C | Android-like surfaces, wallpaper, oversized-logo removal | commits |
| 3D | Uniform 2:3 poster cells | commit |
| 3E | Built-in player presented full screen | commit |
| 4A | type-4 CatVod remote API sources | `docs/IOS-POC-4A-type4-sources.md` |
| 4B | ATS cleartext decision | same document |
| 4E–4I | Request timeout, category browsing, two-level categories, pagination, type-1 posters | commits |

## Important Decisions

- Input baseline: Recha `wang-movie.json`, 125,864 bytes, SHA-256 `b17576e34eb42b4c589a818ef8b5ec2655a2c7a188d626fc427c37d628897168`, 167 sites (2 type-0, 22 type-1, 137 type-3, 6 type-4). The archive itself is external, not committed.
- **Of the 137 type-3 sites, 132 are structurally out of reach on iOS**, not merely unimplemented: 90 are `csp_*` DEX/JAR and 42 are Python. Only 5 are drpy JavaScript, which iOS JavaScriptCore could plausibly host. Never describe all 137 as pending work.
- The WebHome JS SDK is injected by the app, not shipped by pages: pages only touch `window.fm` / `window.fongmi`. Porting the bridge therefore means porting `HomeWebController.getSdk()`, not designing an API from the method list.
- Core names no hosting provider. A remote config source is an HTTPS URL and nothing more; GitLab and GitHub appear only in test and verification data.

## Completed Work

### Sources and browsing

- 28 of the 167 configured sources are usable: 22 type-1 plus 6 type-4. Type-4 extends `CMSClient` rather than adding a second client; its only structural difference is that its home returns categories, so the first browsable category fills the grid.
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

- `WKWebView` + `WKScriptMessageHandler` reproducing the Android string-RPC contract. Implemented: `net.request`, `player.playUrl`, `app.search`, `app.history`, `cache.get/set/del`, `ui.getViewport`, `ui.setToolbar`, `navigation.back`, `navigation.reload`, `site.info`, `config.info`, `ext.info`, `ext.log`, `ext.toast`, `device.info`.
- Android payload shapes are reproduced field for field including the fields iOS cannot fill; a missing value is zero, empty or false rather than omitted, so a page never reads `undefined`.
- Deviations, each commented in code: `net.resourceUrl` returns the raw URL (no local proxy server); results are never chunked, so the synchronous `resultLength`/`resultChunk` accessors are unnecessary; `app.history` returns `[]` until a history store exists; `device.info` is built natively; Android-only gesture and system-bar insets are zero; `site.info` omits `homePage`, `chromeMode`, `webHomeChrome`, `header`; `config.info` has no `id` or `desc`.
- Still outside the bridge, each for a stated reason: `net.resourceUrl` proxying (no local server), `player.playVod*` / `control` / `status` / `preloadArtwork` (no persistent playback service), `app.open*` (no Live or Keep screen), `pan.*` (no drive-check service), `ui.setChrome` / `restoreChrome` (no equivalent surface). All reject with the same `Unknown method` the Android default branch produces.

## Build / Test / Verification Status

- `WANG_MOVIE_JSON=/tmp/webhtv-recha-new.wprHof/wang-movie.json swift test --package-path ios` → **33 tests pass**. Two live checks are gated on their own variables: `WANG_MOVIE_URL` for the remote config, and the type-4 sweep.
- `xcodebuild -project ios/WebHTVApp/WebHTVApp.xcodeproj -scheme WebHTVApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build` → BUILD SUCCEEDED.
- Remote config, against the real GitLab Raw URL: 125,864 bytes, 167 sites, 28 supported, cached SHA-256 identical to the remote, resolved `jar/fm.jar` HTTP 200. An unreachable URL left the sources and cache intact. Launch retry proven with a local server armed to fail twice — exactly three requests, adopted on the third.
- Simulator, end to end: `爱瓜TV` grid → 莲花楼 detail with 41 episodes → episode 01 plays in the built-in player. Type-1 `如意` and `360` grids load with real posters and both category rows. Pagination scrolls past the first page on both types.
- WebHome bridge in the simulator with the unmodified devkit showcase page: badge reads `SDK: native`; `fm.req JSON` logged `req-json ok (799ms)` with the full contract shape; the HLS button played the stream; `cache-set ok`; `ext-info` and `config` logged real payloads; `legacy hide`/`show` removed and restored the navigation bar.

## Risks / Unverified

- **Nothing has ever run on a real device.** The Xcode project has no `CODE_SIGN` or `DEVELOPMENT_TEAM` setting. Every result above is from the iPhone 17 Pro simulator.
- **Not measured: that HTTPS certificate validation is still enforced.** It is reasoned from the code — no `URLSessionDelegate`, no `serverTrust` handling anywhere — but no test against a known-bad certificate was run.
- Not driven from the WebHome page, covered only by offline tests: `cache.get`, `cache.del`, `app.search`, `app.history`, `device.info`, `site.info`, `ui.getViewport`, `ext.toast`, `navigation.back`, `navigation.reload`.
- Remote reachability is highly volatile. `itv666.cc` went from HTTP 200 to DNS failure within ten minutes, and the GitLab Raw host was unreachable for about a minute mid-session. Never treat one site's failure as a global app defect.
- `URLSession.webHTV` caps request inactivity at 10 s. A type-4 home issues two sequential requests, so its worst case is about 20 s. This is an inactivity timeout, not a total-transfer cap. AVPlayer playback does not use this session.
- A failed next page stops pagination silently, because the error surface only renders when the grid is empty.
- The direct-media test is a path-extension heuristic, marked `ponytail:` in `CMSClient.swift`.
- The `ac=detail` form costs bandwidth: a 20-title page on `360zy` grew from 6.5 KB to 49 KB.
- `drpyS_听友[听]` returns an empty list for all 43 of its categories, and `php_无水印资源` answers HTTP 403. Both are provider state, not app defects.
- The Debug-only CJK font fallback does not fix the log panel's `[上午…]` prefix, and says nothing about a real device.
- Still not implemented: type-0 XML (2 sites), type-3 Spider/Python/DEX, WebHome sites in `wang-movie.json` (this config has none), and SideStore/IPA delivery.

## Next Recommended Step

Agree one bounded stage with the user. Ranked:

1. **Device deployment.** The largest gap and the only one that needs the user's Apple ID and hardware. Free provisioning's 7-day expiry versus a paid account versus SideStore is still an open question.
2. **The playback half of the WebHome bridge** — `player.playVod`, `playVodInline`, `control`, `status` — which needs a persistent playback service rather than the current sheet.
3. type-0 XML (2 sites, needs an XML parser; both endpoints answered HTTP 200 on 2026-09-15).

## Resume Prompt

> Continue the WebHomeTV iPhone port in `/Users/chengchenchih/GIT/webhtv` on the actual `ios-poc` Git state; check `git log` and `git status` first rather than trusting any commit id quoted here. Read `AGENTS.md`, `docs/AGENT_HANDOFF.md`, this file, and the stage document for whatever you touch. The app exposes 28 of 167 configured sources (22 type-1 + 6 type-4) with category browsing, pagination, five players, imported-file or remote-Raw-URL configuration with last-known-good caching and launch refresh, and a WebHome bridge over WKWebView covering the network, cache, UI, navigation and information methods. It ships `NSAllowsArbitraryLoads` because the user explicitly chose global cleartext on 2026-09-15 — keep it and do not broaden transport security further without a fresh decision. Do not resume the Google TV `csp_JPianAmns` repair. Of the 137 type-3 sites 132 are structurally unreachable on iOS, so do not plan them as work. Nothing has ever run on a real device: there is no signing configuration at all. Confirm the next bounded stage with the user before any functional edit, follow the task-guard and Ponytail gates, and preserve Android `main`.
