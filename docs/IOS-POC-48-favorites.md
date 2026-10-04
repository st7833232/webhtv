# IOS-POC-48 收藏（Favorite）與片庫

## Recovery anchor

- 目標：作品層級收藏（identity = `ConfigSource.identity` + `Site.id` + `Vod.id`）、imported 設定的持久 identity、片庫分頁（收藏／記錄）、詳情頁收藏按鈕、已完結影集看完最終集自動取消收藏與復原、Favorite／History／Offline ownership 分離、來源不可用狀態。
- 驗收：第 1 節 A1–A14；測試對照見第 7 節。
- Lane：task guard `IOS-POC-48`（`standard`），base `7573e784b8c43f2995cc4d6536798775b67ee72d`（`origin/ios-poc`）。
- 計畫狀態：設計、核心與測試、App UI、macOS CI 驗證（run `37190088406`）皆完成，已 commit。
- 下一步：見文末「目前狀態」。

## 1. 目標與驗收條件

使用者需求（2026-10-04）共 9 個 Phase，本文件把它們收斂成可驗證的驗收條件：

| 編號 | 驗收條件 |
|---|---|
| A1 | Favorite 是獨立 domain（`FavoriteStore`），不寫入 `WatchHistory`、Offline 或任何其他 store 的欄位。 |
| A2 | identity = `configSourceID`（`ConfigSource.identity`）+ `siteID`（完整 `Site.id`，不是 site key）+ `vodID`；不含任何播放、線路、畫質、字幕或解析後網址。 |
| A3 | 匯入檔案的設定有自己的持久 identity；同一份內容重新匯入沿用，不同內容是新的 identity；不使用暫存路徑；匯入流程中途 crash 不會讓 identity 指錯檔案。 |
| A4 | Favorite 只存作品 metadata snapshot；禁止欄位（觀看位置、集數、時長、線路、畫質、下載狀態、路徑、headers、cookie、token、解析網址、站台健康）不存在於 record。 |
| A5 | Store：atomic write、schema version、欄位容錯 decode、壞檔另存不覆寫、單筆壞資料不影響其他筆、讀取失敗時不寫入、add/upsert、remove、lookup、list（`createdAt` DESC）、metadata refresh。 |
| A6 | Refresh 採 non-empty merge；`createdAt` 永不因 refresh 改變，只有內容真的變更時更新 `snapshotUpdatedAt`。 |
| A7 | Site migration 保守：完全相同或 structured ext 只差 key 順序 → migrate；key 相同但 ext 實質不同、找不到 → 不 migrate，保留並標示來源不可用；來源失效不刪 Favorite。 |
| A8 | 詳情頁右上角收藏按鈕（♡ 收藏／♥ 已收藏），無 Alert、無確認，輕微 symbol 動畫且尊重 Reduce Motion；「立即播放」維持全寬 Primary CTA。 |
| A9 | 底部分頁為首頁／搜尋／片庫／下載／設定，不新增第六個分頁；片庫內 segmented 收藏／記錄，預設收藏；觀看記錄原功能與詳情導覽保留。 |
| A10 | 收藏頁：2:3 poster grid（iPhone 兩欄）、poster＋名稱必顯示、年份有才顯示、來源名稱低權重；觀看進度／集數／看完／已下載集數只做 presentation join，不寫回 Favorite；本機搜尋（名稱、演員、導演、類型、年份）；只有「最近收藏」排序。 |
| A11 | 取消收藏只刪 Favorite；清除／刪除觀看記錄只刪 History（不再連帶刪下載）；刪除下載只刪 Offline；看完自動刪除離線影片不影響 Favorite。 |
| A12 | 只有「可確認已完結＋多集＋完成真正最終集」才自動取消收藏；完成沿用既有 near-ending／ending 判斷；電影、連載中、無法確認完結都保留；Favorite 不存在時 no-op。 |
| A13 | 自動取消時顯示「已看完，已從收藏移除」＋「復原」；復原只恢復 Favorite（含原 `createdAt`），不動 History／Offline；undo 狀態只在記憶體，crash 不造成其他資料異常。 |
| A14 | 原站台或設定不在目前載入的設定中：Favorite 保留、grid 仍以 snapshot 顯示並標示「來源不可用」，開啟時顯示非破壞性說明；不自動對應同名或同 key 的其他來源。 |

