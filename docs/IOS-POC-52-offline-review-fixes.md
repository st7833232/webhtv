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

### 3.1 macOS 驗證（IOS-POC-52-7，2026-10-05，本機）

環境：macOS 27.0、Xcode 27.0（27A266a）、Swift 6.4，基準 `2a887925`。只改測試檔，正式程式碼沒有改動。

- **`swift test` 第一次在 macOS 編譯失敗**，兩個都是 IOS-POC-52 測試留下的問題。雲端 Linux 的 131／131 用的是臨時套件，沒有包含這兩個檔案，所以沒抓到：
  1. `Favorites/FavoriteOwnershipTests.swift:37` 少了 `try`：第 6 批（`8b5ba5e4`）把 `startSimpleDownload` 改成 throws，這個呼叫點沒跟著改。
  2. `AggregateSearchTests.swift` 的 `private actor Gate`，與第 2、3 批在 `Offline/OfflineTestSupport.swift` 新增的 internal `actor Gate` 重複宣告（invalid redeclaration）。兩者行為相同（等待時不理會取消），刪除 `AggregateSearchTests` 的那份，改用共用的。
- **修正後完整 `swift test`**：998 個測試，993 通過、5 失敗。
  - 指定確認的 `OfflineReviewFixTests`、`OfflineManagerTests`、`OfflineSelectionTests`、`StorageMaintenanceTests` 全部通過，`OfflineMediaServerTests` 也通過。
  - 5 個失敗都與 IOS-POC-52／53 無關，本次沒有修：
    - `FavoriteAppWiringTests` 2 個：直接比對 App 原始碼字串（`LibrarySection.initial`、`.pickerStyle(.segmented)`、`Label("立即播放", …)`），IOS-UI-A2／A3 重寫片庫與詳情頁後就過時了。
    - `MediaSnifferTests` 3 個（IOS-POC-45I 的 WKWebView 字幕嗅探）：重跑一次結果相同，是穩定失敗。其中兩個的字幕名稱變成亂碼（「繁體中文」變成「蝜��銝剜�」）；`capturesASubtitleRequestedJustAfterTheMediaURL` 則找不到 media URL。同檔其他 WKWebView 測試都通過。45I 之前只在 Linux 跑過（Linux 不編譯這些測試），這是第一次在 Darwin 上執行。
- **本機 Xcode 建置**：`xcodebuild -scheme WebHTVApp -configuration Release -sdk iphoneos -destination generic/platform=iOS`（不簽章，參數與 release workflow 相同）**BUILD SUCCEEDED**，1 分 22 秒。47 個 warning 都不在 `Offline/`、`StorageMaintenance` 或這次改動的行（抽查 `WebHTVApp.swift` 的兩處，blame 是 2026-09-16 的舊碼）。本機是 Xcode 27，CI 是 Xcode 26.6；CI 版本的編譯證據是 `0.1.66 (67)` 的 release run `37258480859`。
- **Darwin-only 路徑**：
  - **F22**（`OfflineDownloads.manager` 的字幕服務）：程式確認 `OfflineRuntime.swift` 的 manager 用 `SubtitleDownloadService(fetch: SubtitleHTTP.fetcher(session: OfflineHTTP.subtitleSession))`。新測試 `offlineSubtitleRedirectsKeepTheSourceCredentialsOnItsOrigin` 用本機 HTTP 伺服器實際轉址（`127.0.0.1` → `localhost` 視為跨主機），走的就是這個 fetcher：跨主機時 Cookie 與 Authorization 被拿掉、User-Agent 與 Referer 保留；同源時兩者都保留。
    - 平台事實：不套 policy 的 URLSession（ephemeral）在 macOS 27 上，跨主機轉址會**自己**拿掉 Authorization，但手動設定的 Cookie 照樣帶到另一個主機；同源轉址也會掉 Authorization，是 policy 把它補回去的。iOS 17／18 的行為未驗證，所以 policy 兩個都處理是必要的。
  - **F36**（`OfflineHTTP.fetcher` 的串流截斷）：新測試 `theFetcherStopsReadingAtTheLimit`，伺服器不理 Range、送出 256 MB。fetcher 只保留 `probeLimit`（64 KB）、標記 `truncated`，伺服器在連線關閉前送出的量不到總量的四分之一；剛好 64 KB 時不標記截斷。
  - **F29**（`URLSessionOfflineTransport` 的取消計數）：沒有寫測試。要確定性地重現「submit 進行中被取消」，必須在正式程式加注入點；而且建立 transport 必定會建立固定 identifier 的 background session，不適合在測試程序裡建立。改用 scratchpad 小程式在 macOS 27 的 default session 實測兩個前提：
    - 剛建立、還沒 `resume()` 的 task **不會**出現在 `allTasks`，等 300 ms 也不會；resume 之後才會出現。
    - 先 `cancel()` 再 `resume()` 不會重新開始（狀態 completed，錯誤 -999）。
    - 推論：`submit` 在鎖內建立 task、出鎖後才 `resume()`。`cancel(assetID:)` 若剛好在這兩步之間遞增計數並列出 tasks，就會漏掉這個 task，之後它照樣被 resume。程式註解「cancel 在後的話會在 session 的 tasks 裡找到它」不成立。實際上，manager 的 `cancelIfStale`（F3）在 submit 結束後，會取消已被暫停或刪除的那批（這時 task 都已 resume，找得到），所以使用者層面由 F3 補住。最小修正是把 `task?.resume()` 移進同一個 `lock.withLock`（resume 不會同步呼叫 delegate，不會死結），並改正註解。這是正式程式修改，**等使用者決定**。background session 的 `allTasks` 行為未實測。
