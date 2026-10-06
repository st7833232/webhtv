# csp_* migration status

Living record of which spiders are ported, verified, blocked, or waiting on a file.
Audit data: `docs/CSP_PORTABILITY_MATRIX.md`. Runtime contract: `docs/IOS_SPIDER_RUNTIME_SPEC.md`.

Since IOS-POC-5O a ported script no longer has to be rebuilt into the app to be updated: a
compatibility pack published beside the configuration replaces it at runtime, hash-verified, with the
bundled copy as the fallback. What still requires an app release is a new `CatVodHost` primitive.
See `docs/IOS-POC-5O-remote-compatibility-pack.md`.

Last updated 2026-10-06: IOS-POC-44F ported `GuaziTY` and `MoDu`, IOS-POC-44E `AppYQK` and `AppYsV2` (`.vod` dialect only), IOS-POC-44D `Feiyu` and `MiaoWu` (one site each). Earlier, IOS-POC-44A ported `WeiguanDJ` and `HemaDJ`, IOS-POC-44B `QimaoDJ` and `HaokanDJ`, IOS-POC-44C `Jpys` and `Jys` (one script, one site each). Before that, port coverage was unchanged since IOS-POC-5M (`JianPian`, which
drives 薦片 despite its class being blocked; IOS-POC-5L added `AppQi`, `App99`, `App3Q` and `Bili`).
What changed since: IOS-POC-5P gave every spider's play result its request headers, and IOS-POC-5Q
made `Bili` report one line per quality — both noted in the `Bili` row below.

**IOS-POC-55 (2026-10-06): a renamed class no longer needs a port of its own when it is provably
the same protocol.** `scripts/audit_spider_jars.py compat` fingerprints every configured class in the
JAR the configuration actually references and maps it to an existing adapter only on an exact match
plus a live golden run; the mapping travels in the compatibility pack, scoped to configuration, site,
class and JAR SHA-256. On the 2026-10-06 configurations no unported class is such a copy (0 mappings);
the per-class reasons are in `docs/IOS-POC-55-jar-compat-reuse.md`.

## Headline

