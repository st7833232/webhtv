# IOS-POC-5N — do the other protected sites have unprotected equivalents?

Assessment only. No code changed. Triggered by IOS-POC-5M, where 薦片 turned out to be reachable
through a completely different class than the one it is configured with.

## The question

35 configured sites name a class that is an empty shim over a native-encrypted payload
(`aowu-0722.jar`, `fan-0720.jar`, `aowu.jar`). Porting those classes is impossible — there is no
logic in them. But 薦片 proved the site behind such a class can still be reachable, if some *other*
JAR carries an unprotected class for the same service. This asks that question for the other 34.

## Method

1. The 35 protected sites, with their `key`, display name and `ext`, straight from `wang-movie.json`.
2. Every class in the five unprotected JARs — `river-fman`, `xiaosa-0807`, `愛影`, `xyqxbpq`,
   `custom_spider` — **169 distinct names**, taken from the DEX string pools rather than guessed.
3. Each of those classes decompiled far enough to read the API hosts it talks to.
4. Matched in this order, because the orders differ in how much they prove:
   - **ext-level** — the protected site's own `ext` names a host the candidate class targets. This is
     the standard IOS-POC-5M met, and it is proof.
   - **brand-level** — the candidate's API host is unmistakably the service the site is named after
     (`qmplaylet.com` for 七猫, `dbokutv.com` for 獨播庫). Strong, not proof.
   - **name-level** — only the class names correspond (`HxqAmns` ↔ `Hxq`). A lead, nothing more.

All JARs were fetched from the user's own GitLab on 2026-09-17; `aowu.jar` had never been downloaded
before IOS-POC-5M.

## Result: 10 of 35 sites are not actually stuck

| protected class | sites | site name | equivalent | evidence | host checked 2026-09-17 |
|---|---:|---|---|---|---|
| `JPianAmns` | 1 | 薦片 | **`JianPian`** (river-fman) | ext-level | **ported and playable** (IOS-POC-5M) |
| `BidysAmns` | 2 | 哔嘀 2K | **`XueLuo`** (river-fman, 249 lines) | **ext-level** — the site's `ext` is the domain list `https://v.xl01.eu.cc,https://xl02.com.de,…` and `XueLuo`'s compiled-in default host is `https://v.xl01.eu.cc`; its `init` takes that host from `ext` | `v.xl01.eu.cc` → **200** |
| `QmdjAmns` | 1 | 七猫短剧 | `QimaoDJ` (xiaosa, 287 lines) | brand-level — `api-read/api-store/neptune.qmplaylet.com` is 七猫's own playlet API | `neptune…/playlet-domain-android.json` → **200** |
| `DubkAmns` | 1 | 獨播庫 | `Duboku` (river-fman, 255 lines) | brand-level — `api.dbokutv.com`, `w.duboku.io`, `www.duboku.tv` | `api.dbokutv.com` → 400 (host up, needs params); `w.duboku.io` dead |
| `HHkkAmns` | 1 | 好看短剧 | `HaokanDJ` (xiaosa, 158 lines) | brand-level — `sv.baidu.com/haokan/ui-feed/playletShelfFeed`, Baidu 好看's playlet feed | `sv.baidu.com` → 404 on a bare path (host up) |
| `HxqAmns` | 1 | 韓劇 | `Hxq` (xiaosa, 1688 lines) | name-level — identical name; the class builds its host at runtime, so nothing was confirmed | not established |
| `JpysGuard` | 1 | 文采 | `Jpys` (river-fman, 326 lines) / `Jys` (324) | name-level — `JpysGuard` ↔ `Jpys`, but both target `www.hkybqufgh.com`, which does not obviously belong to 文采 | `www.hkybqufgh.com` → **200** |
| `AiGuaAmns` | 1 | 愛瓜 | — **already covered** | the configuration separately carries `爱瓜TV` as a type-4 source, which the sweeps list as PLAYABLE | — |
| `OlyyAmns` | 1 | 歐樂 | — **already covered** | the configuration separately carries `csp_歐樂影院ORG` on the ported `XBPQ` engine | — |

**Seven sites are new, reachable work** (哔嘀 ×2, 七猫短剧, 獨播庫, 好看短剧, 韓劇, 文采), through
**six classes**. Two more were already covered by other entries in the same configuration and simply
had not been noticed. One is done.

## The other 25 sites: no equivalent found

| protected class | sites | site names |
|---|---:|---|
| `AppV7Amns` | 9 | 菠菜专线 ①–⑨ |
| `AppV6Amns` | 2 | 大师兄, 大師 |
| `HgggAmns` | 2 | 嗷嗚短劇, 嗷嗚漫劇 |
| `AowuDmAmns`, `AiyfAmns`, `BddjAmns`, `FanShuAmns`, `JinPaiAmns`, `XydjAmns`, `YIysAmns`, `YspAmns` | 8 | 喵嗚动漫, 愛壹帆, 拜拜短剧, 番薯, 金牌, 星星短剧, 銀牌, 優影 |
| `AueteGuard`, `BttwooGuard`, `NmyswvGuard`, `T4Guard` | 4 | 奥特, 比特, 糯米, 奶酪 |

“Not found” means: no class among the 169 targets a host that matches the site, and no name
corresponds. It is not a statement that no such implementation exists anywhere — only that **this
JAR set does not contain one**.

Three of these groups are worth a note:

- **The 9 `AppV7Amns` sites (菠菜专线) are the ones the user already asked about.** Their `ext` is
  encrypted hex sharing the middle segment `5714a2413f05151fea6864509533510f`, so even the site's
  identity is unknown; that is why the first step recorded for them is black-box observation on
  Android, not a search through JARs. Nothing here changes that.
- **`AppV6Amns` (大师兄)** has no candidate in the downloaded set, and the one remaining undownloaded
  JAR — `op_ticket_…_vip.jar` on `s3plus.meituan.net`, which carries `AppV6` — is the obvious place
  to look. That is the last “resource missing” row in the matrix.
- **`HgggAmns`'s two sites** pass `short_play` and `comic_series` as `ext`, which reads like one
  backend with two content modes. Several 短剧 classes exist (`TianquanDJ`, `WeiguanDJ`, `HemaDJ`,
  `QimaoDJ`, `HaokanDJ`, `Duanjuw`), but none of their hosts matches 嗷嗚.

## Recommended order, if this is pursued

Ranked by evidence and by what a live host was measured doing, not by site count:

1. **`XueLuo`** — 2 sites, ext-level proof, host answers 200. 249 lines, HTML scraping plus one AES
   step; the same shape as `XBPQ`'s play path.
2. **`QimaoDJ`** — 1 site, live domain-config endpoint, 287 lines, and it is a clean app API.
3. **`Duboku`** — 1 site, 255 lines, host up.
4. **`HaokanDJ`** — 1 site, 158 lines, the smallest of all of them.
5. **Confirm before porting:** `Hxq` (1688 lines, identity unconfirmed) and `Jpys` (identity
   unconfirmed). Establish what the site actually is before spending the effort.

Each of 1–4 is the same shape of work as the IOS-POC-5L ports and carries the same caveat: a class
being ported says the engine runs, not that the provider is alive on any given day.

## What this does not claim

- Nothing was ported in this stage and no code changed.
- A brand-level match is not proof. `Duboku`, `QimaoDJ` and `HaokanDJ` should each be confirmed the
  way `JianPian` was — by driving the site end to end — before the migration ledger calls them done.
- The protected payloads were not touched, and this changes nothing about that boundary.