- **突變**（暫時修改正式程式後用 `git checkout` 還原）2／2 被抓到：
  - `subtitleSession` 拿掉 `SubtitleRedirectPolicy` → F22 測試失敗（跨主機帶出 Cookie、同源掉 Authorization）。
  - fetcher 超過上限後不停止讀取（`break` 改成 `continue`）→ F36 測試失敗（伺服器送完 268,435,456 bytes）。
- 新增測試檔：`ios/Tests/WebHTVCoreTests/Offline/OfflineDarwinTests.swift`（`#if canImport(Network)`，Linux 不編譯）。修改後再跑 `OfflineDarwinTests` 2／2 通過。
- 未驗證：真機、iOS 模擬器、background session 的實際行為（喚醒、續傳、取消）。
- Ponytail（`ponytail:ponytail-review`，本次測試 diff）：一項 yagni（`url(_:host:)` 沒用到的 `host` 參數），已套用；其餘 Lean already。

- Ponytail：本文件與 6 批 commit 都沒有記錄（2026-10-05 文件同步時補記）。同一 session 的 IOS-POC-53 記為 `unavailable / skipped`，所以當時的 runtime 可能沒有 Ponytail，但本任務沒有留下紀錄，不能據此認定。目前本機環境有 Ponytail，可以對 `db9618bd..8b5ba5e4` 中 IOS-POC-52 的程式 diff 補跑。

## 4. F11、F12、F35 後續設計（IOS-POC-52-8，提案，**未實作，待使用者核准**）

依 AGENTS.md 第 7 節。2026-10-05 查證，三個子題各由一個子代理讀原始來源；F35 另在 iOS 26.0 模擬器與本機 loopback 伺服器上實測。來源等級：A＝Apple／FFmpeg／mpv 官方文件，B＝Apple 工程師（Quinn）或維護者的論壇文章，C＝成熟專案程式碼，D＝社群文章。存取日期都是 2026-10-05。上游播放器的 commit、論文與效能基準不適用：這三項沒有引入或更新任何依賴，也沒有改變編解碼或渲染。

### 4.1 F11：背景喚醒的處理時間

**問題**：iOS 為了背景下載 session 的事件喚醒 App 時，App 要把事件處理完（搬檔、寫紀錄、完成一集並重寫播放清單），再呼叫系統的 completion handler。目前的部分修正，是先等 `settle()`（下一集準備，最多 20 秒），才呼叫 completion handler（`URLSessionOfflineTransport.attach` 的 `.drained`）。

