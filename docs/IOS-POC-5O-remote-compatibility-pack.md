# IOS-POC-5O — remote compatibility pack

Turns "a site changed its protocol, so rebuild and reinstall the app" into "publish a file". No new
spider class, no Python, no CarPlay, no release work.

## Recovery anchor

- **Objective**: the eight ported spider scripts and their class aliases become a versioned,
  integrity-checked artifact the app fetches, verifies and adopts at runtime, with the bundled copies
  as the fallback that can never be taken away.
- **Acceptance**: an offline launch, a 404, a timeout, a malformed manifest, a wrong hash and a
  too-new script each leave the app working; a pack-delivered spider drives a live site end to end.
- **Not in scope**: new spider classes, Python/drpy, CarPlay, App Store packaging, a signature chain.

## Ponytail pre-review — findings acted on before writing code

1. **Do not build a second cache.** `ConfigSource` + `ConfigLoader` already implement "validate, then
   atomically replace, and never touch the cache on failure". The pack reuses that *shape* and the
   same base-URL resolution (`./spiders/manifest.json`, resolved exactly like the `./json/` rule
   files), while keeping its own directory so a pack and a configuration can never invalidate each
   other. **Scope removed:** a bespoke cache subsystem.
2. **SHA-256 proves integrity, not authorship.** The manifest and the scripts come from the same
   origin, so whoever controls that host controls both. With `NSAllowsArbitraryLoads` shipping for
   playback hosts, a plaintext pack URL would be trivially injectable. **Scope added:** the pack URL
   must be HTTPS regardless of ATS. **Recorded as the upgrade path, not built:** a detached signature
   verified against a key pinned in the app, which is what would make a pack authentic rather than
   merely intact.
3. **No Official/Personal build flavours.** There is no App Store target, no TestFlight, and the app
   has never been installed on a device, so a capability flag would have no consumer. **Scope
   removed**; the one place such a gate belongs is named below so it stays a one-line change.

## Architecture

```
wang-movie.json  (already remote, already LKG-cached)
        │
        └── ConfigSource.resourceURL("./spiders/manifest.json")     ← provider-agnostic, HTTPS only
                     │
                     ▼
            SpiderPackStore.refresh(from:)
                     │  schema gate → pack minHostApi gate → fetch each script
                     │  → per-script SHA-256 → completeness → atomic replace
                     ▼
            Application Support/SpiderPack/{manifest.json, scripts/*.js}
                     │
                     ▼
            InstalledSpiderPack.shared  ──►  SpiderRegistry.active()
                                                 │  pack entry wins
                                                 │  bundled entry otherwise
                                                 ▼
                                        CSPSourceResolver → JavaScriptSpiderRuntime
                                                 │
                                        CatVodHost (native, NOT packable)
```

Everything below the registry is unchanged: `JavaScriptSpiderRuntime`, `CatVodHost`, HTTP/cookies,
crypto, the HTML/JSON parsers, the player and the `Spider` ABI are all still compiled into the app.
`host.js` is **not** packable — it is the SDK that `minHostApi` describes, so it ships with the app.

## Manifest schema

```json
{
  "schema": 1,
  "version": "2026-09-17.1",
  "minHostApi": 1,
  "scripts": [
    {
      "class": "JianPian",
      "path": "./scripts/JianPian.js",
      "sha256": "4f7c62cc…",
      "minHostApi": 1,
      "aliases": ["JPianAmns"],
      "originJar": "river-fman.jar",
      "jarSha256": "3133519d…",
      "notes": "JPianAmns is a protected shim; this drives the same API"
    }
  ]
}
```

| field | required | meaning | on violation |
|---|---|---|---|
| `schema` | yes | pack format version; this build knows `1` | whole pack refused |
| `version` | yes | the pack's own label, shown in settings and in test output | — |
| `minHostApi` | no | host API the whole pack needs | whole pack refused, with the required and current numbers |
| `scripts[].class` | yes | the `csp_*` class without the prefix | — |
| `scripts[].path` | yes | relative to the manifest URL, or absolute HTTPS | non-HTTPS refuses the pack |
| `scripts[].sha256` | yes | digest of the exact bytes | **whole pack refused** |
| `scripts[].minHostApi` | no | gate for this script alone | that script skipped, reason recorded and shown |
| `scripts[].aliases` | no | other configured class names this script serves | — |
| `scripts[].originJar`, `jarSha256` | no | audit provenance for the maintenance flow | — |
| `scripts[].notes` | no | free text for humans | — |

## Cache, last known good, atomic replace

- A refresh writes into `SpiderPack-staging-<uuid>/` and only then calls
  `FileManager.replaceItemAt`, so a crash leaves either the old pack or the new one.
- **Nothing is replaced until everything verified**: manifest parsed, schema known, host new enough,
  every included script downloaded, every digest matched, at least one script usable.
- `installedPack()` **re-verifies on read**, so a cache file edited on the device is not a pack. A
  test tampers with a cached script and asserts the store refuses it.
- A failed refresh throws and does not touch the installed pack — exercised for timeout, HTTP 404,
  malformed JSON, and a hash mismatch, in one test, against one directory, in sequence.

## Bundled fallback

