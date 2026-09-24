# IOS-POC-20 — 全站台搜尋

- 狀態：**已實作並發布，送出搜尋可用**（2026-09-25）：`0.1.17 (18)` 送出搜尋就閃退，`0.1.18 (19)` 修正後使用者真機回報「可以搜尋了，沒有閃退」。其餘驗收項目尚未回報；單元測試未執行。使用者的選擇與實作內容見文末「實作紀錄（2026-09-25）」，設計依據見「設計研究（AGENTS §7，2026-09-25）」；三者衝突時，以實作紀錄為準，其次是設計研究，最後才是下方原計畫。
- 使用者需求（2026-09-24，原文）：「我在切換資訊源的時候需要記錄每個資訊源離開前的站台，以便我回來資訊源我還要重新切換；另外我需要一個全資源搜尋的功能；給我相關計畫」。
- 規劃基準：2026-09-24 15:39 CST，分支 `ios-poc`（規劃時 HEAD `75fc13a5`；之後只多了 17H 解析度修正 `5613517a`，不影響本計畫）。
  證據來自三個唯讀 agent 讀程式碼（iOS 資訊源／站台、iOS 搜尋、Android 參考做法），關鍵行號已人工抽查；**沒有跑 `swift test`、沒有建置、沒有在模擬器或實機試過**。
- 順序：先做 IOS-POC-19，再做 IOS-POC-20（兩者都改 `WebHTVApp.swift`，一個做完再開下一個；各自一次 task guard、一個 commit、`finish --no-tag`）。
  預留：IOS-POC-19B（切回連不上的資訊源時改讀快取）、IOS-POC-20B（跨所有資訊源搜尋）。
- 用語：使用者說的「資訊源」＝ iOS UI 的「設定來源／已存來源」（`ConfigSource`、`SavedSource`）；「站台」＝ UI 的「內容來源」（`Site`）。

**完成條件**：從首頁的搜尋入口輸入關鍵字，同時搜尋目前資訊源所有可搜尋的站台。結果隨到隨顯示，每筆標出來源站台，點進去就是那個站台的詳情頁，可以播放。換關鍵字或關掉畫面會取消舊的搜尋，搜尋期間 App 其他部分照常可用。

**Task guard**（2026-09-25 更新）：
- 車道：`standard`（原寫的 `feature` 不是 task guard 的有效車道）。
- 範圍：
  - 新檔 `ios/Sources/WebHTVCore/AggregateSearch.swift`
  - 新檔 `ios/Sources/WebHTVCore/TraditionalSimplified.swift`（移植 Android `Trans.java` 字表）
  - `ios/Sources/WebHTVCore/WebHTVConfig.swift`
  - 新檔 `ios/Tests/WebHTVCoreTests/AggregateSearchTests.swift`
  - `ios/WebHTVApp/Sources/WebHTVApp.swift`
  - `ios/WebHTVApp/Sources/PythonSpiderRuntime.swift`（Q7 採用時）
  - `.github/workflows/ios-sidestore-release.yml`（Q6 選 A 時）
  - `docs/IOS-POC-20-aggregate-search.md`
  - `docs/current-task-state.md`
- 新畫面放在 `WebHTVApp.swift` 裡：已確認 App target 用明確的 file reference，新增 App 檔案必須改 pbxproj；WebHTVCore 的新檔由 SwiftPM 自動編入。
- **這是新功能，而且涉及併發和效能，所以要先過設計研究關卡**：已於 2026-09-25 完成（官方文件、Swift Evolution、WWDC、Mihon／Aidoku／FongMi 原始碼、本地程式碼複核）；論文與部落格因網路政策無法取得，已記錄。你核准後才開始寫程式。

### 要解決的問題
現在只能在單一站台裡搜尋。要找一部片，得逐一切換站台再搜。

### 目前實作
- **單站搜尋**：首頁 CMSView 的 `.searchable`（「搜尋影片」，`WebHTVApp.swift:625-626`）會呼叫 `load(search:)`（807-830），再走 `SourceClient.make(site:resolver:)`（`SourceClient.swift:23`）→ `search(_:page:)`（57）。
  - CMS 站台送 `wd`、`quick=false`（`CMSClient.swift:369-374`）。
  - Spider 站台走 `SpiderSession.search` → `searchContent(key, quick:false, page)`（`SpiderSession.swift:44-47`）。
- **WebHome 的 `app.search`**（3848、3882-3884）也只開單站的 `CMSView(initialQuery:)`。Android 在這裡開的是全站台搜尋（`HomeWebBridge.java:293-303`）。
- **`Site` 只解碼 `key/name/type/api/ext`**（`WebHTVConfig.swift:84-86`），沒有 `searchable`。
- **`Vod` 不帶站台資訊**（`CMSClient.swift:166-192`）。現成的組合型別 `VodRequest(site:vod:)`（3951-3955）的 `id` 是 `site.key + "/" + vod.id`，同 key 的站台會撞在一起。
- **`VodView(site:summary:source:)`**（1080-1083）只需要傳入的站台和資訊源，不讀首頁選的站台，所以搜尋結果可以直接打開。觀看記錄記在 `Site.id` + `source.identity` 底下。
- **沒有併發控制**：沒有同時進行數的上限、沒有每站期限，也沒有取消。
  - JS 站台：`JavaScriptSpiderRuntime` 不理會 Task 取消，`timeout` 欄位也沒用上。
  - Spider 的 HTTP：`HTTPHost` 用 semaphore 同步等待，每次最長卡住一條 GCD 執行緒 65 秒（`HTTPHost.swift:22-25, 64-69`）。
  - Python：同步呼叫，佔住 Swift 併發共用的執行緒並持有 GIL（`PythonSpiderRuntime.swift:61-63, 91-96, 108-110`）。
- **既有的單站搜尋缺陷**（不修，也不帶進新畫面）：
  - 取消搜尋框後 `searching` 還是 true，往下捲載入更多時，會把首頁或分類的片混進搜尋結果（807-814）。
  - 搜尋失敗時，舊的格子還留在畫面上（611-620、841-843）。

### Android 參考與取捨
| Android（路徑） | 決定 |
|---|---|
| `Site.searchable` 預設 1、`isSearchable()`（`Site.java:306-316`） | 照抄：只解碼 `searchable`，其他欄位不做 |
| `SiteViewModel.searchContent`：20 執行緒、每站 30 秒 `TIMEOUT_SEARCH`（143-173、`Constant.java:16`） | 改寫：總上限 6，Python 另限 1 條（理由見「效能與限制」） |
| `searchEpoch` + `stopSearch()` 丟掉過期結果（215-228） | 照抄：用代數計數加上取消 Task |
| `SearchTask` 用 `Trans.t2s` 繁轉簡（`SearchTask.java:13`） | 照抄，但只用在全站台搜尋（見 Q2） |
| `SiteApi.searchContent` 用 `vod.setSite(site)` 替每筆結果標站台 | 改寫：結果帶 `(Site, Vod)` |
| CollectFragment：「全部 x/總數」頁籤 + 依完成順序排的站台頁籤，全部頁籤不分頁（150-181、239-259） | 改寫：手機直向改用頂部水平 chip |
| 各站台自己的分頁 | v1 不做（見 Q4） |
| `SiteHealthStore` 排序、360kan 熱門詞、搜尋歷史、各站台的可搜尋開關、快速搜尋換源 | 不做，要的時候再加 |