## 2. 現況盤點（base `7573e784`）

- `ConfigSource`（`ios/Sources/WebHTVCore/ConfigSource.swift`）：`case importedFile` 的 `identity` 固定為 `"imported"`，所有匯入檔共用一個 bucket。App 只有一個匯入槽（Application Support 的 `wang-movie.json`，`ConfigView.configURL(for:)`），設定頁沒有「切回匯入檔」的入口，要回到匯入檔只能重新匯入。
- `ConfigSource.identity` 的使用者：`WatchHistory.sourceID`（IOS-POC-10E）、站台記憶 `selectedSiteBySource`（IOS-POC-19）、`SiteHealthStore`（IOS-POC-41）、`RuntimeScope`（只有 remote）、`PlaybackTargetIdentity.configID`、`OfflineTitleInfo.sourceID`。`ContractFreezeTests.theConfigurationIdentityIsTheAddressAsWritten` 釘住 `importedFile.identity == "imported"`。
- `Site.id` = `key + "\0" + sorted-keys ext`（`WebHTVConfig.swift`）；設定檔確實有重複 key（`爱影`、`Bidys`、`AppV6Dxs`、`星芽短剧`）。`SiteSelection.resolveIdentity` 只接受完全相同或 structured ext 正規化後相同；`SiteSelection.resolve` 另有「key 只出現一次就認定」的 fallback，那是站台記憶用的，收藏不採用（需求明確禁止）。
- `WatchHistoryStore`（actor，單一 JSON 檔，`.atomic` 寫入）：壞檔＝整份記錄消失，讀取失敗也當成空清單，下一次 save 會覆寫。收藏 store 不能沿用這個缺點。
- `OfflineAssetStore`：每筆一個 `metadata.json`、`schemaVersion`、`tooNew` 與讀不懂的資料夾保留不刪。收藏 store 參考它的保守原則。
- `Vod`（`CMSClient.swift`）只有 `remarks` 能表達完結狀態（沒有 `vod_isend`／`vod_total` 欄位）；`Flag.episodes` 是線路的集數清單。
- 播放完成：`PlaybackSession.finished(reason:)` 是唯一的集結束路徑（`"end"` 真正 EOF、`"ending"` 使用者片尾設定），`WatchHistory.isNearEnding`（剩餘 ≤ 1% 且介於 5–30 秒）是觀看記錄「已看完」與續播判斷。Offline 自動刪除只認 `finished`（`OfflineCompletionPolicy`）。
- `HistoryView`（IOS-POC-47）：刪除／清除記錄時，若作品有下載會跳確認並 `OfflineDownloads.manager.delete` 一併刪除（使用者 2026-10-04 補充的規則）。本任務需求明確推翻：History 刪除只處理 History。
- 分頁：`TabView` tag 0 首頁、3 搜尋、1 記錄、4 下載、2 設定（tag 不重編，程式只切 tag 0）。
- App target 是 Swift 5 語言模式（target `SWIFT_VERSION = 5.0`），WebHTVCore 是 Swift 6（tools 6.2）。

## 3. 最佳實務查證（2026-10-04 取得）

