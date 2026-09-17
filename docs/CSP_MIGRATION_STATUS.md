# csp_* migration status

Living record of which spiders are ported, verified, blocked, or waiting on a file.
Audit data: `docs/CSP_PORTABILITY_MATRIX.md`. Runtime contract: `docs/IOS_SPIDER_RUNTIME_SPEC.md`.

Last updated 2026-09-17 (IOS-POC-5C reconciliation; the ports themselves are unchanged since
IOS-POC-5B).

## Headline

| | audit rows | distinct classes | sites |
|---|---:|---:|---:|
| configured `csp_*` | 58 | 51 | 90 |
| **portable** (categories A–C) | **33** | **26** | **54** |
|  ported and verified | 3 | 3 | 15 |
|  portable, not yet ported | 30 | 23 | 39 |
| blocked by native protection (H) | 23 | 23 | 34 |
| missing resource | 2 | 2 | 2 |

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

**Since IOS-POC-5D these 15 sites are listed in the app UI**, which now offers 45 of 167 sources
(30 native + 15 spider) through `SourceClient`.

**But listed is not working.** IOS-POC-5E swept all 15 through the app's own path and fetched the
first bytes of each resolved stream; IOS-POC-5F fixed five host/engine defects it found.
**5 are now playable** (王子, 农民, 果果短剧, 灵虎, 不戳 — 农民 played in the simulator), 2 browse and
list 158 episodes but resolve no stream (動漫巴士 / 巴士动漫: their rule file expects a sniffer and the
play page currently 522s), 1 resolves media that 404s, 2 list category links instead of titles
because the provider's listing URL 404s, and 5 are empty on provider state (522/403/301, or the
site itself answering 「暂无数据」). Per-site table: `docs/IOS-POC-5E-all-source-sweep.md`; fixes:
`docs/IOS-POC-5F-spider-defect-fixes.md`. A class being “ported and verified” means the engine
runs, not that every site configured for it is alive.

## Verified

| class | sites | category | evidence |
|---|---:|---|---|
| `AppGet` | 5 | C. HTTP + crypto | Live golden: home 6 classes → category 30 → detail 荒山野店, 2 flags → search 20 → player `parse:0` direct m3u8. |
| `XBPQ` | 7 | C. rule engine | Live golden on **two** sites. 果果短剧: category 30 → detail → `parse:0` m3u8. AG動漫: category 12 → detail 金田一少年事件簿 with **149 episodes** → `parse:0` m3u8. |
| `XYQHiker` | 3 | A. rule engine | Live golden on 农民影视: category 30 → detail 《抓特务》 with flags `[线路①, 线路②]` → search 20 → player `parse:0` m3u8. |

All three were re-run live on 2026-09-17 at HEAD `226e826c` and each still ends in a `parse:0`
direct stream. **Caveat on `XYQHiker`:** all 3 of its configured sites set `ext` to a relative path
(`./json/农民影视.json`), and `ConfigSource.importedFile` has no base URL, so `resourceURL` returns
nil and the rule file cannot be fetched. Those 3 sites therefore work only when the configuration
was loaded from a remote URL; the 2026-09-17 golden run substituted the absolute URL by hand.
`AppGet` and `XBPQ` carry inline `ext` objects and are unaffected.

`XBPQ` and `XYQHiker` are **rule engines**, so those 10 sites are what this configuration happens to
contain — the ports serve any future site configured for either engine without further work.

## Not ported yet — ranked by sites unlocked

Highest value first. `AppQi`, `App99` and `App3Q` are the same 苹果CMS App-API family as the ported
`AppGet`, so they mostly reuse its shape; `XBPQ` and `XYQHiker` are **rule engines** rather than
site-specific scrapers, which is why they are worth far more than their site counts suggest.

| class | sites | category | note |
|---|---:|---|---|
| `AppQi` | 6 | B | same App-API family as `AppGet` |
| `App99` | 4 | C | App-API family plus a signed login |
| `AppDrama` | 4 | C | App-API family; **needs RSA in the host** |
| `Bili` | 4 | B | Bilibili public API, no crypto |
| `App3Q` | 2 | C | App-API family |
| `Douban` | 2 | A | plain JSON |
| remaining A/B/C | 3 | A–C | `AppYsV2`, `GuaziTY`, `Wwys`, `Jpys`, `Jys`, `Hxq`, `PianKu8`, `Feiyu`, `AppYQK`, `HemaDJ`, `WeiguanDJ`, `HaokanDJ`, `QimaoDJ`, `AppSy`, `MiaoWu`, `MoDu`, `Uvod`, 1 site each |

### `AppQi` — static reading done 2026-09-17, not implemented

Recorded so the decompilation is not repeated. Against the verified `AppGet`, `AppQi` differs only
in: the `/qijiappapi.index/` endpoint prefix; `init` and `search` method names taken from `ext`
(defaults `initV120` / `searchList`, and all 6 configured sites set `initV122`, one setting
`search: mineInfo`); a home that also builds `filter_type_list` into CatVod `filters`; a slider
challenge retried when search answers `code 1001`; and a player that POSTs the whole
`parse_api=…&url=…&token=…` string to `/qijiappapi.index/vodParse` signed with
`app-api-verify-sign: base64(AES-CBC(timestamp, dataKey, dataIv))`, whose decrypted reply is
`{"json": "{\"url\": …}"}`. The crypto is stock `AES/CBC/PKCS7` on the site's own `dataKey`/`dataIv`,
already in `CatVodHost`.

Two things must not be copied from `AppGet.js`: the episode `url=` payload is
`base64(AES(url))`, **not** plain base64 — the site's own `vodParse` endpoint consumes it, so the
encryption is not internal to the spider — and `Proxy.getUrl()` danmaku URLs have no iOS equivalent
(no local HTTP server) and are simply dropped. 5 of the 6 sites resolve their host from an `ext.site`
text file of candidate URLs, which `AppGet.js` already handles.

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
