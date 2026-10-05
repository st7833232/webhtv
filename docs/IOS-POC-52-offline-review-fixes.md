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
| 3 | 下載流程、背景與傳輸 | F3、F4、F10、F11、F14、F18、F19、F29、F30、F34、F39（F26 已在批次 2） | 完成 |
| 4 | 自動刪除與播放 | F1、F12、F13、F23 | 完成 |
| 5 | 安全與介面 | F22、F21、F31、F32、F33、F35 | 完成 |
| 6 | 測試缺口與發布 | F24、F25、F36–F38、F40 | 完成（發布另記） |

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

### F3、F29（中、低）送出途中被暫停或刪除，後續建立的傳輸沒人取消
- 修正：
  - 傳輸層 `URLSessionOfflineTransport` 以每個下載的取消計數保護送出：建立任務前在鎖內檢查，取消先遞增計數再列出任務，所以送出途中被取消時，後續任務不會建立。
  - 新增 `cancel(tags:)`，只取消指定的傳輸。
  - manager 每次送出後再檢查一次 generation，不符時取消剛送出的那批（`cancelIfStale`）。
  - 啟動時取消資產已不存在、不在下載中，或 generation 不符的傳輸。
- 測試：
  - `aPauseDuringASubmitStopsWhatTheSubmitCreatedAfterIt`：讓送出停在半路，期間暫停，放行後剛建立的傳輸全被取消。
  - `launchCancelsStaleTransfersOnly`
  - F29 在傳輸層，只有 Darwin 才能編譯，沒有單元測試。

### F4（中）強制關閉後剩下的每個片段下載兩次
- 修正：
  - 屬於目前 generation 的 `.cancelled` 只有系統會產生（強制關閉），改為不重試，由重開後的 `submitMissing` 負責重新送出。
  - 重試前若該片段已在磁碟上，或仍在傳輸中，就跳過。
- 測試：
  - `aCancelledCurrentTransferIsNotRetried`
  - `aFailureForAUnitAlreadyInFlightIsNotRetried`

### F10（中）需要憑證的傳輸全部排進預設 session 而逾時
- 修正：
  - 需要憑證的片段一次最多 6 個在傳輸中，每完成一個補一個（`credentialedWindow`、`feedCredentialed`）。
  - 逾時、連線中斷、沒有網路、不允許行動網路、漫遊關閉，改歸類為 `.connectivity`，重試上限 10 次；其他失敗維持 2 次。
  - App 回到前景（`didBecomeActive`）時呼叫 `resubmitRunning()`，把 App 暫停期間中斷的傳輸重新送出。
- 測試：
  - `credentialedUnitsAreSentThroughAWindow`
  - `connectivityFailuresHaveTheirOwnBudget`

### F11（中）背景 session 的完成通知太早
- 修正：
  - `urlSessionDidFinishEvents` 不再直接呼叫系統的 completion handler，而是在事件串流尾端放入一個標記。前面的事件都處理完、`settle()` 等待準備中的下載最多 20 秒之後，才呼叫 completion handler。
  - `finalize` 之後的 `pump` 改為不等待，下一集的準備不會卡住其他下載的事件。
  - 暫存檔名改為 `<tag>.<status>.<uuid>.part`（`OfflineStagedBody`）。啟動時，對應目前 generation 的暫存檔由 `accept` 直接接手，不再重新下載。
- 未做：沒有另外向 UIApplication 申請背景執行時間。這部分在 App 端，雲端 session 無法編譯驗證，且 `settle` 已限制在 20 秒內。
- 測試：
  - `aStagedBodyIsTakenUpAtLaunch`
  - `theTransportWaitsForPreparingToSettle`

### F14（中）單一檔案下載途中不檢查空間
- 修正：每次收到單一檔案的進度事件（最多每秒兩次）時檢查可用空間：低於 200 MB，或伺服器已告知總長但剩餘部分加保留空間放不下，就以空間不足停止，續傳資料會保留。
- 測試：`aSingleFileStopsWhenTheRestNoLongerFits`（大小未知時開始，進度回報 2 GB、可用 1 GB，下載停止）。

### F18（中）刪除暫停或失敗的單一檔案下載不會釋放空間
- 修正：
  - 新增 `discardResumeData`：用續傳資料建立任務後立即取消，讓系統刪除對應的部分檔案。
  - 刪除、切換行動網路設定、時間軸改變、重新解析時，都改用 `discardResumeFiles`。
  - HLS 暫停或失敗時不再要求續傳資料，因為片段的續傳資料只會留下部分檔案。
