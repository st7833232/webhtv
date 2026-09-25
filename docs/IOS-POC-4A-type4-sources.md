# IOS-POC-4A — type-4 (CatVod remote API) source support

## Recovery anchor

- Branch `ios-poc`, baseline HEAD `2c1c2a35` (clean worktree at plan time, 2026-09-15 15:45 CST).
- Objective: expose the 6 `type: 4` sites of the current `wang-movie.json` in the existing SwiftUI app, alongside the 22 `type: 1` sites, without changing type-1 behaviour.
- Status: COMPLETE. Offline gates A1-A5 pass and B1-B3 are satisfied after the IOS-POC-4B ATS change recorded at the end of this file.
- Exactly one next action: choose the next stage with the user; type-0 XML (2 sites) and the WebHome bridge remain the open candidates. (Corrected 2026-09-25: both have landed, type-0 XML in IOS-POC-4J (`4a9fd68f`, `docs/IOS-POC-4J-type0-xml-sources.md`) and the WebHome bridge in IOS-POC-2B to 2F (`docs/IOS-POC-2B-webhome-bridge.md`, `docs/IOS-POC-2D-webhome-bridge-ui-info.md`, `docs/IOS-POC-2E-webhome-bridge-playback.md`).)

## Completion sentence

The iPhone app lists and opens all 6 `type: 4` sites from the current `wang-movie.json`, showing a populated poster grid and playing an episode through the existing player picker, with type-1 behaviour and system TLS validation unchanged.

## Allowed paths

- `ios/Sources/WebHTVCore/WebHTVConfig.swift`
- `ios/Sources/WebHTVCore/CMSClient.swift`
- `ios/WebHTVApp/Sources/WebHTVApp.swift`
- `ios/Tests/WebHTVCoreTests/CMSClientTests.swift`
- this document

Protected pre-existing dirty paths: none (worktree clean at plan time; re-check on start).

## Estimate

Agent elapsed wall-clock in this workspace, not person-effort.

| Phase | Estimate |
|---|---|
| Core + app edits | ~20 min |
| Offline fixture tests | ~10 min |
| Simulator build + one live site scenario | ~20 min |
| Docs, commit, tag | ~10 min |

Total ~60 min; expected finish ~16:45 CST. If a live type-4 site is unreachable at verification time, do not extend the task waiting for it — record it as unverified and finish.

## Evidence gathered (read-only probes, 2026-09-15)

`wang-movie.json` SHA-256 `b17576e34eb42b4c589a818ef8b5ec2655a2c7a188d626fc427c37d628897168`, 167 sites, 6 of `type: 4`.

1. **type-4 speaks the same JSON dialect the app already parses.** `爱瓜TV` detail returned `vod_play_from` = `普快线路$$$超快线路` and `vod_play_url` using the same `$$$` / `#` / `$` separators. `CMSClient.Vod.flags` and `Episode.parse` handle this unchanged.
2. **type-4 home returns categories, not titles.** `爱瓜TV` with no params returned `class: 5, list: 0`. A category call is required to populate the grid: `采集集合` with `t=1&pg=1` returned `list: 56`. This is the one structural difference from type-1 and the reason `home()` needs a type-4 branch.
3. **Some type-4 episodes are web pages, not media.** `drpyS_枫林影视` detail returned `https://play.8maple.st/play/PrXC-2-1.html`. Resolution works: `?play=<url>&flag=速通線路` returned `{"parse":0,"url":"https://v.cdnlz21.com/20241215/2960_8b52b5ad/index.m3u8"}`.
4. **Other type-4 episodes are already direct.** `爱瓜TV` returned `.m3u8` in `vod_play_url` with no resolution step.
5. **`ext` shapes are inconsistent**: 3 `null`, 2 string, 1 dict (`php_无水印资源` → `{module_name: CmsSuggest, url: ...}`). A strict decode would throw on the string form.
6. **Remote reachability is volatile.** `itv666.cc` resolved and returned HTTP 200 at 15:30 CST and failed DNS at 15:40 CST; both drpyS hosts responded then timed out. Acceptance criteria below therefore do not depend on any specific remote host.

## Design (Ponytail pre-review)

Ladder outcome — reuse over new code:

- **Reused unchanged**: `CMSResponse`, `CMSCategory`, `Vod`, `Vod.flags`, `Flag`, `Episode.parse`, the `request()` plumbing, `ExternalPlayer`, and the whole player-picker UI.
- **No new type**: extend `CMSClient` rather than add a `Type4Client`. One implementation means no protocol, no factory, no registry.
- **`detail()` and `search()` are not branched** — type-4 uses the same `ac=detail&ids=` and `wd=` contracts.

