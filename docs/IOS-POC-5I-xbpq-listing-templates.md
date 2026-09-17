# IOS-POC-5I — 永樂 showed its own category nav as four films

Stage record. Sweep method: `docs/IOS-POC-5E-all-source-sweep.md`.

## What the user saw

A screenshot of 永樂 whose poster grid held four cells titled **电影 / 剧集 / 综艺 / 动漫** with no
artwork. Those are the site's own category names, rendered as if they were films.

**Playable sources: 35 → 36 of 45, and NO-EPISODE is now zero.**

| | 5G | 5I |
|---|---:|---:|
| PLAYABLE | 35 | **36** |
| NO-EPISODE | 2 | **0** |

## I had this filed under the wrong cause

IOS-POC-5E recorded `csp_YLSP` / `永乐影视` as "provider, listing URL 404s". That was wrong, and it
was wrong because I conflated two sites with almost the same name:

- **`csp_YLSP`** points at `ylsp.tv`, and its listing URL really does 404
- **`永乐影视`** points at **`ylys.tv`**, which answers **HTTP 200 with 62 KB**

I checked the first, wrote the verdict, and applied it to both. The user's screenshot is what
exposed it. Both sites happen to share the same `分类url` template shape, so both were fixed by the
same change and both are now playable — `ylsp.tv` evidently resolves somewhere that works.

## Two faults, both ours

### 1. The selector chain fell through to a bare `li`

`defaultList` tries `.stui-vodlist li`, then `ul.stui-vodlist__media li`, then `.myui-vodlist li`,
then a bare `li`. 永樂 uses the newer 苹果CMS skin, which has **no `*-vodlist` class at all** — its
grid is `<div class="module-items module-poster-items-base">` holding `<a href="/voddetail/126509/">`
directly. So the chain reached the bare `li` and picked up the category nav list.

Added `.module-items a` to the chain, before the bare `li`.

### 2. The nav blacklist had a hole exactly the shape of this site's links

```js
if (/\/(type|show|label|area|year|by|class|lang)\//i.test(link)) continue;
```

永樂's nav links are **`/vodtype/1/`** and `/vodshow/6-----------/`. In `/vodtype/`, `type` is not
preceded by a slash, so the pattern never matched and every nav entry sailed through. They also pass
the "looks indexed" test, because `/1/` satisfies `\/\d+\/?$`.

Adding `(vod)?` closes it. `/voddetail/<id>/` is unaffected — `detail` is deliberately not in the
list, which the new test pins down.

### And the detail page needed the same treatment

Fixing the listing revealed the next layer: 72 real titles, then `flags=0`. 永樂's `ext` defines no
line or episode rules at all, so XBPQ falls back to its defaults, and those only knew the two older
skins:

- line names come from `.module-tab-item span` (`<div class="module-tab-item" data-dropdown-value="大陆0线"><span>大陆0线</span><small>1</small></div>`) — taking the `<span>` avoids the episode count in the `<small>`
- the play list is `div.module-play-list-content`, not a `ul`, and holds `<a>` directly, so the item
  selector falls back from `li a` to a bare `a`

## Verification

- `swift test --package-path ios` with `WANG_MOVIE_JSON` → **75 tests, 74 pass**. The one failure is
  the pre-existing live-network `reportsLiveType4SitesFromProvidedConfig` (88看球).
- `xcodebuild … iPhone 17 Pro Debug` → **BUILD SUCCEEDED**.
- `rejectsVodPrefixedNavLinksButKeepsDetailLinks` pins the filter: `/vodtype/1/` and
  `/vodshow/6-----------/` are nav, `/voddetail/126509/` is not and is indexed, and the older
  `/vod/12345.html` and `?id=99` shapes keep working.
- Full 45-source sweep: 永乐影视 and csp_YLSP went `home=4 flags=0` → `home=72 flags=1` → PLAYABLE.
  No previously working source regressed.
- **Simulator, end to end:** 永樂 now lists 托尼2026 / 还有其他人 / 伴魔而行 / 元月之灾 with real
  posters instead of four nav entries → 托尼2026 detail shows line 大陆0线 with 正片 → **played**.

## Note on a test I wrote and deleted

I first wrote `picksTitlesNotCategoryNavFromTheNewerAppleCMSSkin`, which fed HTML through the
engine's `action` hook. XBPQ has no such hook, so the test returned early and asserted nothing while
appearing to pass. A test that cannot fail is worse than no test, so it was removed; the filter test
above is the one that actually pins the fix, and the live sweep covers the selector chain.

## Files

| file | change |
|---|---|
| `Resources/Spiders/XBPQ.js` | `.module-items a` in the listing chain; `(vod)?` in the nav filter; `.module-tab-item span` and `.module-play-list-content` in the detail defaults |
| `Tests/WebHTVCoreTests/SpiderHostTests.swift` | 1 new test pinning the nav filter |