### 方案比較
| 方案 | 評估 |
|---|---|
| A 不改 | 問題照舊 |
| B 照抄 Android（全部站台 20 路同時） | 不採用。iOS 的 JS HTTP 會卡住 GCD 執行緒，Python 會佔住 Swift 併發的共用執行緒，20 路同時跑會拖慢整個 App |
| **C 窄版改寫（建議）** | 只搜目前資訊源的站台；總上限 6、Python 1 條；每站 30 秒期限；可取消並丟掉過期結果；另開一個獨立畫面 |
| D 跨所有資訊源 | 延後到 IOS-POC-20B。要同時解析多份設定，每份用自己的 `CSPSourceResolver`。`SpiderSessionStore` 只用 `Site.id` 當鍵，可能拿到別的資訊源的 session。HistoryView 只顯示目前資訊源的記錄，看過的片會「消失」。Android 也不做 |
| E 把首頁現有搜尋框改成多站台 | 不採用。會動到 IOS-POC-8F 已經請你確認過的搜尋框和來源選單行為，而且單站搜尋還有它的用途 |

### C 的核心設計（WebHTVCore）
- **新函式 `AggregateSearch`**：
  - 輸入：`sites`、`keyword`、一個 `search: @Sendable (Site) async throws -> [Vod]` 閉包（讓測試可以塞假實作）、上限參數。
  - 輸出：`AsyncStream`，每個站台回報一次結果：有結果、失敗或逾時。
- **每站 30 秒期限**：
  - 做法：每個站台用一個獨立的 Task，加上只會完成一次的 continuation，看是結果先到還是計時器先到。
  - 不用 TaskGroup 競速的原因：JS 和 Python 的工作不理會取消，TaskGroup 結束前還是會一直等它們，期限根本擋不住。
  - 逾時的站台只會在進度上標成「逾時」。它佔的名額要等底層工作真的結束才釋放，所以背景執行緒數量不會超過上限。這裡要留一條 `ponytail:` 註記：卡住的站台最長會佔住名額 65 秒，要真正中斷得靠 runtime 支援取消。
- **Python 另限 1 條**（`site.isPythonSpider`）。反正 GIL 本來就讓 Python 一次只能跑一條，限 1 條不損失速度。要留 `ponytail:` 註記，升級路徑是把 Python 呼叫移出 Swift 併發的共用執行緒，屬於 runtime 工作。
- **取消**：取消負責接收結果的 Task 後，就不再啟動新的站台。CMS 的 URLSession 請求會真的取消；JS 和 Python 跑完後，結果直接丟掉。
- **`Site` 解碼 `searchable: Int?`**：沒有這個欄位就當成 1，等於 0 才不搜。`Site.id` 只看 key 和 ext，不受影響；舊的快取也照樣能解。
- **繁轉簡**：`keyword.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? keyword`。iOS 上能不能用這個 ICU 轉換還沒確認，要用測試驗。
- **結果型別**：沿用 `VodRequest`，把 `id` 改成 `site.id + "\u{0}" + vod.id`，順便修掉 WebHome 同 key 站台的碰撞。這一行算修正。

### UI 行為
- **入口**：首頁工具列右側加一個放大鏡，用 sheet 開啟全站台搜尋畫面，畫面有自己的 NavigationStack 和搜尋欄。首頁 CMSView 原本的搜尋框不動。
  - sheet 裡的 `.searchable` 在 iOS 26 的行為還沒確認（IOS-POC-8F 只驗過首頁）。如果模擬器看到異常，改用 `TextField`。
- **狀態**：
  - 還沒搜尋時，顯示輸入提示。
  - 搜尋中，頂部顯示「全部 已完成/總數」和取消按鈕，結果隨到隨加。
  - 全部站台回完後，搜尋結束。
- **分組**：頂部 chip 列，第一個是「全部 (n)」，後面是有結果的站台，依完成順序排；點 chip 就只看那個站台。每筆結果標站台名。
- **沒結果或出錯**：
  - 全部完成、0 筆：顯示「沒有找到『關鍵字』」。
  - 部分失敗或逾時：小字顯示「x 個站台失敗或逾時」。
  - 全部失敗：顯示錯誤和重試按鈕。
  - 站台回「暫不支持搜索」這類錯誤：算失敗，不跳錯誤訊息。
- **打開詳情**：`NavigationLink` 到 `VodView(site: hit.site, summary: hit.vod, source: source)`，不改 `selectedSiteID`，避免首頁 526 重建。觀看記錄會出現在「記錄」頁（同一個資訊源）。
- **換關鍵字**：取消舊 Task、代數加一、清空結果。**關掉 sheet**：取消搜尋。
- **分頁**：v1 每個站台只取第一頁（Q4）。
- **WebHome `app.search`**：改成打開這個畫面並帶入關鍵字（Q3）。

### 效能與限制
- **規模**：目前資訊源約 60 多個可用站台，其中多少個標 `searchable:0` 還沒實測。
- **同時進行數**：總上限 6，Python 1 條。
  - JS 站台最多卡住約 6 條 GCD 執行緒。
  - Python 最多佔 1 條 Swift 併發共用的執行緒。
- **時間**：每站顯示期限 30 秒。卡住的站台最長 65 秒才釋放名額，所以最慢的情況是整批要跑好幾輪。
- **第一次搜尋會比較慢**：每個 spider 站台都要初始化，drpy 和 Python 可能還要下載規則或腳本。切換資訊源或 Spider 套件更新時，`SpiderSessionStore.reset()` 會把這些暖機丟掉。
- **取消後的殘留**：JS 和 Python 已經開始的呼叫會跑完才結束，期間那個站台的佇列被占住。如果你立刻去首頁瀏覽那個站台，會等比較久。
- **網路和電量**：一次搜尋每個站台至少一個請求。只在按下搜尋時觸發，不做邊打字邊搜。
- **匯入檔資訊源**：drpy 和 Python 站台本來就不能用（`CSPSourceResolver.swift:35-42`），自然不在搜尋範圍內。
- **既有問題，只回報**：`SpiderSessionStore` 可重入。首頁瀏覽和搜尋同時第一次呼叫同一個站台時，可能建出兩個 session。

