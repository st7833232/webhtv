# IOS-POC-33 — 搜尋時簡體、繁體各搜一次，合併結果後顯示

- 狀態：**已實作（2026-09-28，使用者核准第九節四項建議；第十節）：未編譯、單元測試未執行、真機未驗證、尚未發布。**
- 使用者要求（2026-09-28）：「在執行搜尋功能 簡體繁體都搜尋一次 把結果merge後再顯示」
- 分類：新功能，改變每次搜尋送出的請求數與結果內容，適用 AGENTS.md §7 設計研究門檻；本文件是它的研究、計畫與實作紀錄。
- 研究方式：workflow `wf_51a0f1ba-938` 的六個代理分別研讀核心搜尋、App 搜尋流程、各類來源、Android、外部證據，最後由一個代理做風險批判並抽查程式行號。
- 本環境沒有 Swift，本文件的程式都**未編譯**。

## 一、要實現的能力

1. 使用者輸入繁體關鍵字（台灣鍵盤的常態）時，除了現在送出的簡體寫法，也用輸入的原文再搜一次。
2. 同一個站的兩次結果合併成一份：先放簡體寫法的結果（與現在相同、順序不變），再加上繁體寫法才找到的片子。
3. 各站仍然「哪一站先回就先顯示哪一站」；合併發生在站內，不是等所有站都回來才顯示。
4. 範圍：搜尋分頁、WebHome 的 `app.search`（它開的就是搜尋分頁），以及首頁的站內搜尋。

## 二、研究證據（讀取日期均為 2026-09-28）

等級：A＝原始碼或原始資料；B＝官方文件；C＝次級資料。