Four edits only:

1. `Site.isNativeCMS` and the two app-side filters accept type 4 as well as type 1.
2. `CMSClient.home()` gains a type-4 branch: fetch `filter=true`, take the first `class` id, then request `t=<id>&pg=1`. Type-1 keeps its current single no-param call.
3. New `CMSClient.resolve(episodeURL:flag:)` for type 4, calling `?play=&flag=` and reading `url` from the response. Applied only when the episode URL is not already direct media — checked by path extension (`m3u8`/`mp4`/`flv`). This avoids a wasted round-trip on sites like `爱瓜TV`.
4. `Site.ext` decoded leniently with `try?` into an optional `[String: String]`; its `module_name` / `url` entries are merged into the query. A string or null `ext` yields nil and changes nothing.

Deliberate ceiling, to be marked in code with a `ponytail:` comment: the type-4 home shows only the **first** category and the extension-based direct-media check is a heuristic. Upgrade path is a real category picker, which is worth building only if the user wants category browsing for type-1 as well.

### Hazard this stage must close

`Episode.mediaURL` only checks the scheme is http/https, so a `…/play/PrXC-2-1.html` page URL currently passes and would hand AVPlayer an HTML document, failing silently with no error shown. Routing type-4 playback through resolution is what closes this; it is not optional polish.

## Acceptance criteria

Offline, deterministic — these gate the stage:

- A1. `swift test --package-path ios` passes, including the existing 5 tests unchanged.
- A2. New fixture test: a type-4 config decodes and `nativeCMSSites` includes the 6 type-4 keys, and a string-valued `ext` does not throw.
- A3. New fixture test: type-4 detail JSON in the `$$$`/`#`/`$` form yields the expected flags and episode names/URLs.
- A4. New fixture test: `?play=` response `{"parse":0,"url":"…m3u8"}` resolves to that URL, and a direct `.m3u8` episode resolves without an extra request.
- A5. Type-1 regression: an existing type-1 site still issues exactly the same home/search/detail requests as before this change.

Live, best-effort — recorded honestly, not gating:

- B1. Xcode simulator Debug build succeeds.
- B2. On at least one reachable type-4 site, the home grid is populated and one episode plays in the built-in player.
- B3. Any type-4 site unreachable at verification time is named individually with its observed error. A DNS/TLS failure on one host is not reported as an app defect.

## Out of scope

Type-0 XML, type-3 Spider/Python/DEX, WebHome/WKWebView bridge, category browsing UI, pagination, SideStore/IPA packaging, and any ATS/TLS relaxation.

## Rollback

Single commit on `ios-poc` plus a `recovery/IOS-POC-4A/*` tag, matching prior stages. Revert restores `2c1c2a35` behaviour; no data migration, no persisted-format change.


## Verification result (2026-09-15)

### Offline gates — all pass

`WANG_MOVIE_JSON=/tmp/webhtv-recha-new.wprHof/wang-movie.json swift test --package-path ios` → 9 tests pass, including the pre-existing 5.

- A1 pass. A2 pass (`classifiesType4SitesAndToleratesNonDictionaryExt`: the string and numeric `ext` forms decode to nil instead of throwing).
- A3 pass, A4 pass (`parsesType4DetailAndResolvesPlaybackURLs`).
- A5 pass (`keepsType1RequestsUnchangedAndMergesType4Ext`). The empty-query build has always emitted a bare trailing `?`; the test pins that pre-existing shape rather than changing it.

### Defect found and fixed during verification

`爱瓜TV` answers `ac=detail` with **only** `vod_play_from` and `vod_play_url` — no `vod_id`, no `vod_name`. `Vod.init(from:)` required both, so the decode threw and the entire detail record was dropped, leaving the episode list empty with no error. Fixed in the shared `Vod` decoder (identity now defaults to empty), so every caller and every site type benefits rather than only the type-4 path. Covered by `decodesDetailCarryingOnlyPlaybackFields`.

### Protocol-level live verification — pass

`reportsLiveType4SitesFromProvidedConfig`, all 6 type-4 sites:

| Site | Result |
|---|---|
| `爱瓜TV` | classes=5, list=24; 莲花楼 / 01 → `https://cf186.magicvodcdn.com/…/index.m3u8` |
| `采集集合` | classes=1, list=56; TV-无水印资源 / HD → `https://v14.wsyzym3u8.com/…/index.m3u8` |
| `php_无水印资源`, `drpyS_枫林影视`, `88看球`, `drpyS_听友[听]` | unreachable at run time |

