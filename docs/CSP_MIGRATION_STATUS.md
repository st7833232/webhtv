# csp_* migration status

Living record of which spiders are ported, verified, blocked, or waiting on a file.
Audit data: `docs/CSP_PORTABILITY_MATRIX.md`. Runtime contract: `docs/IOS_SPIDER_RUNTIME_SPEC.md`.

Last updated 2026-09-17 (IOS-POC-5M: `JianPian` ported, which drives 薦片 despite its class being
blocked; IOS-POC-5L added `AppQi`, `App99`, `App3Q` and `Bili`).

## Headline

| | audit rows | distinct classes | sites |
|---|---:|---:|---:|
| configured `csp_*` | 58 | 51 | 90 |
| **portable** (categories A–C) | **33** | **26** | **54** |
|  ported | 8 | 7 | 31 |
|  portable, not yet ported | 25 | 19 | 23 |
| blocked by native protection (H) | 24 | 24 | 35 |
|   of which driven anyway, through an equivalent class | 1 | 1 | 1 |
| missing resource | 1 | 1 | 1 |

**Read the two class columns carefully.** The audit keys a class by *(class name, JAR)*, so the same
class shipped in two JARs is two rows: 58 rows over 51 distinct names. Only the distinct column adds
up to 51 (26 + 23 + 2). The sites column is exact either way, because each configured site maps to
exactly one row. Earlier revisions of this file and the summary table in
`docs/CSP_PORTABILITY_MATRIX.md` put the 33-row figure under a “classes” heading against a
denominator of 51, which cannot be right — 33 + 23 + 2 = 58, not 51. The port count is what matters
for planning, and a duplicated class costs one port, not two: porting the 26th portable class covers
every JAR it appears in.

**54 of 90 sites are reachable work.** The earlier record called all 90 permanently unreachable;
that was wrong, and this file supersedes it — `docs/IOS-TYPE3-REACHABILITY-2026-09-16.md` now
carries a banner saying so.

**Since IOS-POC-5M these 32 sites are listed in the app UI**, which now offers 62 of 167 sources
(30 native + 32 spider) through `SourceClient`.

**A blocked class does not always mean a blocked site.** `JPianAmns` is an empty shim over an
encrypted payload, but 薦片 is served today by river-fman's unprotected `JianPian`, registered under
both names (`docs/IOS-POC-5M-jianpian.md`).

**That question has now been asked for all 35 protected sites** (IOS-POC-5N, assessment only):
**7 more are reachable** through 6 unprotected classes — `XueLuo` for 哔嘀 ×2 with ext-level proof,
then `QimaoDJ`, `Duboku`, `HaokanDJ`, and `Hxq` / `Jpys` whose identity still needs confirming — and
**2 were already covered** by other entries in the same configuration (愛瓜 as a type-4 source,
歐樂 on `XBPQ`). The remaining 25, including the 9 菠菜专线 sites whose very identity is encrypted,
have no equivalent anywhere in this JAR set. Table and evidence grades:
`docs/IOS-POC-5N-protected-site-equivalents.md`.

**But listed is not working.** Every listed source is swept through the app's own path and the first
bytes of each resolved stream are fetched, because a URL resolving and the media existing are
different things. Per-site verdicts live in the stage documents: 45 sources in
`docs/IOS-POC-5E-all-source-sweep.md` (with the fixes in `-5F`, `-5G` and `-5I`), and the 61-source
sweep after this stage in `docs/IOS-POC-5L-appqi-app99-app3q-bili.md`. **A class being “ported”
means the engine runs, not that every site configured for it is alive** — of the 16 sites added
here, all six `AppQi` hosts were dead on the day, and two of the four `App99` hosts time out.

## Verified

| class | sites | category | evidence |
|---|---:|---|---|
| `AppGet` | 5 | C. HTTP + crypto | Live golden: home 6 classes → category 30 → detail 荒山野店, 2 flags → search 20 → player `parse:0` direct m3u8. |
| `XBPQ` | 7 | C. rule engine | Live golden on **two** sites. 果果短剧: category 30 → detail → `parse:0` m3u8. AG動漫: category 12 → detail 金田一少年事件簿 with **149 episodes** → `parse:0` m3u8. |
| `XYQHiker` | 3 | A. rule engine | Live golden on 农民影视: category 30 → detail 《抓特务》 with flags `[线路①, 线路②]` → search 20 → player `parse:0` m3u8. |
| `App99` | 4 | C. HTTP + crypto | IOS-POC-5L live golden on 剧圈99: home 18 classes → category 21 → detail 打生桩 with 4 flags → search 21 → player `parse:0` direct m3u8. |
| `App3Q` | 2 | C. HTTP + crypto | IOS-POC-5L live golden on 云朵影视: home 4 classes → category 24 → detail 八仙！ with 4 flags → search 15. Playback stops at the site's own `{"code":403,"msg":"VIP权益已过期"}`. |
| `Bili` | 4 | B. HTTP + JSON | IOS-POC-5L live: 39 classes from the site's own JSON → search listing 20 → detail → `playurl` `parse:0` progressive MP4. The MP4 then needs a `Referer` the player cannot send yet. |
| `AppQi` | 6 | B. HTTP + crypto | **Ported, unverified.** All four hosts the six sites resolve to were dead on 2026-09-17 — two connection-refused, one 504, one DNS failure — so no request reached a live API. |
| `JianPian` | 1 | A. HTTP + JSON | IOS-POC-5M live golden on 薦片 (configured as `csp_JPianAmns`): 5 classes → 15 titles → detail with **24 lines** → search 20 → `parse:0` m3u8 whose playlist fetches as media with no Referer. |

