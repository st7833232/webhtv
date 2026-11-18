# W-313 iOS 集數更新通知與系列新季通知——評估（只評估、不改碼）

- 工單：herdr W-313（Manager #8787／#8792，brief `.herdr-synapse/webhtv-dev/artifacts/w313-brief.md`）。
- 使用者需求（2026-11-18）：
  1. 對某部劇設定通知後，打開 App 時能在「紀錄」那邊知道有新集數。
  2. 也評估「系列更新」：影集出了新的一季時也能知道。
- 階段：**只做設計研究，不改程式碼**（AGENTS.md §7）。經 Reviewer 審查、使用者選定方案並核准「開始實施」後才實作。
- 分支：`task/W-313`，底版 ios-poc `645c5152`（0.1.104 (105)）。下文 iOS 行號以此為準。
- 研究時間：2026-11-18 10:00–11:00（Asia/Taipei）。網路：手機熱點 172.20.10.7。
- 設定基準：GitHub `st7833232/recha` main `f650d84378821a2d0ff2964a2d9022f48ed798fc`（`git ls-remote`，2026-11-18 10:15）。

## Recovery anchor

- 目標：評估「追更（集數更新）」與「系列新季」兩個功能在 iOS 上怎麼做、做到什麼程度可靠，並提出方案、驗收、回退、預估。
- 狀態：使用者決定 1a、2b、3b。方案 B（§12，606bdcb1）與方案 C（§13）都已實作、在 Simulator 驗證並送審。
- 新季偵測依賴 W-312 的 Core 系列拆名器；介面已由 claude-dev-2 確認（#8809），見 §6.2。
- 下一步：等 Reviewer 審查 B、C；拆名器提交後把 SHA 告訴 claude-dev-2（W-312 A2 會用）。

## 1. 證據來源

| 類別 | 來源 | 版本／存取 | 支持的結論 | 等級 |
|---|---|---|---|---|
| iOS 現況 | `ios/Sources/WebHTVCore/*`、`ios/WebHTVApp/Sources/WebHTVApp.swift`、`ios/WebHTVApp/Info.plist` | `645c5152`，2026-11-18 讀 | 現有資料模型、插入點（§2） | A（實際程式） |
| 參考實作（本倉 Android） | `app/src/main/java/com/fongmi/android/tv/bean/Keep.java`、`History.java`，全 `app/src/main/java` 搜尋 `WorkManager`／`NotificationCompat` | 本倉 HEAD，2026-11-18 讀 | FongMi 的收藏（`Keep`：key、siteName、vodName、vodPic、createTime、type、cid）**不記集數、沒有追更或新季檢查**；Android 沒有可對齊的行為，這是 iOS 新功能 | A |
| 正式文件 | Apple〈Choosing background strategies for your app〉 https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app | 2026-11-18 讀 | `BGAppRefreshTask`：「系統決定最佳啟動時間」，最多約 30 秒，逾時被系統終止 | A |
| 正式文件 | Apple〈Using background tasks to update your app〉 https://developer.apple.com/documentation/uikit/using-background-tasks-to-update-your-app 、`BGAppRefreshTask`、`BGTaskScheduler` 參考頁 | 2026-11-18 讀 | 需要 `UIBackgroundModes` 加 `fetch`，以及 `Info.plist` 的 `BGTaskSchedulerPermittedIdentifiers`；`earliestBeginDate` 只是「不早於」 | A |
| 正式文件 | Apple〈Scheduling a notification locally from your app〉 https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app | 2026-11-18 讀 | 本機通知由 App 自己排程（`UNUserNotificationCenter.add`），須先向使用者要權限；不經推播伺服器 | A |
| 維護者討論 | Apple Developer Forums thread 783297、738991、793189、780848 | 2026-11-18 嘗試讀原文：頁面由前端腳本產生，`curl` 只拿到外框，**未讀到原文** | 搜尋摘要提到：背景重新整理頻率看使用習慣、不是可靠的喚醒機制；滑掉 App 後 `BGAppRefreshTask` 不再喚醒 | **未讀原文，只當線索**（審查 N-1）。§5 中「不會準時」的結論以 Apple 正式文件的「system decides」為準；「滑掉後不跑」只影響已暫緩的方案 D，D 開工前要實機確認 |
| 側載環境 | SideStore README 原文 https://github.com/SideStore/SideStore/blob/develop/README.md | develop 分支，2026-11-18 讀 | 原文：用個人開發憑證重新簽章，App 有「normal 7-day development period」，SideStore 會在背景定期重新整理 | A（原文）；「推播屬付費權限」仍只有搜尋摘要，不影響方案 B/C |
| 成熟相關專案 | TVBox 各分支、Animeko（open-ani/animeko）發布說明 | 2026-11-18 搜尋 | 查不到 TVBox 系有「追劇更新」；Animeko 的追番進度靠 Bangumi 中央資料庫，不是逐站輪詢。**沒有可直接參考的逐站追更實作**，本設計以本倉現有收藏／完結判斷為基礎 | C |
| 實測（熱點） | 6 個 recha type 1 採集站 `ac=detail` | 2026-11-18 10:20，`.herdr-synapse/webhtv-dev/artifacts/w313/cms-probe.txt` | 單筆詳情 0.47–1.96 秒；`vod_serial` 全空、`vod_isend` 全 0；`vod_remarks` 有「更新全集」卻只有 1 集、綜藝寫「更新至20261117期」 | A（實測） |
| 實測（Simulator 既有紀錄） | 3 台 Simulator 的 `site-health.json`（W-311 等測試留下） | 2026-11-18 讀 | 真實站詳情 `lastDetailMilliseconds` 1032–1742 ms（3 筆，樣本少，只當量級） | B |
| 論文／部落格 | — | — | 本題是 iOS 平台限制＋本 App 資料流的設計，論文不會改變結論；不另查 | — |

## 2. iOS 現況（檔案:符號）

### 2.1 觀看紀錄
- `ios/Sources/WebHTVCore/WatchHistory.swift:9` `struct WatchHistory`：一部作品一筆。欄位有：
  - `key`（`Site.id@@@vodId`）、`sourceID`（設定來源）、`siteKey`、`siteName`、`vodId`、`vodName`、`vodPic`。
  - `vodFlag`（線路）、`vodRemarks`（**最後播的那一集的名稱**，不是作品的更新說明）、`episodeUrl`、`quality`。
  - `position`、`duration`、`opening`、`ending`、`createTime`。
  - **沒有集數清單，也沒有總集數。**