- 未驗證：系統是否真的刪除部分檔案，需要真機確認。
- 測試：`deletingGivesUpResumeDataAndSegmentsMakeNone`

### F19（中）失效的續傳資料一直被重送
- 修正：單一檔案的傳輸失敗且沒有帶回新的續傳資料時，刪除舊的續傳資料，下次從頭開始。
- 測試：`resumeDataThatFailedIsNotSentAgain`。這次用真實流程：帶續傳資料的傳輸失敗且沒有新資料，下一次送出就不帶續傳資料，不再靠手動刪檔模擬。

### F30（低）「離線內容」總量在下載中或失敗後不更新
- 修正：總量改為即時計算：已完成的下載用量測到的實際大小，未完成的用已收到的 bytes（單一檔案的部分資料在系統暫存檔裡，也計入），再加上無法讀取的資料夾大小。
- 測試：`usageCountsWhatUnfinishedDownloadsHold`

### F34（低）啟動時沒有清掉子資料夾裡的寫入暫存檔
- 修正：`removeStaleTemporaries` 也掃 `playlists/` 和 `partial/`。
- 測試：`launchRemovesInterruptedWritesInSubfolders`

### F39（低）準備中刪除時，外掛字幕又把資料夾建回來
- 修正：外掛字幕下載完時，如果該下載已經沒有紀錄，就刪除它重建的資料夾。
- 測試：`deletingWhilePreparingLeavesNoFolder`（讓字幕下載停在半路，期間刪除）。

### F1、F23（中、低）拖到片尾被當成看完；「真正結束」的判斷沒有能失敗的測試
- 修正：
  - 判斷規則移到 Core 的 `OfflineCompletionPolicy`：
    - `endReason(finishedBy:)` 只把 `end`（播放器到檔尾）和 `ending`（觀眾的片尾自動下一集）視為結束；
    - `viewerSeeked(to:duration:)` 記錄觀眾手動拖到片尾 3 秒內的情況，之後的檔尾不算看完；
    - 往回拖、或開始新的一集會清除這個記錄。
  - App 的 `PlaybackSession.seek(toSeconds:)`（進度條、±10 秒、子母畫面、鎖定畫面都經過這裡）呼叫 `viewerSeeked`；App 自己做的續播與跳廣告直接呼叫引擎，不經過這裡。
  - `finished(reason:)` 改用 `endReason` 對應。
  - 片尾自動下一集即使是在拖進片尾之後發生，仍算看完（需求允許）。
- 測試：
  - `aSeekToTheEndIsNotAWatch`
  - `theFormalAutoNextCountsEvenAfterASeekIntoTheCredits`
  - `onlyTheEngineEndAndTheViewersEndingAreEnds`

### F12（中）App 暫停後本機伺服器沒有重開
- 修正：
  - 恢復暫停中的離線 HLS 之前（`reloadPaused`、鎖定畫面的播放），先 `await OfflineDownloads.server.start()`；伺服器優先使用原本的連接埠，網址不變。
  - 安全網：位置離片長還有 5 秒以上的檔尾不算看完。避免播放器讀不到片段、跳到清單結尾而被誤判為看完並刪除。
- 未做：原連接埠被占用、伺服器換了連接埠時，已載入的網址會失效，需要重開那一集。這部分需要重建播放項目，風險較高，沒有處理。
- 測試：`anEndOfFileShortOfTheDurationIsNotAWatch`。App 端的伺服器重開沒有單元測試，需要真機驗證。

### F13（中）關閉「看完後自動刪除」不影響既有下載
- 修正：
  - manager 新增 `setAutoDeleteEnabled`。關閉時，所有下載都不會被排定自動刪除，已排定的取消；開啟時，各集依下載時的選擇。
  - App 在啟動完成前、以及切換設定時呼叫。
  - 重開時，若設定是關閉，當機留下的排定也會先取消。
  - 設定頁註腳同步更新。
- 測試：
  - `theSettingTurnedOffStopsEveryAutoDelete`
  - `aCrashArmedAutoDeleteWaitsForTheSettingAtLaunch`

