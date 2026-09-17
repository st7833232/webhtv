# IOS-POC-5L — porting `AppQi`, `App99`, `App3Q` and `Bili`

Batch port of four `csp_*` classes, chosen because together they unlock **16 configured sites**, the
largest remaining block after the three engines already shipped. Runtime contract:
`docs/IOS_SPIDER_RUNTIME_SPEC.md`. Progress ledger: `docs/CSP_MIGRATION_STATUS.md`.

## Recovery anchor

- **Objective**: `csp_AppQi` (6 sites), `csp_App99` (4), `csp_App3Q` (2) and `csp_Bili` (4) run
  through `SourceClient` like the three already-ported classes, with the live sweep recording what
  each site actually does.
- **Acceptance**: the four scripts are registered, `swift test` stays green, and every one of the 16
  sites has a measured verdict — playable, provider-dead, or a named defect.
- **Not in scope**: the remaining 23 portable classes, Python/drpy, per-request headers for
  `AVPlayer`, the protected `aowu`/`fan` JARs.

## Sources read

Decompiled 2026-09-17 with `jadx` from the user's own GitLab (`.../recha/-/raw/main/jar/`), because
`recha-main.zip` was never restored to this machine.

| JAR | md5 | matches `wang-movie.json` |
|---|---|---|
| `river-fman.jar` | `ca48f92eac069c85a17e4ccf381d5f0a` | yes, byte for byte |
| `xiaosa-0807.jar` | `d8f71fc80b0ae9561838ca59585077e5` | **no** — the config declares `4d26327105a38656ed960e7422a85251`, so the published JAR has been replaced since the config was written |
| `愛影.jar` | `12116b9d861206d798677da148c0d331` | config declares no md5 |

Line counts for the `river-fman` classes match `docs/CSP_PORTABILITY_MATRIX.md` exactly (494 / 556 /
265 / 284), so the audit and this decompilation are looking at the same file. The `xiaosa` mismatch
means its three variants were read from a **newer** build than the one audited; both variants were
diffed and the port covers the union.

## What differs between JAR variants

One script per class serves every variant, because the differences are small:

| class | river-fman | xiaosa-0807 / 愛影 | how the port handles it |
|---|---|---|---|
| `AppQi` | — | search re-tries through `getSlider` + `verifySlider` when the API answers `code 1001` | always parse the envelope first; run the slider round only on `1001` |
| `App3Q` | `finger`/`pkg`/`sk`/`ver` are compiled-in constants, `ext` is a bare host string | the same fields come from `ext`, plus `accept` and `x-platform` headers | read `ext` when it is JSON, fall back to the constants; send the two extra headers always |
| `App99` | player parses via `GET api_url + url` | player parses via `POST /app/vodParser` with an encrypted body | try `api_url` when the parse entry has one, else `vodParser` |
| `Bili` | — | not present | — |

## Design decisions

**Deliberate deviations from the decompiled original, and why.**

1. **`Bili` never builds the DASH manifest.** The original's `playerContent` returns
   `Proxy.getUrl()?do=bili&…&type=mpd`, a URL served by the Android app's own local HTTP server,
   which calls `Bili.proxy()` to synthesise an MPD from `dash`. iOS has no such server — and it
   would not help, because **`AVPlayer` cannot play MPEG-DASH at all**. The port asks
   `playurl` for `fnval=1` instead, which returns a progressive `durl` MP4 that `AVPlayer` opens
   directly. Measured 2026-09-17: the `upos-*.akamaized.net` CDN serves that MP4 with a 206 to a
   bare `AppleCoreMedia` request — no Referer, no cookie — so the missing per-request headers in
   `PlayerView` do not block this source.
2. **`Bili` reads `/x/web-interface/wbi/view`, not `/x/web-interface/view`.** The endpoint the
   original calls now answers with an HTML error page for every aid and bvid tried (with and without
   a fresh `buvid3` from `/x/frontend/finger/spi`). `wbi/view` returns the same document — title,
   pic, desc, owner, duration, `pages[]` — and, measured today, needs no `w_rid` signature.
