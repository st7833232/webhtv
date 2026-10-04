# IOS-POC-50：多工下載（最多同時 3 集）

## Recovery anchor

- 目標：使用者要求「多工下載」，選定「同時 3 集」（AskUserQuestion）。
- 驗收標準：
  1. 最多 3 集同時處於「準備中」或「下載中」，其餘「等待下載」。
  2. 有空位時先開始最早加入的集數。
  3. 開始下載前的空間檢查，要把其他正在下載的集數依預估還需要的空間一起算進去。
- 狀態：程式與 Core 測試完成（Linux 71／71，突變 3／3）。依使用者先前的指示「不要跑ci修改後就發佈」，不另跑 macOS CI，直接發布。
- 已發布 `0.1.60 (61)`：run `37199415029` success，tag `ios-v0.1.60-b61` → `8889c9a1`，`source.json` `6e019a09`，IPA 34,933,408 bytes。真機未驗證。
- 下一步：等使用者在真機確認多工下載。

## 1. 現況（以 `f108dae8` 為準）

- `OfflineDownloadManager.pump()` 只在沒有任何一集「準備中」或「下載中」時，才開始最早的一集，並在 pump 內直接 await 該集的準備。
- 單集 HLS 的所有片段一次送出。兩個 session 都設定 `httpMaximumConnectionsPerHost = 4`。

## 2. 決策

- 與使用者說明的取捨：
  - 會變快的情況：單一檔案的影片（一集只有 1 條連線）、不同來源主機的集數，以及準備階段（解析網址、讀播放清單）和其他集的下載重疊；
  - 不太會變快的情況：同一個來源主機的 HLS，因為本來就用滿 4 條連線，同時下載只是共用頻寬，每集完成時間反而延後。
- 選擇：固定 3 集，不加設定項目，每主機連線數維持 4，不放大對來源伺服器的壓力。
- 實作：
  - `pump()` 依 `createdAt` 由舊到新，把空位數量的 queued 項目先全部標成 preparing（中間沒有 await，同時執行的 pump 會把它們算進去），再以 task group 平行執行各自的 `prepare`；
  - `prepare` 的空間檢查改為「自己剩下的預估 + `reservedBytes(excluding:)`」。後者是其他 downloading 項目的預估減去已占用的空間。
  - 檢查與狀態改為 downloading 之間沒有 await，因此兩集不會同時通過同一份空間。
  - 預估未知時的結果與舊版相同，因為 `requiredBytes(nil) == requiredBytes(0)`。
- 下載中途的空間保護仍是「可用空間低於 200 MB 就停止」，與並行數無關，所以沒有改。
- 「全部下載」確認框的「依序下載」改為「最多同時下載 3 集」。
- 並行解析：每次呼叫 Python spider 都會先取得 GIL（`PythonSpiderRuntime.swift`），播放中預先解析下一集也已經有同時解析的情況。風險已知，但未在真機上驗證 3 集同時解析。

## 3. 驗證

- Linux：71／71。
  - 新增 `OfflineConcurrencyTests`（2 項）：
    - 5 集中前 3 集同時下載；完成 1 集後補上最早的第 4 集，第 5 集仍等待；
    - 空間只夠一集時，第二集以 insufficientStorage 失敗，第一集照常下載。
  - 修改 IOS-POC-49 的 `downloadAllResolvesEachEpisodeOnlyWhenItsTurnComes`：改為 4 集，前 3 集解析，第 4 集輪到時才解析。
- 突變 3／3 被抓到：
  - 上限改成 1；
  - 移除預留空間；
  - 改成由新到舊。
- 未驗證：真機上 3 集同時背景下載、iOS 對背景 session 的排程方式、3 集同時解析 spider。
- Ponytail：unavailable / skipped。

## 4. Rollback

- revert 本 commit，排程回到一次一集。資料格式沒有改變。