| 來源 | 版本／日期 | 等級 | 支持的結論 | 對本專案的影響 |
|---|---|---|---|---|
| Android 上游 `app/src/main/java/com/fongmi/android/tv/bean/Keep.java`、`db/dao/KeepDao.java`、mobile `VideoActivity.onKeep/createKeep` | repo 內 `app/` | A（上游原始碼） | 收藏 key = `siteKey@@@vodId` + `cid`；只存 `vodName`、`vodPic`、`siteName`、`createTime`；`ORDER BY createTime DESC`；點擊直接切換，只有 Toast，沒有確認 | 排序與「無確認切換」照上游；identity 不照上游（site key 不唯一，iOS 已用 `Site.id`）；snapshot 比上游多存搜尋需要的 metadata |
| Apple HIG Tab bars（`developer.apple.com/tutorials/data/design/human-interface-guidelines/tab-bars.json`） | 取得日 2026-10-04 | A（官方） | 「Avoid overflow tabs」，空間不足時最後一格變成 More；分頁用於導覽，不用於動作 | 維持 5 個分頁，收藏不另開第六個 |
| Apple HIG Segmented controls | 同上 | A | 「Consider a segmented control to switch between closely related subviews」；iPhone 不超過約 5 段；標籤用名詞 | 片庫內以 segmented 切換「收藏／記錄」 |
| Apple HIG SF Symbols（Animations） | 同上 | A | Bounce「help communicate that an action occurred」；Replace「communicating a change in state」；「Apply symbol animations judiciously」 | 收藏按鈕用 replace＋一次 bounce |
| Apple HIG Motion | 同上 | A | 「Make motion optional」；回饋動畫簡短精準 | Reduce Motion 時不播 bounce |
| SwiftUI `symbolEffect(_:options:value:)` | iOS 17.0+ | A | 以值變化觸發，部署目標 iOS 17 可用 | 直接使用，不需 availability 分支 |
| SwiftUI `accessibilityReduceMotion` | iOS 13.0+ | A | 讀取系統 Reduce Motion | 以它關閉 bounce |
| Apple HIG Feedback | 同上 | A | Alert 用於關鍵、可行動的資訊，過度使用會失去作用 | 手動收藏／取消不跳 Alert |
| Apple HIG Undo and redo | 同上 | A | 簡短精確描述被復原的操作，並顯示復原結果 | 「已看完，已從收藏移除」＋「復原」，復原後卡片與愛心立即回來 |
| Apple HIG Searching | 同上 | A | 分區清楚的 App 可提供 local search，並以 placeholder 標示搜尋範圍 | 收藏頁本機搜尋，placeholder「搜尋收藏」 |

不適用的證據類別：上游 PR／issue／revert（收藏不是上游合併候選，上游 `Keep` 已直接讀原始碼）；論文與 benchmark（資料量為數百筆，沒有效能決策需要）。

## 4. 方案比較

| 方案 | 內容 | 結論 |
|---|---|---|
| 不改 | 沒有收藏 | 不符需求 |
| 上游原樣 | `siteKey@@@vodId` + config id，只存名稱／海報／站名，`createTime` 排序 | 拒絕 identity：重複 site key 會互撞（IOS-POC-5L 已證實）；snapshot 不足以支援本機搜尋與來源失效顯示 |
| WebHTV 調整（採用） | identity 改用完整 `Site.id`＋每份設定自己的 identity；snapshot 加 metadata；獨立 store 採逐筆容錯；完結判斷只信來源明確文字 | 採用。取捨見第 5 節 |

## 5. 決策與設計

### 5.1 Imported 設定 identity（A3）

- `ConfigSource` 改為 `case imported(id: String)`；`ConfigSource.importedFile` 保留為 static（`imported(id: "imported")`），既有呼叫端與 `ContractFreezeTests` 不變。
- identity 由匯入檔內容的 SHA-256 指紋決定：`ImportedConfigIdentities` 在 `UserDefaults` 保存「指紋 → identity」。第一次匯入某份內容時產生 `imported:<UUID>`，之後相同內容（重新匯入）沿用；不同內容是新的 identity。
- 啟動時以匯入槽目前的 bytes 查表；查不到（IOS-POC-48 之前匯入的檔）就是 legacy `"imported"`，所以既有使用者的觀看記錄、站台記憶、健康紀錄完全不受影響。
- 匯入時先寫指紋表、再寫匯入槽：兩步之間 crash 只會留下一筆用不到的指紋，identity 永遠對應槽內真正的內容；沒有另外的「目前 identity」欄位可以跟檔案不同步。
- 取捨：修改內容後重新匯入是新的設定。`ConfigSource.identity` 是所有以設定區分的資料共用的鍵，所以影響不只收藏：舊內容的收藏顯示「來源不可用」，「記錄」列表（`records(for:)`）、站台記憶（IOS-POC-19）與站台健康紀錄（IOS-POC-41）也從新的 identity 開始。舊資料都不刪除，重新匯入原本的檔案就回來。IOS-POC-48 之前，重新匯入任何檔案都沿用同一個 `imported`，所以這是對匯入檔使用者可見的行為變更，與遠端來源換網址就是另一份設定（IOS-POC-10E）的規則一致。用檔名判斷「同一份」是猜測，不採用。使用者 2026-10-04 回覆「不需要匯入設定檔」（使用遠端來源），維持此規則。

### 5.2 Model 與 Store（A1、A2、A4、A5、A6）