- `WatchHistory.swift:289` `actor WatchHistoryStore`：存 `Application Support/WatchHistory/history.json`，整檔重寫。
  - 保留 60 天（`retention`，`:293`），最多 500 筆（`limit`，`:296`）。
  - `save(_:)`（`:369`）整筆取代：播放器每次存檔都用播放當下的新紀錄覆蓋。
  - 結論：**不能把追更狀態加在這筆紀錄上**，否則播放存檔會蓋掉，而且 60 天後會被刪。
- `ios/WebHTVApp/Sources/WebHTVApp.swift:3959` `HistoryView`（片庫 →「記錄」）：
  - `.task` 每次進頁讀 `records(for: source.identity)`。
  - 列表顯示片名、站名／線路／集名（`:4071–4077`）。
  - 已有 `.badge(...)` 樣式，用在「需要爬蟲工具」（`:4051`）。
  - 沒有下拉重新整理。
- `WebHTVApp.swift:4203` `LibraryView`：片庫分「記錄」「收藏」兩頁，預設開「記錄」。

### 2.2 收藏
- `ios/Sources/WebHTVCore/Favorites/Favorite.swift:15` `FavoriteIdentity { configSourceID, siteID, vodID }`：
  - 跨設定、跨站唯一識別一部作品。
  - 有 `historyKey`，可對到觀看紀錄。
  - **追更可直接沿用這個識別**。
- `Favorite.swift:93` `Favorite`：快照欄位有 name、picture、`remarks`、year、area、typeName 等，另有 `createdAt`、`snapshotUpdatedAt`。
- `Favorites/FavoriteStore.swift:20` `actor FavoriteStore`：
  - 存 `favorites.json`，有 `schemaVersion`，解碼寬容。
  - `refresh(_:with:)`（`:105`）：在詳情頁載入時更新快照。
- `Favorites/FavoriteCompletion.swift:8` `SeriesCompletion`：從 remarks 判斷「完結／更新中／未知」。
  - `episodeNumber(_:)`（`:39`）從集名取集數。
  - 已處理簡繁、全半形；可重用。
- `FavoriteCompletion.swift:66` `FavoriteAutoRemoval`：看完已完結作品的最後一集會自動移出收藏。
  - 追更若綁收藏，完結移出時要一起停止追更（§4.7）。
- `WebHTVApp.swift:4108` `FavoriteLibrary`：
  - `detailLoaded(_:snapshot:lines:)`（`:4159`）：詳情載入時把線路清單放在記憶體（最多 32 部）。
  - 另有 `playerOpen` 旗標（`:4117`）。

### 2.3 詳情頁怎麼拿集數
- `WebHTVApp.swift:3098` `VodView`，`loadDetail()`（`:3157`）流程：
  1. `SourceClient.make(site:resolver:)`。
  2. `client.detail(id:)`。
  3. 記 `SiteHealth`。
  4. 交給 `favoriteLibrary.detailLoaded`。
- `ios/Sources/WebHTVCore/SourceClient.swift:94` `detail(id:)`：
  - CMS（type 0/1/4）走 HTTP。
  - 爬蟲（type 3：Python／JS）走 `SpiderSession.detail`，session 依 `Site.id` 快取。
  - **recha 影視設定 87 站中 66 站是 type 3**，所以多數追更檢查需要爬蟲執行環境。
- `ios/Sources/WebHTVCore/CMSClient.swift:286` `Vod.flags`：線路陣列，每條線路有 `episodes`。
  - `Vod.remarks` 是站台寫的更新說明，例如「更新至12集」。

### 2.4 App 啟動
- `WebHTVApp.swift:385` WindowGroup 的 `.task`，依序做：
  1. 讀爬蟲包。
  2. `restore()` 還原設定與站台。
  3. `WatchHistoryStore.migrateSiteIdentities`。
  4. `refreshRemote(quiet: true)` 重抓遠端設定。
  5. `refreshSpiderPack()`。
- 站台清單 `sites` 是 View 的 `@State`，只在前景 UI 流程裡建立。
- 全 App 沒有使用 `scenePhase`，所以回到前景時不會觸發任何事。
- Python：`ios/WebHTVApp/Sources/PythonBoot.swift:80` `ensureStarted()` 是在第一次用到時才啟動。
- 併發先例：`ios/Sources/WebHTVCore/AggregateSearch.swift:22` 跨站搜尋同時最多 6 站，總期限 30 秒。

### 2.5 背景與通知
- `ios/WebHTVApp/Info.plist`：`UIBackgroundModes` 只有 `audio`。
  - 沒有 `fetch`，也沒有 `BGTaskSchedulerPermittedIdentifiers`。
- 全專案沒有 `BGTaskScheduler`，也沒有 `UNUserNotificationCenter`。
- 唯一的背景執行是離線下載：
  - `beginBackgroundTask`（`WebHTVApp.swift:4808`，`OfflineAppDelegate`）。
  - 背景 `URLSession`（`Offline/OfflineRuntime.swift:125`）。
- 最低版本 iOS 16（`project.pbxproj` `IPHONEOS_DEPLOYMENT_TARGET = 16.0`）。
  - 可以用 SwiftUI `.backgroundTask(.appRefresh(_:))`。
  - App 圖示紅點數字可用 `UNUserNotificationCenter.setBadgeCount`。

## 3. 實測：站台的「集數訊號」可不可靠

6 個採集站各取最新 20 筆（熱點，2026-11-18 10:20）：

| 站 | 首頁詳情 | 單筆詳情 | remarks 分布 | 觀察 |
|---|---|---|---|---|
| 360 | 1439 ms | 798 ms | 更新 18／完結 2 | 「更新至07集」與集數 7 相符 |
| 非凡 | 3629 ms | 470 ms | 更新 19／完結 1 | 「更新至第710集」與 710 相符 |
| 量子 | 3182 ms | 624 ms | 更新 18／完結 2 | 綜藝「更新至20261117期」，實際 149 期：**remarks 是日期，不是集數** |
| 如意 | 1787 ms | 875 ms | 更新 18／完結 2 | 同上，日期型 |
| 優酷 | 2173 ms | 1957 ms | 其他 5／更新 14／完結 1 | 「正片」 |
| 天涯 | 1242 ms | 950 ms | 更新 20 | 「更新全集」卻只有 1 集：**remarks 會說謊** |

