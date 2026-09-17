# IOS-POC-5E — end-to-end sweep of every source the app lists

Stage record. Measured 2026-09-17 at HEAD `f0e42264`, against the user's own `wang-movie.json`
(SHA-256 `b17576e3…897168`, 167 sites) loaded from its GitLab URL.

> **Superseded as the current sweep by IOS-POC-5L.** This document records the 45-source sweep and
> stays as that stage's record. The app now lists 61 sources; the current per-site table is in
> `docs/IOS-POC-5L-appqi-app99-app3q-bili.md`.

## What this stage is

IOS-POC-5D added a sweep over the 15 spider sites. The 30 native CMS sources had never been checked
systematically — only spot tests and a type-4 live check. This extends the sweep to **every source
the app lists** and adds the step that was missing from the previous one: after a spider or client
resolves a playback URL, **fetch the first bytes of it**, because resolving a URL and the media
existing are different things. AG動漫 resolves cleanly and then 404s.

`sweepsEveryDrivableSourceThroughTheAppPath` lives in `SourceClientTests.swift` (moved from the
spider golden file, since it now covers native sources too). It drives `SourceClient` — the same
path the app uses — and asserts nothing about individual sites: provider reachability is volatile
and a dead host is not a defect. It is a diagnostic.

```bash
SWEEP_CONFIG=/path/wang-movie.json SWEEP_BASE=https://…/wang-movie.json \
  swift test --package-path ios --filter sweepsEveryDrivableSource
```

## Result: 27 of 45 play

| outcome | count | meaning |
|---|---:|---|
| **PLAYABLE** | **27** | home → detail → episode → playback URL → **first bytes fetched, not HTML** |
| DEAD-MEDIA | 6 | a URL resolved, but the media 404s or is a web page |
| NO-PLAY | 1 | detail has episodes, `playerContent` yields no URL |
| NO-EPISODE | 4 | titles list, detail returns no flags |
| EMPTY | 7 | no titles at all |

Split by kind:

| | listed | playable | dead media | no play | no episode | empty |
|---|---:|---:|---:|---:|---:|---:|
| native CMS (type-0/1/4) | 30 | **24** | 4 | 0 | 0 | 2 |
| ported `csp_*` spider | 15 | **3** | 2 | 1 | 4 | 5 |

## Native CMS — 24 of 30 play

Working: `爱瓜TV`, `tufun采集`, `vod_蜜雪`, `采集集合`, `vod_360`, `vod_优质`, `vod_天涯`, `vod_豆瓣`,
`vod_极速`, `vod_豪华`, `vod_飘零`, `vod_虎牙`, `vod_魔都`, `无忧采集资源`, `如意采集资源`, `vod_艾旦`,
`vod_索尼`, `vod_無盡`, `vod_順播`, `vod_红牛`, `drpyS_枫林影视`, `vod_光速`, `如意`, `魔都`.

Not working:

| site | outcome | cause |
|---|---|---|
| `非凡采集资源` | DEAD-MEDIA | episode URL is `…/share/<id>` — **a web player page, not media** |
| `量子采集资源` | DEAD-MEDIA | same `/share/` shape |
| `vod_优酷` | DEAD-MEDIA | same `/share/` shape |
| `88看球` | DEAD-MEDIA | episode resolves to `embed.st/embed/…`, an HTML page |
| `php_无水印资源` | EMPTY | host answers HTTP 403 (recorded since IOS-POC-4A) |
| `drpyS_听友[听]` | EMPTY | 43 categories, every one returns an empty list (recorded since IOS-POC-4A) |

**The `/share/` finding is new and worth acting on.** Those three type-1 sources hand back a player
page rather than a stream. Confirmed with `curl` including a mobile `User-Agent` and a matching
`Referer`: still `text/html`, still a full HTML document. So it is not the dropped-header limitation
— the URL genuinely is a page. Extracting the stream needs the WebView sniffer this app does not
have, which is the same gap that makes `parse:1` unplayable. `CMSClient.playbackURL` only resolves
web pages for type-4 (via `?play=`); type-1 has no equivalent hop, and `isDirectMedia` is a
path-extension heuristic that a `/share/<id>` path slips past. This is pre-existing behaviour, not a
regression, and it is now measured rather than suspected.

## Spider — 3 of 15 play

Unchanged from the IOS-POC-5D sweep except that the media probe now separates 王子/农民/果果短剧
(playable) from 不戳/AG動漫 (URL resolves, media 404s).

| site | outcome | cause | whose |
|---|---|---|---|
| `王子`, `csp_Wwys` (农民), `果果短剧` | PLAYABLE | — | — |
| `不戳` | DEAD-MEDIA | play URL is two URLs concatenated → 404 | **ours** |
| `csp_AG動漫` | DEAD-MEDIA | clean resolve, media 404 | provider |
| `灵虎` | NO-PLAY | 8 flags / 24 episodes, `playerContent` returns nil | **ours** |
| `csp_YLSP`, `永乐影视` | NO-EPISODE | ~~listing URL 404s~~ → **wrong, corrected in 5I**: `永乐影视` is `ylys.tv` and answers 200; I applied `ylsp.tv`'s 404 to both. XBPQ knew neither the newer skin's grid nor its `/vodtype/` nav shape | ~~provider~~ **ours, fixed in 5I** |
| `csp_動漫巴士`, `巴士动漫` | NO-EPISODE | browse fixed in 5D by the lenient rule parse; detail still returns no flags | **ours** |
| `猎豹`, `csp_歐樂影院ORG` | EMPTY | hosts answer HTTP 522 | provider |
| `方舟动漫` | EMPTY | host answers HTTP 403 | provider |
| `csp_If101` | EMPTY | ~~we parse 0 titles from a 200 page~~ → **corrected in 5F**: the page says 「暂无数据」 in all four categories | ~~ours~~ **provider** |
| `csp_天天動漫` | EMPTY | redirects to `ttdm11.me`, which answers 599 bytes (confirmed in 5F) | provider |

> **Superseded in part by IOS-POC-5F**, which fixed five of the defects below and corrected two
> “ours” verdicts to “provider”. Playable went 27 → 29 of 45. Read
> `docs/IOS-POC-5F-spider-defect-fixes.md` for the current state.

## Open defects, ranked by sources recovered

1. `csp_If101` — a 200 page parsed to nothing. Most likely an XBPQ list-rule gap, and the same gap
   may explain `csp_天天動漫` once its redirect is followed. **1–2 sources.**
2. `csp_動漫巴士` / `巴士动漫` detail returning no flags. **2 sources.**
3. `灵虎` `playerContent` → nil, and `不戳` concatenating two URLs. Both AppGet, possibly one cause.
   **2 sources.**
4. A WebView sniffer would recover `非凡采集资源`, `量子采集资源`, `vod_优酷` and `88看球`, and would
   also make `parse:1` spiders playable. **4 sources**, but much the largest piece of work.

## Verification

- `swift test --package-path ios` with `WANG_MOVIE_JSON` → **64 tests, 63 pass**. The one failure is
  the pre-existing live-network `reportsLiveType4SitesFromProvidedConfig` (88看球 — the same site
  this sweep independently classifies as DEAD-MEDIA, which is the test telling the truth).
  `completesLiveCMSFlowFromProvidedConfig`, which failed during IOS-POC-5D because
  `cj.rycjapi.com` briefly returned `vod_play_url: "$$$"`, passes again — confirming that failure
  was provider state.
- No production code changed in this stage. The only source edits are the sweep moving into
  `SourceClientTests.swift` and gaining the media probe.