- `FavoriteIdentity { configSourceID, siteID, vodID }`；`historyKey`（= `WatchHistory.key`）只用於 presentation join。
- `Favorite`：identity、name、picture、remarks、year、area、typeName、director、actor、content、siteName、configSourceName、createdAt、snapshotUpdatedAt。名稱等文字存 `VodText.plain` 後的來源文字（不轉繁體，顯示時才 `zhTW`），年份存 `VodText.year`。
- `FavoriteSnapshot(summary:detail:siteName:configSourceName:)`：每個欄位 detail 優先、列表項補空。
- 檔案 `Application Support/Favorites/favorites.json`：`{"schemaVersion":1,"favorites":[…]}`，`Data.write(.atomic)`。
  - 每筆各自 decode；讀不懂的那一筆原樣保留、每次寫回，不影響其他筆。
  - 整個檔不是 JSON／不是這個格式：另存為 `favorites.corrupt-<時間>.json`，從空清單開始。
  - 檔案存在但讀取失敗（例如開機後尚未解鎖的資料保護）：本次不載入也不寫入，下次存取重試，避免以空清單覆寫。
  - `schemaVersion` 比目前新：第一次改寫前另存 `favorites.schema<N>.backup.json`。
  - 同一 identity 重複出現：保留最早 `createdAt` 的一筆。
- 排序：`createdAt` DESC，同時間依 identity 排序以求穩定。
- Refresh：新值非空才覆蓋；`createdAt` 不變；有欄位變更才更新 `snapshotUpdatedAt` 並寫檔。

### 5.3 Site migration 與來源可用性（A7、A14）

- 只用 `SiteSelection.resolveIdentity`（完全相同，或 structured ext 正規化後相同），並只處理 `configSourceID` 等於目前設定的收藏。不使用 `SiteSelection.resolve` 的 key-only fallback。
- migrate 後若與既有收藏 identity 相同，保留較早 `createdAt` 那一筆。
- 可用性：設定不同 → 不可用（原設定未載入）；設定相同但找不到站台 → 不可用；否則可開啟。不可用的收藏只在畫面標示，不刪、不 remap。

### 5.4 片庫 IA 與收藏頁（A9、A10）

- `記錄` 分頁（tag 1）改為 `片庫`，navigation bar principal 放 segmented `收藏｜記錄`（`LibrarySection`，預設收藏）；記錄子頁就是原本的 `HistoryView`。
- 收藏頁：與首頁相同的 `GridItem(.adaptive(minimum: 140, maximum: 220))`（iOS 17 支援的 iPhone 直向皆為兩欄）、2:3 poster；卡片：名稱、`年份 · 站名`、觀看記錄 join（看到哪一集＋進度條／已看完）、下載 join（已下載 N 集）、來源不可用標籤。
- 本機搜尋只查 snapshot 的名稱、演員、導演、類型、年份；查詢與欄位都轉成簡體再比對（`TraditionalSimplified`），所以繁簡輸入都找得到。

### 5.5 詳情頁按鈕（A8）

- `VodView` toolbar `.topBarTrailing`：`♡ 收藏`／`♥ 已收藏`（`Label` titleAndIcon），`contentTransition(.symbolEffect(.replace))`，加入收藏時 bounce 一次，Reduce Motion 時不 bounce；套用 IOS-POC-46 的 `legibleToolbarLabel()`。
- 點擊直接切換，沒有 Alert、確認或 Toast；「立即播放」按鈕不變。
- detail 載入成功時：已收藏的作品以 non-empty merge 更新 snapshot，並把線路清單留在記憶體供完結判斷。

### 5.6 完結判斷與自動取消收藏（A12、A13）

- 完成：`finished(reason:)`（EOF 或使用者片尾）或關閉播放器／切集時該集 `isNearEnding`，兩者都是既有判斷，沒有新增門檻。
- 完結：只讀來源 remarks（先轉簡體）。含「更新、连载、更至、未完、待续」→ 連載中；同時有連載與完結字樣 → 無法確認；`全N集`、`N集全`、`共N集`、`N集完` → 完結且總集數 N；`完结`、`全集`、`大结局`、`final`、`complete(d)` → 完結但未知總數；其他 → 無法確認。
- 最終集：
  - 已知 N：完成的那集名稱中的集數（`12集`、`第12话`，或名稱只有一組數字時取該數字）等於 N；名稱沒有數字時，線路恰有 N 集且它是最後一集。
  - 未知 N：需要詳情的線路清單，完成的是該線路最後一集，且該線路是集數最多的線路（避免落後的線路被當成完結）。
  - 沒有線路清單（例如從下載頁播放）時只接受已知 N 的規則。