### 驗收標準
1. 輸入繁體關鍵字：多個站台回結果，每筆標站台名；進度跑到「總數/總數」後結束。
2. `searchable:0` 的站台不會被呼叫。
3. 同時進行中的站台不超過 6 個，Python 不超過 1 個。
4. 慢的站台 30 秒後回報逾時，其他站台的結果不等它。
5. 換關鍵字後，舊的結果不再出現；取消後不再啟動新站台。
6. 點結果：進到該站台的詳情頁，可以播放，觀看記錄出現在「記錄」頁；回到首頁時站台沒變。
7. 同 key 的站台（`爱影`）結果不會互相覆蓋。
8. 「慶餘年」送出去是「庆余年」。
9. 首頁原本的單站搜尋行為不變。
10. 搜尋期間首頁可以捲動、操作。

### 驗證方式
- **`swift test`**（跑一次）：
  - 新的 `AggregateSearchTests` 用假閉包驗第 2、3、4、5 條：計算同時進行數，逾時用很短的期限參數測。
  - `Site` 解碼 `searchable`（沒有欄位、0、1）。
  - 繁轉簡。
- **模擬器**：真實資訊源，用兩組關鍵字；中途換關鍵字；中途關掉；點結果播放；確認第 7、9、10 條。Python runtime 能不能在模擬器上跑還沒確認，不能的話 Python 那條只能到實機驗。
- **實機**（你用 SideStore 安裝 IPA）：Python 站台參與時是否流暢、會不會發熱、整體要多久。我只建 device build 並交 IPA。

### 回滾
Revert 單一 commit 即可。v1 不存任何資料（沒有搜尋歷史）。`searchable` 是 Optional，舊快取不受影響。

### 風險
- iOS 的執行緒模型比 Android 脆弱。如果實機上上限 6 還是會卡，就調低常數；要根本解決，得讓 JS 和 Python 的 runtime 支援取消（IOS-POC-12/13 的範圍）。
- 繁轉簡可能讓少數只收錄繁體的台灣站台找不到東西。
- 結果依完成順序加入，chip 列會一邊跑一邊變動。每筆結果的識別要用 `Site.id`，不能用 key，畫面才不會閃。
- 把 `VodRequest.id` 改成 `Site.id`，會影響 WebHome 用 sheet(item:) 開詳情時的識別。預期只修掉碰撞，但要在模擬器確認 WebHome 點片仍然正常。

### 待你決定
- **Q1**：「全資源搜尋」是只搜目前資訊源的所有站台，還是所有已存的資訊源都要搜？**預設：目前資訊源**，和 Android 的聚合搜尋一樣；跨資訊源另開 IOS-POC-20B。
- **Q2**：關鍵字要不要先繁轉簡？**預設：全站台搜尋會轉；首頁單站搜尋不動**。如果單站也要轉，會改變現有行為，要你另外同意。
- **Q3**：WebHome 首頁的 `app.search` 要不要改開全站台搜尋（Android 的行為）？**預設：要改**。
- **Q4**：v1 每個站台只取第一頁結果，可以嗎？**預設：可以**；需要時再加各站台自己的「載入更多」。
- **Q5**：搜尋歷史、熱門詞、站台健康排序、每個站台的可搜尋開關，這次要做嗎？**預設：都不做**。

### 預估（我自己的執行時間）
| 階段 | 時間 |
|---|---|
| 設計研究 + 任務文件（完成後停下來等你核准） | 40 分 |
| 核心：`AggregateSearch`、`Site.searchable`、繁轉簡、測試 | 45 分 |
| UI：sheet、chip、進度、各種狀態、接 VodView、WebHome 路由 | 60 分 |
| 建置 + 模擬器情境 | 40 分 |
| device build + IPA | 15 分 |
| 文件、finish commit | 10 分 |
| **合計** | **約 3.5 小時**（不含等你核准和實機回報） |

## 實作前要先查的事（兩份計畫共用）

- HistoryView 會不會寫 `selectedSiteID`（影響 19 的 Binding 能不能蓋住所有寫入路徑）。
- 冷啟動時，csp 類的 spider 站台是否要等 Spider 套件就緒才算可用（影響 19 的「暫時不在」情境多常發生）。
- 你的設定檔裡 `searchable`、`quickSearch` 的實際分布。
- iOS 上 `StringTransform("Hant-Hans")` 能不能用、Python runtime 能不能在模擬器上跑、Python 做 HTTP 時會不會釋放 GIL。
- CMSView 的海報格能不能直接拿來重用；sheet 裡的 `.searchable` 在 iOS 26 的行為。

主要檔案：
- `/Users/chengchenchih/GIT/webhtv/ios/WebHTVApp/Sources/WebHTVApp.swift`
- `/Users/chengchenchih/GIT/webhtv/ios/Sources/WebHTVCore/SiteSelection.swift`
- `/Users/chengchenchih/GIT/webhtv/ios/Sources/WebHTVCore/WebHTVConfig.swift`
- `/Users/chengchenchih/GIT/webhtv/ios/Sources/WebHTVCore/SourceClient.swift`
- `/Users/chengchenchih/GIT/webhtv/ios/Sources/WebHTVCore/ConfigSource.swift`

## 設計研究（AGENTS §7，2026-09-25）

- 研究基準：2026-09-25 00:40 CST，分支 `ios-poc`，HEAD `5e67e1be`（程式碼與 `507c49b6` 相同）。存取日期一律為 2026-09-24（UTC）。
- 決策問題（只有一個）：在 iOS 的執行緒模型下，如何同時搜尋目前資訊源的所有可搜尋站台（CMS、JS、Python 混合），做到可取消、有期限、結果隨到隨顯示，而且不拖慢 App 其他部分。
- 做法：一個唯讀 agent 讀外部來源並保存原文（Apple 文件 JSON、WWDC 逐字稿、shallow clone 的專案原始碼），另一個唯讀 agent 複核本地程式碼；關鍵引文與 commit 已由主工作階段抽查。
- 證據等級：A＝官方文件、規格或原始碼；B＝成熟專案程式碼；C＝文章或部落格。

### 外部證據

