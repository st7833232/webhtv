# IOS-POC-19 — 每個資訊源記住自己的站台

- 狀態：**計畫，待使用者核准**（2026-09-24）；未實作。
- 使用者需求（2026-09-24，原文）：「我在切換資訊源的時候需要記錄每個資訊源離開前的站台，以便我回來資訊源我還要重新切換；另外我需要一個全資源搜尋的功能；給我相關計畫」。
- 規劃基準：2026-09-24 15:39 CST，分支 `ios-poc`（規劃時 HEAD `75fc13a5`；之後只多了 17H 解析度修正 `5613517a`，不影響本計畫）。
  證據來自三個唯讀 agent 讀程式碼（iOS 資訊源／站台、iOS 搜尋、Android 參考做法），關鍵行號已人工抽查；**沒有跑 `swift test`、沒有建置、沒有在模擬器或實機試過**。
- 順序：先做 IOS-POC-19，再做 IOS-POC-20（兩者都改 `WebHTVApp.swift`，一個做完再開下一個；各自一次 task guard、一個 commit、`finish --no-tag`）。
  預留：IOS-POC-19B（切回連不上的資訊源時改讀快取）、IOS-POC-20B（跨所有資訊源搜尋）。
- 用語：使用者說的「資訊源」＝ iOS UI 的「設定來源／已存來源」（`ConfigSource`、`SavedSource`）；「站台」＝ UI 的「內容來源」（`Site`）。

**完成條件**：在資訊源 A 選了站台 X，切到 B 選 Y，再切回 A 時自動回到 X；重開 App 也一樣；升級後不會跳回第一個站台。

**Task guard**：
- 車道：`quick-fix`。
- 範圍：`ios/Sources/WebHTVCore/SiteSelection.swift`、`ios/Tests/WebHTVCoreTests/SiteSelectionTests.swift`、`ios/WebHTVApp/Sources/WebHTVApp.swift`、`docs/IOS-POC-19-per-source-site-memory.md`、`docs/current-task-state.md`。
- 研究：Android 已有現成做法可照著改，這次在任務文件裡寫一段簡短的研究紀錄就夠，不需要另外上網查。

### 要解決的問題
每次切換資訊源都會落到第一個站台，切回原來的資訊源也一樣，你得再打開「內容來源」重選一次。

### 目前實作
- **只存一個全域值**：UserDefaults 鍵 `selectedSiteKey`（`WebHTVApp.swift:11`），在 `.onChange(of: selectedSiteID)`（167-171）寫入 `SiteSelection.token`，沒有依資訊源分開。
- **根因**：`adopt(_:config:from:)`（360-375）是匯入、切換、重新整理共用的路徑。第 374 行 `selectedSiteID = loaded.first { $0.id == selectedSiteID }?.id ?? loaded.first?.id` 只比對記憶體裡的 id，不讀存下的值。另一個資訊源通常沒有這個 id，所以落到第一個站台。
- **冷啟動** `restore()`（377-411）只在 404-407 用全域值還原。快取檔不存在時在 399 提早 return，這是已知、還沒修的缺陷（`docs/IOS-POC-10-plan-ux-and-sources.md:505-509`、`docs/current-task-state.md:1112-1116`）。
- **Spider 套件更新後** `rebuildSites()`（326-332）第 331 行 `?? selectedSiteID ?? sites.first?.id` 也不讀存下的值。
- **刪除已存來源** `forget(_:)`（265-270）只刪清單和快取檔。
- **現成可用的部分**：
  - 每個資訊源的穩定鍵：`ConfigSource.identity`（`ConfigSource.swift:18-23`）。遠端是 `url.absoluteString`，和 `SavedSource.id` 相同；所有匯入檔共用 `"imported"`。
  - 存值的格式：`SiteSelection.token/resolve`（`SiteSelection.swift:4-29`），已經包含 IOS-POC-18 的舊 object-ext 遷移。
- **缺口**：站台的 `ext` 一改，`resolve` 就回 nil。它最後的退路是拿 token 字串本身去比 `key`，所以永遠比不到。
- **測試**：`SiteSelectionTests` 有 6 條。ConfigView 的選擇邏輯沒有任何測試。