- 只套用多集：線路 ≥ 2 集（或 N ≥ 2）；`typeName` 含「电影／電影／movie」一律保留。
- 自動取消時記憶體內保留 8 秒的 undo offer，root 畫面顯示「已看完，已從收藏移除」＋「復原」；復原呼叫 `FavoriteStore.restore`（原 record、原 `createdAt`；期間若已手動重新收藏則不覆蓋）。

### 5.7 Ownership（A11）

`FavoriteStore`、`WatchHistoryStore`、`OfflineDownloadManager` 各自只刪自己的資料，可互相讀取（收藏頁的 join、詳情頁的狀態）。`HistoryView` 移除 IOS-POC-47 的「記錄與下載一起刪」確認與刪除呼叫，下載只由下載頁自己的刪除流程控制。

## 6. 實作紀錄

| 檔案 | 內容 |
|---|---|
| `ios/Sources/WebHTVCore/ConfigSource.swift` | `case imported(id:)`、`legacyImportedIdentity`、`importedFile`（static）；`ImportedConfigIdentities`（內容 SHA-256 → identity，沿用 `runtimeSHA256`） |
| `ios/Sources/WebHTVCore/Favorites/Favorite.swift` | `FavoriteIdentity`、`FavoriteSnapshot`（detail 優先、列表補空）、`Favorite`（容錯 decode、`merging`） |
| `ios/Sources/WebHTVCore/Favorites/FavoriteStore.swift` | actor：add／toggle／remove／refresh／restore／migrate、逐筆容錯、壞檔另存、讀取失敗不寫、schema 備份 |
| `ios/Sources/WebHTVCore/Favorites/FavoriteBrowsing.swift` | `LibrarySection`、`FavoriteAvailability`、`FavoriteSearch` |
| `ios/Sources/WebHTVCore/Favorites/FavoriteCompletion.swift` | `SeriesCompletion`、`FavoriteAutoRemoval`、`FavoriteUndoOffer`、`WatchHistory.favoriteIdentity` |
| `ios/WebHTVApp/Sources/WebHTVApp.swift` | 分頁「記錄」→「片庫」（tag 1）；匯入時先登記 identity 再寫檔、啟動時依內容查 identity；`FavoriteLibrary`、`LibraryView`、`FavoritesView`、`FavoriteCard`、`FavoriteUnavailableView`、`FavoriteToggle`、`FavoriteUndoBanner`；`VodView` 收藏按鈕與 detail 後 refresh；`PlaybackSession` 完成回報（`finished`、關閉、切集）；`HistoryView` 移除連帶刪下載 |
| `ios/Tests/WebHTVCoreTests/Favorites/*.swift`、`ContractFreezeTests.swift` | 第 7 節 |

實作中的決定（第 5 節以外）：

1. **near-ending 只認本次播放量到的位置**：`open` 會把同一集的舊位置帶入 record（IOS-POC-21），重開已看完的最終集、在播放器載入前就關閉時，舊位置仍是「接近結尾」。`PlaybackSession` 以 `measuredNearEnd`（本次 `persist()` 量到才設）把關，避免誤刪；核心的 `decide(record:ended:)` 仍以 record 當下位置再判一次。
2. **toggle 在 store actor 內完成**：連點兩下是兩次切換，不會兩個 add 互相競爭（`twoQuickTogglesEndWhereTheyStarted`）。
3. **不可用收藏的「取消收藏」**：來源不可用時無法進入詳情頁，所以說明頁提供使用者自己按的「取消收藏」（不自動刪、不確認，與手動取消一致）。
4. **undo banner 放在 TabView 上層，且只在播放器關閉後出現**：播放器可能從任何分頁開啟。收藏可能在播放器還開著時被移除（循環播放、從最終集結尾切回上一集），所以 `PlaybackSession` 以 `playerOpened()`／`playerClosed()` 告知；banner 出現時才以 `FavoriteUndoOffer.shown(at:lasting:)` 開始計時（8 秒，VoiceOver 開啟時 30 秒），被遮住時 task 取消但不解除 offer。banner 顯示被移除的作品名稱。
5. **完成回報的 near-ending 必須在回報當下仍成立**（`measuredNearEnd && record.isNearEnding`）：拖到結尾又拖回、再切集失敗時，不會用掉這一集唯一的一次回報。
6. **獨立審查**：背景 reviewer 讀 diff 後沒有發現編譯問題，提出 5 個 runtime 項目；第 4、5 點與 VoiceOver 是據此修正，重新匯入的影響寫入 5.1。

