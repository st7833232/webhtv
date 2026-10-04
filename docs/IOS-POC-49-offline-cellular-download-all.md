# IOS-POC-49：行動網路設定即時生效與「全部下載」

## Recovery anchor

- 目標：
  - 修正使用者回報的「5G 下載停在 0%」。
  - 新增「全部下載」：從觀看進度那一集（含）起，下載本線路尚未下載的集數，畫質用設定的預設值。
- 驗收標準：
  1. 切換「允許使用行動網路下載」後，已在佇列、暫停、失敗或下載中的項目都改用新設定。下載中的項目以新設定重新送出未完成的片段，已完成的片段不重抓。
  2. App 每次啟動都套用目前設定；設定沒變時不重啟任何下載。
  3. 只有行動網路、且設定未允許時，下載列和集數下方顯示「等待 Wi-Fi」，不再是看似卡住的「0%」。
  4. 需要憑證的下載走前景 session，在只有行動網路時改為等待連線，不再直接失敗。
  5. 「全部下載」：
     - 每集輪到時才解析播放網址；
     - 畫質、音軌、字幕與單集下載畫面未改動時的預設相同；
     - DRM 等無法下載的集數列在「需要處理」，重新下載時會重新解析；
     - 啟動時若站點尚未載入，最多等 30 秒，不直接判失敗。
- 狀態：程式與 Core 測試完成（Linux 69／69，突變 4／4）。依使用者指示「不要跑ci修改後就發佈」，不另跑 macOS CI，由發布 workflow 的 IPA 建置兼作 App 編譯檢查。
- 編號：原本編為 IOS-POC-48，push 時發現另一個 session 已用該編號（收藏與片庫，`f40c31a3`）並發布 `0.1.58 (59)`。改編為 IOS-POC-49，在 `a9d2cd56` 上重新套用，程式碼沒有衝突，`docs/current-task-state.md` 的衝突已手動合併。
- 發布第一次 run `37195931755`（版號 commit `5a79e781`）在「Build unsigned device app」失敗：`WebHTVApp.swift:2078:29: error: the compiler is unable to type-check this expression in reasonable time`。原因是「全部下載」按鈕與確認框直接寫在詳情頁 body 裡，body 加上另一個 session 的收藏改動後超出 type checker 的時限。IOS-POC-49-1 把按鈕與確認框移到 `downloadAllButton(_:)`，body 只多一行呼叫；確認框改掛在按鈕上，不再接在 body 的 modifier 鏈上。
- 下一步：以 `0.1.59 (60)` 重新 `workflow_dispatch`（tag 只在成功時建立，第一次 run 沒有建立）。

## 1. 使用者回報與決策

- 回報（2026-10-04，附截圖）：「行動網路看起來沒再下載」。截圖是 5G 網路，「正在下載」區一筆停在 0%，顯示「已下載 0 B / 最多約 281 MB」。另外要求「要有一鍵全部下載的按鈕」。
- 使用者選擇（AskUserQuestion）：
  - 下載範圍：「從目前觀看進度之後」；
  - 畫質：「用設定的預設畫質」。
- 使用者指示：「不要跑ci修改後就發佈」。

## 2. 根本原因（以 `7573e784` 為準；`a9d2cd56` 的離線程式碼與它相同）

1. **設定只在入列時記錄一次。** `enqueue` 把當下的 `allowsCellular` 存進 `OfflineAsset`；之後每個片段請求都用這個值（`request(for:asset:plan:)` → `URLRequest.allowsCellularAccess`），不讀目前設定。設定關閉時加入的下載，之後打開設定也只會等 Wi-Fi。
2. **IOS-POC-47 文件第 12 節第 7 點寫錯。** 原文寫「暫停再繼續才會套用新設定」，但 `resume()` 從不更新 `allowsCellular`。本次已改正該段。
3. **畫面沒有提示。** 等待 Wi-Fi 的下載顯示「0%」和轉圈。
4. **前景 session 沒有 `waitsForConnectivity`。** 需要憑證的片源在只有行動網路時，請求會直接失敗，重試 2 次後整筆標成失敗。

## 3. 設計

### 3.1 行動網路設定

- 新增 `OfflineDownloadManager.setAllowsCellular(_:)`。對每個未完成、且設定與新值不同的項目：
  - 更新 `allowsCellular`；
  - 若在下載中：generation 加一、取消傳輸（不產生續傳資料），再以 `submitMissing` 重新送出未完成的片段；
  - 刪除 `partial/` 中的續傳資料。