所有站的 `vod_serial` 都是空的，`vod_isend` 都是 0。

結論：
- **判斷新集數以「詳情的集數清單」為準**。
- remarks 只拿來顯示，不拿來判斷。
- 每部作品每次檢查成本是一次詳情請求：CMS 約 0.5–2 秒；爬蟲站依 Simulator 紀錄約 1–1.7 秒，但第一次還要加上 Python 啟動與規則下載。

## 4. 集數更新（追更）設計

### 4.1 入口與資料
- 詳情頁右上角收藏旁加「追更」開關（鈴鐺）。
  - 只有多集作品可開：最長線路 ≥ 2 集，且 typeName 不是電影。
  - 另一種做法是「收藏的劇集自動追更」，交使用者決定（§8 決定 1）。
- 「記錄」列表長按選單加「追更／取消追更」，兩個入口寫同一份資料。（實作：使用者選 1a，只做詳情頁鈴鐺；「記錄」的追更區可左滑取消追更，沒有做長按追更。）
- 新檔 `Application Support/follows.json`，由 `actor FollowStore` 管理（新增 `ios/Sources/WebHTVCore/Follows/`），寫法比照 `FavoriteStore`：有 `schemaVersion`、解碼寬容、atomic 寫入。
- 一筆追更 `Follow` 的欄位：
  - `identity: FavoriteIdentity`：重用，不新造識別。
  - `vodName`、`vodPic`、`siteName`：快照；觀看紀錄過期後仍能顯示。
  - （評估稿的 `seenCount` 不實作：決定 2b 改成播放才清除，見 §4.5。）
  - `latestCount`、`latestEpisodeName`。
  - `knownTail: [String]`：最長線路「最新端」往回最多 20 個集名（正規化後），給 §4.2 的第二個訊號用。只存集名不存網址：網址每次抓取可能不同（`WatchHistory.carryingOver` 也是因此用名稱比對）。
  - `unseen: [String]`：已偵測到、還沒播放的新集名稱（舊到新，上限 200），徽章數字就是它的數量。
  - `checkedAt`、`seenAt`、`failures`。
  - `state`：`ok`／`siteMissing`／`notFound`／`failing`。
- 上限 50 部：超過時提示先取消一些，不默默丟掉。
- 不改 `history.json` 和 `favorites.json`，所以舊檔不需要遷移。

### 4.2 比對規則（Core 純函式，可單元測試）
- `count = max(每條線路的 episodes.count)`：
  - 取最長線路，換線路或某條線路落後都不影響。
  - 這和 `FavoriteAutoRemoval` 用最長線路判斷最後一集是同一個理由。
- **最新端在哪一頭**（審查 F-1，倒序清單）：
  - 用 `SeriesCompletion.episodeNumber` 取最長線路第一集與最後一集的編號；第一集編號比最後一集大，就是倒序，最新端在開頭；否則最新端在結尾。
  - 日期型（「20261117期」）的編號就是日期，一樣適用。
  - 兩端都拿不到編號（例如「預告」「正片」「上」「下」），視為正序，這是站台最常見的排法；倒序又沒編號的清單，`latestEpisodeName` 可能顯示錯，列為限制（§11）。
- **兩個訊號**：
  1. 長度：`count > latestCount` 時，新集數 = `count - latestCount`。
  2. 最新端集名（處理長度不變或變短的更新）：從最新端往回走，數到第一個出現在 `knownTail` 裡的集名為止；走過的集名數量就是新集數。
     - 只保留最近 N 期的滾動清單：每天新一期，最新端是沒見過的名字、下一個見過 → `+1`。
     - 正片取代預告：最新端從「預告」變成「第12集」，下一個見過 → `+1`。
     - 兩個訊號取較大的值，這麼多集的名稱（從最新端取）加進 `unseen`。
- **改版保護**：走完整個 `knownTail` 範圍（20 個）都沒碰到見過的集名，表示站台整批改了集名格式或換了片源。**重設基準**（`knownTail` 改成這次的），不加徽章，以免一次跳出「+20」。
  - 實作條件（審查 N-4）：短劇常一次上架 20 集以上。往回走的範圍取 `max(20, count - latestCount)`；長度增量本身就說明新集數，改版保護只在**長度沒有增加**時才生效。單元測試：10 集→40 集要顯示 `+30`。長度變短也一樣只重設基準，不顯示負數。
- 每次檢查後更新 `latestCount`、`latestEpisodeName`（最新端那一集）和 `knownTail`。
- remarks 不參與判斷，只照原樣顯示在列上，例如「更新至12集」。
- 已知漏報（寫進 §11、§8）：站台在最新端以外的位置插入新集（例如中間補上漏掉的一集），長度又同時刪掉一集時，兩個訊號都看不到。這種情況少見，不另外處理。

### 4.3 什麼時候檢查
- **打開 App**：在 `refreshRemote` 完成後，延遲 3 秒再背景執行。
  - 不擋首頁，啟動流程不等它。
- **回到前景**：新增 `scenePhase == .active`，條件是距離上次整批檢查超過 30 分鐘。
- **在「記錄」頁下拉重新整理**：強制檢查。
- **背景重新整理**：屬於方案 D，見 §5。
- 節流：
  - 每部作品 30 分鐘內最多檢查一次（下拉例外）。
  - 同一站一次只跑一部，避免被站台擋。
  - 整批最多 60 秒，超過的留到下一輪。
- **播放中暫停**：`favoriteLibrary.playerOpen` 為真時不開新請求，避免搶頻寬或拖慢播放。
- 檢查結果也記進 `SiteHealthStore`，因為那是真實的詳情請求。

#### 爬蟲站不能中斷：期限只停止等待（審查 F-2）
- 事實（`AggregateSearch.swift:6-17`）：
  - CMS 站是 async `URLSession`，取消 Task 就真的停止。
  - JS 與 Python 爬蟲各自跑在該站的序列佇列上，HTTP host 用號誌擋住執行緒，**每個請求最多 65 秒，沒有東西能中斷**。