## 7. 驗證

### 7.1 需求 → 測試

新增 75 個測試函式（`Favorites/` 74 個，`ContractFreezeTests` 1 個；部分為參數化）。

| 使用者 Phase 9 清單 | 測試 |
|---|---|
| 1. Favorite model／store | `FavoriteStoreTests`：`favoritingTheSameTitleTwiceKeepsOneFavorite`、`favoritesSurviveARelaunch`、`theMostRecentFavoriteComesFirst`、`removingAFavoriteRemovesOnlyThatFavorite`、`twoQuickTogglesEndWhereTheyStarted`、`anIncompleteIdentityIsNeverStored`、`aFavoriteHoldsOnlyTitleMetadata`、`aRefreshNeverMovesTheFavoritedTime`、`aSourceThatLeavesFieldsOutDoesNotEmptyTheSnapshot`、`openingADetailNeverFavoritesIt`、`oneDamagedRecordCostsNoOtherFavorite`、`aCorruptFileIsSetAsideNotOverwritten`、`aFileThatCannotBeReadIsNeverOverwritten`、`aNewerSchemaIsCopiedAsideBeforeThisBuildRewritesIt`、`aRepeatedRecordKeepsTheFirstFavoritedOne`、`restoreBringsBackTheSameRecord`、`restoreNeverReplacesAFavoriteMadeSince` |
| 2. ConfigSource identity | `ImportedConfigIdentityTests`（6 個）、`ContractFreezeTests.theFavoriteIdentityAndTheImportedIdentityAreFrozen`、既有 `theConfigurationIdentityIsTheAddressAsWritten` |
| 3. Site identity migration | `aReorderedStructuredExtIsStillTheSameSite`、`aSiteWhoseExtReallyChangedIsNotGuessed`、`aKeyWithSeveralCandidatesIsNotGuessed`、`aSiteThatIsGoneKeepsItsFavorite`、`migrationOnlyTouchesTheLoadedConfiguration`、`migratingOntoAnExistingFavoriteKeepsTheEarlierOne` |
| 4. VodView favorite state | `aDetailScreenSeesOnlyItsOwnTitlesFavorite`、`aRefreshedDetailIsStillTheSameFavorite`、`theSnapshotTakesTheDetailAndFillsFromTheListItem`、`theSameTitleFromAnotherSourceIsAnotherFavorite`（同名不同來源）、`sitesSharingAKeyNeverShareAFavorite`、`playNowStaysTheFullWidthPrimaryAction`、`theFavoriteToggleAsksNothingAndRespectsReduceMotion` |
| 5. Library navigation | `theLibraryOpensOnFavoritesThenHistory`、`theTabBarIsFiveTabsWithTheLibraryInTheMiddle`、`theLibraryShowsBothPagesAndOpensOnFavorites` |
| 6. Local favorite search | `searchFindsNameCastDirectorGenreAndYear`（7 組）、`searchMatchesEitherScript`、`searchLooksOnlyAtTheListedFields`、`anEmptySearchListsEveryFavoriteInOrder` |
| 7. Favorite + History | `unfavoritingKeepsTheHistoryAndTheDownloads`、`clearingTheHistoryKeepsTheFavoriteAndTheDownloads`、`anAutomaticRemovalKeepsTheWatchHistory`、`deletingWatchHistoryNeverDeletesDownloadsOrFavorites`、`theFavoritesScreensOnlyReadHistoryAndDownloads` |
| 8. Favorite + Offline | `deletingADownloadKeepsTheFavoriteAndTheHistory`、`theWatchedAutoDeleteKeepsTheFavorite`、`anAutomaticUnfavoriteAndItsUndoTouchOnlyTheFavorite` |
| 9. Completed-series auto-unfavorite | 連載中最後一集 `anOngoingSeriesKeepsItsFavoriteAtItsLatestEpisode`；已完結未播最後一集 `aFinishedSeriesKeepsItsFavoriteBeforeItsFinalEpisode`；最終集 near-ending `theFinalEpisodeNearItsEndRemovesAFinishedSeries`；Favorite 不存在 `noFavoriteIsANoOp`；保留 History `anAutomaticRemovalKeepsTheWatchHistory`；保留 Offline `anAutomaticUnfavoriteAndItsUndoTouchOnlyTheFavorite`；Undo `undoBringsTheFavoriteBackAsItWas`、`anExpiredOfferUndoesNothing`；電影 `aFilmKeepsItsFavoriteWhenItEnds`；無法確認完結 `aFinishThatCannotBeConfirmedKeepsTheFavorite`；另有 remarks／集數解析參數化測試、`aLaggingLineDoesNotEndAFinishedSeries`、`aMergedFinalEntryIsTheFinalEpisode`、`unnumberedEpisodesNeedTheWholeDeclaredLine`、`withoutTheListingOnlyADeclaredTotalProvesTheEnd`、`theFinalEpisodeStoppedHalfwayIsNotFinished`、`theEndOfFileOrTheViewersEndingCountsAsFinished`、`aRecordWithoutItsConfigurationIsNotGuessed` |
| 10. Source unavailable | `aFavoriteOpensOnlyOnItsOwnConfigurationAndSite`、`aSiteWhoseExtReallyChangedIsNotGuessed`、`aSiteThatIsGoneKeepsItsFavorite` |
| 11–12. 既有 WatchHistory／Offline 回歸 | macOS CI 全套（7.3） |
| 13–14. Swift package tests、iOS App build | macOS CI（7.3） |