The type-4 home branch and the `?play=&flag=` resolution both work against real servers. `drpyS_枫林影视` resolution was separately confirmed earlier: `?play=…PrXC-2-1.html&flag=速通線路` → `{"parse":0,"url":"https://v.cdnlz21.com/…/index.m3u8"}`.

### B1 simulator build — pass

`xcodebuild -project ios/WebHTVApp/WebHTVApp.xcodeproj -scheme WebHTVApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build` → `** BUILD SUCCEEDED **`.

### B2 in-app behaviour — partially blocked

On the iPhone 17 Pro simulator, with the config restored from POC-1E persistence:

- The source picker now lists the type-4 entries (`｜無水｜(T4)`, `｜愛瓜｜PHP`, `｜采集集合｜PHP`) alongside the type-1 entries. Exposure works.
- Selecting `爱瓜TV` fails with *"The resource could not be loaded because the App Transport Security policy requires the use of a secure connection."*
- Type-1 regression check: `如意` loads its poster grid normally in the app, so the app itself is healthy. `360` failed separately with a TLS error, matching the volatile-site behaviour already recorded in the handoff.

### Blocker found during verification — needs a user decision

**No type-4 site can currently load inside the iOS app, and the cause is transport policy rather than this implementation.**

- 5 of the 6 type-4 sites use plain `http://` (`爱瓜TV`, `采集集合`, `drpyS_枫林影视`, `88看球`, `drpyS_听友[听]`). The app declares no `NSAppTransportSecurity` at all, so the iOS default blocks cleartext. The macOS command line does not apply ATS, which is why the protocol-level runs above succeed.
- The only `https` type-4 site, `php_无水印资源`, now presents a self-signed certificate chain. With TLS validation preserved it is correctly refused.

For reference the same policy already affects type-1: 21 of its 22 sites are `https`, and the remaining `http` one is blocked for the same reason. This is pre-existing, not introduced here.

Relaxing ATS is listed as out of scope for this stage and the handoff forbids weakening TLS/ATS globally to make one site work, so no ATS change was made. The decision belongs to the user. Note that a cleartext ATS exception and TLS certificate validation are separate settings: permitting `http` for named domains would not weaken certificate checking for `https` hosts.


## IOS-POC-4B — ATS decision and outcome (2026-09-15)

The user was shown three options (per-domain exception, no change, global cleartext) with a recommendation for the narrow per-domain exception and an explicit note that the handoff forbids weakening ATS globally for one site. **The user chose global cleartext.** That decision is recorded here and supersedes the earlier prohibition for this personal POC.

`ios/WebHTVApp/Info.plist` now sets `NSAppTransportSecurity` → `NSAllowsArbitraryLoads = true`, wired in through `INFOPLIST_FILE` on both the Debug and Release configurations. Confirmed present in the built bundle with `plutil -p`.

### B2/B3 now satisfied — full in-app flow

On the iPhone 17 Pro simulator, source `爱瓜TV` (type-4, cleartext `http`):

1. Poster grid loads with real artwork (莲花楼, 狂飙, 庆余年2, 云之羽).
2. 莲花楼 detail shows the `普快线路` flag with all 41 episodes — this is the in-app proof of the `Vod` decoder fix, since that response carries no `vod_id` or `vod_name` and previously produced an empty screen.
3. Episode 01 resolves and **plays video in the built-in player**.

Type-1 regression re-checked after the change: `360` loads its grid normally (its earlier failure was transient, not a certificate problem).

`php_无水印资源` still shows an empty grid. Over a system-trust client the endpoint completes TLS and answers HTTP 403, so this is that provider's own response, not an app or transport defect.

### What was NOT verified about TLS

The claim that `NSAllowsArbitraryLoads` leaves HTTPS certificate validation intact is supported **structurally, not empirically**: `grep` over `ios/Sources` and `ios/WebHTVApp/Sources` finds no `URLSessionDelegate`, no `didReceive challenge`, and no `serverTrust` handling, so all requests use `URLSession.shared` with default system trust evaluation, and bypassing that evaluation requires an explicit delegate override that does not exist in this codebase. An empirical check against a known-bad certificate was not run: the intended candidate (`php_无水印资源`) turned out to present a chain the system accepts, and the `360` before/after comparison collapsed when that site recovered on its own. Treat "certificate validation still enforced" as reasoned from the code and the ATS/trust layering, not as measured.
