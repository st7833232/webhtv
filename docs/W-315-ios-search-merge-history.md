# W-315 iOS 搜尋第二批：跨站同片合併（A3）＋搜尋紀錄（A4）

- 規格：`docs/W-312-ios-search-improvements.md` §5 A3／A4、§4.3 第 5 點（不跳動）、§7 第二批、§8 回退。設計已在 W-312 評估並由使用者核准（Manager 派工 #9022），本文件只記實作。
- 分支 `task/W-315`，底 ios-poc `ae662d20e2276b9bd6e5ae7a990860b0351b3fe7`（0.1.105）；在 dev-2 自己的 worktree `webhtv-dev2` 開新分支。只提交、不推送。
- 證據放在 `.herdr-synapse/webhtv-dev/artifacts/w315/`（不進 git）。

## 1. A3 跨站同片合併

| 項目 | 做法 | 位置 |
|---|---|---|
| 合併鍵 | `SearchRelevance.folded(片名)`（全形轉半形、繁轉簡、小寫、只留字母數字；**季數保留**）＋年份。年份只取站台年份欄位裡第一個獨立的四位數 19xx／20xx（「2019」「2019年」「2019-11-26」都算 2019，「未知」「1080P」算沒有）。沒有年份的只和同樣沒有年份的合併；資料夾（`tag == "folder"`）和折疊後空白的片名不合併 | `ios/Sources/WebHTVCore/SearchMerge.swift` `key(for:)`、`year(_:)` |
| 合併位置 | 同鍵的結果併成一張卡，放在第一個出現的位置（`SearchMerge.merged`）。「全部」先照第一批做相關度排序與同系列歸組，最後才合併，所以卡片位置就是該片最前面那個來源原本的位置 | `SearchMerge.merged`、`AggregateSearchView.cards` |
| 不跳動 | 凍結的順序改存「卡片 ID」（合併卡＝`=`＋合併鍵；單一來源＝原本的 hit ID）。凍結後新到的站如果是畫面上已有的片，只讓那張卡的來源數變多、位置不變；新片名才算進「有 N 筆新結果」 | `cards`、`unseenCount`、`freeze()` |
| 卡片 | 只有一個來源時和以前一樣直接進詳情、下方顯示站名；兩個以上顯示「N 個來源」，點了先開來源選單 | `grid`、`cardLabel` |
| 來源選單 | sheet（半高可拉全高），每列：站名、年份 · 備註。依站點健康排序（`SiteHealth.ordered`，和第一批 A5 發問順序同一個「站點健康排序」開關；關閉時照站台回應順序）。選了之後關掉選單再推進詳情頁（避免 sheet 關閉途中推頁被丟掉） | `openSources`、`sourcesMenu`、`.sheet(item:onDismiss:)`、`.navigationDestination(isPresented:)` |
| 不變的 | 單站晶片（一張卡一個結果，照站台順序）、載入更多、失敗／逾時／上一輪仍在執行計數、第一批 A0／A1／A2／A5 | — |

**和 W-312 §4.4 的偏離（Reviewer #9043 同意，已同步改 W-312 §4.4 末列）**：評估時寫「A3 另外要求年份或集數也相符」。實作只比完整片名＋年份、不比集數，因為搜尋結果多半沒有總集數欄位（備註是「更新至 40 集」這類字串，各站寫法不同）。後果：兩個都沒年份的同名短劇會併成一張卡；來源選單逐站列出年份與備註，使用者自己分辨。片名尾端的標籤（`[預告片]`、`[電影解說]`、`(國語)`）保留在合併鍵裡，所以預告片、解說不會和正片併在一起。

凍結後的規則（Reviewer #9036 第 2 點）：新來源加入畫面上已有的卡時，只讓卡上的來源數變多、位置不變，不算進「有 N 筆新結果」。卡片的代表來源（海報、片名、備註）在凍結時記下（`frozenLeads`），之後到的站不會換掉它；代表來源怎麼挑見 §4（W-318）。點單站晶片時「全部」會先凍結，所以在晶片裡「載入更多」之後回到「全部」，代表來源也不會換（W-318 的 `frozenLeads`；Reviewer N-5 指出原本這裡寫的例外已過時）。

單元測試 `SearchMergeTests`（5 項）：同片名不同寫法＋同年合併；別季、別年、一邊有年份一邊沒有、預告片／解說標籤不合併；資料夾與空片名不合併；年份解析；卡片放在第一個結果的位置。