### 7.2 Linux（雲端 session，Swift 6.2.3 scratch package）

- Ubuntu archive 的 `swiftlang 6.2.3`＋`libswiftlang`＋`libxml2-16` 解壓到 scratchpad；`lib_Testing_Foundation.so` 以空 stub 連結。scratch package 以 symlink 連結本任務的核心檔與 `WebHTVConfig`、`SnifferRules`、`SiteSelection`、`WatchHistory`、`VodText`、`TraditionalSimplified`、`SavedSource`；`Vod`／`Flag`／`Episode` 由 `CMSClient.swift` 擷取副本，`runtimeSHA256` 以純 Swift SHA-256、`CSPSourceResolver` 以 stub 取代（皆不進 repo）。`FavoriteOwnershipTests`（需 Offline）與 `FavoriteAppWiringTests`（讀 App 原始碼）只在 macOS 執行，後者以 Python 模擬掃描確認對目前原始碼成立。
- 結果：63 個測試全數通過（Swift 6 語言模式，核心與測試零警告）。
- Mutation check（Rule 9）：20 條規則逐一破壞（non-empty merge、重複收藏重設 createdAt、讀取失敗當空清單、存檔丟棄讀不懂的筆、壞檔直接覆寫、migration 改用 key-only、連載＋完結字樣視為完結、無線路清單接受未知總集數、落後線路當完結、未完成也算完成、單集線路移除、連載移除、每次匯入都新 identity、legacy 未登記、搜尋含簡介、搜尋不轉簡體、restore 覆蓋新收藏、可用性忽略設定、過期仍可復原、片庫預設記錄），20 條都讓對應測試失敗。

### 7.3 macOS CI（暫時驗證分支 `ci/ios-poc-48-verify`）

雲端 session 沒有 Xcode，比照 IOS-POC-45／47：工作區改動複製到一次性分支 `ci/ios-poc-48-verify`（另一個 git worktree，`ios-poc` 的 HEAD 不動），加一個只在該分支觸發的 workflow，在 `macos-26`（Xcode 26.6、Swift 6.3.3）上跑；base `7573e784` 與本次各跑一次全套再比對失敗清單。