### Android 參考
- `Config.home`（`app/src/main/java/com/fongmi/android/tv/bean/Config.java:40-41`）每個資訊源存一個站台 key。
- `VodConfig.initSite`（`VodConfig.java:194-203`）依 `config.getHome()` 找站台，找不到就用 `sites[0]`。
- `setHome`（312-318）在使用者選站台時立刻存。
- `BaseConfig.loadConfig`（98-105）成功後會呼叫 `config.update()`，把退回的第一個站台寫回去，原本記住的站台就沒了。
- **取捨**：
  - 照抄：每個資訊源一筆、選的當下就存。
  - 改寫：存 `Site.id` 的 token，不存 key。這份設定有 4 組重複的 key（`WebHTVConfig.swift:88-94`）。
  - 不抄：記住的站台暫時不在時，用第一個站台覆寫記憶。

### 方案比較
| 方案 | 內容 | 評估 |
|---|---|---|
| A 不改 | — | 問題照舊 |
| B 照抄 Android | 每個資訊源存 key；找不到時把第一個站台寫回去 | 不採用。同名站台（例如兩個 `爱影`）會還原錯；Spider 套件還沒就緒、站台暫時不在時，記憶會被永久覆寫 |
| **C 窄版改寫（建議）** | 用字典依資訊源存 token；只有使用者親手選才寫入；三個讀取點共用同一套還原規則 | 改動最小，不會丟記憶，也順便修掉冷啟動缺陷 |
| D 存進 `saved-sources.json` | `SavedSource` 加一個 Optional 欄位 | 不採用。匯入檔沒有 `SavedSource` 條目；每選一次站就要重寫整個清單 |

**C 的具體做法**
1. **新鍵** UserDefaults `selectedSiteBySource`，型別 `[String: String]`：鍵是 `ConfigSource.identity`，值是 `SiteSelection.token`。不能存 raw `Site.id`，因為裡面有 NUL，會被截斷（IOS-POC-10C）。
2. **寫入**：把 ConfigView 傳給子畫面的 `$selectedSiteID` 換成自訂的 `Binding`。它的 set 會做三件事：更新 `@State`、寫 `selectedSiteBySource[source.identity]`、繼續寫舊鍵 `selectedSiteKey`（留給回滾用）。167-171 的 `.onChange` 寫入移除。`adopt`、`restore`、`rebuildSites` 自動選站台時只改 `@State`，不寫記憶。這樣記住的站台暫時不在時，不會被第一個站台蓋掉。
3. **讀取**：`adopt`:374、`restore`:404-407、`rebuildSites`:331 三處統一改成 `SiteSelection.resolve(memory[source.identity], in: loaded) ?? loaded.first { $0.id == selectedSiteID }?.id ?? loaded.first?.id`。第二段保留現有行為。
4. **`SiteSelection.resolve` 加一條退路**：token 解出來的 id 比不到時，如果這個 key 在設定裡只有一個站台，就用 key 比對；key 重複就不猜。唯一受影響的是這三個呼叫點。`WatchHistoryStore.migrateSiteIdentities` 用的是 `resolveIdentity`，不受影響。
5. **升級遷移**：`restore()` 開頭如果發現沒有 `selectedSiteBySource`，但有舊的 `selectedSiteKey`，就把舊值放進目前資訊源（`configSourceURL`，沒有就是 `"imported"`）那一格。只做一次。
6. **刪除**：`forget(_:)` 一併刪掉那個資訊源的記憶（見待決 Q1）。

### 資料模型與持久化
- 記住的站台從設定消失：畫面顯示退回的站台，但記憶保留，直到你親手選別的。站台回來後，切換或重新整理時會自動回到它。
- 站台的 `ext` 變了、`key` 沒變：key 在設定裡唯一時照樣還原；重複時退回第一個站台。
- 站台改名（key 變了）：對不到，退回第一個站台，舊記憶無害地留著。
- 所有匯入檔共用一格記憶（`ConfigSource.swift:15-17` 刻意這樣設計）。網址字串不同就算不同資訊源，和觀看記錄、快取的規則一致。
- 字典大小等於用過的資訊源數，`forget` 時會清掉。