**現況**：`OfflineAppDelegate`（`WebHTVApp.swift`）只保存 handler，沒有 `beginBackgroundTask`。`OfflineDownloadManager.settle()` 每 200 ms 檢查一次，最多 20 秒。

**查證**

| 來源 | 等級 | 結論 |
|---|---|---|
| developer.apple.com/documentation/foundation/downloading-files-in-the-background | A | 保存 handler，在 `urlSessionDidFinishEvents` 裡於主執行緒呼叫；背景中建立的 task 會被延後（"the task doesn't begin until the delay expires"） |
| …/urlsessiondelegate/urlsessiondidfinishevents(forbackgroundurlsession:) | A | 可以先做內部更新再呼叫 handler；handler 要在主執行緒呼叫 |
| …/uiapplication/beginbackgroundtask(withname:expirationhandler:)、…/extending-your-app-s-background-execution-time | A | 盡量在進入背景前就開始；每個 begin 都要有對應的 end；可能回傳 `.invalid` |
| developer.apple.com/forums/thread/85066（Quinn，UIApplication Background Task Notes，2023-06-16 修訂） | B | 整個 App 共用約 30 秒；expiration handler 要在約 1 秒內 end；沒 end 的 task 會讓 App 被以 0x8badf00d 終止 |
| developer.apple.com/forums/thread/74730、806116、103396（Quinn） | B | 喚醒期間由 power assertion 維持，呼叫 handler 就釋放；背景傳輸本身不需要 background task；工作中途被暫停也沒關係，只要能接續 |
| developer.apple.com/forums/thread/14854（Quinn） | B | 背景中建立的 task 會被視為 discretionary，延遲每次喚醒加倍；建議一次送出一批 |
| Alamofire 4.9.1 `SessionManager.swift`；Tiercel @2c025a79 `SessionManager.swift` | C | 都是事件送達後立刻呼叫 handler，都沒有用 `beginBackgroundTask`；Alamofire 5 已不支援背景 session |

未查到：Apple 沒有公布喚醒的確切秒數（唯一的數字是 2018 年開發者自己量到的約 30 秒）；background task 的時間能不能疊加在喚醒時間之上，也沒有資料。

**方案比較**

| 方案 | 內容 | 評估 |
|---|---|---|
| 不改 | 繼續把 handler 延到 settle 之後 | 不符合文件的順序：等下一集的網路準備，不屬於「處理完事件」；延到 20 秒也沒有任何保證 |
| 直接照提案 | 在現有流程外再包一層 `beginBackgroundTask` | 能多拿一點時間，但 handler 仍然延後，順序問題沒解決 |
| **WebHTV 調整版（建議）** | handler 在送達的事件處理完後**立刻**呼叫；settle 改由 background task 保護 | 符合文件順序，也提供額外的處理時間。被暫停也安全：準備中的下載有 generation 保護，暫存檔在下次啟動時會被接手（F11 已實作的 `OfflineStagedBody`） |

**建議做法（實施）**
1. Core `URLSessionOfflineTransport`：`.drained` 時先在主執行緒呼叫 handler，再 `await settle()`，最後呼叫 App 提供的 `afterSettle` closure。
2. App `OfflineAppDelegate`：在 `handleEventsForBackgroundURLSession` 開頭呼叫 `beginBackgroundTask(withName: "offline-wake")`，回傳 `.invalid` 時照常繼續。
   - 用一個只會執行一次的 `end()` 結束 task。settle 完成、20 秒到期、expiration 三條路徑中，先發生的那條呼叫它。
   - expiration handler 只呼叫 `end()`，不等待網路。
   - 重疊的喚醒各自有自己的 task ID。
3. 不使用 `backgroundTimeRemaining` 決定任何事。

**風險**
- 忘記 end 會導致 0x8badf00d：由只執行一次的 `end()` 加上測試涵蓋。
- 多出來的時間沒有保證。
- 下一集的 task 在背景送出，仍會被頻率限制延後；這一點 `beginBackgroundTask` 改變不了。在前景時預先送出更多集可以減少影響，但網址可能會過期，所以不在本項範圍。