- 所以：
  - **CMS 站**：每部 10 秒逾時，逾時就真的取消。
  - **爬蟲站**：10 秒只是「不再等它」，這次記為失敗並把該站本輪剩下的追更跳過；請求本身會一直跑到結束（最多 65 秒），在那之前**使用者對同一站的首頁、詳情、播放都會排在它後面**。「播放中暫停」也只擋新請求，擋不住已經在跑的。
- 避免卡到使用者的規則（全部在發出爬蟲請求「之前」判斷，因為發出去就收不回）：
  1. **全域一次只跑一個爬蟲請求**；CMS 站可另外同時跑 2 個。
  2. **忙碌就略過，不排隊**：該站有任何進行中的呼叫（使用者的、搜尋的、或上一個檢查）就跳過，留到下一輪。比照 `AggregateSearch` 的 `.busy`，但要把「進行中的呼叫」記錄提升成全 App 共用（例如 `SpiderSessionStore` 依 `Site.id` 計數，所有爬蟲呼叫都經過它），讓使用者自己的操作也算進去。
  3. **使用者最近碰過的站不檢查**：使用者正在看的站，或 2 分鐘內碰過首頁、分類、詳情、播放的站，本輪跳過。
  4. **使用者正在看「記錄」頁或詳情頁時不發新的爬蟲檢查**：這時候點列表最可能點到追更作品的站。CMS 站不受限，因為可以取消。
  5. **慢站先排除**：`SiteHealth` 顯示該站最近詳情失敗、或上次詳情超過 5 秒，本輪不檢查。
  6. **下拉重新整理**：仍遵守 1、2；3、4、5 不適用，因為是使用者自己要求的。（實作時依 Ponytail 審查改掉 5：慢站的判斷依據只有詳情請求會更新，下拉若也排除，慢過一次的站就永遠不會再被檢查。）
- 剩餘風險（直說）：
  - 檢查剛發出時，使用者正好點進同一站，最多等這一個請求結束。一般 1–2 秒（§3），站台當掉時最壞 65 秒。
  - 規則 1–5 只能降低機率，不能保證不撞。
- **不採用「追更用獨立 session」**：
  - 等於同一站多一個 JS context 或 Python 模組實例，要重跑 `init`（規則檔下載、模組匯入），記憶體和網路成本加倍。
  - Python 的 GIL 仍然共用，還是會互相拖慢。
  - 換來的只是避開上面那個小機率的等待，不划算。

### 4.4 紀錄頁顯示
- 「記錄」最上面加一區「追更」，列出所有追更作品：
  - 有新集的排在最前，標 `+N 集`（沿用 `.badge`）。
  - 其餘依 `seenAt` 排序。
  - 原本的觀看紀錄列表照舊在下方。
- 追更作品的觀看紀錄過了 60 天被刪掉，仍會靠 `Follow` 的快照顯示。
- 片庫分頁標籤顯示有更新的部數（`:325` 的 `.tabItem` 加 `.badge(n)`）。
- 「記錄」裡同一作品的觀看紀錄列也加 `+N 集`。
- 點一下打開詳情頁（和現在一樣）。

### 4.5 看過後怎麼清除（使用者決定 2b：播放到最新一集才清除）
- 徽章數字就是 `unseen`：偵測到、還沒播放的新集名稱，舊到新排列。
- **播放才算看過**：播放器存觀看紀錄時（`PlaybackSession.persist`，每次存檔都會呼叫 `FollowCenter.played`），只有該筆紀錄的 `key` 與設定來源和追更那筆**完全相同**才算（審查 N-2）。同一部片從別站或別的設定來源播放，不算。
- **部分觀看的顯示規則**：
  - 播放的那一集如果在 `unseen` 裡，它和比它舊的新集一起清掉，比它新的留著。例：新集是第 11、12、13 集（+3），播第 11 集 → +2，播第 13 集 → 0。
  - 播放的是站台目前最新的一集（`latestEpisodeName`），全部清掉。
  - 播舊集（例如回頭看第 3 集）不影響徽章。
  - 「開始播放」就算，不用看完：只要播放器存過一次進度（`WatchHistory.canSave`，位置大於 0）。
- **打開詳情頁不清除**：詳情載入只當成一次檢查，更新 `latestCount`、`knownTail`；若看到更新的集數，還會再加到徽章。
- 舊欄位 `seenCount`、`pending` 不再需要：徽章直接是 `unseen.count`，實作沒有這兩個欄位。

### 4.6 異常情況
| 情況 | 處理 |
|---|---|
| 站慢／逾時／一次失敗 | 保留上次狀態，`failures += 1`，不顯示錯誤 |
| 連續 3 次失敗 | 列上灰字「最近檢查失敗」，下拉時再試；成功一次就歸零 |
| 換線路 | 不影響：取最長線路 |
| 站台不在目前設定（改名、移除、換設定來源） | 只檢查 `identity.configSourceID == 目前來源`、且站台在 `sites` 裡的；其他列灰字「站台不在目前設定」，**不刪資料**，比照收藏 `FavoriteAvailability` |
| 站台還在等爬蟲工具 | 跳過，比照 `waiting` |
| `vod_id` 變動或作品下架（詳情回 nil） | `state = notFound`，灰字「站台找不到這部作品」（方案 B 沒有做「用片名搜尋」按鈕，使用者可自行到搜尋頁找）。**不自動改綁**：同名不同作品太常見 |
| 站台身分遷移（ext 鍵序變動） | 重用 `SiteSelection.resolveIdentity`，與收藏的 `migrateSiteIdentities` 相同 |
| 多倉／換設定 | 追更跟著 `configSourceID` 走，只在該設定載入時檢查 |

### 4.7 與現有功能的關係
- 收藏的完結自動移除（`FavoriteAutoRemoval`）不受影響。
  - 若選「收藏即追更」，移除收藏時追更一起移除。
  - 若選獨立開關，追更看到 remarks 說已完結，而且使用者看完最後一集時，提示是否取消追更，不自動刪。
- 觀看紀錄、收藏、下載三個 store 都不改格式。
- 啟動時間：檢查是在啟動完成後延遲執行的背景工作，驗收時要量啟動 log「site list ready」前後差不超過量測誤差（§7）。

## 5. iOS 背景與通知限制（結論）

