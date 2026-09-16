# IOS-POC-1F — local file and remote Raw URL as config sources

## Recovery anchor

- Branch `ios-poc`, baseline HEAD `f047d3de`, clean worktree, 2 commits ahead of `origin/ios-poc`.
- Objective: make the configuration input an explicit choice between an imported local file and a remote Raw URL, and resolve config-relative resource references against the config's own directory.
- Status: COMPLETE. A1-A5 and B1-B5 all pass, as recorded below.
- Exactly one next action: agree the next stage with the user. Device deployment remains the largest open gap.

## Completion sentence

The app can load its configuration either from an imported file or from any HTTPS Raw URL, keeps the last known good copy when a remote refresh fails, reports when it last updated, refreshes on demand, and can turn a config-relative reference such as `./jar/fm.jar;md5;…` into the matching Raw URL — with the existing 28 sources and every current behaviour unchanged.

## Allowed paths

- `ios/Sources/WebHTVCore/ConfigSource.swift` (new)
- `ios/Sources/WebHTVCore/ConfigLoader.swift`
- `ios/Sources/WebHTVCore/WebHTVConfig.swift`
- `ios/WebHTVApp/Sources/WebHTVApp.swift`
- `ios/Tests/WebHTVCoreTests/ConfigSourceTests.swift` (new)
- `ios/Tests/WebHTVCoreTests/ConfigLoaderTests.swift`
- `docs/IOS-POC-1F-config-sources.md`, `docs/current-task-state.md`

Protected pre-existing dirty paths: none. Android `app/` is read-only.

## Evidence (measured 2026-09-16)

1. **The real remote config is reachable and identical to the local baseline.** `https://gitlab.com/st7833232/recha/-/raw/main/wang-movie.json?ref_type=heads` returns HTTP 200, 125,864 bytes, SHA-256 `b17576e34eb42b4c589a818ef8b5ec2655a2c7a188d626fc427c37d628897168` — the same bytes as the imported file — with 167 sites and 28 of type 1 or 4.
2. **Relative references are real and resolvable.** The config carries 150 relative references, 54 distinct: 96 under `jar/`, 38 under `py/`, 8 under `json/`, 4 under `drpy_libs/`, 4 under `drpy_js/`. Resolved against the config directory, `jar/fm.jar` returns HTTP 200 (282,717 bytes) and `py/Uvod.py` returns HTTP 200 (12,723 bytes), so the base-URL rule matches how the archive is actually laid out.
3. **Foundation already implements the resolution correctly.** `URL(string:relativeTo:)` against that base drops the `?ref_type=heads` query per RFC 3986, percent-encodes non-ASCII names such as `./py/油管-6.py` and `./jar/愛影.jar`, passes absolute URLs through, and handles `../`. No hand-written URL joining is needed.
4. **Two forms must not be treated as resources.** `jar` references carry a `;md5;<hash>` suffix that is not part of the path, and `csp_*` values are Spider class names — `URL(string:relativeTo:)` would happily turn `csp_XYZ` into a URL, so the resolver must only accept references beginning `./` or `../`.

## Design (Ponytail pre-review)

- **No provider knowledge in Core.** A remote source is an `https` URL and nothing else; GitLab and GitHub are not named anywhere in `WebHTVCore`. The GitLab URL is only test and verification data.
- **No new dependency, no new storage layer.** `URLSession.webHTV` already carries the timeout policy, `Data.write(.atomic)` already provides the atomic replace, and two `UserDefaults` keys record the source and the update time. `ConfigSource` deliberately does not conform to `Codable`: one optional string and one date are less machinery than an encoded enum.
- **An imported file has no base URL**, so its relative references cannot resolve. That is the honest answer, not a guess at a mirror location.
- **Reuse over addition.** `nativeCMSSites.filter { type == 1 || type == 4 }` is currently duplicated in two places in the app; it moves to `WebHTVConfig.supportedSites` and both call sites use it.
- **Deletion.** `ConfigLoader.load(from:)` exists with no caller and no test; `fetch(from:)` replaces it rather than sitting beside it.
- Last-known-good is the existing POC-1E pattern extended, not a new mechanism: validate first, write atomically, assign state only after the write succeeds. A failed refresh therefore cannot touch the cached file.

### Explicitly not in this stage

Executing Python, JAR/DEX or JavaScript; any Spider runtime; type-0 or type-3 support; per-resource download or caching; checksum verification of resolved resources. **This stage locates and names resources; it does not run them.** The `;md5;` suffix is discarded for URL resolution and is not verified.