| 證據 | 等級 | 版本 | 支持的結論 | 對 WebHTV 的適用性與限制 | 對設計的影響 |
|---|---|---|---|---|---|
| Apple `TaskGroup`、`withTaskGroup` 文件（developer.apple.com，JSON API） | A | 2026-09-24 | 「A task group *always* waits for all child tasks to complete before it's destroyed」；`cancelAll()` 不會中斷執行中的工作 | JS／Python 不理會取消，直接當 child 會讓群組等到最長 65 秒 | 支持「不把不可取消的工作直接放進 TaskGroup」；若 child 只是保證在期限內返回的包裝，TaskGroup 仍可用 |
| Swift Evolution SE-0304 Structured Concurrency（`swiftlang/swift-evolution`） | A | `cf74276b94dbf0bb4bd9c7fbd8617f2e1b9bd9c2` | 取消是協作式且同步設旗標；scope 結束時隱式等待所有 child；`Task.sleep` 被取消立即丟 `CancellationError`；文中有以取消 handler 取消 URLSession 請求的範例 | 可直接套用在換關鍵字時的代數加取消 | 支持代數加取消；提示 JS 的 HTTP 橋接可在取消時中止底層請求 |
| Apple `withTaskCancellationHandler`、`Task.sleep` 文件 | A | 2026-09-24 | handler 最多執行一次、可能與 operation 並行；「if a cancellation handler must acquire a lock, other code should not cancel tasks or resume continuations while holding that lock」；sleep 不佔執行緒 | 直接影響「只完成一次的 continuation 與計時器競賽」的寫法 | 需修正實作細節（見下方修正 3） |
| Apple `AsyncStream` 文件與 SE-0314 | A | 同上 commit | 預設 buffer 無上限；`finish()` 重複呼叫無效果，會先交付已緩衝元素；取消迭代時先呼叫 `onTermination`；從多個執行環境 yield 可能亂序；只能有一個消費者 | 每次搜尋的元素數不超過站台數，無上限 buffer 沒有記憶體風險 | 支持串流設計；需補 `onTermination` 與 `finish()` 的規則 |
| WWDC21 10254〈Swift concurrency: Behind the scenes〉逐字稿 | A | WWDC21 | cooperative pool「only spawn as many threads as there are CPU cores」；semaphore、condition variable 對 Swift concurrency 不安全；GCD 遇阻塞會再開執行緒（thread explosion） | Python 同步呼叫會佔住 pool 執行緒；65 秒的 semaphore 若落在 pool 上會耗盡 pool | 否定「Python 在 cooperative pool 上執行」 |
| WWDC22 110350〈Visualize and optimize Swift concurrency〉逐字稿 | A | WWDC22 | 需要阻塞的程式碼應「move that code outside of the concurrency thread pool – for example, by running it on a Dispatch queue – and bridge it to the concurrency world using continuations」；continuation 必須恰好 resume 一次 | 可直接套用在 JS／Python 呼叫 | 需修正（見下方修正 1、3） |
| WWDC23 10170〈Beyond the basics of structured concurrency〉逐字稿 | A | WWDC23 | 官方的限流模式：先開最多 N 個 task，每完成一個再補一個；「cancellation does not stop a task from running」 | 取代無法連線的部落格文章 | 支持總上限 6 的滑動視窗 |
| Apple `URLSession.data(for:delegate:)`、`httpMaximumConnectionsPerHost` 文件；WWDC21 10095 | A | 2026-09-24 | Swift 的取消對 URLSession async 方法有效；每個 host 的 HTTP/1.1 連線預設上限 6（以 session 計，HTTP/2 忽略） | CMS 站台可靠 Task 取消真正中止請求；多站同 host 時排隊時間要算進期限 | 支持，無需修正 |
| Apple `StringTransform`、`applyingTransform(_:reverse:)` 文件；ICU `icu4c/source/data/translit/root.txt`、`Hans_Hant.txt`；Apple `ICU-76142.2` 原始碼 | A | ICU `302159b39f9489ce9a07ba156a04c279fb93adcf`；Apple ICU `9e80977766f830c93e3cdae3d5628997e1a61b63` | `Hant-Hans`（別名 `Traditional-Simplified`）存在於 ICU 與 Apple ICU 原始碼；`applyingTransform` 回傳 `String?`；文件未列出 iOS 上可用的 ID | 原始碼無法證明各 iOS 版本實際出貨的資料；本環境沒有模擬器可做 runtime 檢查 | 需修正（見下方修正 5） |
| Mihon `SearchViewModel.kt`、`GlobalSearchToolbar.kt`、`NetworkHelper.kt`（`mihonapp/mihon`） | B | `f52d890e7f8a3c418ddab41f41d4b577bce0dc06` | 以固定 5 條執行緒限制真正在跑的來源呼叫；新搜尋 `searchJob?.cancel()` 並在寫入前檢查 `isActive`；只抓第 1 頁；每個來源有載入中／成功／錯誤狀態；完成數／總數進度與「只顯示有結果」篩選；搜尋層沒有逾時 | Android 的阻塞呼叫用實體執行緒限流，與 iOS 的 GCD 阻塞同性質 | 支持上限、取消、只抓首頁、逐步顯示、明確的錯誤狀態與進度 |
| Aidoku `SearchContentView+ViewModel.swift`、`SearchContentView.swift`（`Aidoku/Aidoku`） | B | `8ae2da15d9edef05d0e6f27e0799c629883d0890` | `withTaskGroup` 滑動視窗，`maxConcurrentTasks = 3`，註解指出同時太多會讓 sources freeze；新查詢 `searchTask?.cancel()`；輸入 debounce；錯誤以 `try?` 吞掉；沒有逾時 | 同為 iOS／Swift；「freeze」是同步工作耗盡 pool 的實際案例 | 支持 TaskGroup 限流與取消；沒有逾時與錯誤狀態是反例 |
| FongMi/TV（分支 `fongmi`）`ViewModelSearchRunner.java`、`SiteViewModel.java`、`Task.java`、`Constant.java`、catvod `Trans.java`、`CollectFragment.java` | B | `4afc4473e22a7ed3d98ee12233e0c2a490061000` | 固定 20 條執行緒；`TIMEOUT_SEARCH` 30 秒；`AtomicInteger` 代數加 `future.cancel(true)`；只抓第 1 頁；`Trans.t2s` 是固定字表，只在繁體模式啟用；「全部」chip 加上有結果的站台 chip | 與本庫 Android（`app/`、`catvod/`）數值相同；本庫 `Trans` 有 2,528 組字對，啟用條件由 `Setting.java:387-389` 的語言設定決定，未設定時依 region 是否為 `TW` | 支持 30 秒、代數、只抓首頁與 chip；簡繁轉換的做法需修正 |

### 無法取得的來源

- 環境的網路政策以 `CONNECT tunnel failed, response 403` 拒絕以下主機，每個主機只重試一次：
  - ICU user guide（unicode-org.github.io）：改讀 ICU repo 內同一份 markdown。
  - Dean & Barroso〈The Tail at Scale〉（research.google、static.googleusercontent.com、www.barroso.org、cacm.acm.org）：沒有讀到論文，所以**不引用**它的結論。
  - TaskGroup 限流的技術文章（www.donnywals.com、www.avanderlee.com）與 forums.swift.org：改用 WWDC23 10170（A 級）替代，因此本次 C 級來源為 0 篇。
- 程序註記：SE-0304 與 SE-0314 是先從 raw.githubusercontent.com 取得，之後才以唯讀方式加入 `swiftlang/swift-evolution`；事後已確認內容與 `cf74276b` 相同。

### 本地程式碼複核（HEAD `507c49b6`）