The first three were re-run live on 2026-09-17 at HEAD `226e826c` and each still ends in a `parse:0`
direct stream. **Caveat on `XYQHiker`:** all 3 of its configured sites set `ext` to a relative path
(`./json/农民影视.json`), and `ConfigSource.importedFile` has no base URL, so `resourceURL` returns
nil and the rule file cannot be fetched. Those 3 sites therefore work only when the configuration
was loaded from a remote URL; the 2026-09-17 golden run substituted the absolute URL by hand.
`AppGet` and `XBPQ` carry inline `ext` objects and are unaffected.

`XBPQ` and `XYQHiker` are **rule engines**, so those 10 sites are what this configuration happens to
contain — the ports serve any future site configured for either engine without further work.

## Not ported yet — ranked by sites unlocked

Highest value first. The App-API family (`AppQi`, `App99`, `App3Q`) and `Bili` left this table in
IOS-POC-5L; `AppDrama` is the last of the family and is blocked on RSA in the host.

| class | sites | category | note |
|---|---:|---|---|
| `AppDrama` | 4 | C | App-API family; **needs RSA in the host** |
| `Douban` | 2 | A | plain JSON |
| remaining A/B/C | 3 | A–C | `AppYsV2`, `GuaziTY`, `Wwys`, `Jpys`, `Jys`, `Hxq`, `PianKu8`, `Feiyu`, `AppYQK`, `HemaDJ`, `WeiguanDJ`, `HaokanDJ`, `QimaoDJ`, `AppSy`, `MiaoWu`, `MoDu`, `Uvod`, 1 site each |

### The App-API family, as ported in IOS-POC-5L

`AppGet`, `AppQi`, `App99` and `App3Q` are four dialects of the same 苹果CMS app backend and share
`homeContent → categoryContent → detailContent → playerContent` shape, but not much else:

| | endpoint prefix | body | response | player |
|---|---|---|---|---|
| `AppGet` | `/api.php/getappapi.index/` | plain JSON | `{"data": base64}`, AES-CBC on `dataKey`/`dataIv` | `parse_api=…&url=base64(url)` |
| `AppQi` | `/api.php/qijiappapi.index/` | plain JSON | same envelope | `url=base64(AES(url))`, resolved by a signed `vodParse` POST |
| `App99` | `/vod/…`, `/app/…` | AES-CBC under a **random IV**, `base64(iv‖ct)`, keyed by the client's own uuid | same dialect, **zlib-compressed inside** | the site's parse list, by `api_url` or a signed `/app/vodParser` |
| `App3Q` | `/api.php/app/` | none — plain GET | plain JSON | `/app/decode/url/` |

Two things in `AppQi` must not be copied from `AppGet.js`: the episode `url=` payload is
`base64(AES(url))`, **not** plain base64 — the site's own `vodParse` endpoint consumes it — and
`Proxy.getUrl()` danmaku URLs have no iOS equivalent and are dropped. 5 of its 6 sites resolve their
host from an `ext.site` text file of candidate URLs.

`App99` was the one port that needed a new host primitive: nothing in `CatVodHost` could express an
IV carried in front of the ciphertext, and its `systemInit` reply is 36 KB of zlib that has to be
inflated **before** the bytes become a String. Both now live in `CryptoHost`
(`host.aesEncryptIV` / `aesDecryptIV`), not in the spider.

Full design record, including every deliberate deviation from the decompiled original:
`docs/IOS-POC-5L-appqi-app99-app3q-bili.md`.

## Blocked — native-protected payload

`aowu-0722.jar` (18 classes, 29 sites) and `fan-0720.jar` (5 classes, 5 sites).

These JARs contain no spider logic. Every `csp_*` class in them is an empty 6-line subclass:

```java
public class AppV7Amns extends AowuShinidie { }
```

`DexNative` extracts an embedded `awdm-v7/v8.so`, `System.load()`s it, and `Init.getSpider(name)`
asks that native library to hand back a `Spider` decrypted from a payload (`aowunnn.amns`) shipped
inside the JAR. `fan-0720.jar` does the same and additionally ships `ftyguard_v7.so` /
`ftyguard_v8.so`, whose names state their purpose.

The logic is therefore not merely obfuscated — it is **encrypted, and decrypted only by a native
library built to stop exactly this inspection**. Reading it means defeating that protection, which is
a different act from decompiling ordinary bytecode, so it is not attempted here.

Note this is a statement about how those two JARs are packaged, not about the underlying sites. If a
site in this group matters, the practical routes are a rule-engine equivalent (`XBPQ`/`XYQHiker`) or
a direct HTTP/CMS entry, not unpacking the payload.

## Missing resource — not a technical verdict

Both are referenced by URL and were never downloaded into `recha-main.zip`.

| class | site | JAR |
|---|---|---|
| `JPianAmns` | 1 | `https://gitlab.com/st7833232/recha/-/raw/main/jar/aowu.jar` |
| `AppV6` | 1 | `https://s3plus.meituan.net/opapisdk/op_ticket_1_5677168484_1774853250308_PA5tmo8g_vip.jar` |

Nothing is known about their portability. The first is on the user's own GitLab and could simply be
fetched; the name `aowu.jar` suggests it belongs to the protected family, but that is a guess and is
recorded as one.

## Native `.so` inventory

| JAR | native payload | who calls it |
|---|---|---|
| `fan-0720.jar` | `ftyguard_v7.so`, `ftyguard_v8.so` | its 5 shim classes, via the protected loader |
| `aowu-0722.jar` | `awdm-v7/v8.so`, embedded encrypted rather than stored as `.so` | `DexNative`, for all 18 shim classes |
| every other JAR | none | — |

**No spider in the portable set touches JNI.** The `.so` question is confined entirely to the two
protected JARs, and does not block any of the 33 portable classes.
