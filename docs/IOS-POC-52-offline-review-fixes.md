# IOS-POC-52：修正 IOS-POC-47 審查確認的 40 項問題

## Recovery anchor

- 目標：使用者 2026-10-05 指示「修那40項問題」。問題來自 IOS-POC-47 多面向審查 workflow `wmgturmc6`：42 項經三方驗證，確認 40 項。完整描述存在 session scratchpad 的 `findings40.md`，本文件第 2 節列出每項的處理結果。
- 做法：依主題分批，每批一個 task guard session、一個 commit、各自的測試。全部完成後發布一版；依使用者先前「不要跑ci修改後就發佈」的指示，不另跑 CI。
- 基準：`db9618bd`（0.1.65 (66) 發布紀錄之後）。
- 目前進度見第 2 節；下一步見最後一節。

## 1. 批次

| 批次 | 主題 | 項目 | 狀態 |
|---|---|---|---|
| 1 | 當機與卡死 | F2、F15 | 完成 |
| 2 | 資料錯誤與遺失 | F5–F9、F16、F17、F20、F27、F28 | 待處理 |
| 3 | 下載流程、背景與傳輸 | F3、F4、F10、F11、F14、F18、F19、F26、F29、F30、F34、F39 | 待處理 |
| 4 | 自動刪除與播放 | F1、F12、F13、F23 | 待處理 |
| 5 | 安全與介面 | F22、F21、F31、F32、F33、F35 | 待處理 |
| 6 | 測試缺口與發布 | F24、F25、F36–F38、F40 | 待處理 |

## 2. 各項處理

### F15（中）播放清單數字異常造成閃退
- 原因：
  - `Int(Double("inf"))` 會讓程式閃退；
  - `FRAME-RATE=nan` 經過 `min`／`max` 後仍是 nan，再轉成整數也會閃退；
  - 很大的 `RESOLUTION` 相乘會溢位；
  - 宣告位元率 × 片長若超過 Int64，轉換時也會閃退。
- 修正：
  - `HLSPlaylist.number`／`integer`：只接受有限、非負、在上限內的數字。上限為片長 1 天、位元率 100 Gb/s、邊長 100,000 像素、byte range 10 TB、幀率 1,000。
  - `TARGETDURATION`、`EXTINF`、`BYTERANGE`（含 MAP 的）不合法時，整份播放清單以 `ParseError.badNumber` 拒絕，下載會以「無法讀取播放清單」失敗。
  - 選填屬性（位元率、解析度、幀率）不合法時直接忽略。
  - 所有計算出的大小改經 `OfflineSizeEstimate.bytes(_:)`，只接受有限且小於 1 PB 的值。
- 測試：
  - `brokenNumbersFailThePlaylistInsteadOfTrapping`
  - `unusableVariantNumbersAreIgnored`
  - `aBrokenVariantPlaylistFailsTheDownloadAndStaysFailed`：下載失敗，重開後仍是失敗，不會重新準備而再次閃退。

### F2（中）磁碟滿、紀錄寫不進去時卡在下載中
- 原因：`OfflineAssetStore.update` 先寫檔才改記憶體。寫入失敗時，`fail`、`pause` 等全部不動，下載卡在「下載中」或「準備中」。
- 修正：
  - `update` 改為先改記憶體，再嘗試寫入；寫入失敗時把該筆紀錄標成 `unwritten`。
  - 下一次寫入同一筆、`flush`，或每次 `pump` 的 `flushUnwritten()` 會再補寫。
  - 磁碟上保留的是上一筆完整紀錄，重開時照當機後的方式處理。
  - `update` 不再 throw，呼叫端的 `try?` 一併移除。
  - `prepare` 在寫入計畫之前先檢查空間；轉成「下載中」之前仍再檢查一次。兩次檢查之間沒有 await，維持 IOS-POC-50 的並行預留。
- 測試：`aRecordTheDiskRefusesStillChangesStateAndIsWrittenLater`
  - 把 metadata.json 的位置換成目錄，模擬寫入失敗。
  - 403 之後，下載仍會變成失敗，傳輸也被取消。
  - 寫入恢復後，下一次 `pump` 會把狀態寫進磁碟。

## 3. 驗證紀錄

- 批次 1：Linux `swift test` 84／84，Offline 原始檔沒有新的警告。

## 下一步

- 批次 2（資料錯誤與遺失）。
