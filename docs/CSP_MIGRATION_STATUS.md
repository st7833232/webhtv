# csp_* migration status

Living record of which spiders are ported, verified, blocked, or waiting on a file.
Audit data: `docs/CSP_PORTABILITY_MATRIX.md`. Runtime contract: `docs/IOS_SPIDER_RUNTIME_SPEC.md`.

Last updated 2026-09-16 (IOS-POC-5B).

## Headline

| | classes | sites |
|---|---:|---:|
| configured `csp_*` | 51 | 90 |
| **portable** (categories A–C) | **33** | **54** |
| ported and verified | 3 | 15 |
| blocked by native protection (H) | 23 | 34 |
| missing resource | 2 | 2 |

**54 of 90 sites are reachable work.** The earlier record called all 90 permanently unreachable;
that was wrong, and this file supersedes it.

## Verified

| class | sites | category | evidence |
|---|---:|---|---|
| `AppGet` | 5 | C. HTTP + crypto | Live golden: home 6 classes → category 30 → detail 荒山野店, 2 flags → search 20 → player `parse:0` direct m3u8. |
| `XBPQ` | 7 | C. rule engine | Live golden on **two** sites. 果果短剧: category 30 → detail → `parse:0` m3u8. AG動漫: category 12 → detail 金田一少年事件簿 with **149 episodes** → `parse:0` m3u8. |
| `XYQHiker` | 3 | A. rule engine | Live golden on 农民影视: category 30 → detail 《抓特务》 with flags `[线路①, 线路②]` → search 20 → player `parse:0` m3u8. |

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