3. **`Bili` drops the up-主 collection branch.** `categoryContent` has a second path for a `tid`
   ending in `/{pg}`, which needs wbi query signing. None of the four configured sites uses it: all
   39 + 12 + 12 + 10 categories in their `./json/*.json` are plain search keywords. Not written.
4. **`App99` publishes no filter rows.** The original builds them from `type_extend` and then
   `categoryContent` reads each value and throws it away — the filters are dead in the DEX. A row
   that does nothing is worse than no row, so the port omits them rather than shipping dead chips.
5. **`App99` keeps the first parse result.** The decompiled loop assigns the resolved URL and then
   clears it after the loop, which would make every non-direct episode unplayable. The port stops at
   the first non-empty result and, if none resolves, hands the raw target back as `parse:1` so the
   IOS-POC-5G sniffer gets a chance — the fallback `AppGet.js` already uses.
6. **`AppQi` sends `全部` as an empty filter value**, as `AppGet.js` does since IOS-POC-5J. The
   original sends the literal word, which the API would filter by.
7. **`App99`'s `processDetailResult`** (xiaosa only: reorder 4K/藍光 flags to the front) is not
   ported. Flag order stays the site's own.
8. **Danmaku is dropped** in all four, as in every earlier port: the URLs are
   `Proxy.getUrl()`-relative and there is no local HTTP server on iOS.

**Host additions.** `App99` encrypts with AES-CBC under a random IV and ships `base64(iv‖ct)`,
decrypting the reply the same way. That cannot be expressed with `host.aesEncrypt`, whose IV is a
string, so `__crypto.symmetricIV` joins `CryptoHost` and surfaces as `host.aesEncryptIV` /
`host.aesDecryptIV` — a primitive in the host, not a cipher inside a spider, per the runtime spec.

**Config-relative `ext`.** `CSPSourceResolver.resolvedExtend` resolved a bare relative `ext`
(`./json/农民影视.json`) but not a relative path *inside* a JSON `ext`, which is what `Bili` uses
(`{"json": "./json/bili听书.json"}`). It now rewrites `./…` string values one level into a JSON
object, so the same rule covers both.

## Results — measured 2026-09-17

`SWEEP_CONFIG=… SWEEP_BASE=https://gitlab.com/…/wang-movie.json swift test --package-path ios
--filter sweepsEveryDrivableSource`, the same `SourceClient` path the app uses, with the first bytes
of every resolved stream fetched.

**61 sources listed (was 45): PLAYABLE 37, DEAD-MEDIA 7, NO-PLAY 1, NO-EPISODE 1, EMPTY 15.**
Native CMS is 26 of 30 today, spiders 11 of 31.

The 16 sites this stage adds:

| class | site | verdict | what actually happened |
|---|---|---|---|
| `App99` | 剧圈99 | **PLAYABLE** | 18 classes → 21 titles → 4 flags → `parse:0` `vip.ffzy-play10.com/…m3u8`, first bytes are media |
| `App3Q` | 三秋影视 | **PLAYABLE** | resolves and plays — but the file is `bubutv.top/video_close_site.mp4`, the provider's own "site closed" notice |
| `App3Q` | 云朵影视 | NO-PLAY | browse, detail (7 flags, 14 episodes) and search all work; `/app/decode/url/` answers `{"code":403,"msg":"VIP权益已过期"}` — the account, not the port |
| `Bili` | bili, bilitingshu, bilimanhua, biligequ | DEAD-MEDIA ×4 | all four list (39/12/12/10 classes, 20 titles each), reach detail and resolve a **real progressive MP4** — which then 403s, see below |
| `AppQi` | gulu | NO-EPISODE | 15 classes, 30 titles — then detail returned no flags on a host that answers 504 more often than not |
| `AppQi` | csp_AppQi_爱影, 爱影 ×2, 星河, 怀桑 | EMPTY ×5 | no host to talk to, see below |
| `App99` | 听心99, 橙子99, 双星99 | EMPTY ×3 | `api.12321app.com` and `113.31.180.218` time out; `175.178.65.250` answers HTTP 500 |

### `Bili`: resolved, and blocked on one header

The four bilibili sites resolve an MP4 that plays — with a `Referer`. Measured on the same URL
minutes apart:

