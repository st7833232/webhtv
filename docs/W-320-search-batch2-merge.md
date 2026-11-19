# W-320 搜尋第二批合併候選（W-315＋W-318、W-316、W-319）

- 分支 `task/W-320`，底 ios-poc `ae662d20e2276b9bd6e5ae7a990860b0351b3fe7`；依序 `git merge --no-ff`，原分支都沒有 rebase。只提交、不推送。
- 證據在 `.herdr-synapse/webhtv-dev/artifacts/w320/`（不進 git）。

| 順序 | 合併 commit | 合進來的分支 | 衝突 |
|---|---|---|---|
| 1 | `32f06c9b` | `task/W-315` `0a1f6785`（A3 3b6ffea7、A4 c86deb07、W-318 0a1f6785） | 無 |
| 2 | `a23035c0` | `task/W-316` `e76cac4c`（A6 94e2ee99、A10 e76cac4c） | `WebHTVApp.swift` 一處 |
| 3 | `6611304a` | `task/W-319` `a18c711d`（probe 計時測試） | 無 |

## 衝突與解法

- **唯一的文字衝突**在 `AggregateSearchView.page` 的捲動區：W-316 把進度列條件改成 `searching || answered > 0 || !skipped.isEmpty`（有略過的站時也顯示「略過 n 個…」），W-315 把結果清單從 `hits` 改成合併後的 `cards`。解法：兩邊都要——用 W-316 的條件、W-315 的 `let shown = cards`。
- **`submit()`**（W-316 審查 N-3 預期會衝突）實際由 git 自動合併，結果和審查建議一致：簽章與紀錄寫入用 W-315（`submit(remember:)`、`history = SearchHistory().add(text)`），本體（健康排序、略過、`ask`）用 W-316；W-316 新增的 `retrySkipped()` 不寫紀錄。已逐行確認。
- 其他自動合併：`docs/W-312-ios-search-improvements.md`（兩邊各加連結）。W-316 的晶片編號偏移（`offset + report.index`）和 W-315 的卡片 ID（`站序\0vod.id`、`=合併鍵`）不衝突：重試那批的站序接在第一批後面，ID 不會撞。
- 順手修 W-315 文件（Reviewer N-5、N-6）：刪掉已過時的「載入更多後代表來源可能換人」，改寫成實際行為；把 §3 環境收尾移回 §4 前面。

## 驗證

- Core：`swift test` 1614 項全過（`swifttest.log`）。
- App：Simulator Debug 建置成功（`app-build.log`）。
- Simulator（11-19 11:14–11:28，熱點 172.20.10.1；GitHub recha `main` = `f650d84378821a2d0ff2964a2d9022f48ed798fc`，App 用同 SHA 的 raw 網址；webhtv-w308）：
  - 事前：偏好裡關掉「可可影視」（`webhtv.search.excludedSites`，與設定頁開關存的格式相同）；空白頁顯示「會同時搜尋這個資訊源的 77 個站台」（78－1）。用 哪吒／怪奇物語／海街日记 暖身三次（各 77 站），讓一直失敗的站累積連續失敗。
  - 一次搜「庆余年」：只問 67 站（77－10 略過）、12.3 s 完成，日誌沒有「可可影視」；進度列「已完成 67/67」＋「略過 10 個近期一直失敗的站」；合併卡「慶餘年 · 第01集 · 19 個來源」（W-318 代表來源）、「慶餘年（全）4 個來源」；清空輸入框後搜尋紀錄依序「庆余年、海街日记、怪奇物語、哪吒」。截圖 `sim/f2-end.png`（結果）、`sim/f3-end.png`（紀錄），日誌 `sim/f1-search.log`。
  - 暖身時剪貼簿貼上沒有生效（重開機後的模擬器），改用 XCUITest 直接輸入關鍵字。
- 收尾：Simulator 偏好整份換回測試前（`https://127.0.0.1:18448/wang-sex.json`、沒有關站、沒有紀錄）並關機；探針與建置資料夾已刪。模擬器裡的 `site-health.json` 留有這次的連續失敗紀錄（測試機，不影響使用者）。
- Ponytail（合併 commit `a23035c0` 的衝突解法與 `submit()`／`retrySkipped()`／`cards` 的互動）：Ship，沒有發現。查過：重試批次的站序接在第一批後面，卡片 ID 不撞；凍結後重試的結果照凍結規則（同名併進原卡、新片名算「有 N 筆新結果」）；`clear()` 同時清 `skipped` 與 `frozenLeads`；重試不寫紀錄。沒驗到：凍結後重試略過站這條路徑只讀程式碼，Simulator 沒操作。