- 刪除續傳資料的理由：續傳資料保存的是當初的請求。依 `NSURLRequest` 的 archive 內容，其中包含行動網路限制，沿用它可能讓新設定無效。
  - 這一點未在真機驗證，所以採保守做法。
  - 代價：HLS 正在傳的片段重抓，每段只有幾 MB；單一檔案的下載從頭開始。
- 設定與新值相同的項目完全不動。App 每次啟動都會呼叫一次，因此這是必要條件，有測試保護。
- App 端：
  - 設定開關的 `onChange` 呼叫 `setAllowsCellular`；
  - 啟動時在 `start()` 之後套用目前設定，涵蓋 `0.1.57` 時加入的下載。
- 設定頁註腳改為「行動網路設定立即套用到所有未完成的下載；高幀率設定套用到之後開始的下載」。
- 「等待 Wi-Fi」：App 新增 `OfflineNetwork`（`NWPathMonitor`）。路徑可用、使用行動網路、且沒有 Wi-Fi 或有線網路時，若下載不允許行動網路，`OfflineText.status` 回傳「等待 Wi-Fi」。
  - monitor 的 handler 在 nonisolated 的靜態函式裡建立，避免 main-actor closure 在 monitor 的 queue 上被呼叫。
- 前景 session 設定 `waitsForConnectivity = true`，與背景 session 的等待行為一致。

### 3.2 全部下載

- 範圍由 `OfflineBulkSelection.downloadAll` 決定：
  - 本線路可播放的集數，從觀看進度那一集（含）到結尾；
  - 進度的找法與「立即播放」相同：同一線路比對網址，其他線路比對集名；
  - 找不到進度就是整條線路；
  - 已有任何狀態下載紀錄的集數排除。
- 新增 `enqueueAutomatic`：
  - 只存模式與偏好字幕語言（`OfflineDownloadRequest.automatic`），`needsFreshSource = true`；
  - 網址欄位暫放 `about:blank`，在解析完成前不會被讀取。
- `prepare`：輪到時先由既有的 resolver 解析，再呼叫單集畫面用的 `options(for:)`，取得該模式的預設選擇：
  - 選項（含 fallback）、預設音軌、預設字幕都與單集畫面相同；
  - 選定後把 `automatic` 清掉並存回，重試會沿用同樣的選擇；
  - 被拒絕（DRM、直播等）時以該原因失敗。此時請求仍是 `needsFreshSource`，重新下載會重新解析。
- 考慮過但不採用的做法：按下時就逐集解析並入列。逐集解析很慢；排在後面的集數簽章網址可能在輪到前就過期。
- `OfflineAppContext.resolve` 在站點清單是空的時，最多等 30 秒，每 0.5 秒檢查一次。啟動時 `start()` 會立刻準備佇列中的下一集，那時 `ConfigView` 可能尚未載入站點。這也順帶修正先前審查中「啟動時需要重新解析的重試可能失敗」那一項（低度）。
- UI：
  - 集數格上方加「全部下載」按鈕，沒有可加入的集數時停用；
  - 確認框顯示集數、起始集與畫質；
  - 空間不足時停止加入，並說明已加入幾集。

## 4. 驗證

- Linux（Swift 6.2.3 scratch package，與 IOS-POC-47 相同的方式）：`swift test` 共 69／69 通過，其中新增 7 項在 `OfflineCellularAndBulkTests.swift`。
- 突變測試，各自只跑新 suite，4／4 被抓到：
  - 不刪除舊續傳資料 → `aCellularChangeDropsResumeDataMadeUnderTheOldRule` 失敗；
  - 設定相同也重啟 → `applyingTheSameCellularSettingRestartsNothing` 失敗；
  - 全部下載不套用單集畫面的預設 → `downloadAllPicksWhatTheSheetPreselects` 失敗；
  - 切換後不重新送出 → `turningCellularOnReachesADownloadAlreadyRunning` 失敗。
- **未驗證：**
  - App 端程式碼無法在 Linux 編譯，依使用者指示不另跑 CI，以發布 workflow 的建置為編譯檢查；
  - 真機上的「等待 Wi-Fi」顯示、切換設定後實際改走行動網路、續傳資料是否真的保留行動網路限制。
- Ponytail：unavailable / skipped（此 runtime 沒有 Ponytail）。

## 5. 不在範圍內

- 先前審查確認的 40 項問題，使用者尚未決定是否處理。

## 6. Rollback

- revert 本任務的 commit 即可。資料格式只新增 optional 的 `automatic` 欄位，舊版讀到會忽略。
- 已用「全部下載」加入、但尚未解析的項目，在舊版會以 `about:blank` 準備而失敗，可直接刪除。