- Run `37188633777`（`5857700`）：推送新修正時由 `cancel-in-progress` 取消，未產生結果。
- Run `37188753774`（`4803587`）：
  - macOS host `swift test`：本次 928 個測試、base 853 個（+75 為新增）；兩邊都是同樣 5 個 issue，「本次失敗、base 未失敗」為空；收藏相關測試全部通過。
  - Debug（device，未簽章）：**BUILD SUCCEEDED**；Release（device，未簽章）：**BUILD SUCCEEDED**。
  - 警告：本任務新增／修改的程式 0 個；`WebHTVApp.swift` 列出的 4 行在既有的 `deviceInfo()`（`UIDevice.current`）與 `evaluateJavaScript`，base 同樣存在。
  - iOS Simulator：收藏測試沒有失敗；本次多出 3 個 base 這輪沒失敗的測試，都在本任務未觸及的模組：`AdBlockListTests.blocksTheAdSubresourcesWithoutTouchingThePageOrOverMatching`、`MediaSnifferTests.overlappingSniffsCancelUnlessTheyWaitTheirTurn`（WKWebView／本機 socket），`SourceClientTests.theProbeReadsOnlyTheHeadOfABodyThatNeverEnds`（5.57 s > 5 s 時間門檻）。IOS-POC-47 也記錄過這三類在 CI 模擬器上的不穩定。
- Run `37190088406`（`ae5d4c9`，含 reviewer 修正；`ios/` 與本任務 commit 逐檔相同）：
  - macOS host `swift test`：本次 929 個測試、base 853 個（+76）；兩邊同樣 5 個既有 issue，「本次失敗、base 未失敗」為空；收藏相關測試全部通過。
  - Debug（device）：**BUILD SUCCEEDED**；Release（device）：**BUILD SUCCEEDED**。
  - 警告：本任務程式 0 個（同上，只有既有的 `deviceInfo()`／`evaluateJavaScript`）。
  - iOS Simulator：收藏測試沒有失敗；「本次失敗、base 未失敗」只有 `SourceClientTests.theProbeReadsOnlyTheHeadOfABodyThatNeverEnds`（5.06 s > 5 s 時間門檻，run 2 為 5.57 s，IOS-POC-47 run 1 在 host 也失敗過 6.5 s）。本任務未改 `SourceClient`；run 2 多出的 AdBlock／MediaSniffer 兩項在 run 3 沒有再出現，屬既有的不穩定測試，未修改（不在本任務範圍）。
- 暫時分支 `ci/ios-poc-48-verify` 需在 GitHub 網頁刪除（雲端 session 無法刪除遠端分支）。

## 8. 限制與待真機驗證

1. **真機未驗證**：收藏按鈕的 symbol 動畫與 Reduce Motion、iOS 17／18／26 工具列可讀性（`legibleToolbarLabel`）、片庫 segmented 在導覽列的版面、海報格線兩欄、本機搜尋、最終集播完自動移出與「復原」banner 位置（tab bar 之上）、App 重啟後收藏仍在、從下載頁播放最終集的判斷。
2. 完結判斷只讀 remarks（`Vod` 沒有 `vod_isend`／總集數欄位）；remarks 沒有明確字樣的來源一律不自動移出。
3. 從下載頁播放、且本次啟動未開過該作品詳情頁時，沒有線路清單，只有「全N集／N集全／共N集」且集名有集數時才會自動移出。
4. 自動移出時若播放器沒有關閉（例如最終集之後還有花絮接著播放），banner 等到播放器關閉才出現，那時才開始計時。
5. 修改內容後重新匯入的設定檔是新的設定，舊內容的收藏顯示「來源不可用」（不刪除）；重新匯入完全相同的檔案會回到原本的 identity。
6. 收藏頁顯示所有設定的收藏；不是目前設定的收藏標示「來源不可用」，需切回原設定才能開啟。

## 9. Rollback

- 程式：revert 本任務 commit。
- 資料：舊版不讀 `Application Support/Favorites/`，檔案留在裝置上不影響其他功能；`UserDefaults` 的 `webhtv.importedConfig.identities` 舊版不讀。回到舊版後，IOS-POC-48 之後匯入的設定其觀看記錄的 `sourceID` 是 `imported:<UUID>`，舊版的記錄清單只顯示 `"imported"` 與沒有 `sourceID` 的記錄，所以那些記錄在舊版看不到（不會刪除）。

## 10. Ponytail

`Ponytail: unavailable / skipped`（本 runtime 的 skills 清單沒有 `ponytail:*`）。

## 目前狀態

- 2026-10-04：實作與驗證完成（第 7 節），commit `f40c31a3`，使用者選擇 push `ios-poc`（不發版）；5.1 的匯入檔規則維持。
- 下一步：使用者依第 8 節第 1 項做真機驗證；遠端暫時分支 `ci/ios-poc-48-verify` 需在 GitHub 網頁刪除。