### 1.1 A3 驗收

環境：2026-11-19 10:05–10:15（Asia/Taipei），Mac 在手機熱點（閘道 172.20.10.1）；設定檔 GitHub recha `main` = `f650d84378821a2d0ff2964a2d9022f48ed798fc`（10:00 `git ls-remote` 確認），App 用同一 SHA 的 raw 網址（設定頁已存的來源）；Simulator webhtv-w308，本分支 Debug 建置。證據在 `artifacts/w315/sim/`。

- 合併：搜「庆余年」78 站回完（30.9 s），「全部」579 筆。第一張「慶餘年」標「19 個來源」、「慶餘年（全）」4 個來源；「慶餘年第一季 · 2019」11 個來源和沒有年份的「慶餘年第一季」18 個來源分成兩張（年份規則）；「慶餘年[電影解說]」單獨一張。截圖 `a3k1-end.png`（搜尋中 35/78 時已是 12 個來源）、`a3m-done`（結束後）。
- 來源選單：點「19 個來源」開半高 sheet，每列站名＋備註，依健康排序（`a3m-menu.png`）。選「王子｜高畫 + 都採集」→ 進該站詳情（全 46 集、立即播放），返回後「全部」順序不變（`a3d-detail.png`、`a3d-back.png`）。
- 不跳動：送出後 4 秒捲動一次（凍結），30 秒後再截圖：畫面上同樣的卡片在同樣的位置，只有來源數變多（13→19、4→11、15→18），提示列「有 21 筆新結果」→「83 筆」（`a3f-1.png`、`a3f-2.png`）。兩張截圖整體往上差約 14 pt，卡片順序沒變。
- 單元測試：`swift test` 1607 項，1 項失敗：`SourceClientTests.theProbeReadsOnlyTheHeadOfABodyThatNeverEnds` 平行執行時 5.88 s 超過 5 s 上限（和本單無關的計時測試）；單獨重跑 0.04 s 通過（`a3-swifttest.log`、`a3-probe-retest.log`）。
- Ponytail（A3 diff）：Ship。唯一 Nice-to-have 是來源排序可少兩行（直接依分數排），保留現狀，讓排序規則只在 `SiteHealth.ordered` 一處。未查：上千筆時每次重繪的合併成本（只多一次線性合併，579 筆時沒有可見延遲）。

## 2. A4 搜尋紀錄

| 項目 | 做法 | 位置 |
|---|---|---|
| 儲存 | `UserDefaults.standard` 的字串陣列（鍵 `webhtv.searchHistory`），只存在本機、不送出；設定頁「初始化」清掉整個偏好網域時一起清除 | `ios/Sources/WebHTVCore/SearchHistory.swift` |
| 規則 | 新的排最前；同一個關鍵字不重複（再搜一次移到最前）；最多 12 筆，超過丟最舊的；前後空白去掉、空白關鍵字不記 | `SearchHistory.add` |
| 何時記 | 使用者自己送出的搜尋（輸入框送出、點紀錄、全部失敗時的「重試」）。其他畫面帶片名打開搜尋頁（豆瓣片單的 `msearch:`、WebHome 的 `app.search`）的那次自動搜尋**不記**，那不是使用者打的字 | `submit(remember:)`、`.task` |
| 顯示 | 輸入框是空的、而且有紀錄時，在結果區最上方顯示「搜尋紀錄」與一排關鍵字膠囊；點關鍵字就搜，膠囊右側 × 刪除單筆，「全部清除」清掉全部。沒放在 `emptyState`，避開 W-316 會改的同一段（Reviewer #9036 第 6 點）；搜尋後按輸入框的 × 清空，紀錄出現在原本結果的上方，結果不受影響 | `historyRow` |
| 多個搜尋頁 | 搜尋分頁一直留著，sheet 或推入的搜尋頁記下的關鍵字，回到分頁時（`onAppear`）重新讀取 | `.onAppear` |

單元測試 `SearchHistoryTests`（3 項）：新的在前、不重複、空白不記；最多 12 筆、丟最舊；刪一筆、全部清除，以及新的實例（等同重開 App）讀回同樣的清單。

### 2.1 A4 驗收

環境同 §1.1（10:20–10:26）。證據在 `artifacts/w315/sim/`。