- 行號：WebHTVCore 各檔自 `75fc13a5` 起沒有改過，上方引用仍正確；`WebHTVApp.swift` 因 IOS-POC-19 與 P10-IOS 位移：

| 上方計畫引用 | 目前位置 |
|---|---|
| 首頁 `.searchable` 625-626 | 657-658（`CMSView` 起於 562） |
| `load(search:)` 807-830 | `listing(page:)` 839-846、`load(search:category:)` 848-876、`loadMore()` 822-837 |
| 既有缺陷 807-814、611-620／841-843 | 839-846、643-652／873-875 |
| `VodView` 初始化 1080-1083 | 1112-1115 |
| 首頁重建「526」 | `.id(selectedSite.id)` 558 |
| WebHome `app.search` 3848、3882-3884 | `onSearch` 4090、sheet 4124-4126 |
| `VodRequest` 3951-3955 | 4193-4197（`private`） |

- **執行緒模型**（決定併發設計的事實）：
  - CMS（type 0/1/4，30 站）：`CMSClient` 走 `URLSession.webHTV` 的 async 請求，閒置逾時 10 秒（`ConfigLoader.swift:6-8`）；Task 取消會真正中止請求。
  - JS runtime：每個 spider 有自己的 serial `DispatchQueue`（`JavaScriptSpiderRuntime.swift:21`），方法呼叫以 continuation 加 `queue.async` 執行（54-89），不在 Swift 併發的共用執行緒上；但沒有取消 handler，`timeout` 只存不用。HTTP 橋接以 semaphore 阻塞該 queue 的執行緒，每次請求最長 `timeoutInterval + 5`（`HTTPHost.swift:46、66-69`，預設 65 秒），一次搜尋可能發多次請求。**已移植的 csp 站台也是 JS**（`SpiderRegistry.swift:50`：「Adding a port is a new `.js` resource plus one line here」），所以 JS 類共 39 站（csp 32、JS／drpy 7）。
  - Python runtime（`ios/WebHTVApp/Sources/PythonSpiderRuntime.swift`，App target）：async 方法內直接同步呼叫 `call()`（61-63），先取每個實例的 `NSLock`（22、91-96），再在 `bridge()` 全程 `PyGILState_Ensure`（108-110）。**整個呼叫（含網路）都佔住一條 Swift 併發共用的執行緒**；同一站台的第二個並行呼叫還會在 `NSLock` 上阻塞另一條。CPython 在 socket I/O 期間會釋放 GIL，所以不同站台的 Python 呼叫本來可以重疊等網路（直譯器由 `scripts/fetch_python_ios.sh` 下載，不在 repo 內，這一點以 CPython 標準行為推定）。
  - JS 與 Python runtime 的初始化都在呼叫者的執行緒上同步執行（`JavaScriptSpiderRuntime.swift:29-35` 的 `evaluateScript`），第一次搜尋時會短暫佔用共用執行緒。
- **與計畫不符、會改變設計的事實**：
  1. `searchable`：Android 是 `searchable == 1` 才搜，缺值當 1，`2` 代表使用者關掉（`Site.java:306-308、386-388、394-397`）。計畫的「等於 0 才不搜」會搜到設定檔裡那個 `searchable:2` 的站台。
  2. `Site.id` 會完全相同：`id = key + "\u{0}" + ext 的正規化 JSON`（`WebHTVConfig.swift:94、207-214`），不含 `api`。目前設定裡兩個 `星芽短剧`（都是 Python、都沒有 ext、api 不同，其中一個跨源）的 id 相同，會共用同一個 spider session（`SourceClient.swift:230`）。計畫的 `site.id + "\u{0}" + vod.id` 修不掉這個碰撞。
  3. `VodRequest` 是 App 檔的 `private` 型別，Core 無法沿用；WebHome 的同 key 碰撞只是理論上（`player.playVod` 只取第一個同 key 站台，`WebHomeBridge.swift:317`）。
  4. WebHome 在 iOS 上只能從「設定 › 開發者」進入（`WebHTVApp.swift:998`）。
  5. 規模：iOS 會列出約 111 站（CMS 30、csp 32、JS／drpy 7、Python 42），不是「60 多個」；4 個 Python 站跨源，會列出但一開就失敗。
  6. 首頁 stack 有 `.id(selectedSite.id)`（558）。全站台搜尋的 sheet 若掛在這個 stack 裡，自動換站（312→334、378）會把 sheet 拆掉。
  7. 簡繁轉換：Android 用 catvod `Trans.java` 的逐字對照表（2,528 組字對），只在繁體模式啟用（語言設定為繁體；未設定時依 region 是否為 `TW`，`Trans.java:17、34-36`、`Setting.java:387-389`），**單站搜尋也會轉**（`SiteViewModel.java:136-141`）。iOS 目前完全沒有繁轉簡；`swift test` 在 macOS 上執行，驗不出 iOS 能不能用 ICU 的 `Hant-Hans`。
  8. 專案檔：App target 用明確的 file reference（`project.pbxproj`，沒有 `PBXFileSystemSynchronizedRootGroup`），在 `ios/WebHTVApp/Sources/` 新增檔案必須改 pbxproj；WebHTVCore 是 SwiftPM target，新檔自動編入。
  9. 可沿用的既有寫法：`MediaSniffer.swift:238-278` 的 continuation 加 `timeoutTask`；正式程式碼沒有併發上限或逾時 helper。
- **使用者設定檔**（2026-09-25 重新下載）：126,181 bytes，SHA-256 `efd3ef720599ebcb19024e112f1c4ff64006d79d150b624d15d69bfd6ad32c7f`，與文件記錄的 `b17576e3…` 不同（上游已改，169 站）。`searchable`：1 有 149、缺 17、0 有 2、2 有 1；依 Android 規則，iOS 可用的約 111 站中約 110 站可搜尋（兩個 `searchable:0` 都屬於未移植的 csp 類別）。重複 key：`爱影`、`Bidys`（ext 不同，id 不撞）、`AppV6Dxs`（id 相同，未移植、不會列出）、`星芽短剧`（id 相同，見第 2 點）。
- **既有問題，只回報、不在本任務修**：`SpiderSessionStore` 可重入（同站同時第一次呼叫會建出兩個 session，`SourceClient.swift:231-233`）；`SpiderSession.start()` 先設 `started = true` 才等 init，並行的第二個呼叫不會等 init、init 失敗也不重試（`SpiderSession.swift:19-23`）；`Site.id` 碰撞（上方第 2 點）也讓首頁 `List(sites)` 出現重複 id（`WebHTVApp.swift:495`）。建議另開任務處理。

### 修正後的設計（與上方「C 的核心設計」「UI 行為」衝突時以本節為準）