| 項目 | 結論 | 依據 |
|---|---|---|
| 本機通知權限 | 可用，不需要特殊權限，但要向使用者要通知權限；推播（APNs）需要付費帳號權限加伺服器，**本專案不用** | Apple 本機通知文件；SideStore 免費簽章 |
| 背景重新整理在 SideStore 上 | `fetch` 背景模式與 `BGTaskSchedulerPermittedIdentifiers` 是 Info.plist 設定，不是付費權限，側載後**理論上可用**；**未在實機驗證**，要使用者裝 IPA 實測 | Apple 文件；本專案已用 `audio` 背景模式，側載後正常 |
| 會不會準時跑 | **不會**。系統依使用習慣決定，可能一天幾次，也可能完全不跑。低電量模式、「背景 App 重新整理」關閉、被使用者從多工畫面滑掉，都不會跑 | Apple 文件「system decides」；DTS 論壇回覆 |
| 可用時間 | 每次約 30 秒，用完被終止 | Apple 文件 |
| 背景時爬蟲能不能跑 | CMS（URLSession）可以；JS 爬蟲（JavaScriptCore，程序內）可以；Python 是程序內 CPython，背景冷啟動要 `Py_Initialize` 加規則下載，**30 秒內只夠檢查少數幾部**，啟動耗時未量 | 程式結構；未實測 |
| 背景啟動要改的結構 | 站台清單現在只在前景 View 裡建立（`restore()` 寫入 `@State`），背景喚醒時沒有 `sites`。要先把「從磁碟還原設定與站台」抽成 Core 可呼叫的函式，屬中等重構 | §2.4 |
| 7 天簽章 | SideStore 憑證過期時 App 整個不能開，背景也不會跑 | SideStore 說明 |

**結論**：
- 背景重新整理加本機通知可以做成「有跑到就通知」的加分功能，但**不能當成主要機制**，也不能承諾準時。
- 主要機制應是「打開 App／回到前景／下拉」時檢查，並在紀錄頁顯示。
- 這也正好符合使用者原話「打開 App 時，在紀錄那邊能知道」。

## 6. 系列新季偵測

### 6.1 做法
1. 對每部追更作品，用 W-312 的 Core 拆名器拆片名，得到基名鍵 `key`、可搜尋的基名 `searchBase`、季數 `season`（沒寫季數視為第 1 季）、種類 `kind`。
2. 只有 `kind == 正季` 才做新季檢查。特別篇、劇場版、外傳都不做。
3. **只搜尋原作品所在的那一站**：一次 `search(searchBase)`。
   - 解析每筆結果，條件是 `key` 完全相同、`kind == 正季`、`season > 目前季數`。
   - 若片名或 remarks 拆得出年份，還要求不早於原作品年份，以排除同名重拍。
   - 命中就標「可能有新季：第 N 季」，點了打開那筆詳情。
4. 頻率：每部每天最多一次（新季很少，而且搜尋比詳情貴），整批與追更檢查共用 60 秒預算和併發上限。
5. 跨站找新季**不自動做**：一次跨站搜尋要等全部站，同時 6 站、最多 30 秒（`AggregateSearch`），50 部作品就是 50 次全站搜尋，太重，也容易被站擋。
   - 改成詳情頁加按鈕「找其他季」，使用者點了才跑一次跨站搜尋，結果用 W-312 的系列歸組顯示。

### 6.2 拆名器介面（claude-dev-2 已確認，看板 #8809；以 W-312 為準）
- 入口：`SeriesTitle(title)` 建構子（不另設 `SeriesName.parse`）。
- W-313 用到的欄位：
  - `baseKey`：跨站比對用的正規化基名。
  - `baseDisplay`：原文基名，拿去 `searchContent` 當關鍵字。
  - `season: Int?`：nil 表示沒標記，當第 1 季。
  - `special: Special?`：nil 表示正季；`.movie` 劇場版／電影版、`.special` 特別篇／SP／OVA／總集篇、`.extra` 番外。
  - `strength`：strong／weak／none。
- 新季判斷直接用 `SeriesGrouping.isNewerSeason`（W-312 83c3730e §4.1／§4.5 定案）：只認 `candidate.strength == .strong`、`special == nil`、`season > (watched.season ?? 1)`；weak 與沒標記一律不算，weak 只用在搜尋歸組排序。§6.1 的「`key` 相同、`kind == 正季`、`season` 更大」就是這個函式的條件，W-313 不自己重寫。
- 季數寫法規則見 `docs/W-312-ios-search-improvements.md` §4（W-312 完稿後回填段落位置）。

### 6.3 可靠度（直說）
| 風險 | 例子 | 程度 | 對策 |
|---|---|---|---|
| 漏報（看不到新季） | 新季只在別站有；站台把第二季命名成新片名（「XXX 歸來」）；第 1 季寫「XXX 第一季」但第 2 季沒標季數 | **高**，同站搜尋只能找到同站有的 | 用語寫「可能有新季」，不承諾；提供「找其他季」手動跨站 |
| 誤報 | 同名不同作品（重拍版）；「XXX 2」是電影續集而非第二季；基名太短（兩字片名命中一堆） | 中 | `key` 完全相等、`kind` 必須是正季、年份不倒退、基名 < 2 字不檢查；點進去才確認，不自動追更新季 |
| 站台搜尋本身不準 | 有的站搜尋只回前 N 筆、或是模糊比對 | 中 | 只當提示 |
| 成本 | 每部每天一次搜尋，CMS 約 1–3 秒 | 低（有節流） | 每日一次、共用預算 |

**判斷**：同站新季提示可做，但只是「提示」，漏報率不低。若使用者期待「一定會通知新季」，目前的資料來源（沒有中央片庫 ID，只有各站片名）做不到。

## 7. 方案比較