**驗收標準**
- Core／macOS 單元測試：
  - 呼叫順序是「事件處理完 → handler → settle → `afterSettle`」，handler 只被呼叫一次；
  - settle 卡住時，`afterSettle` 也只會在 20 秒到期時被呼叫一次。
- App 端 background task 的 begin／end 包成一個小型 helper，單元測試覆蓋三條結束路徑，並確認 `end()` 只執行一次。
- 真機（未驗證項目，需使用者協助）：鎖定螢幕下載多集，Console 看到 `offline-wake` 的 begin／end 成對出現，沒有 0x8badf00d。

**Rollback**：revert 該 commit 就回到目前「handler 等 settle」的行為；沒有資料格式變更。

### 4.2 F12：本機伺服器換 port 時重建已載入的離線 HLS

**問題**：App 暫停後，本機伺服器如果換了 port，已載入的播放項目仍然指向舊 port，所有 segment 都讀不到，要關掉再重開那一集。

**現況**
- `OfflineMediaServer.start()`：listener 還是 `.ready` 時直接沿用；否則優先用原本的 port 重開，失敗才換 port。token 在同一個程序內固定，所以變的只有 port。
- `reloadPaused` 與鎖定畫面的「播放」，都會先 `await server.start()`，但之後仍用舊網址：`router.reload(at:autoplay:)` 沿用原本 request 的 target，「播放」則直接呼叫 `engine.play()`。
- 安全網：離片長還有 5 秒以上的檔尾不算看完。這可以擋住 mpv 在 segment 讀不到時一路跳到檔尾的誤判。

**查證**

| 來源 | 等級 | 結論 |
|---|---|---|
| developer.apple.com/library/archive/technotes/tn2277（2011-03-30） | A | 進背景時關閉 listening socket、回前景再開；資源可能被系統收回 |
| developer.apple.com/forums/thread/840808（Quinn，2026-08） | B | 沒註冊 Bonjour 的 `NWListener` 被暫停後**不會**失效，恢復後能繼續接受連線；播放音訊期間 App 不會被暫停 |
| developer.apple.com/forums/thread/129452（Quinn，2020～2022） | B | 實機上 `allowLocalEndpointReuse` 無效（FB8658821）；同 port 重開會 EADDRINUSE，大約 1 分鐘後才恢復；到 2022-02 還沒修好 |
| GCDWebServer（master，2023 封存）、KTVHTTPCache @388da9af、Swifter @1e4f51c9 | C | 進背景就停、回前景再開（預設 port 0，會換 port），或先 ping 自己、不通才重開；**都沒有**在換 port 後重建已載入的 player |
| AVFoundation `replaceCurrentItem`、`AVPlayerItem.status`／`.failed`、`select(_:in:)`、`AVMediaSelectionOption.propertyList()`；QA1820 | A | `.failed` 的 item 不能再用；換 item 後要等 ready 再 seek；音軌／字幕選擇要透過 propertyList 對應到新的 asset |
| mpv `DOCS/man`（input／options.rst）@c1529642 | A | `loadfile … replace` 可以帶 `start=`、`pause` 跨檔保留；`sub-add` 的外掛字幕換檔後要重新加 |
| FFmpeg `libavformat/hls.c` @a35c8799 | C | segment 開不起來時，`seg_max_retry`（預設 0）次之後就跳過 |
| developer.apple.com/forums/thread/113063（Apple 工程師） | B | resource loader 對 segment 只接受「redirect 到 HTTP」，所以自訂 scheme 仍需要 server |

未查到：AVPlayer 在 segment 主機拒絕連線時的確切行為沒有官方文件；FB8658821 在 iOS 17～26 是否已修好不明；VLC／Telegram 的本機 server 沒有查。

**發生條件（很窄）**：listener 真的失效（依 Quinn 的說法，沒有 Bonjour 時通常不會），**而且**同 port 重開失敗（最可能是上面那個 reuse bug，在約 1 分鐘內重開），或那個 port 被別的程序佔用。

