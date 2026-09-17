# IOS-POC-5M — 薦片, by way of `JianPian`

The configured site `薦片` names `csp_JPianAmns`. That class cannot be ported. The site can.

## What was actually established

`aowu.jar` had never been downloaded, so `docs/CSP_PORTABILITY_MATRIX.md` recorded `JPianAmns` as
“resource missing — portability unknown”, with a note that the JAR's name *suggested* the protected
family but that this was a guess. It is no longer a guess. Fetched 2026-09-17 from the user's own
GitLab (`.../recha/-/raw/main/jar/aowu.jar`, 922,473 bytes, md5 `29ee0730017660db62f57a585cd1aeb6`):

```
classes.dex              34,188      assets/aowunnn.amns    725,756
assets/awdm-v7.so       165,284      assets/awdm-v8.so      277,704
```

```java
public class JPianAmns extends BaseSpiderAmns { }
```

Same construction as `aowu-0722.jar`: an empty shim, the logic encrypted in `aowunnn.amns`, decrypted
only by the bundled native library. **Category H, confirmed rather than assumed.** Not attempted.

## The site is reachable another way

`river-fman.jar` carries `com.github.catvod.spider.JianPian`, 351 lines, plain HTTP and JSON, no
crypto of any kind. **It drives the same API**, and that is provable from the configuration itself
rather than from the name: the site's `ext` is a filter file whose categories are `1, 2, 3, 4, 67`
and whose keys are `type/area/year/sort` — and `67`'s are `category_id/sort`. Those are exactly the
placeholders `JianPian.categoryContent` substitutes into

```
/api/crumb/list?fcate_pid={cateId}&category_id={category_id}&area={area}&year={year}&type={type}&sort={sort}&page={page}
```

including `67` being the one category it sends to `/api/crumb/shortList` instead.

## How the port is wired

`SpiderRegistry` registers `JianPian` under its own name **and** aliases `JPianAmns` to the same
script, so the configuration needs no edit. The alternative — changing `api` (and `jar`) in
`wang-movie.json` — was rejected because that file is also what the Android app reads, where the
protected class works; the alias keeps the substitution inside the iOS project.

`SpiderRegistry.aliases` exists for exactly this shape and nothing else: a configured class name with
no logic of its own, paired with a different class proven to serve the same site.

## Notes on the port

- **Host discovery is a DNS-over-HTTPS TXT lookup.** `swrdsfeiujo25sw.cc` TXT returns
  `hzhnl.com,hzkfr.com,hzlfm.com,whfft.com,zxfmj.com`, and each domain answers on *any* subdomain, so
  the original reaches it as `https://<six random letters>.<domain>` and takes the first that
  answers 200. Reproduced as written.
- **Filters come from `ext`, not from a constant.** The Java hard-codes ~4 KB of filter JSON; this
  configuration supplies the same rows as a URL, so the port fetches that and carries no constant
  that could go stale. A site configured without `ext` simply shows no filter chips.
- **`vod_id` carries four fields** (`id$$$title$$$pic$$$tid`) because the detail endpoint returns
  neither title nor cover for 短剧, and because the category decides which endpoint to call. Kept
  exactly as the original encodes it.
- **`tvbox-xg:` is not reproduced.** The original rewrites `ftp://` episode URLs to that scheme for
  an external Android downloader; iOS has no equivalent, so the raw address is passed through and
  fails honestly rather than failing as an unknown scheme.
- **`parse:1` only for the VIP portals** (iqiyi/qq/youku/…), which is what the original's `ku.f`
  host test selects. iOS has no parse service, so those go to the IOS-POC-5G sniffer instead.

## Verification — live, 2026-09-17

```
[golden] home classes: 电影, 电视剧, 动漫, 综艺, 短剧
[golden] category 1: 15 items, first=牛来
[golden] detail 牛来: flags=[VIP线路, 极速蓝光, 高速蓝光, 蓝光线路, 高清线路1, …] (24 lines), episodes=2
[golden] search 我: 20 results
[golden] player: parse=0 url=https://mv.cqhnq.com/api/v2/vip/normal/1650023/index.m3u8
```

The resolved stream fetches as media with no Referer and no cookie:
`206`-capable `200 application/vnd.apple.mpegurl`, 188,125 bytes of playlist, requested with a bare
`AppleCoreMedia` user agent.

The full sweep agrees, and puts the site in its listing:

```
[sweep] JPianAmns  薦片  classes=5 home=15 flags=24 eps=2
        play=https://mv.cqhnq.com/api/v2/vip/normal/1650023/index.m3u8 [media]  -> PLAYABLE
```

- `swift test --package-path ios` with `WANG_MOVIE_JSON`: the app now lists **62 sources
  (30 native + 32 spider)**.

> **Do not read that sweep's aggregate as the app's state.** It was the third full sweep of the same
> 60-odd providers inside an hour and it collapsed to `PLAYABLE=10 … EMPTY=28 ERROR=19`, where 9 of
> the errors are TLS certificate-chain failures on hosts that had served media 40 minutes earlier —
> `cj.lziapi.com` fails the same way from `curl`, so it is not the app. The last coherent aggregate
> is IOS-POC-5L's **37 of 61**. The lesson for whoever sweeps next: **provider state moves by the
> hour and repeated sweeps degrade it**, so treat one bad run as a measurement of the network that
> day, and re-measure before calling anything a regression.
- `xcodebuild … -scheme WebHTVApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
  -configuration Release build` → BUILD SUCCEEDED.
- **Simulator only**, as everywhere else in this project.

## Ponytail review of the diff

- One new script, one alias entry, one line changed in the registry loader. No new Swift type, no
  loader mechanism beyond a `[String: String]` map.
- The 4 KB of filter constants in the original are replaced by the `ext` the site already carries.
- The registry test asserts the alias resolves to `JianPian`'s script rather than to an empty entry,
  which is the one way this could silently half-work.

## What this does not change

The other 33 sites behind `aowu-0722.jar` and `fan-0720.jar` are untouched. Whether any of them has
an unprotected equivalent elsewhere in the JAR set is now a **concrete, answerable question** — this
stage is the first evidence that the answer can be yes — but it has not been asked for any of them.