| | A 不做 | B 前景追更（建議先做） | C = B ＋同站新季提示 | D = C ＋背景重新整理＋本機通知 |
|---|---|---|---|---|
| 使用者看得到 | 無 | 打開 App 或下拉後，紀錄頁出現「+N 集」，片庫標籤有數字 | 加上「可能有新季」與「找其他季」 | 加上 App 沒開時偶爾跳出通知、App 圖示紅點 |
| 可靠度 | — | 高：每次打開都會檢查 | 新季部分中低 | 背景部分低且不可預期 |
| 改動 | 0 | Core：`Follow`、`FollowStore`、比對與檢查器，加測試；App：詳情頁開關、記錄頁區塊與徽章、下拉、前景觸發 | 加上拆名器呼叫、同站搜尋、每日節流、詳情頁按鈕 | 加上 Info.plist 兩個鍵、通知權限 UI、背景任務、把設定還原抽到 Core（中等重構） |
| 風險 | — | 低到中：新檔、新 UI，不動既有三個 store；對站台多一些請求（有節流）；爬蟲請求不能中斷，偶爾讓使用者對同一站的操作多等一個請求（§4.3） | 誤報或漏報，用語要保守 | 背景 Python 冷啟動、30 秒限制、記憶體；重構還原流程可能影響啟動 |
| 依賴 | — | 無 | W-312 拆名器先落地 | 實機 SideStore 安裝驗證（使用者操作） |
| 預估（Claude 實作、本機） | — | 約 7–9 小時：Core 加測試 3–4（含兩個集數訊號、排程規則、共用的進行中呼叫記錄）、UI 2–3、Simulator 驗證 2 | B 之外 +3–4 小時（拆名器已存在時） | C 之外 +6–10 小時，另加使用者實機測試的等待 |

**建議**：
- 先做 **B**。
- W-312 拆名器落地後再做 **C**。
- **D 暫緩**：等 B/C 用一陣子、使用者仍需要「沒開 App 也要被通知」時，再先做一個最小背景任務 PoC，由使用者實機確認在 SideStore 上真的會被喚醒，再決定。

## 8. 需要使用者決定的事（Manager 整理）
1. 追更入口：
   - (a) 詳情頁獨立「追更」開關（建議，對應「對某部劇設定通知」）。
   - (b) 收藏的劇集自動追更（不用多一個按鈕，但收藏多時檢查量大）。
2. 清除時機：
   - (a) 打開詳情頁就清除（建議）。
   - (b) 播放最新一集才清除。
3. 方案：B（建議）／B+C／B+C+D。

**使用者決定（2026-11-18，Manager #8828）**：1a 詳情頁獨立「追更」開關；2b 播放到最新一集才清除（部分觀看規則見 §4.5）；3b 實作方案 B＋C。

另外要讓使用者知道的限制（不需要選）：
- 新集數看「集數清單變長」和「最新一集的名稱變了」兩件事；站台在清單中間補集又同時刪集，這種少見情況會漏報。
- 大部分站是爬蟲站，爬蟲請求一旦發出就停不下來。追更檢查會避開正在用、最近用過、忙碌和慢的站，但若檢查剛發出時正好點進同一站，可能要多等一下：一般 1–2 秒，站台當掉時最久 65 秒。

## 9. 驗收條件（方案 B；C 另列）

**Core 單元測試**
- 集數增加 → `+N`。
- 集數減少 → 重設基準且不顯示徽章。
- 多條線路取最長。
- 綜藝日期型以清單長度判斷。
- 滾動清單（長度固定 20，最新端多一期、最舊端少一期）→ `+1`。
- 預告換正片（長度不變，最新端集名改變）→ `+1`。
- 倒序清單（第一集編號大於最後一集）→ 最新端取開頭，`latestEpisodeName` 正確；兩端都沒編號時視為正序。
- 整批改集名（`knownTail` 全部對不上）→ 重設基準、不加徽章。
- 一次上架大量集數（10 集→40 集）→ `+30`，不被改版保護吃掉（審查 N-4）。
- 清除只在 `FavoriteIdentity` 完全相同時發生；同片別站的詳情不清除。
- 排程規則（純函式）：忙碌的站、2 分鐘內碰過的站、`SiteHealth` 慢或失敗的站、使用者在「記錄」或詳情頁時的爬蟲站，都不會被排入；全域同時最多 1 個爬蟲檢查。
- remarks 說謊（「更新全集」1 集）不影響判斷。
- 連續 3 次失敗才顯示「最近檢查失敗」，成功一次歸零。
- 30 分鐘節流（下拉例外）。
- 只檢查目前設定來源的追更。
- 站台缺席與找不到作品時保留資料。
- `follows.json` 損毀或多出欄位時解碼寬容。
- 舊 `history.json`／`favorites.json` 不變。

**Simulator（本機 HTTPS 假 CMS 站，可在兩次啟動間改集數）**
1. 追更一部 3 集作品，改成 5 集，重開 App，紀錄頁出現「+2 集」並排在最前，片庫標籤顯示 1。
2. 打開詳情，回來徽章消失。
3. 下拉立即重新檢查。
4. 回到前景超過 30 分鐘才檢查（可用除錯開關縮短）。
5. 讓假站逾時，不出錯誤視窗，第 3 次後顯示灰字。
6. 刪掉假站，追更列顯示「站台不在目前設定」，資料還在。
7. 播放中不發檢查請求（看 log）。
8. 爬蟲站卡住（審查 F-2）：用本機假 JS 爬蟲站，其詳情固定延遲 8 秒。
   - 檢查進行中立刻點同一站的詳情：log 證明詳情最多等那一個進行中的請求，而且檢查器沒有再發第二個。
   - 先點進該站詳情，再觸發檢查：log 顯示該站被略過（最近碰過或忙碌），詳情載入時間與沒有追更時相同。
   - 檢查超過 10 秒：畫面不等它，本輪該站剩下的追更被跳過。

**效能**：「site list ready」啟動 log 在有 10 部追更、無追更兩種情況下，差異在量測誤差內。

**熱點實機站**：追更 1 部真實採集站作品、1 部 Python 爬蟲站作品，檢查成功，並記錄耗時。

**C 另加**：拆名器測試由 W-312 負責；W-313 測試同站搜尋命中「第二季」會提示，同名不同作品（年份倒退、基名不同、劇場版）不提示，每日節流生效。

## 10. 遷移與回退
- **遷移**：只新增 `follows.json`，沒有舊資料要轉換。舊版 App 不認得這個檔案，會直接忽略。
- **回退**：
  - revert 該任務 commit 即可。
  - `follows.json` 留在手機上沒有副作用，也可以在下一版加一行刪檔。
  - 三個既有 store 不動，回退不會丟失觀看紀錄或收藏。
- **D 的回退**：拿掉 Info.plist 兩個鍵與任務註冊；已排程的本機通知要在下一版啟動時 `removeAllPendingNotificationRequests()`。