1. **站台清單**：目前資訊源中 `(searchable ?? 1) == 1` 的站台；`Site.id` 重複時只搜第一個（與 spider session 的鍵一致，避免同一個 session 跑兩次）。
2. **Python 呼叫移出共用執行緒**（Q7，建議採用）：`PythonSpiderRuntime` 改成和 JS runtime 相同的做法，每個實例一條 serial `DispatchQueue`，呼叫以 continuation 橋接回 async（取代 `NSLock`，序列化語意不變）。依據：WWDC21 10254、WWDC22 110350。這樣 Python 不再需要單獨限 1 條，不同站台可以重疊等網路；首頁瀏覽、詳情與播放的 Python 呼叫也一併不再佔住共用執行緒。只改這一個檔案，runtime 初始化維持現狀（殘留風險見下）。
   - 若不採用：維持原計畫，Python 另限 1 條；42 個 Python 站會一個接一個跑，整體時間主要由 Python 決定。
3. **併發上限**：每次搜尋同時進行的呼叫最多 6 個（Mihon 5、Aidoku 3、FongMi 20；6 也是 URLSession 每個 host 的預設連線上限）。一個站台若還有上一次搜尋留下、仍在執行的呼叫（JS／Python 無法中止），這次**跳過**並標示「上一輪仍在執行」，不佔這次的名額；JS 與 Python 的 serial queue 本來就保證同一站台同時只有一個呼叫在跑。
4. **期限**：每站 30 秒，從該站呼叫**開始時**算，不含排隊時間。到期時 CMS 站台取消 Task（真正中止請求）；JS／Python 只在畫面標示「逾時」，名額等底層呼叫真正結束才歸還，所以阻塞中的 GCD 執行緒不會超過上限加上先前搜尋殘留的呼叫數（每個站台最多一個）。
5. **只完成一次**：每站用一把鎖（`OSAllocatedUnfairLock`，iOS 16+；專案最低 iOS 17）決定「結果先到」或「期限先到」，出鎖之後才 resume continuation，結果先到時取消計時用的 `Task.sleep`。依據：`withTaskCancellationHandler` 文件、WWDC22 110350。
6. **串流**：每次搜尋一個 `AsyncStream`，只有一個消費者；`onTermination` 取消這次搜尋的所有站台 Task 與計時器；全部站台回報後呼叫 `finish()`。結果以站台在清單中的位置識別（不用 `Site.id`，見上方第 2 點），UI 在 MainActor 套用前再比對一次代數。
7. **繁轉簡**：移植 Android `Trans.java` 的 2,528 組逐字對照表到 WebHTVCore，不用 ICU `Hant-Hans`。理由：與 Android 對同一個關鍵字的轉換結果完全相同，可以在任何平台以單元測試驗證，不依賴 iOS 實際出貨的 ICU 資料（本環境也沒有模擬器可做 runtime 檢查）。iOS 介面固定是繁體，相當於 Android 的繁體模式，所以全站台搜尋一律轉換；簡體輸入不受影響。
8. **結果型別**：Core 新增公開的結果型別（站台、在清單中的位置、`Vod`），不改 App 的 `private VodRequest`，也不改 WebHome 的識別方式。
9. **UI 補充**：sheet 掛在首頁 `.id(selectedSite.id)` 範圍之外；進度顯示「完成數／總數」，站台狀態分成有結果、無結果、失敗、逾時、上一輪仍在執行；只在送出時搜尋，不邊打字邊搜（每次重新搜尋都可能留下無法中止的呼叫）。
10. **殘留風險**：JS／Python runtime 的初始化仍在共用執行緒上同步執行，第一次搜尋時最多 6 個站台同時初始化，可能短暫占滿共用執行緒；若真機出現卡頓，再把初始化也移到各自的 queue（屬 runtime 工作）。一次 JS 搜尋可能發多次各最長 65 秒的請求，Python 腳本直接呼叫 `requests.get` 且不帶 timeout 時沒有上限（`ios/WebHTVApp/Python/base/spider.py:152、162` 的 `fetch／post` 預設 5 秒），這些站台會一直標示「逾時」直到底層結束。

### 方案比較（更新）

| 方案 | 評估 |
|---|---|
| A 不改 | 問題照舊 |
| B 照抄 Android（20 路同時、逐字對照表、每站 30 秒） | 不採用。iOS 上 Python 在共用執行緒上同步執行、JS 以 semaphore 阻塞 GCD 執行緒，20 路會耗盡共用執行緒或造成 GCD 執行緒暴增（WWDC21 10254） |
| **C′ 窄版改寫加上本次修正（建議）** | 只搜目前資訊源；上限 6、跳過仍在執行的站台；每站 30 秒從開始算；可取消並丟掉過期結果；Python 移出共用執行緒；Android 字表繁轉簡；獨立畫面 |
| C 原計畫（Python 限 1 條、ICU 轉換） | Q7 不採用時的退路；Python 一個接一個跑，整體較慢；ICU 轉換在本環境無法驗證 |
| D 跨所有資訊源 | 延後到 IOS-POC-20B（理由同上方原表） |
| E 把首頁現有搜尋框改成多站台 | 不採用（理由同上方原表） |

### 驗收標準（更新，取代上方同名一節）

1. 輸入繁體關鍵字：多個站台回結果，每筆標站台名；進度跑到「總數／總數」後結束。
2. `searchable` 為 0 或 2 的站台不會被呼叫；沒有這個欄位的站台會被呼叫。
3. 每次搜尋同時進行的呼叫不超過 6 個；還在執行上一輪呼叫的站台被跳過並標示。
4. 慢的站台在它開始後 30 秒標示逾時，其他站台的結果不等它；CMS 站台到期時請求被取消。
5. 換關鍵字後，舊的結果不再出現；關掉畫面或換關鍵字後，舊的搜尋不再啟動新站台。
6. 點結果：進到該站台的詳情頁，可以播放，觀看記錄出現在「記錄」頁；回到首頁時站台沒變；首頁自動換站不會關掉搜尋畫面。
7. `爱影` 兩個站台的結果各自分開；`Site.id` 重複的 `星芽短剧` 只搜一次。
8. 「慶餘年」送出去是「庆余年」，與 Android `Trans.t2s` 對同一輸入的結果相同。
9. 首頁原本的單站搜尋行為不變。
10. 搜尋期間首頁可以捲動、操作，沒有明顯卡頓。
11. （Q7 採用時）Python 站台的首頁瀏覽、詳情、播放與搜尋結果和修改前相同。

### 驗證方式（更新，取代上方同名一節）