```
GET …upos-sz-mirrorcosov.bilivideo.com/…  bare AppleCoreMedia UA  → 403
GET …upos-sz-mirrorcosov.bilivideo.com/…  + Referer bilibili.com  → 206
```

The port attaches that Referer to its play result. `SourceClient` drops it, because `AVPlayer` takes
request headers only through `AVURLAsset` options and `PlayerView` does not thread them through —
the limitation already documented in `SourceClient.swift`. **These four sites become playable the
day per-request headers land, with no change to `Bili.js`.** (Not every mirror checks: an
`upos-hz-mirrorakam.akamaized.net` URL served 206 to a bare request. Which CDN a request lands on is
bilibili's choice, not ours.)

### `AppQi`: ported, essentially unverified

Its six sites resolve to four distinct hosts, and on 2026-09-17 all four were dead:

| host | sites | state |
|---|---|---|
| `103.86.44.11:28236` / `:22346` | 爱影 ×2 | connection refused (the `ext.site` text files that name them are reachable) |
| `v12-1-hulucms.nmgbch.cn` | gulu | HTTP 504 from nginx, intermittently — it answered once mid-sweep and 12 retries later never did |
| `daen-…myqcloud.com/MuQi/mqxhqj.txt` | 星河, 怀桑 | the host-list file itself fails to resolve |
| `222.211.75.252:16118` | csp_AppQi_爱影 | connection refused |

The one window in which `gulu` answered proves `init` (fetching the host list), the AES envelope,
`homeContent` (15 classes) and `categoryContent` (30 titles) work. `detailContent` and
`playerContent` are **not** verified; the single attempt returned no flags, which on a host that
504s at that rate is at least as likely to be the host as the port. Re-run the golden test whenever
one of these hosts is up:

```bash
CSP_GOLDEN_SITE='{"key":"gulu","name":"gulu","type":3,"api":"csp_AppQi","ext":{…}}' \
  swift test --package-path ios --filter appGetDrivesTheWholeCatVodFlow
```

### Two defects found and fixed during the stage

1. **`App99` returned nothing at all.** Its `systemInit` reply decrypts to 36 KB of **zlib**, not
   text, and reading those bytes as a String produced replacement characters. The decompiled
   `c()` runs `java.util.zip.Inflater` and silently falls back to the raw bytes, which is easy to
   read as defensive noise; it is not. `CryptoHost.ivPrefixed` now inflates before decoding, and all
   four `App99` sites went from `classes=0` to a working listing.
2. **`Bili` intermittently listed nothing.** bilibili answers an HTML error page instead of JSON when
   it dislikes the session, and three of the four sites carry a `SESSDATA` that expired in 2025. One
   retry as the anonymous visitor fixed `bilitingshu` and `bilimanhua`, which had swept as EMPTY.

## Ponytail review of the final diff

- `NSData.decompressed(using: .zlib)` replaced a hand-rolled `compression_decode_buffer` loop with a
  growing output buffer: 25 lines became 4, same behaviour.
- `CryptoHost.transform` is extracted rather than duplicated, because `run` and `ivPrefixed` need the
  identical `CCCrypt` call; no other caller exists and none is anticipated.
- `Bili` does not implement wbi signing, the DASH assembly or the up-主 branch — none is reachable
  from the configured sites, and DASH cannot play on `AVPlayer` at all.
- `App99` publishes no filter rows and no flag reordering; both exist in the original and both are
  dead or cosmetic.
- One runnable check for the new primitive:
  `carriesTheIVInFrontOfTheCiphertextTheWayApp99Does` in `SpiderHostTests.swift`, which asserts the
  round trip, a fresh IV per call, the `base64(iv‖ct)` length, and that a wrong key or a truncated
  payload is empty rather than a crash.

## Verification

- `WANG_MOVIE_JSON=… swift test --package-path ios` → **78 tests**. Live golden runs of `App99`
  (剧圈99) and `App3Q` (云朵影视) pass through home → category → detail → search → player.
- The sweep above, 61 sources.
- `xcodebuild -project ios/WebHTVApp/WebHTVApp.xcodeproj -scheme WebHTVApp -destination
  'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build` passes.
- **Simulator only.** Nothing in this stage has run on a physical device; the project still carries
  no `CODE_SIGN` or `DEVELOPMENT_TEAM` settings.