### F22（低）離線外掛字幕轉址時帶著 Cookie／Authorization 送往其他主機
- 原因：外掛字幕經 `SubtitleHTTP.fetcher()` 用 `URLSession.webHTV` 下載，沒有轉址 delegate。URLSession 會把原請求的 header 複製到轉址後的請求，所以與影片同源而帶了憑證的字幕，被 302 到其他主機時，憑證也一起送出。
- 修正：
  - 新增 `OfflineHTTP.subtitleSession`：沿用 `URLSession.webHTV` 的設定，加上 `SubtitleRedirectPolicy`。
  - 轉址時以「請求第一次送往的網址」為基準套用 `OfflineHTTP.redirect`。來源的 Cookie、Authorization 只會送往影片自己的 origin，所以需要保護的憑證存在時，該網址就是影片的 origin。
  - 跨主機、或 https 降為 http 時移除憑證，保留 User-Agent、Referer；字幕請求自己的 `Accept` 不動。
  - `OfflineDownloads.manager` 的字幕服務改用這個 session。線上字幕的路徑沒有改（不在本項範圍）。
- 測試：`offlineSubtitleRedirectsKeepTheSourceCredentialsOnItsOrigin`（跨主機移除、同源保留、降為 http 移除）。
- 未驗證：`OfflineDownloads` 的接線只在 Darwin 編譯，Linux 測不到；依靠發布建置編譯。

### F21（低）選「最省空間」但來源沒有 720p 以下版本時，默默下載 1080p 卻記成最省空間
- 使用者決定（2026-10-05）：這種情況照常下載 1080p，1080p 是上限，預設也是 1080p。
- 修正：
  - 表單：沒有 720p 以下版本時，照常退回「智慧 1080p」的版本，並顯示「此影片沒有 720p 以下的版本，將以「智慧 1080p」下載。」；送出與量測都用實際採用的模式。
  - 全部下載：同樣退回，下載紀錄與 request 改記實際採用的模式。
  - 退回用的是智慧 1080p 的挑法：1080p 中位元率最低但合理、HEVC 優先，不是 1080p 高畫質。
- 測試：`downloadAllInSaverModeWithoutA720pVersionRecordsTheModeItUsed`。表單部分沒有單元測試。

### F31（低）下載中的項目換區時，刪除確認視窗被關掉
- 修正：刪除確認改由 `OfflineDownloadsView`、`OfflineTitleDownloadsView` 持有，`OfflineAssetRow` 只回呼 `onDelete`。項目從「下載佇列」移到「已下載」或「需要處理」時，確認視窗不會跟著舊的列消失。
- 測試：純 SwiftUI，沒有單元測試；需要真機驗證。

### F32（低）App 在背景被喚醒時，需要重新解析的下載因設定還沒載入而失敗
- 原因：iOS 為了完成的背景傳輸喚醒 App 時，可能不會建立 `ConfigView`，站點清單一直是空的。IOS-POC-49 的 30 秒等待之後仍會判定「無法重新取得來源」。
- 修正：
  - `setResolver(_:ready:)` 新增 `ready`，回答 App 是否已載入設定；`pump` 在還沒載入時，跳過需要重新解析的排隊項目（`needsFreshSource` 或沒有 request），讓它們留在排隊中。已有網址的下載不受影響。
  - App 端 `OfflineAppContext.markLoaded`：`ConfigView` 讀完已存設定與快取的 spider pack 後呼叫，接著 `resolverBecameReady()` 重新排程。
  - 「是否就緒」由 manager 每次向 App 讀取，而不是由 App 推送 true／false，避免啟動流程與 `ConfigView` 兩邊的先後競態。
  - 移除 IOS-POC-49 的 30 秒等待。
- 測試：`aDownloadThatMustResolveWaitsQueuedUntilTheConfigurationIsLoaded`。

### F33（低）每集的下載選單點擊範圍只有 26×26 pt
- 處置：不另修。`c361c637`（IOS-UI-A）重做版面時，選單已改為與集數按鈕並排的獨立 44×44 pt 元件（有 `contentShape` 和無障礙標籤），不再壓在集數按鈕角落；VoiceOver 可以單獨選到它。
- 驗證：閱讀目前程式碼確認（`OfflineEpisodeMenu` 與它在集數列的位置）。