- **環境限制**：本工作階段在 Linux 雲端容器，沒有 Xcode、Swift 與模擬器；使用者 2026-09-25 決定「每次發布前先問我」「不新增 push 觸發的測試 CI」。上方原計畫的本機 `swift test`、模擬器情境與本機 device build 都無法執行。
- **可做到的驗證**：
  1. 靜態複查：逐段對照呼叫端、型別與 Swift 6 並行檢查規則（沒有編譯器）。
  2. 編譯：只有在你核准發布時，由 `ios-sidestore-release.yml` 的 Release device build 編譯 App 與 WebHTVCore；編譯失敗會停在 build 步驟，不會發布。同一版號因編譯失敗修正後重跑，算在同一次核准內。
  3. 單元測試：`AggregateSearchTests`（以假閉包驗第 2、3、4、5 條與繁轉簡、`searchable` 解碼）照樣寫進 repo，但**是否執行取決於 Q6**。
  4. 真機：你用 SideStore 安裝後依驗收標準操作；搜尋會以 `os.Logger` 記錄 `[search]` 的同時進行數、逾時與跳過，需要時可用 Mac 的 Console 讀取。
- **對應**：第 1、6、7、8、9、10、11 條靠真機；第 2、3、4、5 條原本靠單元測試，若 Q6 選 C，只能從真機的 log 間接觀察，無法證明上限在所有時序下都成立。

### 預估（更新，本 agent 的執行時間）

| 階段 | 時間 |
|---|---|
| 核心：站台清單、上限、期限、串流、`searchable`、Android 字表、測試 | 50 分 |
| Python runtime 改用 serial queue（Q7） | 15 分 |
| UI：sheet、chip、進度、各種狀態、接 VodView | 60 分 |
| 靜態複查整份 diff | 15 分 |
| 文件、commit、push | 10 分 |
| 發布（經你核准）：準備 5 分，CI 約 4 分；編譯失敗時每次修正加重跑約 10 分 | 10～30 分 |
| **合計** | **約 2.5～3 小時**（不含等你核准與真機回報） |

### 待你決定（更新，取代上方同名一節）

- **Q1**：只搜目前資訊源的所有站台（**預設**），跨資訊源另開 IOS-POC-20B。
- **Q2**：全站台搜尋一律以 Android 字表繁轉簡（**預設**）。Android 的單站搜尋也會轉；iOS 首頁單站搜尋要不要一起轉？**預設：不動**，因為會改變現有行為，需要你另外同意。
- **Q3**：WebHome 的 `app.search` 要不要改開全站台搜尋？**預設改為：v1 不改**。理由：iOS 的 WebHome 只能從「設定 › 開發者」進入，改它會多動一條路徑，收益很小。
- **Q4**：v1 每個站台只取第一頁結果（**預設**：可以；與 FongMi、Mihon 相同）。
- **Q5**：搜尋歷史、熱門詞、站台健康排序、每個站台的可搜尋開關都不做（**預設**）。
- **Q6（新）**：單元測試怎麼執行？
  - A（**建議**）：在既有 `ios-sidestore-release.yml` 的 build 前加一步 `swift test`。不新增 workflow，只在你核准發布時執行，失敗就不發布。第一次執行可能暴露與你 Mac 不同的環境差異（例如需要網路的測試），屆時個別處理，不跳過測試。
  - B：你在自己的 Mac 上跑一次 `swift test` 回報結果。
  - C：不跑，接受第 2、3、4、5 條只做真機間接觀察。
- **Q7（新）**：`PythonSpiderRuntime` 改用 serial queue，讓 Python 不再佔住共用執行緒（**建議採用**）。會多改一個 App 檔，影響所有 Python 站台的呼叫路徑（結果不變，只換執行的執行緒）；不採用則 Python 限 1 條。

## 實作紀錄（2026-09-25）

### 使用者的選擇

- Q1 只搜目前資訊源；Q2 **全站台與單站搜尋都轉**（首頁單站搜尋的行為因此改變，使用者同意）；Q3 **WebHome 的 `app.search` 改開全站台搜尋**；
  Q4 **站台可載入更多**；Q5 附加功能都不做；Q6 **不跑單元測試**；Q7 Python 移到專用 queue；隨後核准開始實作。
- 入口：使用者選擇**底部新增「搜尋」分頁**（首頁、搜尋、記錄、設定），取代原計畫的首頁右上角按鈕與 sheet；WebHome 的 `app.search` 仍以 sheet 開啟同一個畫面。

### 實作內容

- `ios/Sources/WebHTVCore/AggregateSearch.swift`（新檔）：
  - `sites(from:)`：`isSearchable` 且 `Site.id` 第一次出現的站台，保持設定檔順序。
  - `run(_:keyword:)`：回傳 `AsyncStream<Report>`，每站一筆 `found`／`failed`／`timedOut`／`busy`。同時最多 6 個呼叫；呼叫的名額在底層工作真正結束時才歸還；上一輪仍在執行的站台回報 `busy` 且不佔名額（全 App 共用一份記錄）；每站 30 秒從呼叫開始算，到期時取消 Task（CMS 會真正中止，spider 繼續跑）。
  - 期限與取消的競賽用一把 `NSLock` 保證 continuation 只 resume 一次，且在鎖外 resume；不用 TaskGroup 等待不可取消的工作。
  - `page(_:of:keyword:)`：單一站台的下一頁，不受上限與跳過影響。
  - 以 `Logger`（subsystem `com.webhtv.ios.poc`、category `search`）記錄 `[search]` 的詢問、同時進行數、回應時間、逾時與跳過。
- `ios/Sources/WebHTVCore/TraditionalSimplified.swift`（新檔）：Android `Trans.java`（`cf2d9c7f875bbdcc752a2b34ee0fe9ea422f0914`）的 2,528 組字對，逐字複製。
- `ios/Sources/WebHTVCore/WebHTVConfig.swift`：`Site.searchable`（接受數字或字串）與 `isSearchable`（`(searchable ?? 1) == 1`）。
- `ios/WebHTVApp/Sources/PythonSpiderRuntime.swift`：以每個實例一條 serial `DispatchQueue` 取代 `NSLock`，所有方法改為在 queue 上執行並以 continuation 回到 async；`destroy()` 排在執行中的呼叫之後，呼叫者不等待（與原本立即返回相同）。runtime 載入腳本的初始化維持在呼叫者的執行緒。
- `ios/WebHTVApp/Sources/WebHTVApp.swift`：
  - `AggregateSearchView`：自己的 NavigationStack 與常駐搜尋欄；只在送出時搜尋；進度「已完成 x／總數」、停止按鈕，以及失敗、逾時、上一輪仍在執行的計數；「全部」與各站台 chip（依回應順序）；只有選了站台 chip 才載入下一頁；每筆結果標站台名，點進 `VodView`。
  - 底部分頁 tag 3（不改既有 tag 0/1/2）。
  - 資訊源改變時清空結果並作廢進行中的請求。
  - 以 sheet 開啟時，關閉就停止搜尋；分頁切走時繼續搜尋。
  - CMSView 單站搜尋的第一頁與載入更多都先繁轉簡。
  - WebHome 的 `app.search` 改開這個畫面。
