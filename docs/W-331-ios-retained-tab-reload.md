# W-331 片庫在 iOS 26 切換來源或重新進入分頁時重新載入

- 分支 `claude/kind-dirac-ojjljm`，從 ios-poc `dc78a15b`（0.1.108 發版 commit）開。
- Lane：quick-fix。範圍：`ios/WebHTVApp/Sources/WebHTVApp.swift`、本文件。

## 1. 問題

使用者回報（2026-11-19）：切換來源 JSON 後，片庫的觀看記錄沒有跟著切換。

## 2. 原因

- `HistoryView` 與 `FavoritesView` 用不帶 id 的 `.task` 載入，註解寫明「每次重新進入分頁都會重跑」。
- `3c78c1cf`（2026-11-16，0.1.103 起）讓 iOS 26 以上改用 `ZStack` + `retainedTab`：分頁第一次開啟後一直保留，切換分頁只改透明度，畫面不會重新出現，`.task` 不會重跑。
- 結果（只影響 iOS 26 以上）：
  - 切換來源後回到片庫，觀看記錄仍是舊來源的（`records(for: source.identity)` 沒有重讀）。
  - 在其他分頁看完一集後回到片庫，觀看記錄與收藏的觀看進度不更新（同一原因，推論，未實測）。
- 今天（11-19）的 commit 沒有改到這段載入邏輯。

## 3. 做法

- 新增環境值 `isSelectedTab`（預設 `true`）。只有 iOS 26 的 `retainedTab` 會設定它（`selectedTab == tab`）。原生 `TabView`（iOS 25 以下）不設定，行為不變。
- `HistoryView`：`.task(id: HistoryLoad(source: source.identity, selected: isSelectedTab))`，分頁不在畫面上時直接返回。切換來源或重新進入分頁都會重讀。
- `FavoritesView`：`.task(id: isSelectedTab)`，同樣在不在畫面上時返回。重新進入分頁時重讀收藏與觀看進度。
- 沒有改到 `WatchHistoryStore`、追更、下載、分頁外框的保留與捲動位置。

## 4. 驗證

- 本機沒有 Swift／Xcode，無法編譯或執行測試。
- 已完成：diff 靜態審查。`ConfigSource.identity` 是 `String`，`.task(id:)` 在部署目標 iOS 16 可用。
- 未完成：macOS CI 編譯（需要推送分支）、iOS 26 實機確認以下三項：
  1. 切換來源後回到片庫，記錄是新來源的。
  2. 在首頁看完一集，切回片庫，最新記錄出現。
  3. iOS 25 以下行為不變。
- Ponytail：unavailable / skipped（此環境沒有提供）。

## 5. 回復

`git revert <W-331 commit>`。只動到一個檔案的載入時機，沒有資料格式變更。

## Recovery anchor

- 狀態：程式碼與文件已完成，等待使用者授權推送分支，再用 `ios16-compat-check` 做 CI 編譯。
- 下一步：取得推送授權後推送 `claude/kind-dirac-ojjljm`，在該分支觸發 `ios16-compat-check.yml` 編譯。
