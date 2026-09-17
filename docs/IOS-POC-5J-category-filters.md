# IOS-POC-5J — one 全部 chip, and category filter rows

Stage record. Requested from two screenshots: a source showing **two 全部 chips** side by side, and
a reference app with **類型 / 地區 / 年代 / 排序** filter rows under its category row.

## 1. Two 全部 chips

`parentChips` added its own 全部 unconditionally (except for type-4). Every 苹果CMS App-API source
already opens its `type_list` with `{type_id: 0, type_name: 全部}`, so those sites showed two.

Now the app's chip is suppressed when the provider's first category is itself an "all" entry —
either named 全部 or carrying `type_id: 0`. XBPQ and XYQHiker sites, whose categories come from a
rule file and have no such entry, still get the app's chip.

## 2. Filter rows

CatVod already has a contract for this and `host.result.home(classes, items, filters)` already took
a third argument nobody was passing. The shape, keyed by `type_id`:

```json
"filters": { "1": [ {"key":"class","name":"類型","value":[{"n":"全部","v":""},{"n":"喜剧","v":"喜剧"}]} ] }
```

So this stage is mostly wiring, not invention:

| piece | state before | change |
|---|---|---|
| `filter_type_list` in the API | already served by AppGet sites | — |
| `host.result.home` filters arg | already accepted | — |
| `AppGet.js` | ignored it | now maps `filter_type_list` → CatVod rows |
| `CMSResponse` | no `filters` key | `filters: [String: [CMSFilter]]` |
| `CMSFilter` | did not exist | new, CatVod's `{key,name,value:[{n,v}]}` |
| `SourceClient.category` | no `extend` | takes `extend`, passes to `SpiderSession` |
| `SpiderSession.category` | already had `extend` | — |
| `AppGet.js categoryContent` | already read `extend.class/lang/area/year/by` | — |
| UI | category rows only | one chip row per filter, with a leading label |

### 全部 in the filter rows too, nearly

The API leads most rows with its own 全部 — and that entry must travel as an **empty** value, not
the literal word, or the API filters by a genre called 全部 and returns nothing. My first version
prepended a second 全部 on top of the API's, which would have reproduced the exact bug this stage
was fixing, one row lower. Caught because the live test printed `applying class=全部`; the value
should never have been the label. Now the API's own entry is mapped to an empty value, and a
synthetic one is added only when a row does not already start with one.

`sort` is renamed `by` on the way out, because `by` is the key `categoryContent` maps back onto the
API's `sort` — the same rename the original Java does in `createFilterItem`.

### Only where the source has them

MacCMS has no filter protocol, so a type-0/1/4 response decodes to an empty set and no rows appear.
XBPQ and XYQHiker do not publish rows either. Rows are also hidden while searching, and a child
category inherits its parent's rows because the API keys them by the parent's `type_id`.

**Changing category clears the chosen filters.** They belong to the category that published them;
sending 剧情 to a category with no such class empties the listing for no visible reason.

## Verification

- `swift test --package-path ios` with `WANG_MOVIE_JSON` → **77 tests, 76 pass**. The one failure is
  the pre-existing live-network `reportsLiveType4SitesFromProvidedConfig` (88看球).
- `xcodebuild … iPhone 17 Pro Debug` → **BUILD SUCCEEDED**.
- `decodesTheCatVodFilterRowsAndToleratesTheirAbsence` covers the shape, an empty value surviving
  decode, a numeric year row, and a MacCMS response with no `filters` key at all.
- `sendsChosenFilterValuesBackToTheSpider` (gated on `CSP_GOLDEN_SITE`) drives the live API: 电影
  publishes `class, area, lang, year, by`, and applying `class=喜剧` still returns a listing.
- **Simulator, end to end:**
  - 王子 (AppGet) now shows **one** 全部 followed by 电影/电视剧/综艺/动漫/短剧.
  - Selecting 电影 reveals five rows — 類型 / 地區 / 語言 / 年代 / 排序 — each with a single 全部.
  - Tapping 恐怖 re-listed the grid as horror titles (荒山野店, 元月之灾, Sengkolo) with the chip lit.
  - 永樂 (XBPQ) keeps its single app-supplied 全部 and shows no filter rows, as intended.

## Files

| file | change |
|---|---|
| `Sources/WebHTVCore/CMSClient.swift` | `CMSFilter`, `CMSResponse.filters` |
| `Sources/WebHTVCore/SourceClient.swift` | `category(extend:)`; the home fallback keeps filters |
| `Resources/Spiders/AppGet.js` | `filter_type_list` → CatVod rows, 全部 mapped to an empty value |
| `WebHTVApp/Sources/WebHTVApp.swift` | suppress the duplicate 全部; filter rows; clear on category change |
| `Tests/WebHTVCoreTests/SourceClientTests.swift` | 2 new tests |
