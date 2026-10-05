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
| 2 | 資料錯誤與遺失 | F5–F9、F16、F17、F20、F27、F28（含 F26） | 完成 |
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

### F5（中）finalize 先刪計畫才寫完成紀錄
- 修正：先把紀錄寫成 completed（含實際大小），再刪除計畫、request 和暫存；最後再更新一次實際大小。
- 測試：無單元測試。「在兩個步驟之間被終止」無法在測試中重現，此項以閱讀程式碼確認。F6 的測試涵蓋「沒有 request 時仍能重新下載」的復原路徑。

### F6（中）檔案遺失的已完成項目無法重新下載
- 修正：
  - `prepare` 找不到 request 時，用下載時的模式建立一個與「全部下載」相同的自動 request（`needsFreshSource`），由 resolver 重新解析。
  - 移除 `resume()` 中永遠不會執行的 integrity 分支。
- 測試：`aCompletedDownloadWithMissingFilesCanBeDownloadedAgain`（重開後標成 integrity，重新下載會重新解析，並送出 4 個片段）。

### F7（中）金鑰伺服器的錯誤頁被當成金鑰
- 修正：
  - `accept` 收到大小不是 16 bytes 的金鑰時，直接以 expiredSource「金鑰無效」失敗，檔案不放進套件。
  - `OfflinePackageVerifier.problems` 也檢查金鑰大小。
- 測試：
  - `aKeyThatIsNotSixteenBytesFailsTheDownload`
  - `theVerifierRefusesAKeyOfTheWrongSize`

### F8（中）重寫播放清單時 KEY 被移到 MAP 之前
- 修正：
  - `HLSMap.key` 記錄 MAP 宣告當下有效的金鑰。
  - 重寫時先切換到 MAP 的金鑰（可能是 NONE），再寫 MAP，最後切換到片段自己的金鑰。
- 測試：
  - `aMapDeclaredBeforeTheKeyStaysClear`
  - `aMapDeclaredAfterTheKeyStaysEncrypted`
  - `aMapAndAKeyChangingTogetherKeepTheirOrder`

### F9、F16（中）重試時混入不同編碼或不同版本的舊檔
- 修正：
  - `timelineFingerprint` 改為 `sameTimeline(as:)`，除原本的角色、檔名、byte range 長度外，再比對每段的秒數與遠端檔名（不含 query）。
  - 舊計畫沒有秒數欄位時，只比對其餘欄位，避免更新 App 後進行中的下載全部重來。
  - 讀不到上一份計畫（不存在或無法解碼）時，一律丟棄 media、audio、subtitles、keys、playlists、partial。
- 測試：
  - `aReResolveWithOtherDurationsStartsTheFilesOver`
  - `anUnreadablePlanDiscardsTheFilesItDescribed`

### F17（中，安全）重新解析後仍沿用舊的續傳資料
- 修正：只要是重新解析過的 request，或計畫的 origin、headers 和上一份不同，就刪除 `partial/`。
- 測試：`aReResolvedSingleFileDoesNotResumeTheOldRequest`（重試使用新網址，且不帶續傳資料）。

### F20（中）重試時抓不到外掛字幕就把它從下載中拿掉
- 修正：
  - `downloadSidecars` 保留紀錄中已存在的字幕檔，不重新抓。
  - 重新解析時，依名稱與語言把已選字幕對應到新網址。
- 測試：`aSavedSubtitleSurvivesARetryThatCannotFetchItAgain`

### F26（低）暫停後，過時的解析失敗蓋掉新的狀態
- 修正：resolver 回傳 nil 時，先檢查 generation 與 preparing 狀態，不符合就不做任何事。
- 測試：`aLateResolverFailureDoesNotOverrideAPause`

### F27（低）只有第一份播放清單接受 BOM
- 修正：`HLSPlaylist.parse` 先去掉開頭的 U+FEFF。
- 測試：`everyPlaylistMayStartWithAByteOrderMark`（解析與實際下載都測）。

### F28（低）智慧與高畫質模式選到 AV1／VP9
- 修正：在畫面大小篩選之後、解析度比較之前，先排除 AV1 和 VP9，除非沒有其他版本可選。
- 測試：`av1AndVP9AreChosenOnlyWhenNothingElseFits`（三種模式都選 720p H.264；只有 AV1 時才選 AV1）。

## 3. 驗證紀錄

- 批次 1：Linux `swift test` 84／84，Offline 原始檔沒有新的警告。
- 批次 2：
  - Linux 97／97，沒有新的警告。
  - 突變 9／9 被對應的測試抓到：F8、F9、F16、F17、F20、F26、F7、F28、F27。
  - F17 第一次的突變只拿掉一半條件，因 origin 改變仍會刪除而沒有被抓到；改成整段拿掉後即被抓到。

## 下一步

- 批次 3（下載流程、背景與傳輸）。