### F35（低）單一檔案與沒有 master 的播放清單不受 1080p 上限，表單文字也不正確
- 修正（部分）：
  - Core 新增 `OfflineDownloadOptions.singleUndeclaredVersion`：只有一個版本且沒有標示解析度。
  - 這類來源的表單不再說「依位元率挑選不超過 1080p 的版本」，改說「來源只有一種版本，也沒有標示解析度。」；註腳改為「來源只有一種版本，會照原樣下載；無法確認解析度，可能超過 1080p。」
- 未做：
  - 讀取檔頭或第一個片段來確認解析度、超過 1080p 就拒絕；
  - 把解析度與編碼存進紀錄，讓已完成的列顯示。
  - 原因：需要媒體探測（Apple 平台上讀 AVAsset 的影像軌，或自行解析 MP4／MKV／TS 檔頭），屬於新功能且風險較高，本批不做。目前這類來源可能下載到超過 1080p 的版本，表單已明確告知。
- 測試：`aLoneUndeclaredVersionIsToldApartFromAPickedOne`（單一檔案、沒有 master 的播放清單為 true；有解析度的 master、兩個未標示解析度的 master、拒絕下載的情況為 false）。

### F37（低）等待用的輔助函式逾時不會失敗
- 原因：`waitFor` 逾時時回傳當下的紀錄而不是失敗，呼叫端又常丟棄結果；`waitForSubmissions` 少於預期時回傳較短的陣列，呼叫端用 `requests[2]` 取值會讓整個測試程序崩潰。
- 修正：
  - `waitFor` 逾時時在呼叫位置記錄 Issue，並回傳 nil。
  - `waitForSubmissions` 數量不足時在呼叫位置記錄 Issue。
  - `startSimpleDownload` 改為 `throws`，送出的傳輸不是 4 個時以 `#require` 失敗，不再讓索引崩潰；所有呼叫端改為 `try await`（含 `StorageMaintenanceTests`）。
  - `aTransferFromBeforeAPauseChangesNothing` 改為 `try #require` 等到「下載中」。
- 驗證：改完後原有測試全部仍通過，沒有測試依賴逾時回傳值。突變「resume 不重新排程」會讓 `aTransferFromBeforeAPauseChangesNothing` 等測試失敗。
- 順帶發現：批次 5 的 F32 測試原本寫成 `waitFor(...) != nil`，因此必定成立；已在批次 5 改正。

### F24（低）SDR 優先、24／30 fps 優先的選片測試因錯誤的理由通過
- 修正：`smartPrefersSDROverHDR`、`standardFrameRateUnlessHighFrameRateIsAskedFor` 改用「被偏好的版本反而較貴、編碼排序也較後」的組合（SDR H.264 比 HDR HEVC 貴；24 fps H.264 對 60 fps HEVC），並檢查三種模式（含 720p 的最省空間）。測試名稱不變，因為 IOS-POC-47 文件引用這些名稱。
- 驗證：拿掉 SDR 規則、或讓幀率規則只在要求高幀率時才生效，兩個測試都會失敗。

### F25（低）當機復原與安全網沒有能失敗的測試
- 新增：
  - `launchFinishesADeleteACrashInterrupted`：留下 `.deleting` 紀錄後重開，資料夾與紀錄都被刪除。
  - `aPackageMissingAFileWhenTheLastUnitLandsFailsVerification`：第一個片段完成後刪掉它的檔案，其餘完成後必須以「檔案完整性」失敗，不能標成完成。
  - `aDownloadQueuedWithoutAnEstimateIsRefusedWhenItsPackageDoesNotFit`：沒有預估大小時加入佇列，準備時算出的大小放不下，必須以「空間不足」失敗，而且一個傳輸都沒有送出。
- 驗證：三個對應的突變（重開時忽略 `.deleting`、略過驗證、拿掉準備時的空間檢查）都會讓對應測試失敗。

### F36（低）probe 不會整個讀進記憶體的測試不會失敗
- 修正：測試用的網路紀錄每個請求允許讀取的上限；`theProbeNeverReadsAWholeFileIntoMemory` 檢查只有一個請求、帶 `Range: bytes=0-1023`、上限是 `OfflineHTTP.probeLimit`。
- 驗證：probe 改用播放清單上限、或拿掉 Range，測試都會失敗。
- 未測：`OfflineHTTP.fetcher` 本身的串流截斷只在 Darwin 編譯，Linux 測不到。

