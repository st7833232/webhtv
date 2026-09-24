# IOS-POC-20 — 全站台搜尋

- 狀態：**計畫，待使用者核准**（2026-09-24）；未實作；開工前需先完成 AGENTS §7 設計研究並再經核准。
- 使用者需求（2026-09-24，原文）：「我在切換資訊源的時候需要記錄每個資訊源離開前的站台，以便我回來資訊源我還要重新切換；另外我需要一個全資源搜尋的功能；給我相關計畫」。
- 規劃基準：2026-09-24 15:39 CST，分支 `ios-poc`（規劃時 HEAD `75fc13a5`；之後只多了 17H 解析度修正 `5613517a`，不影響本計畫）。
  證據來自三個唯讀 agent 讀程式碼（iOS 資訊源／站台、iOS 搜尋、Android 參考做法），關鍵行號已人工抽查；**沒有跑 `swift test`、沒有建置、沒有在模擬器或實機試過**。
- 順序：先做 IOS-POC-19，再做 IOS-POC-20（兩者都改 `WebHTVApp.swift`，一個做完再開下一個；各自一次 task guard、一個 commit、`finish --no-tag`）。
  預留：IOS-POC-19B（切回連不上的資訊源時改讀快取）、IOS-POC-20B（跨所有資訊源搜尋）。
- 用語：使用者說的「資訊源」＝ iOS UI 的「設定來源／已存來源」（`ConfigSource`、`SavedSource`）；「站台」＝ UI 的「內容來源」（`Site`）。

**完成條件**：從首頁的搜尋入口輸入關鍵字，同時搜尋目前資訊源所有可搜尋的站台。結果隨到隨顯示，每筆標出來源站台，點進去就是那個站台的詳情頁，可以播放。換關鍵字或關掉畫面會取消舊的搜尋，搜尋期間 App 其他部分照常可用。

**Task guard**：
- 車道：`feature`。
- 範圍：
  - 新檔 `ios/Sources/WebHTVCore/AggregateSearch.swift`
  - `ios/Sources/WebHTVCore/WebHTVConfig.swift`
  - 新檔 `ios/Tests/WebHTVCoreTests/AggregateSearchTests.swift`
  - `ios/WebHTVApp/Sources/WebHTVApp.swift`
  - `docs/IOS-POC-20-aggregate-search.md`
  - `docs/current-task-state.md`
- 新畫面放在 `WebHTVApp.swift` 裡，避免為了新增檔案去改 pbxproj。App target 是否要手動加檔還沒確認。
- **這是新功能，而且涉及併發和效能，所以要先過設計研究關卡**：
  - 要查的：Apple 對 TaskGroup 取消語意、`withTaskCancellationHandler`、`StringTransform` 的官方文件。
  - Android 程式碼已經對照完。
  - 論文和部落格不適用，在任務文件裡寫明原因。
  - 研究完、你核准後才開始寫程式。

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

## Recovery anchor

- 目前：只有計畫，**尚未核准、沒有任何程式修改**。
- 下一步（唯一）：使用者回覆「待你決定」各題（或接受預設）並核准後開始實作。