- `ios/Tests/WebHTVCoreTests/AggregateSearchTests.swift`（新檔）：8 個測試，涵蓋 `searchable` 規則、站台去重、繁轉簡、送出簡體關鍵字、上限、慢站不拖累其他站、跳過忙碌站台與失敗回報。**依 Q6 未執行。**

### 與 Android 字表的刻意差異

- `Trans.java` 有 10 個繁體字各出現兩次（這張表同時用於簡轉繁），`HashMap.put` 保留後者，所以 Android 實際送出：餘→馀、強→犟、線→缐、滾→磙、濫→漤、墊→埝、壟→垅、鯰→鲶、諮→谘、謔→谑。
  例如「慶餘年」會變成「庆馀年」，站台多半搜不到。
- iOS 改為**前者優先**，另把「謔」手動指定為「谑」。結果：餘→余、強→强、線→线、滾→滚、濫→滥、墊→垫、壟→垄、鯰→鲇、諮→咨、謔→谑。
  其餘 2,508 個字與 Android 完全相同。
- 上方驗收標準第 8 條的「與 Android `Trans.t2s` 對同一輸入的結果相同」因此改為：除上述 10 個字外相同，「慶餘年」送出「庆余年」。

### 驗證

- **本環境沒有 Swift 編譯器**（Linux 容器，apt 也沒有 Swift 工具鏈），所以**沒有編譯**，也沒有執行任何測試。
- 字表：以腳本確認 Swift 檔內兩個字串與 `Trans.java` 逐字相同（各 2,528 字、全在 BMP、無跳脫字元），並以同一規則模擬轉換，測試檔裡的 6 組期望值全部相符。
- 靜態複查：逐段對照 Swift 6 並行規則，包括 Sendable、actor 隔離、continuation 只 resume 一次、`NSLock.withLock` 在同步函式內、struct 的隱式 self，以及 `try` 不放在 `await` 右側。已修正 3 處疑慮：預設參數改用完整型別名、log 的可變計數先複製成常數、測試中的 `try` 移出 `await` 運算式。
- 未驗證：編譯（要等使用者核准發布後由 CI 的 Release device build 執行）、所有執行期行為、真機。
- Ponytail：unavailable / skipped。

### 發布（2026-09-25）

- 使用者核准後以 `0.1.17 (18)` 發布：版號 commit `b3c19fd4`，`workflow_dispatch` run `36034238374` success（17:25:50Z → 17:29:43Z），tag `ios-v0.1.17-b18`，`source.json` `0dff1af1`，IPA 25,017,556 bytes，SHA-256 `e9e5b5ddce9e8e219ad7493ba5c148f5e0a8e43882f7247f5a82f33feb2ce3f5`（與 asset digest 相同）。紀錄見 `docs/IOS-POC-11-sidestore-release.md` 第十八次發布。
- 這次 Release device build 是本任務的**第一次編譯**，一次通過，所以 App 與 WebHTVCore 的程式碼可以編譯；`AggregateSearchTests` 不在這個 target 裡，仍然沒有編譯或執行過。

### 風險與回滾

- 編譯風險已解除（見上方「發布」）；測試檔若日後在 Mac 上執行，仍可能需要修正。
- 殘留：runtime 初始化仍在共用執行緒上；一次 JS 搜尋可能發多次各最長 65 秒的請求；Python 腳本不帶 timeout 的請求沒有上限。以上都會讓站台一直標示「逾時」，直到底層結束。
- 回滾：revert 本任務的單一 commit。不寫入任何持久資料；`searchable` 是 Optional，舊快取照樣能解。

## 修正紀錄：送出搜尋就閃退（2026-09-25）

- 使用者回報（`0.1.17 (18)`，真機）：「輸入關鍵字、按鍵盤上的『搜尋』後」App 閃退。
- 根因（程式碼與設定檔推定，沒有 crash log）：
  - `PythonBoot.start()` 沒有任何同步，只靠「只在啟動時、沒有並行」的假設（`ios/WebHTVApp/Sources/PythonBoot.swift`）。
  - Debug 版在啟動時就啟動 Python（`WebHTVApp.swift` 的 `#if DEBUG` 區塊），**Release 版不會**；Release 版要等第一個 Python spider 建立時，才由 `PythonSpiderRuntime.init → PythonBoot.ensureStarted()` 啟動。
  - 首頁一次只建立一個 spider，所以這個競態從未出現；全站台搜尋同時啟動 6 個站台，依使用者目前設定檔的順序，前 6 個裡有 4 個是 Python 站台（第 1、4、5、6 個）。
  - 結果是多條執行緒同時進入 `boot()`，重複 `setenv` 與 `Py_Initialize()`，App 在送出搜尋的當下終止。模擬器與本機測試跑的都是 Debug 版，所以測不到。
- 修正：`PythonBoot` 加一把 `NSLock`，`start()` 在鎖內檢查並執行唯一一次 `boot()`，同時到達的呼叫者等第一次啟動完成；`status` 只在鎖內讀寫。沒有改變 Debug 版的啟動時機，也沒有改 Release 版延後啟動的設計。
- 驗證：靜態確認 `status` 沒有其他讀取者、`boot()` 內不會再呼叫 `start()`（不會自我鎖死）；專案沒有把 warning 當 error。**沒有編譯**（本環境沒有 Swift 工具鏈），編譯與實際效果要等下一次經核准的發布與真機驗證。
- 發布：以 `0.1.18 (19)` 發布（版號 `ccfad785`，run `36036441567` success，tag `ios-v0.1.18-b19`，`source.json` `86eab8bb`，IPA SHA-256 `8b5e203e…` 與 asset digest 相同）；修正由這次 Release device build 編譯成功。
- 真機驗證（2026-09-25）：使用者以 `0.1.18 (19)` 回報「可以搜尋了，沒有閃退」，修正成立；驗收標準第 1 條的基本行為（送出後有站台回結果）確認，第 2～11 條尚未回報。
- 殘留風險（真機回報前的紀錄，保留）：若閃退的原因不只這一個，下一版仍可能閃退；屆時請使用者提供 iPhone 的 crash 報告（設定 › 隱私權與安全性 › 分析與改進項目 › 分析資料，檔名以 `WebHTVApp` 開頭）。

## Recovery anchor

- 目前（2026-09-25）：實作 `ee597124` 已以 `0.1.17 (18)` 發布（run `36034238374`），CI 第一次編譯即成功；單元測試未執行；**真機未驗證**。
- 研究產物（不進 repo）：外部來源原文與 clone 在本工作階段 scratchpad 的 `research/`；使用者設定檔的新 SHA-256 為 `efd3ef72…`（見本地程式碼複核）。
- 下一步（唯一）：使用者在 `0.1.18 (19)` 上依「驗收標準（更新）」第 2～11 條實測並回報（站台 chip 與載入更多、點結果播放與觀看記錄、搜尋中操作首頁、單站搜尋繁轉簡、Python 站台首頁瀏覽）；有問題再依回報修正。
