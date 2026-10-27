# W-197 XBPQ 篩選分組也接受半形 `||`

## 目標與驗收
- iOS XBPQ.js 的篩選分組同時接受半形 `||` 與全形 `｜｜`（含混用），讓同一份規則在 iOS 與 FongMi 原版 Android（xyqxbpq.jar）都能分組。
- 既有全形規則（永乐 `类型`、csp_YLSP `地区`）iOS 行為不變。
- 驗收：Reviewer 核准；單元測試含 `||`、`｜｜`、混用；XBPQ 全部測試通過。

## 依據
- W-196 反編譯 FongMi 原版 xyqxbpq.jar（`.herdr-synapse/webhtv-dev/artifacts/new-sites-filter/w196/RESULT.md`）：分組 `split("\\|\\|")`，全 jar 沒有全形 `｜`。
- W-185 移植時依現有設定寫成只認全形 `｜｜`（`docs/W-185-ios-xbpq-filter.md`）。

## 做法
`filterGroups` 的分組由 `split('｜｜')` 改為 `split(/｜｜|\|\|/)`；`spider-pack/scripts/XBPQ.js` 與 `ios/Spiders/XBPQ.js` 位元組相同。之後新規則一律用半形 `||`。

刻意不對齊的原版差異（沒有現行設定用到，要用時再開單）：
- 原版的 `分类名--選項` 指名分組（以分類名或序號對應組），iOS 仍只依位置對應。
- 原版 `年份` 的 `2025-2012` 區間寫法，iOS 不展開。
- 原版 Java `split` 會丟掉尾端空組，組數少於分類數時 Android 會出錯；iOS 缺組時該分類不顯示該列。規則請別寫尾端空組。

## 驗證
- `cd ios && swift test --filter XBPQ`：29 個測試全過（含新 `filterGroupsAcceptHalfWidthAndMixedSeparators`：純 `||` 與 `｜｜`／`||` 混用各三組，第 k 個分類拿到第 k 組；既有 `homeContentOffersConfiguredFilters` 全形 `｜｜` 仍過）。
- `spider-pack/manifest.json` 的 XBPQ sha256 早已過時（W-185 起即未同步），官方包 manifest 在發包時重產，本單不動。
- Simulator：本單是 JS 字串切分，單元測試已用真 spider 引擎跑；要等官方包序號 12 才能在 App 實機看到。

## Ponytail
- `ponytail:ponytail-review`（2026-10-27，對本單未 commit diff）：Looks good. Ship. 無發現。已查：`filterGroups` 唯一呼叫端 `buildFilters`；現行 171 站設定的篩選鍵沒有半形 `||`，既有站不會被誤切；兩份 JS 位元組相同。