| # | 來源 | 版本 | 等級 | 支持的結論 | 對本計畫的影響 |
|---|---|---|---|---|---|
| E1 | WebHTV `AggregateSearch.swift:60-147`、`AggregateSearchTests.swift` | `1e9d24e3` | A | `run()` 只轉一次關鍵字；每站一個名額、一次回報；忙碌判斷以 `Site.id` 為鍵、全 App 共用；30 秒期限從該站開始算，逾時回報不帶任何結果 | 兩種寫法必須在同一個站的同一次呼叫內完成，並補上「逾時但已有結果」的處理 |
| E2 | WebHTV `WebHTVApp.swift` `AggregateSearchView`（`:946-1215`）、`CMSView`（`:588-596`、`:832-886`） | `1e9d24e3` | A | 畫面假設每站只回報一次（`answered`、`ForEach(groups, id: \.index)`、`Hit.id`）；每站只有一個頁碼；站內搜尋另有一套程式，翻頁時用的是搜尋框目前的文字 | 合併要在回報前完成；翻頁要改成每種寫法各自的頁碼 |
| E3 | WebHTV `JavaScriptSpiderRuntime.swift`、`PythonSpiderRuntime.swift`、`SourceClient.swift:224-235`、`SpiderSession.swift:19-23` | `1e9d24e3` | A | 每個 spider 在自己的序列佇列上一次跑一個呼叫；同一站兩個呼叫同時開始時，`SpiderSessionStore` 可能建出兩個 session（兩次 init、Python 實例不會卸載） | 同一站的兩種寫法依序執行，不平行 |
| E4 | 本 repo Android：`SearchTask.java:12-17`、`Trans.java:9-66`、`Setting.java:42-45`、`SiteViewModel.java:143-184`；commit `9a43cde0a3a05e2365bd7ee85c156752f5da19c8` | repo 現況 | A | Android 只送一種寫法：繁體模式（或未設定時地區為 TW）才轉簡體，否則原文送出；不會搜兩次、不合併、也不去重 | 本功能沒有 Android 先例，是 WebHTV 自己的改進 |
| E5 | [FongMi/TV](https://github.com/FongMi/TV) `SiteViewModel.java:97-103`、commit `4a5dc8b324b25e9e26f5fea56d66bfc08b34bb69` | `4afc4473e22a7ed3d98ee12233e0c2a490061000` | A | 上游同樣只送一次；整個歷史沒有同時搜繁簡的 commit | 同上 |
| E6 | [q215613905/TVBoxOS](https://github.com/q215613905/TVBoxOS) `SourceViewModel.java:915-938`；[takagen99/Box](https://github.com/takagen99/Box) `SourceViewModel.java:606-730` | `ab11d289e09963a9daf65ca7f6b7a9a8cbe184e1`、`258a5fef61578869ae905ca230bdde9e99fc19a8` | A | TVBox 系分支直接送原文、不轉換 | TVBox 系沒有可沿用的實作 |
| E7 | [maccms10](https://github.com/magicblack/maccms10) `application/api/controller/Provide.php:13`、`:41-42`、`:70-71`、`:246-262` | `a468b6236c1e028b1aca3f91f463345cf72f16c7` | A | TVBox 用的 provide API 只做 `vod_name LIKE '%wd%'`，簡繁是不同碼位，互不相符；每個關鍵字各自快取；`ac=detail` 的回應不帶分類 | 繁體標題的站只有用繁體關鍵字才找得到，這正是本功能的收益來源 |
| E8 | maccms10 `application/common/util/OpenccConverter.php:222-247`、`application/common.php:2064-2083`、`MeilisearchService.php:333-371`；commits `aa5aa847…`、`dbb445b302db4c8631a11afcb845d4a3b25b0f98` | 同上 | A | MacCMS 2026 年自己的「繁简同搜」：原文加上轉換後的寫法，只保留與原文不同的；後台以 OR 合併所有寫法的結果。Meilisearch 路徑取「第一個有結果的寫法」 | 採用「只送不同的寫法、結果取聯集」；不採用「第一個有結果就停」，它會把只有繁體寫法找得到的片子藏起來 |
| E9 | maccms10 `application/index/controller/Base.php:109-127`、`application/common.php:723-733`、`application/extra/maccms.php:106-109` | 同上 | A | MacCMS 前台網頁搜尋有頻率限制：同一個 PHP session 3 秒內第二次搜尋第 1 頁會得到「搜尋太頻繁」頁面 | 以 HTML 爬前台的 spider（XBPQ、XYQHiker）第二種寫法可能靜默地找不到東西（第六節第 2 點） |
| E10 | [OpenCC](https://github.com/BYVoid/OpenCC) 字典；[unihan-database](https://github.com/unicode-org/unihan-database) `kTraditionalVariant.txt` | `2939943bd6f4d459b46d7fdcf07a885ab3f01761`；`b6ab1dca5ac093579fbc81c976022eb5c273c49c`（草稿資料） | A | 簡轉繁常是一對多（发→發／髮、干→乾／幹、台→臺／颱）；反轉 Android 對照表會得到 頭發、皇後、台風、面條 | 簡體輸入若要產生繁體寫法，只能用詞組級的 OpenCC，不能反轉 Android 表 |
| E11 | Wikimedia CirrusSearch `AnalysisConfigBuilder.php:1039-1062`（`e2d8e9c3…`）、Solr `filters.adoc:1221-1273`（`0d2a4649…`）、charabia `chinese.rs:9-22`（`bc63b986…`）、STConvert README（`de6642b2…`） | 各自 HEAD | A | 自己擁有索引時，成熟做法是索引與查詢都正規化成同一種寫法 | 不適用：來源的索引不在我們手上，只能在查詢端展開 |
| E12 | Elasticsearch `reciprocal-rank-fusion.md:10-52` | `d4e6f4b4334cf1661b3bfaa874f774e922c7c5fe` | B | 多組排序結果可用 RRF 融合 | 不採用：來源不給分數，且使用者要看到的是「原本的結果不動、只多出新片」 |

未取得的證據：學術論文（ACL Anthology、CJKI）、RRF 原始論文、unicode.org、Solr 與 elastic.co 官網都被網路政策擋住（403）；OK影視、影視倉沒有公開原始碼。這幾類都不會改變本計畫的決定：查詢端展開是唯一可行方式，已有 MacCMS 的實作可對照。

## 三、現況程式（HEAD `1e9d24e3`）

1. **搜尋分頁**：`AggregateSearchView.submit()` 呼叫 `engine.run(targets, keyword: text)`（`WebHTVApp.swift:1139-1158`）。核心在 `run()` 把關鍵字轉成簡體（`AggregateSearch.swift:65`），每站在 `call()` 內搜一次第 1 頁（`:116-147`）。
2. **WebHome `app.search`**：開同一個 `AggregateSearchView`（`WebHTVApp.swift:5042-5045`、`WebHomeBridge.swift:340-344`），不需要另外改。
3. **載入更多（搜尋分頁）**：每站一個 `page`，下一頁沒有新片或失敗就停（`WebHTVApp.swift:1193-1211`）；核心 `page()` 只送簡體（`AggregateSearch.swift:76-78`）。
4. **首頁站內搜尋**：`CMSView.load(search:)` 自己呼叫 `client.search(TraditionalSimplified.toSimplified(search))`（`:859-874`）；翻頁在 `listing(page:)`，用的是搜尋框目前的文字（`:849-853`），IOS-POC-20 已記錄為既有問題。
5. **合併工具**：`Array<Vod>.merging(newTitlesFrom:)` 以 `vod.id` 去掉已有的片子（`CMSClient.swift:250-258`）。
6. **測試**：`sendsTheKeywordInSimplifiedForm` 規定只送一種寫法（`AggregateSearchTests.swift:38-47`），要跟著改；`TaiwanTraditionalTests.searchStillReportsExactlyWhatTheSourceSent` 規定搜尋結果逐位元組不變，改完仍要成立。

## 四、方案比較

| 方案 | 說明 | 判斷 |
|---|---|---|
| 不改 | 繁體標題的站仍然找不到 | 不符合要求 |
| Android／上游做法 | 只送一種寫法 | 不符合要求；本功能沒有上游先例 |
| 兩次 `run()`，或每種寫法各自排程 | 第二種寫法會被自己的第一次呼叫判成「忙碌」；每站回報兩次，畫面計數與 id 全部錯亂 | 不採用 |
| 同一站兩種寫法同時送出 | spider 在序列佇列上本來就一次一個，沒有加速；冷啟動時可能建出兩個 session | 不採用 |
| **同一站在一個名額內依序搜兩種寫法，合併後回報一次** | 忙碌判斷、名額、回報次數與畫面都不變；只在兩種寫法不同時才多送一次 | **建議** |

繁體寫法從哪裡來：

| 方案 | 說明 | 判斷 |
|---|---|---|
| (a) **輸入的原文** | 輸入繁體時，原文就是繁體寫法；輸入簡體、英文或數字時只搜一次，與現在完全相同 | **建議**：不需要新的轉換器，也不動 IOS-POC-32 的「只用於顯示」規則 |
| (b) 用 OpenCC `s2tw`（IOS-POC-32 C 的轉換器）把簡體輸入轉成繁體 | 簡體輸入也能多搜繁體；但要放寬「轉換器只用於顯示」的規則與測試，字典載入前只能搜一種 | 替代方案，要你同意 |
| (c) 反轉 Android 對照表 | 頭發、皇後、台風、面條，錯字 | 不採用 |

## 五、設計（建議）

1. **關鍵字寫法**（新檔 `DualScriptSearch.swift`）：`[TraditionalSimplified.toSimplified(k), k]`，相同就只留一個。簡體寫法排第一，所以送出順序、結果順序與現在相同；英文、數字、簡體輸入只有一種寫法，行為與今天逐位元組相同。
2. **搜尋分頁**：`call()` 的同一個 `work` Task 內依序搜每種寫法的第 1 頁，合併後回報一次。忙碌判斷、6 個名額、每站一次回報都不變。
3. **期限與部分結果**：30 秒仍以整個站計算。期限到時，若至少一種寫法已經回來，就回報已合併的結果（不算逾時），否則回報逾時。第二種寫法只在搜尋未被取消、未逾時時才開始。這樣不會出現「今天找得到、改完反而逾時看不到」的退步。
4. **結果判定**：任一種寫法成功就算找到（清單可能是空的）；兩種都失敗才算失敗，訊息取第一個錯誤。
5. **合併與排序**：第一種寫法的清單保持來源原樣；後面的寫法只加入 `vod.id` 尚未出現的片子（沿用 `merging(newTitlesFrom:)`）。只在同一站內合併，不跨站去重（`vod.id` 只在站內唯一，Android 也不跨站去重）。
6. **載入更多**：每站記錄每種寫法各自的下一頁。每次載入依序翻「還在增加新片」的寫法；某種寫法的下一頁沒有新片或失敗就不再翻它；全部停了才不再載入。只有一種寫法時，規則與今天完全相同。起點依第 1 頁的實際結果決定（查核後修正）：回來的寫法從第 2 頁開始；被期限或取消切斷、或沒問到的寫法從第 1 頁開始；失敗的寫法不再翻；第二種寫法的第 1 頁若沒有新片也不再翻它（來源本身不分繁簡時可省下重複的請求）。
7. **首頁站內搜尋**：第 1 頁與翻頁用同一套核心工具。分類列與篩選列仍取第一種寫法的回應（與今天相同）。翻頁改成使用送出時的關鍵字，所以 IOS-POC-20 記錄的「翻頁用搜尋框目前文字」問題在搜尋翻頁上會一起消失（第六節第 7 點）。
8. **log**：兩種寫法時，每種寫法回來後記一行「`[search] <站名> form 2/2: N titles`」，真機可用來量第二種寫法多找到多少、花多久。
9. **不做**：設定開關、跨站去重、把繁轉簡表換成 OpenCC `tw2s`（會改變今天每次搜尋送出的內容，要另案）、XBPQ／XYQHiker 兩次搜尋之間等 3 秒（先用 log 確認影響）。

## 六、已知風險與限制

1. **變慢**：約 73% 的站是 spider（IOS-POC-20 的統計：30 CMS、32 csp、7 JS／drpy、42 Python），兩種寫法依序執行，這些站的搜尋時間約為兩倍；只在輸入含可轉換的繁體字時才發生。慢的站可能在第二種寫法時到期，這時顯示第一種寫法的結果。**真機未量測**。
2. **MacCMS 前台的頻率限制**：爬 MacCMS 前台網頁的 XBPQ、XYQHiker 站，第二次搜尋可能拿到「搜尋太頻繁」頁面，被解析成 0 筆。合併不會因此少掉第一種寫法的結果，但這些站的繁體寫法會沒有效果。
3. **收益未量測**：沒有資料顯示使用者的來源有多少是繁體標題；第八點的 log 用來在真機確認。
4. **664 字仍然找不到簡體站的結果**：例如輸入「頭髮」會送「头髮」和「頭髮」，簡體站的「头发」仍找不到（IOS-POC-32 已知風險 1）；要改繁轉簡表才能解決，屬另案。
5. **空的 `vod_id`**：第一種寫法若已有空 id 的片子，第二種寫法的空 id 片子會被去掉；這類片子本來就無法開啟詳情。
6. **未編譯、單元測試未執行**：與 IOS-POC-32 C（`1e9d24e3`，同樣未編譯）一起在下一次 Release build 第一次編譯。
7. **站內搜尋翻頁的既有問題一起修正**：今天在搜尋框改字但不送出、或按取消清空搜尋框，再往下捲，會把新字或首頁、分類的下一頁混進搜尋結果；改完後只要畫面上是搜尋結果，翻的就是送出時的關鍵字。這是設計第 7 點的必然結果。

## 七、驗收

- 單元測試（撰寫，不執行）：
  1. 寫法：`慶餘年` → `庆余年`、`慶餘年`；`庆余年`、`Friends`、`1080` 只有一種。
  2. 搜尋分頁依序送 `庆余年`、`慶餘年`，每站只回報一次，結果為聯集且第一種寫法的清單原樣在前。
  3. 第二種寫法卡住時，期限到回報第一種寫法的結果，不是逾時。
  4. 一種寫法失敗、另一種成功時算找到；兩種都失敗才算失敗。
  5. 中文關鍵字下同時執行的站數仍不超過上限。
  6. 載入更多：某種寫法沒有新片後只翻另一種；兩種都停了才停；只有一種寫法時與今天相同。
  7. 既有測試照常通過，包含 `searchStillReportsExactlyWhatTheSourceSent`。
- 真機：
  1. 輸入繁體片名，搜尋分頁、WebHome 搜尋、首頁站內搜尋都有結果，且比改之前多或相同。
  2. 輸入英文或簡體時行為與改之前相同。
  3. 繁體標題的站（若有）用繁體輸入可以找到。
  4. 看 log 的 `form 2/2` 行，量第二種寫法多找到的數量與時間。
  5. 載入更多可以繼續翻到兩種寫法的後續頁。

## 八、回滾

一個 commit，`git revert` 後重新發布。沒有設定開關。

## 九、使用者的決定（2026-09-28）

| 項目 | 選擇 |
|---|---|
| 繁體寫法的來源 | 輸入原文（不用 OpenCC 轉簡體輸入） |
| 範圍 | 搜尋分頁、WebHome `app.search` 與首頁站內搜尋都改 |
| 載入更多 | 每種寫法各自翻頁 |
| 實作 | 核准 |

## 十、實作（2026-09-28）

1. 檔案：
   - 新檔 `ios/Sources/WebHTVCore/DualScriptSearch.swift`：`forms(of:)`、`firstPage`（依序查詢、合併、產生游標）、`nextPage`、`Cursor`。
   - `ios/Sources/WebHTVCore/AggregateSearch.swift`：`run()` 算出寫法；`call()` 在同一個名額內呼叫 `firstPage`；`Report` 多了 `cursor`；期限到時若已有一種寫法回來就回報合併結果；`page()` 由 `more(after:cursor:of:)` 取代。
   - `ios/WebHTVApp/Sources/WebHTVApp.swift`：搜尋分頁的 `SiteHits` 改存游標；首頁站內搜尋的第 1 頁與翻頁改用核心工具，新增 `searchCursor`。
   - 測試：新檔 `DualScriptSearchTests.swift`（8 個）；`AggregateSearchTests.swift` 改 1 個、新增 5 個；`TaiwanTraditionalTests.swift` 更新一段說明。都未執行。
2. 與第五節設計相比，依查核修正的地方：
   - 游標依各寫法第 1 頁的實際結果產生（第五節第 6 點補充的規則），不再假設每種寫法都已回來。原本的寫法在期限切斷第二種寫法時，會讓它的第 1 頁永遠不顯示。
   - 期限到或按「停止」時，在判定的同一刻就取消底下的工作，第二種寫法不會在那之後才開始。
   - 只有一種寫法時不記錄部分結果，所以期限前一刻才回來的站仍照原本判為逾時，與改之前完全相同。
   - 首頁站內搜尋翻頁：畫面上是搜尋結果就翻送出時的關鍵字，不再看搜尋框目前的文字；翻到的新片加在目前畫面上的清單後面，同一關鍵字重新整理後的第 1 頁不會被舊資料蓋掉；換了關鍵字或清單時丟掉舊的一頁。
3. 驗證：
   - 語法：tree-sitter-swift 分析新增與修改的 6 個 Swift 檔，沒有新的語法錯誤（`WebHTVApp.swift` 另有 3 個既有的分析器誤報）。
   - 預期值：新測試的預期值以 Python 模擬 `forms`、`firstPage`、`nextPage` 的規則重算，全部相符。
   - 查核：workflow `wf_5f88a792-0aa` 以四個面向（Swift 6 編譯、既有行為、測試、App 流程）審查，每個發現再由獨立代理嘗試推翻。確認 9 個次要問題，沒有編譯阻斷；9 個都已修正（本節第 2 點與新增的測試）。修正後由 workflow `wf_9c0f247e-ef7` 複審（編譯、邏輯兩個面向）：沒有確認的問題。唯一的發現「期限到時第一種寫法回了空結果，會顯示沒有找到而不是逾時」經驗證是設計本意（第五節第 3、4 點：改之前這個站會準時回報沒有找到，不能因為第二種寫法慢而變成逾時）。
   - **未編譯**：容器沒有 Swift。單元測試未執行、真機未驗證。第一次編譯是下一次發布的 Release build，會與 IOS-POC-32 C 一起編譯。
   - Ponytail：unavailable / skipped。
4. 待真機驗收：第七節的真機項目。

## Recovery anchor

- 目標：搜尋時簡體、繁體寫法各搜一次，同一站合併後再顯示。
- 狀態（2026-09-28）：已實作並 commit（第十節）；未編譯、單元測試未執行、真機未驗證、未發布。
- 相關檔案：`ios/Sources/WebHTVCore/DualScriptSearch.swift`、`ios/Sources/WebHTVCore/AggregateSearch.swift`、`ios/WebHTVApp/Sources/WebHTVApp.swift`（`AggregateSearchView`、`CMSView`）、`ios/Tests/WebHTVCoreTests/DualScriptSearchTests.swift`、`AggregateSearchTests.swift`。
- 下一步（唯一）：請使用者決定是否把 IOS-POC-32 C 與本任務一起發布為 `0.1.29 (30)`（bump 版本、tag、發布前都要先問）。