| | audit rows | distinct classes | sites |
|---|---:|---:|---:|
| configured `csp_*` | 58 | 51 | 90 |
| **portable** (categories A–C) | **33** | **26** | **54** |
|  ported | 20 | 19 | 43 |
|  portable, not yet ported | 13 | 7 | 11 |
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
(30 native + 32 spider) through `SourceClient`. (Corrected 2026-09-25: 62 is the count from an
imported file. A remote configuration also lists the 5 drpy sites (IOS-POC-6B) and the 42 Python
sites (IOS-POC-7H), 109 in total; see `docs/current-task-state.md` "Source coverage" and
`listsThePortedSpiderSitesAlongsideTheNativeCMSSites` in `ios/Tests/WebHTVCoreTests/SourceClientTests.swift`.)

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
| `Bili` | 4 | B. HTTP + JSON | IOS-POC-5L live: 39 classes from the site's own JSON → search listing 20 → detail → `playurl` `parse:0` progressive MP4. **The `Referer` that MP4 needs reaches the player since IOS-POC-5P.** Since IOS-POC-5Q the detail returns **one line per accepted quality** (`B站 高清 720P` …), each episode id carrying its own `qn`, verified live by `biliOffersMultipleQualityLines`. |
| `AppQi` | 6 | B. HTTP + crypto | **Ported, unverified.** All four hosts the six sites resolve to were dead on 2026-09-17 — two connection-refused, one 504, one DNS failure — so no request reached a live API. |
| `WeiguanDJ` | 1 | C. HTTP + md5 client id | IOS-POC-44A live golden on 围观短剧: 30 tag classes → category 30 → detail with 30 episodes → search 30 → `parse:0` mp4 quality list. |
| `HemaDJ` | 1 | A. HTTP + AES envelope | IOS-POC-44A live golden on 河马短剧: 8 channel groups → category 12 → detail with 71 episodes (one flag; the original repeats the list three times under it) → search 15 → `parse:0` mp4. |
| `QimaoDJ` | 1 | B. HTTP + md5 sign | IOS-POC-44B live golden on 七猫短剧: 150 tag classes → category 16 → detail with 69 episodes → search 10 → `parse:0` m3u8. |
| `HaokanDJ` | 1 | A. HTTP form POST | IOS-POC-44B live golden on 好看短剧: 29 classes → category 9 → two-hop detail with 70 episodes → `parse:0` 1080p mp4 (http). **Search returns nothing upstream** (`猜空了`), so it answers an empty list. |
| `Jpys` | 1 | C. HTTP + sha1(md5) sign | IOS-POC-44C live golden on 金牌: 4 classes with area/year filters → category 48 → detail → search 8 → `parse:0` m3u8. A mirror counts when the signed hotSearch answers, not when HEAD does. |
| `Jys` | 1 | C. (as `Jpys`) | Alias of `Jpys` (same body, same backend). Its only host's certificate expired 2026-08-07, so — exactly like the original's own check — it falls back to the class default `www.hkybqufgh.com`; live golden passes on that path. |
| `Feiyu` | 1 | C. HTTP + double HMAC-SHA256 sign | IOS-POC-44D live golden on 飛魚: 6 classes → category 20 (paged by the API's own total) → detail with 5 lines, best quality first → `parse:0` m3u8; ranking as the home list; search pages. Lines whose media host has an invalid certificate (`无水印`, `极速资源站`) cannot play on Apple platforms. |
| `MiaoWu` | 1 | C. DoH host + AES-256-ECB envelope | IOS-POC-44D live golden on 喵呜动漫: DoH → `app.nyafun.vip`, 6 classes with `class`/`year` filters (the original hides them by an 80-character cap and never sends them; the API honours both) → category 12 → detail → `parse:0` m3u8; `mwvod` files resolve through `vod/parse` to an R2 mp4. |
| `AppYQK` | 1 | B. HTTP + md5 sign | IOS-POC-44E live golden on 一起影视: 6 channels (短剧/体育 skipped as the original does) → one curated page of topics → detail with 18 lines → search with its `nextVal` cursor → `parse:0` quality list. Only `canPlay` qualities are offered: 超清 is marked `APP独享` and the web API refuses it. Many lines' media hosts have invalid certificates and cannot play on Apple platforms. |
| `AppYsV2` | 1 | A. HTTP + JSON | IOS-POC-44E, **`.vod` dialect only** (奴娜, `www.nntv.in/api.php/v1.vod`): 10 types with class/area/lang/year/排序 filters → category 18 a page (`data.total`/`limit`) → detail with 3 lines → `parse:0` m3u8; the `jazsjzlp_1080p` line is a play page that goes to the sniffer. The other dialects (`api.php/app`, `xgapp`, `iopenyun`, `?ac=list`) are not ported. |
| `GuaziTY` | 1 | A. HTTP + AES-CBC form POST | IOS-POC-44F live golden on 瓜子体育: 4 classes → one page of matches started within 24 h and not over → detail with its live lines → `parse:0` live m3u8 (TS segments read while the match was live). A match that has not started answers 404 until kick-off; a day without matches is an empty list, while an undecryptable reply is an error. No search, no second page (as the original). |
| `MoDu` | 1 | A. HTTP + JSON (苹果CMS) | IOS-POC-44F live golden on 魔都动漫 (`www.mdzyapi.com`, its own key beside the type-0 and type-1 魔都 sources): 5 fixed classes → 20 a page with `pagecount` → detail → search → `parse:0` m3u8. Episodes on `modujx10`/`modujx12` have self-signed certificates and 404; `modujx11/13/17` serve. |
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
| remaining A/B/C | 5 | A–C | `Wwys`, `Hxq`, `PianKu8`, `AppSy`, `Uvod`, 1 site each |

Which of these were alive on 2026-10-02, what each needs from the host, and the staged order they
are being ported in: `docs/IOS-POC-44-csp-portable-sites.md`.

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