**方案比較**

| 方案 | 內容 | 評估 |
|---|---|---|
| 不改 | 換 port 時讓播放失敗，使用者重開那一集 | 重開時 `OfflineDownloads.playbackSource` 會拿到新網址，所以能自行恢復；誤判看完有安全網擋著。代價是極少數情況下要手動重開 |
| 直接照提案 | 換 port 時，對兩個引擎重建 item，並自行還原位置、播放／暫停、音軌字幕 | 沒有任何成熟函式庫這樣做；如果另寫一套，重複既有的 reload 機制 |
| **WebHTV 調整版（建議）** | 沿用既有的 `router.reload` 路徑，只把 target 網址換成新的 base | 位置、播放意圖、音軌字幕還原（`tracksToRestore`）、外掛字幕（router 持有、mpv 載入時重新加入）都已由 reload 處理，新增的程式很少 |
| 另一種 | 改用 BSD socket 加 `SO_REUSEADDR`，避開 reuse bug，盡量不換 port | 範圍較大（重寫 server 的 listener 層），而且 port 被佔用時仍需要 fallback。**不建議** |

**建議做法（實施，優先度低）**
1. Core `PlaybackRouter`：新增 `reload(at:autoplay:url:)`，只替換 `request.target.url`，其餘照舊。
2. Core 新增純函式 `OfflinePlaybackSource.rebased(to:)`：舊網址的 base 換成新的 base，結構不符時回傳 nil。
3. App `reloadPaused`：`server.start()` 回傳的 base 如果和 `offlineSource.url` 不同，就更新 `offlineSource`，以新網址 reload。
4. App 鎖定畫面的「播放」：base 變了時改為在目前位置以新網址 reload（autoplay），否則照舊 `play()`。
5. 換 port 時寫一行 log。

**風險**
- 這個情境幾乎無法在真機上刻意重現，App 端的接線只能靠編譯與程式檢查。
- `load(_:)` 用 `offlineSource?.url == url` 判斷是不是離線集數，所以必須先更新 `offlineSource` 再 reload，否則會觸發「換集」的釋放與自動刪除。

**驗收標準**
- Core 單元測試：
  - `reload(at:autoplay:url:)` 只改網址，位置、速度、autoplay、exactStart 都保留；
  - `rebased(to:)` 只換 base，結構不符時回傳 nil。
- App：本機 Xcode Release 建置通過。
- 真機（未驗證項目）：一般的暫停、背景、恢復沒有變化。換 port 的情境沒辦法實測，要寫明。

**Rollback**：revert 該 commit。沒有資料格式變更。

### 4.3 F35：探測單一檔案與沒有 master 的播放清單的實際解析度

**問題**：單一檔案，以及沒有 master 的 HLS 媒體清單，都不知道解析度，可能下載到超過 1080p 的檔案；紀錄上也沒有解析度與編碼。

**現況**
- 表單和「全部下載」都經過 `OfflineDownloadManager.options(for:)`：單一檔案走 `OfflineOptionsBuilder.progressive`，媒體清單會被包成一個沒有解析度的 variant，兩者都是 `resolutionUnknown`。
- 紀錄本來就有 `OfflineAsset.video: OfflineVideoInfo?`（寬、高、編碼），由 `prepared.video` 寫入；`WebHTVApp.swift` 的下載列與詳情已經會顯示 `asset.video?.summary`。所以只要把探測結果放進 `prepared.video`，畫面不用改。
- App 播放時，已經用非公開的 `AVURLAssetHTTPHeaderFieldsKey` 把 header 帶給 AVPlayer（`WebHTVApp.swift` 的 `asset(for:headers:)`）。

**查證與實測**