## Acceptance criteria

Offline, deterministic:

- A1. `swift test --package-path ios` passes with all 23 existing tests unchanged.
- A2. The resolver turns `./jar/fm.jar;md5;…`, `./py/油管-6.py`, `./json/4k.json` and `./drpy_libs/drpy2.min.js` into the expected absolute URLs against a base carrying a query, and percent-encodes non-ASCII.
- A3. The resolver passes absolute references through, returns nil for `csp_XYZ` and for any non-relative token, and returns nil for every reference when the source is an imported file.
- A4. Validation rejects malformed JSON and a syntactically valid config with no type-1/type-4 site, so neither can replace a cached copy.
- A5. `supportedSites` returns exactly 28 entries for the real config.

Live:

- B1. Xcode Debug build succeeds.
- B2. Loading the GitLab Raw URL in the app produces the same 28 sources, and the stored file matches the remote SHA-256.
- B3. A refresh against an unreachable URL leaves the previous sources and cached file intact and reports the failure.
- B4. Last-update status is shown and manual refresh works.
- B5. Existing behaviour unchanged: type-1 and type-4 browsing, categories, pagination, players, persistence.

## Rollback

One commit plus a `recovery/IOS-POC-1F/*` tag. The cached file path and the selected-site key are unchanged, so reverting restores `f047d3de` behaviour with no migration.


## Verification result (2026-09-16)

### Offline gates — all pass

`WANG_MOVIE_JSON=... swift test --package-path ios` → 29 tests, the 23 existing ones unchanged.

A1 pass. A2 and A3 pass (`resolvesConfigRelativeResourcesAgainstTheConfigDirectory`, `dropsTheChecksumSuffixThatIsNotPartOfThePath`, `leavesAbsoluteReferencesAloneAndRefusesNonResources`, `anImportedFileAnchorsNothing`). A4 pass (`validationRefusesPayloadsThatMustNotReplaceAGoodCache`). A5 pass (`countsTheSupportedSitesOfTheSuppliedConfig`: 28 supported, 6 of them type-4).

### Live protocol run against the real Raw URL

`fetchesAndAnchorsARealRemoteConfig`, gated on `WANG_MOVIE_URL` so the suite stays offline by default:

```
remote config: 125864 bytes, 167 sites, 28 supported
resolved: https://gitlab.com/st7833232/recha/-/raw/main/jar/fm.jar
resource HEAD: 200
```

The spider reference `./jar/fm.jar;md5;…` resolved from the config's own directory and the resource answered 200, which is the evidence that the base-URL rule matches the archive's real layout.

### Simulator — B1 to B5

- **B1 pass.** Debug build succeeds; the 設定來源 section renders with source, last-update, load-from-URL, refresh and import rows.
- **B3 pass, checked first on purpose.** Loading `https://10.255.255.1/nope.json` reported "遠端設定載入失敗：The request timed out." after about ten seconds — the IOS-POC-4E timeout — and left the source at 本機匯入檔案, the update stamp at 尚未記錄, the 28 sources and the selected site untouched.
- **B2 pass.** Loading the GitLab Raw URL switched the source to that URL and kept 28 sources. The cached file is 125,864 bytes with SHA-256 `b17576e34eb42b4c589a818ef8b5ec2655a2c7a188d626fc427c37d628897168`, identical to the remote. `configSourceURL`, `configUpdatedAt` and `selectedSiteKey = 如意` are all persisted.
- **B4 pass.** 重新整理 re-fetched and advanced `configUpdatedAt` from `1789529027` to `1789529132`, so the button does real work rather than only re-rendering. The refresh stays in Settings; only pointing the app at a new source switches to Home.
- **B5 pass.** After the remote load, the refresh and a relaunch, the home still shows 如意 with its parent/child category rows, posters, remarks and pagination. The source list, selected site and player paths are unchanged.

### Ponytail final review

Two findings, both fixed before commit:

1. A refresh jumped the user from Settings to Home because `load(remote:)` was shared with the new-source path. It now takes `showHome`.
2. `ConfigLoader.fetch` validated and then `adopt` validated the same bytes again. `adopt` now takes the already-validated config, so each path validates exactly once and the write gate is still the only thing that can replace the cache.

### Out-of-scope defect fixed incidentally

The Settings footer said "目前支援 28 個 type-1 JSON CMS 來源", stale since type-4 landed in IOS-POC-4A. The rewritten footer names both types. This was reported as out of scope in IOS-POC-2B and is corrected here because the same line was being rewritten anyway.
