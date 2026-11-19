# W-326 單站晶片：同系列各季排在一起

- 分支 `task/W-326`，從 ios-poc `2d60cc7d3e1a6621a2cf01ee4df60434c4a615b6`（0.1.106 發版 commit）開。只提交、不推送。
- 證據在 `.herdr-synapse/webhtv-dev/artifacts/w326/`（不進 git）。
- 改題紀錄：原單是「站台晶片依自訂順序排」，Manager #9285 依使用者更正改成本題（晶片列順序不改）；晶片排序的未提交改動已撤回，沒有留在分支上。

## 1. 問題與根因

使用者真機（0.1.106）：搜「實習教師之」點「紅果・短劇」晶片，同一系列各季沒排在一起（S1、S2 在前，S3、S5 散在後面）。

`AggregateSearchView.cards` 在選了單站晶片時直接照站台送來的順序一張一張列（`allHits.filter … .map { Card }`），只有「全部」才套 W-312 A2 的 `SeriesGrouping`。

## 2. 做法

- 單站晶片也套 `SeriesGrouping.groups`：同系列相鄰、季數升冪（沒標季數算第一季，特別篇最後）、整組放在該系列第一次出現的位置；不套 W-312 A1 相關度，其他作品維持站台原順序。判定沿用保守規則（至少一筆有季數標記、跨兩季以上才算同系列），重拍版不會被併在一起。
- **載入更多**：晶片清單滑到底會自動載入下一頁。新的一頁只在自己那頁內分組，接在已顯示的後面，畫面上已顯示的卡片不會在手指下移動。`SiteHits` 記下每頁的起點（`pageStarts`，`vods` 變長時記錄），Core 新增 `SeriesGrouping.paged(_:pageStarts:series:)` 逐頁分組。
  - 代價（刻意取捨）：如果某一季到後面的頁才出現，它會在那一頁裡，不會併回前一頁的那一組。另一個選項是「接在組尾」，但插進前面的組會把後面所有卡片往後推一格，正好是要避免的跳動。
- 「全部」、合併卡片、略過、關站、晶片列順序都不變。

## 3. 驗證

- Core：`swift test` 1619 項全過（新增 `aSitesListGroupsSeasonsPageByPage`：第一頁各季歸組；第二頁的第四季不插進第一頁的組）。`swift-test.log`
- App：Simulator Debug 建置成功（`app-build.log`）。
- Simulator（2026-11-19 15:00–15:06，webhtv-w308，熱點 172.20.10.1）：設定 `https://raw.githubusercontent.com/st7833232/recha/bb69e04c4ad38d867cfb9826f5581bbc002badd1/wang-movie.json`；GitHub recha `main` = `bb69e04c4ad38d867cfb9826f5581bbc002badd1`（`recha-main-sha.txt`）。

| 驗收項目 | 結果 | 證據（`sim/`） |
|---|---|---|
| 搜「實習教師之」點「紅果・短劇」 | 「實習教師之我把倒數班帶成傳奇」沒標季數、第二季、第三季、第四季、第五季五張相鄰依序；「實習教出金牌班…」第三季、第四季也相鄰 | `t5a.png`、`t5-end.png` |
| 載入更多不跳動 | 晶片從 20 筆載入到 40 筆後回到頂端，前面各季仍在原位、原順序 | `t5a.png`（20 筆）對照 `t7-end.png`（40 筆） |
| 「全部」不變 | 「全部」仍依相關度與合併卡片顯示 | `t2-end.png`、`t4a.png` |

- 收尾：Simulator 偏好整份換回測試前（`prefs-before.plist`：`https://127.0.0.1:18448/wang-sex.json`）並關機；App 建置與探針資料夾已刪。

## 4. Ponytail

`ponytail:ponytail-review` 審全部差異：Ship，沒有發現。查過：`pageStarts` 只在清單變長時記錄，所以一定遞增；載入更多的觸發點（最後一張卡片出現）在分組後仍是畫面最後一張；每頁各自分組，每次只處理約十筆；「全部」的路徑沒動。

## 5. 沒驗到的

- 某一季只出現在後面頁的情形（本次各季都在第一頁），只有單元測試。
- 真機。