### F38（低）行動網路預設值與傳遞、刪除記錄的範圍沒有測試
- 新增：
  - `cellularIsOffUntilAllowedAndReachesEveryTransfer`：用獨立的 `UserDefaults(suiteName:)`，預設關閉、設定後保存；關閉時所有傳輸與交給 iOS 的 `URLRequest.allowsCellularAccess` 都是 false，開啟時都是 true。
  - `aTitlesDownloadsIncludeEveryStateButDeleting`：`OfflineLibrary.assets(forHistoryKey:)` 包含除了刪除中以外的所有狀態，不含其他作品，並依集數排序。
- 驗證：預設改為開啟、`URLRequest` 固定允許行動網路、清單只留已完成，三個突變都會失敗。

### F40（低）離線觀看記錄的測試只測到測試資料本身
- 修正：
  - Core 新增 `OfflineIdentity(siteID:vodId:flag:episodeURL:)` 與 `OfflineAsset.historyRecord(quality:)`。
  - App 的 `VodView.offlineIdentity` 與 `OfflinePlayer.record` 改呼叫這兩個 helper，行為不變（`historyKey` 原本就是 `WatchHistory.key(siteID: site.id, vodId: summary.id)`）。
  - `offlineTitleInfoKeepsTheWatchHistoryIdentity` 改為測這兩個 helper：key 來自 `Site.id`；從簽章網址下載後，記錄的 `episodeUrl` 仍是列表上的網址。
- 驗證：helper 的 key 參數對調、記錄的線路欄位寫錯，兩個突變都會失敗。
- 未驗證：線上播放的 `VodView.record(for:flag:)` 仍在 App 端，沒有共用這個 helper；兩者一致靠閱讀程式碼確認。

## 3. 驗證紀錄

- 批次 1：Linux `swift test` 84／84，Offline 原始檔沒有新的警告。
- 批次 2：
  - Linux 97／97，沒有新的警告。
  - 突變 9／9 被對應的測試抓到：F8、F9、F16、F17、F20、F26、F7、F28、F27。
  - F17 第一次的突變只拿掉一半條件，因 origin 改變仍會刪除而沒有被抓到；改成整段拿掉後即被抓到。
- 批次 3：
  - Linux 111／111。
  - 突變 14／14 被對應的測試抓到：F3 兩處、F4 兩處、F10 兩處、F11、F14、F18 兩處、F19、F30、F34、F39。
  - F4 第一次的突變寫錯，造成編譯錯誤；改正後被抓到。
- 批次 4：Linux 122／122；突變 5／5 被對應的測試抓到（F1、F12、F23、F13 兩處）。
- 批次 5：
  - Linux 126／126。Linux 臨時套件為了 `URLSession.webHTV` 加了一個不進版控的 shim。
  - 突變 5／5 被對應的測試抓到：F22（轉址照原樣送出）、F21（不改記模式）、F32 兩處（不擋、全部擋）、F35（不比對版本）。
  - 「全部擋」的突變第一次沒有被抓到：`waitFor` 逾時仍回傳該筆紀錄而不是 nil，測試寫成 `!= nil` 必定成立。改為比對狀態後即被抓到。`waitFor` 本身的問題屬於第 6 批的 F37。
  - App 端（F21 表單、F31、F32 接線、F35 文字）只能靠發布建置編譯，沒有在真機執行。
- 批次 6：
  - Linux 131／131。
  - 突變 13／13 被抓到：F24 兩處、F25 三處、F36 兩處、F37、F38 三處、F40 兩處。
  - 「拿掉準備時的空間檢查」先被既有的 `runningDownloadsKeepTheSpaceTheyStillNeed` 抓到；另外單獨確認新的 F25 測試在同一突變下也會失敗。
- 同步：開始批次 3 時，遠端已被其他 session 推進到 `f39c7d86`。批次 3 的改動先 stash，用 `git pull --no-rebase` 合併（merge commit `1c31013f`，沒有衝突），再放回改動。
  - 原本的 task guard session 尚未 commit，手動把它的狀態標為 abandoned。
  - 新 session 以 `--adopt-dirty` 收進這些改動。

## 下一步

- 依使用者指示把 40 項清單寫進 `docs/IOS-POC-47-offline-downloads.md`，更新 `docs/current-task-state.md` 與 `docs/IOS-POC-49-offline-cellular-download-all.md`，接著發布。IOS-POC-53 已完成，見 `docs/IOS-POC-53-storage-cleanup-reset.md`。