## 11. 未驗證與限制
- 新集數偵測的已知漏報：站台在最新端以外插入新集、同時又刪掉一集時看不到；倒序且兩端都沒有集數編號的清單，最新一集的名稱可能顯示錯（§4.2）。
- 爬蟲請求不能中斷：檢查剛發出時使用者正好點同一站，最多要等這一個請求結束（一般 1–2 秒，最壞 65 秒）。§4.3 的規則只降低機率（審查 F-2）。
- 未在實機確認 SideStore 側載後 `BGAppRefreshTask` 會被喚醒，只有文件推論。
- Python 爬蟲在背景冷啟動的耗時未量。
- 爬蟲站詳情耗時只有 Simulator 的 3 筆既有紀錄，樣本少。
- §6.2 拆名器介面已確認命名（#8809）；季數規則段落位置等 W-312 完稿回填。
- 「成熟相關專案」查不到逐站追更的同類實作。本設計的比對規則來自本倉既有的完結判斷（`FavoriteAutoRemoval`）與 §3 實測，不是外部最佳實務。
- Ponytail：評估階段只有文件、不適用；方案 B 實作的 Ponytail 結果見 §12.4。

## 12. 方案 B 實作紀錄（2026-11-18）

### 12.1 改了什麼
- Core 新增 `ios/Sources/WebHTVCore/Follows/`：
  - `Follow.swift`：`Follow` 資料、`EpisodeListing`（取最長線路、判斷最新端），以及 §4.2 兩個訊號加改版保護、§4.5 播放清除。
  - `FollowStore.swift`：`follows.json`，看不懂的條目原樣保留，上限 50 部。
  - `FollowCheck.swift`：`SiteActivity`（記錄各站忙碌與使用者最近使用時間）、`FollowSchedule`（`due`／`mayStart` 規則）、`FollowChecker`（CMS 兩條、爬蟲一條，爬蟲逾時只停止等待並結束該條）。
- `SourceClient.swift`：首頁、分類、搜尋、詳情、播放解析五個呼叫都包進 `SiteActivity.tracking`。追更自己的呼叫用 TaskLocal `SiteActivity.background` 標記，不算使用者使用。
- `WebHTVApp.swift`：
  - `FollowCenter`：啟動完成後 3 秒、回到前景（距上一輪 30 分鐘）、記錄頁下拉時檢查。
  - 詳情頁加鈴鐺 `FollowToggle`；詳情載入也算一次檢查，但不清除。
  - `PlaybackSession.persist` 存檔後呼叫 `FollowCenter.played`。
  - 記錄頁加「追更」區、`+N 集` 徽章、下拉重新整理。
  - 片庫標籤加數字：iOS 16 用 `.badge`，iOS 17 以上用 `CinematicTabBar` 的 `badges`。
- 測試：`ios/Tests/WebHTVCoreTests/Follows/FollowTests.swift` 23 項。

### 12.2 驗證
- `swift test --filter FollowTests`：23/23 通過。全套 `swift test`：1587/1587 通過（`artifacts/w313/core-tests-full.txt`，是 Ponytail 修正前的結果；修正後只重跑 FollowTests）。
- 期間修掉兩個問題：
  - 既有的 `FavoriteAppWiringTests` 鎖定 `ToolbarItem(...) { detailFavorite }` 這段原始碼，鈴鐺因此改成獨立的 `ToolbarItem`。
  - 計時測試在全套平行執行時不穩，改成驗證行為。
- Simulator：webhtv-w311 這台、iOS 26、本機 Debug 建置；在模擬器裡看得到鈴鐺和追更區，證明裝的是這個版本。測試工具都在 `artifacts/w313/`：
  - `cms_srv.py`：本機 HTTPS 假採集站，集數讀 `srv/eps.txt`。
  - `py/w313slow.py`：假 Python 爬蟲站，延遲讀 `srv/delay.txt`。
  - 驅動程式 `w313.sh`。

| §9 項目 | 結果 | 證據（`artifacts/w313/sim/`） |
|---|---|---|
| 1 追更 3 集→5 集，重開後 `+2 集`、片庫標籤顯示 1 | 通過：啟動後約 3 秒自動檢查 | `s1-followed.png`、`s2-history.png`、applog「checking 1 of 1」 |
| 2（改為 2b）打開詳情不清除；播第 4 集剩 +1；播到最新一集清除 | 通過：第 4 集播完自動接第 5 集時清除；另測 7 集時播第 6 集，兩列都剩 `+1 集` | `s7-detail.png`、`s10-plus1.txt`、`srv.log` 的 `e=4`→`e=5`、`e=6` |
| 3 下拉立即重新檢查 | 通過：`+2 集`（第 6、7 集），觀看紀錄列也顯示 | `s6-pulled.png` |
| 4 回到前景 30 分鐘 | **未在 Simulator 測**（要等 30 分鐘或另加除錯開關）；只有程式碼審視 | — |
| 5 站台逾時 3 次 | 通過：停掉假站下拉 3 次，出現「最近檢查失敗」、沒有錯誤視窗、`+1` 保留；恢復後一次就消失 | `s11-failing.txt`、`s12-recovered.txt` |
| 6 站台不在目前設定 | 通過：把站的 key 改名後重開，列變灰並顯示該字樣，資料還在 | `s15-missing.txt` |
| 7 播放中不發檢查 | **未在 Simulator 測**；Core 測試 `nothingIsAskedWhileThePlayerIsOpen` | — |
| 8 爬蟲卡住（F-2） | 通過：見下 | applog、`srv.log` |
| 效能 | 「site list ready」沒有追更時 187／271 ms，有 1–2 部時 136–274 ms，另有一次 1360 ms 離群值；檢查在啟動完成後 3 秒才開始，不在量測範圍內 | applog |