| 來源 | 等級 | 結論 |
|---|---|---|
| developer.apple.com/documentation/avfoundation/avurlasset-initialization-options、…/avurlassethttpuseragentkey（iOS 16+）、…/avurlassethttpcookieskey | A | 公開的 key 只有 UA 與 Cookie，**沒有** `AVURLAssetHTTPHeaderFieldsKey` |
| developer.apple.com/forums/thread/20421（Apple 工程師，2024-10） | B | 那個 key 是 "not a supported API"，建議改用 `AVAssetResourceLoader` |
| …/avassettrack/naturalsize（iOS 16 起改用 `load(.naturalSize)`）、…/cmvideoformatdescriptiongetpresentationdimensions | A | 尺寸與編碼的讀法；`naturalSize` 不會套用旋轉 |
| …/avplayeritem/presentationsize | A | ready 之前可能是 0，必須真的播放 |
| mpv `options.rst`／`input.rst`／`client.h` @c1529642 | A | `vo=null`、`frames=0`、`demux-w／h` 是容器提供的提示值（"Not always accurate"）；文件沒說明多個 core 並存是否安全 |
| ffmpeg.org/ffmpeg-formats.html、doxygen `avformat_find_stream_info` | A | probesize 預設 5,000,000 bytes，analyzeduration 預設 5 秒 |
| yt-dlp @51bab8a0 README、`extractor/generic.py` | C | 直連影片**不探測**，格式沒有 height；`height<=?1080` 會放行尺寸未知的來源，等同目前「未知就下載並提示」 |
| 實測（iOS 26.0 模擬器、本機 loopback，測試片 2560×1440） | 實測 | MP4／MOV（H.264、HEVC）讀到 2560×1440 與 `avc1`／`hvc1`。moov 在檔尾時用 Range 跳到檔尾，總共約 35～90 KB；faststart 的 open-ended 請求在取消前送出約 1 MB。iOS 上 MKV、FLV、單獨的 TS 都是 -11828（打不開），但 macOS 打得開 TS，**不能用 Mac 的結果推論 iOS**。HLS 的 `.m3u8` 拿不到軌道；fMP4 的 init segment 只要 1,355 bytes 就讀到尺寸與編碼。ffprobe 對 TS 要讀約 4.7 MB |

未驗證：libmpv 探測沒有實際跑；真機沒有測。

**方案比較**

| 方案 | 涵蓋範圍 | 成本 | 評估 |
|---|---|---|---|
| 不改 | 無 | 0 | 目前表單已明確提示可能超過 1080p |
| 直接照提案 | 以 AVURLAsset 讀所有單一檔案與媒體清單 | — | iOS 打不開 TS／MKV／FLV，`.m3u8` 也讀不到軌道，涵蓋不到提案的範圍 |
| **WebHTV 調整版（建議）** | AVFoundation 只處理 MP4／MOV／M4V，以及 fMP4 媒體清單的 init segment；其餘維持「未知＋提示」 | 每次表單或每集多一次小探測：約 35～90 KB，最多約 1 MB；設 10 秒上限 | 可以放在 Core（`canImport(AVFoundation)`），以注入方式提供，Linux 測試用假的探測器 |
| libmpv 無頭探測 | 涵蓋所有格式 | 0.1～7 MB、0.1～1.6 秒 | 只能放在 App target；跟播放中的 mpv core 並存有風險。只有 TS／MKV 的單檔來源真的常見時，才值得另外評估 |

**建議做法（實施）**
1. Core `OfflineDownloadManager.Dependencies` 新增 `videoProbe`：輸入網址與 header，回傳 `OfflineVideoInfo?`，失敗或逾時回傳 nil。
2. Darwin 的實作：
   - **單一檔案**：用 `AVURLAsset` 載入第一條影像軌的 `naturalSize`、`preferredTransform` 和 `formatDescriptions`，取得 FourCC 並對應到 `OfflineVideoCodec`。header 的帶法與播放相同（同一個非公開 key；播放能用，探測就能用，不會多出新的相依）。
   - **fMP4 媒體清單**：init segment 用既有的 `OfflineHTTP.fetcher` 下載，所以會照 `OfflineRequestPolicy` 帶 header。寫入暫存檔後，用本機檔案開 `AVURLAsset`。
   - **TS 分段、MKV、FLV，或打不開的檔案**：回傳 nil。
