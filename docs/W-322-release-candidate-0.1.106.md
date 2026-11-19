# W-322 發版候選 0.1.106（W-320＋W-321＋W-323＋W-317）

- 分支 `task/W-322`，從 `task/W-320` `f24d2a50` 開（Manager #9163）。只提交、不推送；推送與發版由 Manager 做。
- 證據在 `.herdr-synapse/webhtv-dev/artifacts/w322/`（不進 git）。

## 1. 合併

| 順序 | 來源 | 核准 SHA | 合併 commit | 衝突 |
|---|---|---|---|---|
| 底 | W-320（含 W-315／W-318／W-316／W-319） | `f24d2a50` | — | — |
| 1 | W-321 嗅探取消測試 | `6de13ca7` | `d5289943` | 無 |
| 2 | W-323 慢站期限測試（Manager #9185 要求一併合） | `2cdf40e7` | `0011f679` | 無（`AggregateSearchTests.swift` 自動合併，內容與核准版相同） |
| 3 | W-317 自訂站點順序 | `f3d5e42f3c10f1ca30adee016600820053163874` | 見 git log | 無（`WebHTVApp.swift` 自動合併） |

## 2. 合併後的語意調整（本單唯一的程式改動）

`AggregateSearchView.openSources(_:)`（W-315 A3 的「N 個來源」清單）原本在「站點健康排序」開時只依健康排序；W-317 之後搜尋發問順序是「拖過的站在最前，其餘依健康」。兩者沒有文字衝突，所以自動合併沒擋下，但同一張卡片的來源清單會和搜尋順序不一致（註解寫的就是「as the search asks them」）。

改法：改用 `SiteOrder.apply(card 的站, pinned: 目前來源的已排站, health:)` 排名，其餘不變（健康排序關時仍照到達順序，與 W-320 核准行為相同）。

## 3. 驗證

- Core：`swift test` 1618 項／67 suites 全過（`swift-test.log`，合併 W-317 並改完 `openSources` 之後）。合 W-317 前另有一次 1614 項全過（`pre-w317-swift-test.log`）。
- App：Simulator Debug 建置成功（`app-build.log`）。
- Simulator（2026-11-19 13:45–14:13，webhtv-w308，iOS 26，熱點 172.20.10.1）：設定 `https://raw.githubusercontent.com/st7833232/recha/f650d84378821a2d0ff2964a2d9022f48ed798fc/wang-movie.json`，GitHub recha `main` 查到同一個 `f650d84378821a2d0ff2964a2d9022f48ed798fc`。截圖在 `sim/`。

| 驗收項目 | 結果 | 證據（`sim/`） |
|---|---|---|
| 關站 | 「站點順序與搜尋」關掉「量子｜高清」；偏好存成 `{"<設定網址>":["量子采集资源\u0000"]}`；搜尋 log 沒有問這站 | `s3a.png`、`prefs-order-excluded.txt`、`q1-search.log` |
| 拖曳（自訂順序） | 按「排序」把「優質｜高清」往上拖 → 出現圖釘、排第一；偏好存成 `{"<設定網址>":["vod_优质\u0000"]}` | `s5a.png`、`prefs-order-excluded.txt` |
| 首頁換站清單與搜尋順序一致 | 換站清單第一個是 優質｜高清，其餘與設定頁同序；搜尋第一個發問的也是 優質｜高清，接著同序 | `s6-end.png`、`q1-ask-order.txt` |
| 合併卡片 | 庆余年：「慶餘年 · 5 個來源」「慶餘年（全）· 4 個來源」（搜完 11 個來源） | `q1-end.png`、`q3-end.png` |
| 略過提示 | 「略過 10 個近期一直失敗的站」；67 = 78 − 1（關站）− 10（略過） | `q1-end.png` |
| 搜尋紀錄 | 清空欄位後出現「搜尋紀錄 · 庆余年 ×」與「全部清除」 | `q4-end.png` |
| 重開 App | 重開後搜尋仍先問 優質｜高清（之後依新的健康紀錄排） | `r1-search.log`、`r4-search.log` |
| 來源清單 | 「慶餘年」卡片的來源清單可開、可捲動，依健康排序 | `q2a.png`、`r5a.png`、`r5b.png` |

- 收尾：Simulator 偏好整份換回測試前（`prefs-before.plist`：`https://127.0.0.1:18448/wang-sex.json`、沒有關站、沒有自訂順序）並關機；App 建置與探針資料夾已刪。`site-health.json` 留有這次搜尋的健康紀錄（測試機）。

## 4. Ponytail

`openSources` 改動：Ship，沒有發現。查過：已排站不在這張卡片時直接略過；同一站在卡片出現兩次取較前名次；已排清單在主執行緒先讀（同 `submit()`）；唯一呼叫點；`SiteOrder.apply` 已有單元測試。

## 5. 沒驗到的

- 來源清單裡已排站排第一：這次「慶餘年」卡片沒有包含 優質｜高清，Simulator 上沒看到這條路徑，只有程式審查與 `SiteOrder.apply` 的單元測試。
- 真機。
