# IOS-POC-5F — fixing the defects the 5E sweep found

Stage record. Sweep method and per-site table: `docs/IOS-POC-5E-all-source-sweep.md`.
Runtime contract: `docs/IOS_SPIDER_RUNTIME_SPEC.md`.

## Result

**Playable sources: 27 → 29 of 45.** Two sites recovered outright, two more moved from "no titles"
to "browses and shows 158 episodes", and one site the 5E record blamed on our code turned out to be
the provider.

| | 5E | 5F |
|---|---:|---:|
| PLAYABLE | 27 | **29** |
| DEAD-MEDIA | 6 | 5 |
| NO-PLAY | 1 | 2 |
| NO-EPISODE | 4 | 2 |
| EMPTY | 7 | 7 |

`NO-PLAY` rising is progress, not regression: 動漫巴士 and 巴士动漫 moved *up* from NO-EPISODE.

## Five defects fixed

All were found by driving the real sites, not by reading code. Each is a host- or engine-level
fault, so the fix serves every site on that engine rather than the one that exposed it.

### 1. `AppGet` trusted `parse_api_url`, which is not a URL

`parse_api_url` is the site's own concatenation of `player_info.parse` and `url`. 王子 ships an
empty `parse`, so there it equals `url` and looks like a clean link — which is why 王子 worked and
hid the bug. 灵虎 ships `parse = "9902d706…"`, so its `parse_api_url` is `"9902d706…https://cdn…"`,
not a URL at all. The port (and the original Java) trusted that field; now it prefers `ep.url`,
which is only ever the target.

**Recovered 灵虎 (NO-PLAY → PLAYABLE) and 不戳 (DEAD-MEDIA → PLAYABLE).**

### 2. `AppGet` encoded with base64 and decoded with AES

`detailContent` wrote `url=<base64>` and `playerContent` read it back with `aesDecrypt`. Those could
never match, so that path always fell through to the parse endpoint. Both sides are ours, so they
now both use base64.

### 3. `select()` did not match the node itself

Jsoup's `Element.select()` collects from the element itself, not only its descendants. 巴士动漫
picks episodes with `选集列表数组规则: a` and then reads each with `选集链接: a&&href` — against an
`<a>` node, which found nothing, so every episode was skipped. Only the first selector part
self-matches; later parts are descendant combinators and keep descending.

### 4. `XYQHiker` did not fall back to the category field rules

A rule file may define the home block's array rules and leave the per-field rules to the 分类片单*
set — 巴士动漫 and 動漫巴士 both do. Each home field now names its own key first and the category
key as fallback, which is what Hiker does. `extract` also refuses to build items when there is no
link rule at all, because an empty rule made `pdfh` return the node's text and every field —
including `vod_id` — became the title, which `detailContent` then fetched as a URL.

### 5. `XYQHiker` ignored `[firstPage=…]`

Hiker lets a listing template carry `[firstPage=<template>]`: page 1 uses that template, later pages
the main one. 巴士动漫 lists page 1 at `/list-{cateId}.html` and the rest at
`/list-{cateId}-{catePg}.html`. Ignoring the marker requested a literal `…html[firstPage=…]`, so
every category came back empty.

### Plus: `pdfh` treated an empty rule as "give me everything"

Not on the original list, found while fixing 4. An undefined rule key made `pdfh` return the whole
node's text, so 巴士动漫 reported its `vod_year` as the entire HTML document. An empty rule now
returns an empty string; an explicit bare `Text` still means this node's text.

**Together 3–5 took 動漫巴士 and 巴士动漫 from 0 categories to 4 categories, 8 titles and a detail
page with 158 episodes.** They still do not play — see below.

## Two entries in the 5E table were wrong about whose fault it was

- **`csp_If101` is the provider, not us.** Its listing page answers HTTP 200 with 27 KB, which is
  why 5E assumed a parse failure. The page contains `<ul class="vodlist …"></ul>` followed by
  `<div class="show_no">暂无数据</div>` — the site says it has no data. All four configured
  categories say the same. Nothing to fix here.
- **`csp_天天動漫` is also the provider.** It redirects to `ttdm11.me` and answers 599 bytes.

## Still not playable, and why

- **動漫巴士 / 巴士动漫** browse and list episodes but resolve no stream. Two reasons, both outside
  this stage: their rule file defines no extraction rule for the play page at all (`链接是否直接播放: 0`,
  `分析MacPlayer: 0`, and a `手动嗅探视频链接关键词` list) — it expects the player to **sniff** the
  media out of the page — and the play page itself currently answers Cloudflare **522**.
- **非凡采集资源, 量子采集资源, vod_优酷, 88看球** hand back a web player page (recorded in 5E).
- **AG動漫** resolves cleanly and the media 404s.

The sniffer is the single largest remaining gain: it would recover the three `/share/` sources,
88看球, the two 巴士 sites, and every `parse:1` spider.

## Verification

- `swift test --package-path ios` with `WANG_MOVIE_JSON` → **66 tests, 65 pass** (64 before; +2 new
  host tests). The one failure is the pre-existing live-network
  `reportsLiveType4SitesFromProvidedConfig` (88看球), which this sweep independently classifies
  DEAD-MEDIA — the test is right.
- `xcodebuild … -scheme WebHTVApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
  -configuration Debug build` → **BUILD SUCCEEDED**.
- New tests: `matchesTheNodeItselfTheWayJsoupSelectDoes` (self-match, and that descendant rules
  still descend) and `treatsAnEmptyRuleAsNoValueRatherThanTheWholeNode`.
- Full 45-source sweep re-run after every change; **no previously working source regressed**.

## Files

| file | change |
|---|---|
| `Resources/Spiders/AppGet.js` | prefer `ep.url`; base64 on both sides |
| `Resources/Spiders/XYQHiker.js` | home field fallback, `ruleFor`, `[firstPage=…]`, no items without a link rule |
| `Resources/Spiders/host.js` | `select` first-part self-match; `pdfh` empty rule returns empty |
| `Tests/WebHTVCoreTests/SpiderHostTests.swift` | 2 new tests |