**第 8 項（F-2）實測經過：**
- **逾時**：慢站延遲 15 秒。11:13:35 發出檢查，11:13:45 記「past 10.0 seconds — no longer waited for」，這一輪隨即結束；請求本身到 11:13:50 才回來。
- **忙碌略過**：使用者正在載入慢站詳情時下拉，記錄「skip 追更測試PY: busy or in use」，檢查器沒有對它另發請求（伺服器只有一個 `/pydetail`）。
- **慢站排除**：上次詳情 8–15 秒後的自動檢查，`due` 把它排除（「checking 1 of 2」）。
- **剩餘風險實測**：延遲 25 秒。11:22:29.9 發出檢查，11:22:40 不再等待；使用者 11:22:51 把首頁切到同一站，請求排在檢查後面，11:22:54 才開始、11:23:20 回來，等於多等約 3 秒。
- **下拉時點列表**：重新整理期間點列表不會進詳情頁（SwiftUI 的行為），所以「下拉中點同一站」這個情境自然不會發生。

### 12.3 和評估稿不同的地方
- 不用 `seenCount`、`pending`，改用 `unseen` 集名清單（§4.1、§4.5）。
- 沒有做「用片名搜尋」按鈕，也沒有做「記錄」長按追更（§4.1、§4.6）。
- 下拉時不排除慢站（§4.3 規則 6，Ponytail 修正）。
- 記錄頁原本頂部的「最近觀看／清除記錄」列保留在追更區上方，有觀看紀錄時兩區各有標題。

### 12.4 Ponytail
- `ponytail:ponytail-review` 對最終 diff：1 項必修。慢過一次的爬蟲站在下拉時也被排除，而判斷依據只有詳情請求會更新，所以那個站的追更會永遠停住；Simulator 上實際出現過。
- 已修：`FollowSchedule.due` 只在自動檢查時排除慢站；`aSlowSpiderSiteIsLeftOut` 加上下拉仍會檢查的斷言。
- 修正後 FollowTests 23/23 通過；沒有重跑 Simulator（改的只有一個條件，由單元測試覆蓋）。
- 審查也列出沒查到的部分：前景 30 分鐘觸發、播放中暫停（只有 Core 測試），同 §12.2。

## 13. 方案 C 實作紀錄（2026-11-18）

### 13.1 改了什麼
- **Core `ios/Sources/WebHTVCore/SeriesTitle.swift`（W-312 與 W-313 共用）**：`SeriesTitle(title)` 與 `SeriesGrouping.groups`／`isNewerSeason`，規則照 W-312 83c3730e §4.1–4.5。和 W-312 的 Python 試作（`artifacts/w312/series_proto.py`）不同的地方有兩處：
  - `S N` 前面不能是英文字母，「PS5」不會被當成「P」的第 5 季（`SeriesTitleTests` 有這一筆）。
  - 片名裡的零寬空白（U+200B）不算進基名。
- **和試作逐筆比對**：W-312 收集的 5 個關鍵字共 700 個不同片名，基名、季數、強弱三項有 699 筆相同；唯一的差異就是上面零寬空白那一筆。比對用的暫時測試已刪除。
- **Core `Follows/`**：
  - `Follow` 加 `newSeason`、`seasonCheckedAt`。兩者都是 Optional，所以方案 B 寫的 `follows.json` 照樣讀得進來。
  - 另加 `seasonKeyword`（劇場版、特別篇或基名少於 2 字時不做新季檢查）、`seasonDue`（每天一次）、`searched`（取 strong 而且季數最高的候選；不收原作品本身；兩邊片名都有年份時，候選不得比原作品舊；找到的提示保留到出現更高季數為止）、`seasonOpened`、`hasNews`。
  - `FollowChecker` 在某部作品詳情檢查完後，如果到了每日新季檢查時間，就在同一站搜尋 `baseDisplay` 第一頁。這次搜尋和詳情檢查走同一套規則：使用者正在用、最近用過、忙碌的站都不發；爬蟲逾時只停止等待，不中斷請求。結果放在 `Report.seasons`。
- **`WebHTVApp.swift`**：
  - 檢查時把同站搜尋結果交給 `FollowCenter`。
  - 記錄頁的追更列顯示「可能有新季：…」，有新季的也排在最前、也算進片庫標籤的數字。
  - 詳情頁「立即播放」下面放兩個連結：「可能有新季：…」直接開那一季的詳情；「找其他季」用 `baseDisplay` 開現有的跨站搜尋畫面（`AggregateSearchView` 的 `initialQuery`）。搜尋結果怎麼依系列歸組，是 W-312 A2 的工作，不在這裡做。
  - 打開提示的那一季，提示就清除。

### 13.2 驗證
- `swift test --filter "FollowTests|SeriesTitleTests"`：31/31 通過。
- 全套 `swift test`：1595 項中 1594 項通過。唯一失敗的是既有測試 `theProbeReadsOnlyTheHeadOfABodyThatNeverEnds` 的 5 秒時間上限，單獨重跑 0.05 秒就通過，前兩次全套也都通過，判斷是平行負載造成的抖動，和這次改動無關。輸出在 `artifacts/w313/core-tests-full-c.txt`。
- Simulator（同一台、同一套假站；假站收到搜尋請求時，多回一筆「追更測試劇 第二季」）：
  - 重開 App 後，啟動檢查發出詳情請求加同站搜尋（`srv.log` 有 `wd=追更測試劇`），applog 記「1 answered, 1 searched」，`follows.json` 記下 `newSeason` 第 2 季。
  - 記錄頁顯示「可能有新季：追更測試劇 第二季」，片庫標籤數字變 2（`c1-history.txt`）。
  - 詳情頁兩個連結都在（`c2-detail.png`）。點新季連結會開第二季詳情（`ids=2`），提示清除（`follows.json` 的 `newSeason` 變回 null）。
  - 「找其他季」開跨站搜尋，搜尋欄是「追更測試劇」，第一季和第二季都列出（`c3-search.txt`）。
- 沒驗到：爬蟲站的新季搜尋。慢站測試劇因為先前 25 秒的紀錄被判為慢站，這輪自動檢查排除了它；規則和 CMS 相同，由 Core 測試覆蓋。真實站台上的誤判率也沒測，只有 W-312 的 700 個片名離線比對。

### 13.3 Ponytail
- `ponytail:ponytail-review` 程序對方案 C 的 diff：沒有必修。
- 審查時逐項確認過：
  - `detailLoaded` 迴圈裡 `reload` 改到的是陣列副本，不會影響迭代。
  - 中文數字解析不會越界。
  - `\bsp\b` 在中文字後面不成立，這點和 Python 試作一致。
  - 搜尋失敗時不更新 `seasonCheckedAt`，下一輪會重試。