3. `options(for:)`：
   - `.progressive` 與 `.media` 先探測。超過上限就回傳拒絕（`.unsupported`，「影片解析度 W×H 超過 1080p」）。
   - 不超過上限時，把探測結果填進 `option.video`，`resolutionUnknown` 改為 false，表單就會顯示實際解析度。
   - 探測結果為 nil 時，維持現在的提示。
4. `build`：單一檔案與媒體清單的 `prepared.video` 用探測結果，紀錄就有寬、高與編碼，現有畫面會自動顯示。

**待使用者決定**
1. **旋轉**：直立片（例如 1080×1920）算不算 1080p？建議與方向無關：長邊 ≤ 1920 且短邊 ≤ 1080。注意：目前 HLS master 的判斷是寬 ≤ 1920 且高 ≤ 1080，兩者是否要一致，需要一起決定。
2. **未知時**：維持放行並提示（等同 yt-dlp 的 `<=?`，建議），或改成嚴格拒絕。
3. **header**：探測沿用播放已在用的非公開 key（建議，與播放一致），或者單一檔案只帶 UA／Cookie 的公開 key，代價是需要 Referer 的來源會變成「未知」。

**風險**
- 打開表單會多一次網路探測，最多 10 秒，結束前表單維持在「讀取中」。
- 伺服器不支援 Range 時，faststart 以外的檔案可能讀更多才取消。
- 非公開 key 在未來的 iOS 版本可能失效；那時探測會回傳 nil，回到目前的行為，播放也會一起受影響。

**驗收標準**
- Core 單元測試，使用假的探測器：
  - 超過 1080p 被拒絕，表單與「全部下載」都是；
  - 不超過 1080p 時，表單有解析度，紀錄的 `video` 有寬、高與編碼；
  - 探測器回傳 nil 時，行為與現在相同；
  - 逾時時回傳 nil。
- macOS 測試：本機伺服器提供一個小的 MP4 fixture，加上一個 fMP4 init segment，讀回正確的尺寸與編碼。
- iOS 模擬器：至少跑一次 Darwin 探測測試，因為 iOS 與 macOS 支援的容器不同。
- 真機（未驗證項目）：一個超過 1080p 的 MP4 來源被拒絕；一個 1080p 以下的來源，表單和下載列都顯示解析度。

**Rollback**：revert 該 commit。`OfflineAsset.video` 本來就是 optional 欄位，已寫入的紀錄在舊版本仍可讀，不需要遷移資料。

## 下一步

- 未決、等使用者決定：F11（背景執行時間）、F12（換埠時重建播放項目）、F35（探測實際解析度）只做了一部分，未做的部分是否另開任務（同 `docs/current-task-state.md` 最上方交接）。
- 未決、等使用者核准（IOS-POC-52-8，見第 4 節）：F11（handler 提前呼叫，settle 改由 background task 保護）、F12（沿用 reload 路徑，換 port 時換網址重載，優先度低）、F35（AVFoundation 只探測 MP4／MOV 與 fMP4 init segment；另有旋轉、未知時政策、header 三個決定）。
- 未決、等使用者決定（IOS-POC-52-7 發現，見 3.1）：F29 傳輸層的空窗（把 `resume()` 移進鎖內）；`FavoriteAppWiringTests` 2 個過時的期望值；`MediaSnifferTests` 3 個穩定失敗（IOS-POC-45I）。

- 40 項清單、處置、commit 與驗證已寫進 `docs/IOS-POC-47-offline-downloads.md` 第 15 節，`docs/current-task-state.md` 與 `docs/IOS-POC-49-offline-cellular-download-all.md` 已同步更新。
- 已隨 `0.1.66 (67)` 發布（含 IOS-POC-53；run `37258480859`，tag `ios-v0.1.66-b67`），見 `docs/IOS-POC-11-sidestore-release.md` 第六十七次發布。真機未驗證。IOS-POC-53 已完成，見 `docs/IOS-POC-53-storage-cleanup-reset.md`。