- 依序搜「庆余年」「怪奇物語」「海街日记」後按 × 清空輸入框：紀錄顯示「海街日记、怪奇物語、庆余年」（`h4-history.png`）；刪「怪奇物語」後剩「海街日记、庆余年」（`h5-deleted.png`）。
- 結束 App 再開、切到搜尋分頁：紀錄仍是「海街日记、庆余年」（`h6-relaunch.png`）。
- 點紀錄「庆余年」：輸入框填入並開始搜尋，A3 合併卡照常出現（`h7-research.png`）。
- 按 × 清空後點「全部清除」：紀錄列消失（`h8-cleared.png`），偏好檔裡已沒有 `webhtv.searchHistory`。
- 單元測試：`swift test` 1610 項，唯一失敗又是 `SourceClientTests.theProbeReadsOnlyTheHeadOfABodyThatNeverEnds`（平行執行 5.41 s ＞ 5 s，和本單無關的計時測試；A3 那次單獨重跑通過）。`SearchHistoryTests` 3 項過（`a4-swifttest.log`）。
- Ponytail（A4 diff）：Ship，沒有發現。查過：紀錄只寫本機偏好；自動搜尋不記；輸入框非空時不顯示；初始化會清掉。

## 3. 環境收尾（W-315）

- Simulator webhtv-w308 的偏好已整份換回測試前的 `prefs-before.plist`（`configSourceURL` = `https://127.0.0.1:18448/wang-sex.json`）並關機；已存的來源清單沒有新增（GitHub 那筆是 W-312 時就存的）。
- XCUITest 探針建置資料夾 `~/.cache/w308-probe` 已刪；App 建置資料夾 `~/.cache/webhtv-dev2-gui/dd-w315` 保留到審查結束。
- 截圖都是 wang-movie.json（一般片源）的搜尋畫面，保留在 `artifacts/w315/sim/`。

## 4. W-318 補強：合併卡的代表來源（Reviewer N-1）

- 問題：「慶餘年 19 個來源」的代表來源是 bili 合集／漫畫／聽書／歌曲站（回得最快），卡片備註顯示播放時長「13057:27」。原本 Manager 開單寫「優先取有年份的站」，但合併鍵已含年份，同一張卡的來源年份必然相同（這張卡 19 個來源都沒有年份），改了不會有效果；Manager #9082 改定為「優先取備註不是純時長的來源」。
- 做法：`SearchMerge.lead` 取最早到達、**備註不是空白也不是純時長**的來源當代表；都沒有時取最早到達的（和 W-315 相同）。純時長＝`分:秒` 或 `時:分:秒`（`isDuration`，分秒 00–59）；「全46集」「更新至12集」「HD」「2019」「1:7」「1:60」都不算。空白備註也跳過：實測第一版只排除時長時，代表來源換成一個沒海報、沒備註的站，卡片只剩空白圖示，資訊比原本更少。
- 凍結後代表來源不變：凍結（以及按「重新排序」）時記下每張卡的代表 hit，之後新到的來源只加數字。
- 不變：合併鍵、來源選單的內容與排序（仍依站點健康，bili 站仍在選單前面）、不跳動規則、單站晶片。
- 測試：`SearchMergeTests` 新增 2 項（代表來源挑選、時長判斷邊界），共 7 項過；`swift test` 1612 項全過（`artifacts/w318/swifttest.log`）。
- Simulator（11-19 10:46–10:53，熱點 172.20.10.1，GitHub recha main `f650d843`）：搜「庆余年」，同一張合併卡（20 個來源）的代表改成有劇集海報、備註「第01集」的來源（`artifacts/w318/sim/k5-end.png`；改前 bili 時長版見 `artifacts/w315/sim/a3m-done`／`a3k1-end.png`）；來源選單仍是 bilibil合集、bili漫畫屋、王子…（`k6-end.png`）。第一版（只排除時長）的空白代表卡見 `k2-end.png`。
- Ponytail：Ship，沒有發現。查過：凍結前代表來源可隨新來源改變（凍結前本來就會重排）；凍結後由 `frozenLeads` 固定；`Dictionary` 用 `uniquingKeysWith` 避免重複 ID 當掉。
- Simulator 偏好已還原成 `https://127.0.0.1:18448/wang-sex.json` 並關機；探針與建置資料夾已刪。