Resolution order is exactly: **verified pack → bundled script → not supported**. A pack entry
replaces a bundled class and may add a class the bundle never had; a pack *alias* only resolves to a
script that same pack delivered, so a stale alias cannot repoint a bundled class. With no pack
installed, `SpiderRegistry.active()` is byte-for-byte `SpiderRegistry.bundled()`.

## Host API version gate

`SpiderPackStore.hostApiVersion` is `1` today and is bumped whenever `CatVodHost` gains a primitive a
script could depend on — RSA, `proxy`, a WebView primitive. A script declaring a higher `minHostApi`
is **never fetched and never stored**; the pack still installs, and the app shows
「略過 AppDrama（需要 host API 2，這個 App 是 1）」. A *pack-level* `minHostApi` that is too high
refuses the whole pack and keeps the last good one. This is the difference between an app that tells
you it is too old and an app that dies inside a spider call.

## Integrity

Per-script SHA-256, compared against the exact bytes served. A mismatch refuses the **whole pack**,
not just that script: a manifest that describes something other than what it served is not partially
trustworthy. The pack URL must be HTTPS even though ATS is globally relaxed for playback. What this
does *not* give you is authenticity — see Ponytail finding 2.

## JAR maintenance flow

`scripts/spider_pack.py` carries the provenance of all eight ports and implements the flow:

```bash
scripts/spider_pack.py build --version 2026-09-17.1 --out build/spider-pack
scripts/spider_pack.py verify --url https://…/spiders/manifest.json
scripts/spider_pack.py fingerprint --manifest build/spider-pack/manifest.json --jars ~/jars
```

| what changed | what to do | rebuild the app? |
|---|---|---|
| JAR SHA-256 unchanged | nothing | no |
| JAR changed, behaviour did not | update `jarSha256`, republish the manifest | no |
| endpoint / token / parser / response shape moved | edit the script, republish the pack | **no** |
| the fix needs a new `CatVodHost` primitive | add it in Swift, bump `hostApiVersion`, ship the app | **yes** |

The tool never decompiles, unpacks or executes a JAR; it reads bytes and computes a digest. The
protected `aowu-0722.jar` / `aowu.jar` / `fan-0720.jar` policy is untouched — nothing here attempts
to defeat native-encrypted protection. A proven equivalent alias such as `JPianAmns → JianPian` is
ordinary pack metadata and is what the alias field exists for.

## No longer needs an app rebuild

Site host, category, filter and rule-file changes (already true before this stage); **and now**: any
change to a ported spider's protocol handling, a new class alias, and adding a spider class the
bundle never carried — as long as it runs on the current `CatVodHost`.

## Still needs an app rebuild

A new native primitive (RSA, `proxy`, per-request player headers, a WebView capability), anything
touching entitlements, ATS, signing or the `Spider` ABI itself, and any change to `host.js`.

## Distribution risk

- **Personal / sideload (the only pipeline that exists today).** No review, no restriction. This is
  what the stage targets.
- **App Store / TestFlight.** Guideline 2.5.2 permits interpreted code executed by JavaScriptCore
  when it does not change the app's primary purpose — which a spider arguably does not, since
  driving configured sources *is* the purpose. Reading a guideline is not a review outcome, and this
  app has other reasons it would not pass; treat remote code as a risk to disable, not to argue.
- **Isolation, if it is ever needed:** one gate, `SpiderPackStore.url(for:)` returning `nil`, turns
  the whole feature off and leaves the bundled scripts running. No second runtime, no forked code
  path, no duplicated registry. That is why no build flavour was added now.

## Verification

- `WANG_MOVIE_JSON=… swift test --package-path ios` → **91 tests, all pass** (12 new pack tests).
- Live: `aSpiderDeliveredAsACompatibilityPackDrivesTheLiveSite` published the bundled `App99`
  through the pack machinery — real manifest, real SHA-256, real install — and drove 剧圈99:
  `home=18 list=21 play=https://vip.ffzy-play10.com/…/index.m3u8`.
- `xcodebuild … -scheme WebHTVApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
  -configuration Debug build` → BUILD SUCCEEDED.
- `scripts/spider_pack.py build` emitted an 8-script manifest; `fingerprint` reported all eight
  unchanged against the JARs on disk.
- **Simulator only.** Nothing in this project has run on a physical device.

## Ponytail review of the final diff

- The store is one file and one actor; the registry gained a `Source` enum and one overlay function.
  No protocol, no factory, no dependency-injection container.
- `InstalledSpiderPack` is an `NSLock` box because building a registry is synchronous and happens on
  every content call — the same shape `CookieJar` already uses, rather than making the whole
  registry path async.
- `URLSession` is injected as a closure, not a protocol, which is what let all twelve failure modes
  be tested without a server.
- Not written: pack signing, delta updates, a rollback UI, per-site pinning, a second build flavour.

## Known limits

1. **Integrity without authenticity.** Whoever serves the pack decides what runs. Signing is the
   upgrade path.
2. **A pack cannot be rolled back from the device.** The next good publish wins; there is no
   "previous version" button. Deleting the app's data falls back to bundled.
3. **`installedPack()` re-hashes on every cold read** — ~100 KB, so it is not worth caching, but it
   is not free either.