### UI 行為
沒有新畫面。
- 兩個選站台的入口不變：首頁 sheet（465）、設定頁「內容來源」（949）。
- 切換資訊源的入口不變：已存來源列（1030-1033）→ `use`、`useRemote`、匯入本機檔、`refreshRemote`。
- 切換後首頁會用 `.id(selectedSite.id)`（526）重建，直接開在記住的站台。
- 載入失敗時照現在的行為：停在原來的資訊源並顯示錯誤。

### 效能
每選一次站台，寫一個小字典到 UserDefaults，成本可以忽略，沒有網路成本。

### 驗收標準
1. A 選 X → 切到 B（第一次會是第一個站台）→ 選 Y → 切回 A：顯示 X。
2. 關掉 App 重開：A 顯示 X；切到 B 顯示 Y。
3. 升級：舊版 0.1.11 在 A 選了 Z，裝新版後開啟仍是 Z。
4. 快取檔不存在時冷啟動：遠端重新整理成功後回到記住的站台（修掉已知缺陷）。
5. 同 key 不同 ext 的兩個站台（`爱影`）各自記得。
6. ext 改變但 key 唯一：仍然還原；key 重複：不猜，退回第一個站台。
7. 記住的站台暫時不在：顯示第一個，記憶不被覆寫；站台回來後自動回去。
8. `forget` 後重新加入同一網址：回到第一個站台（照 Q1 的預設）。
9. 觀看記錄、Spider、播放不受影響。

### 驗證方式
- **`swift test`**（在 `ios/` 跑一次）：`SiteSelectionTests` 新增兩條，key 唯一時退回 key 比對、key 重複時不猜。遷移只有三行 App 邏輯，用模擬器情境 3 驗。
- **模擬器**：用 xcodebuild 建一次，接著手動跑情境 1、2、4、5、8。遠端資訊源需要網路。情境 3 先裝目前的 release build、選好站台，再蓋上新版。情境 7 模擬器不好重現，改在實作時讀程式碼確認：除了自訂 Binding，沒有其他地方寫記憶。
- **實機**：這個邏輯不需要實機。依你的規則，我只建 device build 證明能編譯並交出 IPA，不直接安裝。

### 回滾
Revert 單一 commit 即可。因為舊鍵 `selectedSiteKey` 會繼續寫入，回滾後的版本還是會還原最後選的站台。新鍵留著也無害。

### 風險
- 如果有子畫面不經過 Binding 直接寫 `selectedSiteID`，那條路徑的選擇就不會被記住。HistoryView 會不會寫還沒確認；實作時要 grep 所有 `selectedSiteID =` 和 `$selectedSiteID`。
- `rebuildSites` 改成讀記憶後，Spider 套件在背景更新時，停在退回站台的使用者會跳回記住的站台。這是想要的行為，但畫面上看得到變化。
- 既有問題，不在這次範圍，只回報：
  - `use(entry)` 沒有取消機制，快速連切兩個資訊源時，最後載入完成的那個會贏。站台和資訊源在 `adopt` 裡一起設定，不會配錯。
  - `use()` 的註解（252-253）說會顯示快取，和實作不符。

### 待你決定
- **Q1**：刪除已存來源時，要不要一起忘記它的站台？**預設：一起忘記**，和快取一起刪的邏輯一致。
- **Q2**：切回一個暫時連不上的資訊源時，要不要改開它的本機快取並還原站台？現在是停在原來的資訊源並顯示錯誤。**預設：這次不做**，另開 IOS-POC-19B。
- **Q3**：所有匯入的本機檔共用一格站台記憶，可以接受嗎？**預設：可以**。

### 預估（我自己的執行時間）
| 階段 | 時間 |
|---|---|
| 任務文件、guard start | 10 分 |
| `SiteSelection.resolve` 加退路 + 測試 | 15 分 |
| App 接線（Binding、三個讀取點、遷移、forget） | 20 分 |
| `swift test` + 模擬器建置 | 10 分 |
| 模擬器情境 | 25 分 |
| finish commit | 5 分 |
| **合計** | **約 85 分** |

核准後立刻開工的話，約 17:05 完成。實機要等你用 SideStore 安裝，這段不算在內。

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
