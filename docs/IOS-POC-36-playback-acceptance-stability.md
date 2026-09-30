# IOS-POC-36 — Playback Acceptance & Stability Consolidation

**狀態（2026-09-30）**：開發完成，只剩真機驗收（PL-14 刻意不修，見第九節）。D1～D7（第八節）已隨 `0.1.39 (40)` 發布，`0.1.40 (41)` 亦包含；36.1（loop 路徑也只處理一次結束＝D8、矩陣證據稽核，第十四節）已隨 `0.1.41 (42)` 發布。矩陣 107 項：`REAL_DEVICE_PASS` 1、`SIMULATOR_PASS` 47（36C 實測 44 項，其餘 3 項沿用 17F／25）、`AUTOMATED_PASS` 27、`RELEASE_BUILD_ONLY` 17、`UNVERIFIED` 12、`KNOWN_LIMITATION` 2、`DEFECT` 1。**D1～D8 都沒有真機驗證。**

## Recovery anchor

- 目標：AVPlayer＋MPV 既有功能的正式 acceptance baseline，修掉找到的 root cause，不新增第三核心、不擴充功能。
- 範圍：`ios/Sources/WebHTVCore`、`ios/WebHTVApp/Sources`、`ios/Tests/WebHTVCoreTests`、`docs`。task guard `IOS-POC-36`（`standard`）。
- 工作位置：36A～36D 在獨立 worktree `/Users/chengchenchih/GIT/webhtv-ios36`（本機分支 `ios-poc-36`，已 push 到 `origin/ios-poc`），因為當時主 checkout 有另一個 session 的 task guard；36.1 在主 checkout `/Users/chengchenchih/GIT/webhtv`（task guard `IOS-POC-36.1`，`quick-fix`）。模擬器用 `05934376-5757-40E5-9FAF-202594565656`（iPhone 17 Pro Max、iOS 26.3），不碰另一個 session 的 `E0A41D48`。
- 已完成：第四節矩陣（107 項，36.1 重新稽核證據強度）、第八節 D1～D8 修正與測試、第六節模擬器證據。
- 未驗證：全部真機項目（第十節）；D7（切換瞬間 0:00）只有 build 證據；D8 只有單元測試與 build（已隨 `0.1.41 (42)` 發布）。
- 回滾：`git revert <本任務 commit>`（36 是 `2840c2e4`，36.1 是它自己的 commit）；只有 Swift 原始碼、測試與文件，沒有二進位、lock 或設定變更。
- 下一步（唯一）：使用者在 `0.1.41 (42)`（含 D1～D8）上跑第十節的清單，結果逐項填回第四節。

## 一、起始狀態

- 2026-09-30 13:55 CST `git fetch`：本機 `59d51115`，`origin/ios-poc` `49f30020`（落後 1，CI 發布 `0.1.38 (39)` 的 `source.json`）；fast-forward 到 `49f30020`。worktree 有他人未 commit 的 `ios/Tests/WebHTVCoreTests/SourceClientTests.swift` 與未追蹤的 `ios/ScreenRecording_09-29-2026 19-40-54_1.mp4`，本任務沒有碰。
- 期間另一個 session 推了 `a1863e47`、`0f9b05cf`、`bc751293`（來源 sweep 與文件），本任務的 worktree 在 `0f9b05cf` 上重新開始 guard，commit 前再 rebase。
- 基準：`swift test` 578／578（9 秒）；模擬器 Debug build 通過（46 秒）。
- 閱讀：`AGENTS.md`、`docs/current-task-state.md`、IOS-POC-8L、14、15、16、17、17H、17I、21、22、23、24、25、26、27、29、35、2E、5P、5Q、5R、5S 全文，以及 `PlaybackEngine.swift`、`PlaybackActivity.swift`、`PausedBackgroundReload.swift`、`PictureInPictureForegroundRestoreState.swift`、`HLSAdSkip.swift`、`WatchHistory.swift`、`MPVEngine.swift`，與 `WebHTVApp.swift` 的 `VodView`、`PlaybackSession`、`AVPlayerEngine`、`PlayerControlBar`、`PlayerSurface`、`PlayerView`。IOS-POC-37～37.3.1 沒有重做；36 的測試沒有看到它們造成播放器問題。

## 二、架構現況

- **Core（`swift test` 覆蓋）**：`PlayerRouter`／`PlaybackEngineSelection`（選哪個核心、每個 attempt 最多換一次）、`PlaybackFailure`（分類）、`PlaybackStartupWatch`（開播逾時只算想播的時間）、`PlaybackActivity`（按鍵與轉圈）、`PausedBackgroundReload`（暫停中被暫停執行）、`PictureInPictureForegroundRestoreState`、`HLSAdPlanner`／`HLSAdSkipper`（兩個核心共用的去廣計畫與決策）、`WatchHistory`（續播、片頭片尾）、`PlaybackTargetPrefetch`（下一集預解析），以及本任務的 `PlaybackEndGate`。
- **App（只有 build 與模擬器證據）**：`PlaybackSession`（resume、片頭片尾、auto-next、預解析、緩衝策略、去廣迴圈、開播監看、背景／前景、音訊工作階段）、`AVPlayerEngine`、`MPVEngine`／`MPVPlayerCore`／`MPVPictureInPicture`、`PlayerView`／`PlayerControlBar`、`VodView`（擁有集數清單、`playNext`、上一集／下一集）。
- 資料流：`VodView` 解析 → `PlaybackSession.open` → `load` → `PlayerRouter.open` → engine `load`；engine 回報 `onFailure`／`onEnded` → router 分類／換核心，或交給 session 的 `finished`。切換時 router 帶著同一個 `PlaybackLoadRequest`（target、headers、history、速度），位置取 engine 當下回報的值。

## 三、歷史 POC 對應

| POC | 內容 | 與本任務的關係 |
|---|---|---|
| 14／14A／14B | auto-next、速度沿用同一部片 | SH、AV-19；D1 修的是它的交接 |
| 15／15C／15D | 緩衝策略、下一集預解析 | SH-11 |
| 16／16B | 自建控制列、panel | UI；D6 改 ±10 秒的基準 |
| 17／17B～17F | 雙核心、router、fallback、開播逾時 | DE；D4、D5 修它的交接契約 |
| 17H／17H-2～4 | MPV PiP | MPV-10～13、PL；本任務只改 PiP 的播放／暫停路徑 |
| 17I | MPV 旋轉（自建 Libmpv） | MPV-08／09（真機未驗） |
| 21 | 換集從頭 | SH-02 |
| 22 | 2.5×／3× 交給 MPV | AV-08 |
| 23 | 暫停後背景 | AV-13、PL-05；其 §十之2 的兩個風險就是 D3、D4 |
| 24 | 音訊工作階段由 App 擁有 | MPV-19／20、PL；中斷改走 `control("pause")` |
| 25／25-2／25-4／25-5 | HLS 去廣 | AD；本任務改了 MPV 的位置回報，所以全部重測 |
| 26 | 切換位置、MPV seek | RC2＝D5、RC4＝D7 |
| 27 | 開播逾時 5 秒、按鍵意圖 | AV-09／10 |
| 29 | 預設速度 | AV-07 |
| 35 | 上一集／下一集、立即播放 | SH-03 |
| 5R／5S | 觀看記錄、片頭片尾 | SH |

## 四、Acceptance matrix

狀態只用七種：`REAL_DEVICE_PASS`（使用者真機確認）、`SIMULATOR_PASS`（模擬器或 Mac 上實際觀察）、`AUTOMATED_PASS`（單元測試或 CI 比對）、`RELEASE_BUILD_ONLY`（只有編譯）、`UNVERIFIED`、`KNOWN_LIMITATION`、`DEFECT`。「有程式碼」不算驗證，模擬器不算真機。「36 前」是各 POC 文件最新紀錄的最強證據；已修但只有發布 build 的，記 `RELEASE_BUILD_ONLY`。

總數與分佈：

| 狀態 | 36 前 | 36 後 |
|---|---|---|
| REAL_DEVICE_PASS | 1 | 1 |
| SIMULATOR_PASS | 24 | 47 |
| AUTOMATED_PASS | 30 | 27 |
| RELEASE_BUILD_ONLY | 15 | 17 |
| UNVERIFIED | 29 | 12 |
| KNOWN_LIMITATION | 2 | 2 |
| DEFECT | 6 | 1 |
| 合計 | 107 | 107 |

36.1 稽核前兩欄是 15／22／26／7／29／2／6 與 15／42／26／9／12／2／1；原本的 15 項 `REAL_DEVICE_PASS` 有 14 項降級，規則與逐項原因在第十四節之 3。



### AVPlayer（19 項）

| ID | 核心 | 項目 | 36 前 | 36 後 | 證據 |
|---|---|---|---|---|---|
| AV-01 | 原生 | 首次開播 | SIMULATOR_PASS | **SIMULATOR_PASS** | 36.1 降級：真機 8L §7.1（`0.1.1 (2)`～`0.1.2 (3)`，當時只有原生）之後開播路徑改過（17 router、26-1 精確起點、27A 5 秒逾時、36 D2），不算目前程式的真機證據；25 §23 與 36C 模擬器：F 在 499～1563 ms 開播（`[playback] started … on 原生`） |
| AV-02 | 原生 | play／pause | AUTOMATED_PASS | **SIMULATOR_PASS** | 36.1 降級：真機 23 T1～T3（`0.1.20 (21)`，兩個核心各一次）在 24-2（播放時才啟用音訊工作階段）、27A（按鍵改依意圖）、36 D4（播放／暫停通知 router）之前；36 前是 27A `PlaybackActivityTests`；36C 模擬器按鍵操作正常 |
| AV-03 | 原生 | ±10 秒 | UNVERIFIED | **SIMULATOR_PASS** | 36C：`seek requested 116.3s from 106.3s`→`landed 116.3s asked 116.3s` |
| AV-04 | 原生 | 任意 seek（落點精確） | UNVERIFIED | **SIMULATOR_PASS** | 36C：每次 `seek landed` 與要求值相同（零容差）；拖曳手勢本身沒有用工具操作，走同一個 `PlaybackSession.seek` |
| AV-05 | 原生 | 連續 seek（快速多次） | UNVERIFIED | **SIMULATOR_PASS** | 36C：0.8 秒內三次（最後兩次相隔 84 ms）106.3→116.3→126.3→116.3，以未完成的目標累加 |
| AV-06 | 原生 | seek 不回彈 | UNVERIFIED | **SIMULATOR_PASS** | 36C：前一個 seek 被取代時回報 `finished=false`、最後落點＝要求值；畫面逐格未量測 |
| AV-07 | 原生 | 0.5×／1×／1.5×／2× | RELEASE_BUILD_ONLY | **RELEASE_BUILD_ONLY** | 36.1 降級（整列取最弱的子項）：0.5× 沒有任何播放紀錄，只有 `needsOtherEngine(rate: 0.5)` 留在原生的單元測試；1.5×、2× 是 23 T7 真機通過但未分核心（`0.1.20 (21)`，之後 27B 依倍速放大預讀）；1.5× 另有 36C 模擬器（MPV→原生後保留）；1× 是一般播放 |
| AV-08 | 原生→MPV | 2.5×／3× 交給 MPV | SIMULATOR_PASS | **SIMULATOR_PASS** | 22 §七；36C：`at 3.0× — AVPlayer cannot play above 2×; moved to MPV`，從 22.0 s 精確接續、183 ms 後開播 |
| AV-09 | 原生 | buffering／stall／spinner 與按鍵意圖 | AUTOMATED_PASS | **AUTOMATED_PASS** | 27A `PlaybackActivityTests` 六條；真機 27 T1～T12 未回報 |
| AV-10 | 原生→MPV | 5 秒 startup timeout | AUTOMATED_PASS | **SIMULATOR_PASS** | 36C：每段 8 秒延遲，`not started on 原生 after 5s — trying MPV`，原因 `neverReady`，MPV 8.6 s 後開播，沒有第二次切換 |
| AV-11 | 原生 | AirPlay／PiP 中不被誤判 timeout（20 秒） | RELEASE_BUILD_ONLY | **RELEASE_BUILD_ONLY** | `watchStartup` 的 `presentedElsewhere`；iPhone 模擬器沒有 PiP、沒有 AirPlay 接收端 |
| AV-12 | 原生 | background audio（播放中離開 App） | RELEASE_BUILD_ONLY | **RELEASE_BUILD_ONLY** | 36.1 降級：23 T4 真機通過但未分核心（`0.1.20 (21)`）；之後 24-2 改由 App 在每次播放前啟用音訊工作階段，沒有再驗；模擬器沒做播放中進背景 |
| AV-13 | 原生 | 暫停後背景、回來 resume | RELEASE_BUILD_ONLY | **RELEASE_BUILD_ONLY** | 36.1 降級：真機 23 T1～T3（`0.1.20 (21)`，原生一次，走暫停執行後 reload）在 24-2（回來不啟用工作階段、播放時才啟用）與 36 D4／D7 之前；36C 模擬器只驗到沒被暫停執行的返回（仍暫停、同一格），reload 路徑在目前程式只有 build |
| AV-14 | 原生 | PiP 進出 | RELEASE_BUILD_ONLY | **RELEASE_BUILD_ONLY** | 36.1 降級：23 T5 真機通過但未分核心（當時 MPV 也有 PiP，不能算原生的）；原生 PiP 程式在 `0.1.20 (21)` 後只加了 36 的 `[pip] native` log；iPhone 模擬器沒有 PiP |
| AV-15 | 原生 | 音軌／字幕切換 | RELEASE_BUILD_ONLY | **RELEASE_BUILD_ONLY** | 36.1 降級：23 T8 真機通過（重新載入後保留）但未分核心；「重新載入後選回」有 `reselections(after:)` 單元測試，原生的切換本身只有 build |
| AV-16 | 原生 | 畫質切換 | AUTOMATED_PASS | **AUTOMATED_PASS** | `theQualityChoiceStartsRememberedAndOpensTheResolvedDefault`；設定檔沒有多畫質來源，UI 從未被真實資料觸發 |
| AV-17 | 原生 | 片頭（opening） | AUTOMATED_PASS | **AUTOMATED_PASS** | 5S-2 `WatchHistoryOpeningEndingTests`；真機 8L ③ 未回報 |
| AV-18 | 原生 | 片尾（ending） | AUTOMATED_PASS | **AUTOMATED_PASS** | 5S-2 測試＋36 `PlaybackEndGate` 兩條＋36.1 loop 三條 |
| AV-19 | 原生 | auto-next | SIMULATOR_PASS | **SIMULATOR_PASS** | 36.1 降級：真機 8L §7.1（`0.1.1 (2)`～`0.1.2 (3)`，當時只有原生）與 23 T10（`0.1.20 (21)`，未分核心）都在 35（上一集／下一集）與 36 D1／D2 改交接之前；36 前是 15C／21 的模擬器；36C：F→G（預解析 0 ms）、G→H（即時解析）。36.1 只改 loop 路徑，非 loop 的交接語意不變（D1 兩條測試） |

### MPV（20 項）

| ID | 核心 | 項目 | 36 前 | 36 後 | 證據 |
|---|---|---|---|---|---|
| MPV-01 | MPV | first frame | REAL_DEVICE_PASS | **REAL_DEVICE_PASS** | `0.1.10 (11)` 真機「MPV 有畫面」；`0.1.35 (36)` 使用者錄影（17H-4 逐格）中 MPV 在 App 內持續有畫面（播放中，不是開播那一刻）；之後 17H-4 只改 PiP 的軟體輸出與截圖、36 沒有改首格路徑，所以 36.1 稽核後保留；36C：開播 105～429 ms |
| MPV-02 | MPV | play／pause | AUTOMATED_PASS | **SIMULATOR_PASS** | 36.1 降級：真機 23 T1～T3（`0.1.20 (21)`，MPV 一次）在 24-2（mpv 不再碰工作階段、`play()` 由 App 啟用）、27A、36 D4 之前；36 前是 27A 測試；36C 模擬器在 MPV 上播放、暫停後切到原生（DE-02、DE-04） |
| MPV-03 | MPV | ±10 秒 | UNVERIFIED | **SIMULATOR_PASS** | 36C：修正 D6 後 93.3→103.3→113.3→103.3 |
| MPV-04 | MPV | 任意 seek（落點） | UNVERIFIED | **SIMULATOR_PASS** | 36C：`seek landed 49.9s asked 49.9s on MPV` 等 |
| MPV-05 | MPV | discontinuity 清單上 seek | SIMULATOR_PASS | **SIMULATOR_PASS** | 25 §23 mpv-A／C；36C：A 上 seek 進廣告 35.2→39.9、自動跳過 100.261→109.9 |
| MPV-06 | MPV | 連續多次 seek | UNVERIFIED | **SIMULATOR_PASS** | 36C 找到 D6（2 ms 內三次都從 95.3 起算），修正後累加正確 |
| MPV-07 | MPV | 0.5×～3× | SIMULATOR_PASS | **SIMULATOR_PASS** | 22 §二（3× 順暢）；36C 3× 播到結束並接下一集 |
| MPV-08 | MPV | 直橫向切換 | UNVERIFIED | **UNVERIFIED** | 17I AC4；模擬器工具不能旋轉 |
| MPV-09 | MPV | 播放中／暫停中旋轉 | UNVERIFIED | **UNVERIFIED** | 17I AC4／AC5 |
| MPV-10 | MPV | PiP 進入（不黑） | RELEASE_BUILD_ONLY | **RELEASE_BUILD_ONLY** | 17H-4 B 修正隨 `0.1.36 (37)` 發布；模擬器的 sample-buffer PiP 視窗一律全黑 |
| MPV-11 | MPV | PiP 內暫停／恢復 | UNVERIFIED | **UNVERIFIED** | 17H AC2；36 改為經 session（意圖會被記住） |
| MPV-12 | MPV | PiP 回 App（不閃格、不重複 stop） | RELEASE_BUILD_ONLY | **RELEASE_BUILD_ONLY** | 17H-4 A 修正、`aSystemInitiatedStopLeavesNoForegroundRequest`；真機未驗證 |
| MPV-13 | MPV | 回前景不 stale frame、不變形 | RELEASE_BUILD_ONLY | **RELEASE_BUILD_ONLY** | 17H-2／17H-3／17H-4；真機最後一次回報在修正前 |
| MPV-14 | MPV | background／foreground | RELEASE_BUILD_ONLY | **RELEASE_BUILD_ONLY** | 36.1 降級：真機 23 T1～T3（`0.1.20 (21)`，MPV 一次）在 24-2（Libmpv 換版、工作階段改由 App 擁有）、17H-2～4（回前景的畫面還原）、36 D3／D5 之前；36C 的暫停中背景沒有記錄核心，也沒有觸發 reload |
| MPV-15 | MPV | idle timer（播放中不鎖屏） | RELEASE_BUILD_ONLY | **RELEASE_BUILD_ONLY** | `setPlaybackIntent`；`0.1.15 (16)` 起出貨，沒有回報 |
| MPV-16 | MPV | `aid` 音軌切換 | UNVERIFIED | **UNVERIFIED** | P10；23 T8 沒有記錄核心 |
| MPV-17 | MPV | `sid` 字幕切換 | UNVERIFIED | **UNVERIFIED** | 同上 |
| MPV-18 | MPV | auto-next | UNVERIFIED | **SIMULATOR_PASS** | 24 AC4 未回報；36C：G→H、H 最後一集關閉，都在 MPV |
| MPV-19 | MPV | audio interruption（電話、Siri） | UNVERIFIED | **UNVERIFIED** | 24 AC6；模擬器無法產生；36 補 `[audio] interruption began/ended` log |
| MPV-20 | MPV | 不錯誤混音外部音樂 | UNVERIFIED | **UNVERIFIED** | 24 AC1 |

### 雙引擎（20 項）

| ID | 核心 | 項目 | 36 前 | 36 後 | 證據 |
|---|---|---|---|---|---|
| DE-01 | 原生→MPV | AV→MPV 切換 | SIMULATOR_PASS | **SIMULATOR_PASS** | 17 §十；36C：`on MPV from 25.794876s exact=yes autoplay=yes reason=viewer` |
| DE-02 | MPV→原生 | MPV→AV 切換 | SIMULATOR_PASS | **SIMULATOR_PASS** | 17 §十；36C：`on 原生 from 103.261333s exact=yes autoplay=no reason=viewer` |
| DE-03 | 雙向 | 播放中切換 | SIMULATOR_PASS | **SIMULATOR_PASS** | DE-01 |
| DE-04 | 雙向 | 暫停中切換 | SIMULATOR_PASS | **SIMULATOR_PASS** | DE-02（暫停保留、1.5× 保留） |
| DE-05 | 雙向 | buffering 中切換仍播放 | AUTOMATED_PASS | **AUTOMATED_PASS** | 27A：`selectEngine` 以 rate 判斷意圖；`aSpeedAVPlayerCannotPlayMovesToMPVWithEverythingKept` |
| DE-06 | 原生→MPV | 開播逾時 fallback | SIMULATOR_PASS | **SIMULATOR_PASS** | 17F（20 秒）；36C（5 秒） |
| DE-07 | 雙向 | network／unclassified 失敗 fallback | SIMULATOR_PASS | **SIMULATOR_PASS** | 17F F4（本機不回應的串流）；router 測試 |
| DE-08 | 雙向 | 每個 attempt 只 fallback 一次 | AUTOMATED_PASS | **AUTOMATED_PASS** | `theFallbackEngineFailingDoesNotBounceBack` 等；36C 逾時切到 MPV 後沒有第二次 |
| DE-09 | 雙向 | 切換後 position 不漂移 | UNVERIFIED | **SIMULATOR_PASS** | 36C：AV→MPV 25.79 s、MPV→AV 103.26 s 皆 exact；來回三次未做 |
| DE-10 | 雙向 | 播放中失敗的 fallback 接在失敗處（IOS-POC-26 RC2） | DEFECT | **AUTOMATED_PASS** | D5；`anEngineThatFailedMidPlayHandsOverWhereItFailed` |
| DE-11 | 雙向 | pause intent（手動切換） | AUTOMATED_PASS | **SIMULATOR_PASS** | DE-02 `autoplay=no` |
| DE-12 | 雙向 | pause intent（失敗 fallback） | DEFECT | **AUTOMATED_PASS** | D4；`aPausePressedWhileStartingIsKeptByTheFallback`、`playPressedAfterAPausedReloadIsKeptByTheFallback` |
| DE-13 | 雙向 | rate 保留 | AUTOMATED_PASS | **SIMULATOR_PASS** | 36C：1.5× MPV→原生、3× 原生→MPV |
| DE-14 | 雙向 | quality 保留 | AUTOMATED_PASS | **AUTOMATED_PASS** | `switchingAVPlayerToMPVKeepsTheTargetPositionRateAndIdentity` |
| DE-15 | 雙向 | headers／Referer／UA 保留 | AUTOMATED_PASS | **AUTOMATED_PASS** | 同上＋`everyHeaderReachesMPVAsOneField`；Bili 真機從未端到端播放 |
| DE-16 | 雙向 | episode identity 保留 | AUTOMATED_PASS | **AUTOMATED_PASS** | 同上（history 原樣隨 request） |
| DE-17 | 雙向 | WatchHistory 不斷裂 | UNVERIFIED | **SIMULATOR_PASS** | 36C：在 MPV 播放時寫入的 93.7 s，重開後原生從 93.741 s 續播 |
| DE-18 | 雙向 | 不得誤觸 auto-next | DEFECT | **AUTOMATED_PASS** | D1／D2／D3；`theViewersEndingAndTheRealEndAdvanceOnce`、`aRetiredEngineCannotEndTheItem` |
| DE-19 | 雙向 | 切換瞬間不讀 0:00（IOS-POC-26 RC4） | DEFECT | **RELEASE_BUILD_ONLY** | D7；Debug／Release build 通過，畫面未量測 |
| DE-20 | 雙向 | requested／actual engine 與切換原因可判定 | UNVERIFIED | **SIMULATOR_PASS** | 36C：`reason=open／viewer／startup-timeout`、`started … after the switch` |

### 智慧去廣（19 項）

| ID | 核心 | 項目 | 36 前 | 36 後 | 證據 |
|---|---|---|---|---|---|
| AD-01 | 雙向 | 無廣告不受影響 | AUTOMATED_PASS | **SIMULATOR_PASS** | 36C：F／G／H `plan no-ads ranges=none`，沒有任何 skip |
| AD-02 | 雙向 | 單段 | SIMULATOR_PASS | **SIMULATOR_PASS** | 25 §23（native 0.065～0.102 s、mpv 0.15～0.46 s） |
| AD-03 | 雙向 | 多段 | SIMULATOR_PASS | **SIMULATOR_PASS** | 36C：A 兩段 30～40、100～110 s 都處理 |
| AD-04 | MPV | 相接廣告一次跳過（25-4） | SIMULATOR_PASS | **SIMULATOR_PASS** | 25 §24 mpv-E 0.417 s |
| AD-05 | 原生 | 相接廣告露出 ≤ 0.2 s | KNOWN_LIMITATION | **KNOWN_LIMITATION** | 25 §24 native-E 0.218 s（F3 落點取整），差 0.018 s |
| AD-06 | 雙向 | 片頭廣告 | AUTOMATED_PASS | **AUTOMATED_PASS** | golden `c`／`u`、`anOpeningThatEndsInsideAnAdStartsWhereTheAdEnds` |
| AD-07 | 雙向 | 片中廣告 | SIMULATOR_PASS | **SIMULATOR_PASS** | AD-03 |
| AD-08 | 雙向 | 片尾廣告 | AUTOMATED_PASS | **AUTOMATED_PASS** | `aTrailingAdJumpsToTheEndSoTheEngineFinishesTheItem`、`theViewersEndingOwnsTheEndOfTheItem` |
| AD-09 | 雙向 | discontinuity | SIMULATOR_PASS | **SIMULATOR_PASS** | 36C：A（DISC）原生 30.011→40.000、MPV 100.261→109.9 |
| AD-10 | 雙向 | AES implicit IV | AUTOMATED_PASS | **AUTOMATED_PASS** | golden `l-aes-seq37`；iOS 未播放過 AES 串流 |
| AD-11 | 雙向 | byte-range | AUTOMATED_PASS | **AUTOMATED_PASS** | golden `k` |
| AD-12 | 雙向 | multi-rendition（master） | AUTOMATED_PASS | **AUTOMATED_PASS** | `everyDeclaredVariantAgreeingIsTheOnlyWayAMasterGetsRanges` 等八條 |
| AD-13 | 雙向 | seek 進廣告 | SIMULATOR_PASS | **SIMULATOR_PASS** | 36C：原生 101.6→110.0、MPV 35.2→39.9（25 時 MPV 只有自動化） |
| AD-14 | 雙向 | seek 跨廣告 | AUTOMATED_PASS | **AUTOMATED_PASS** | `aViewersSeekIntoAnAdLandsAtItsEndAndAnyOtherSeekIsUntouched`、`seekingBackBeforeASkippedAdSkipsItAgain` |
| AD-15 | 雙向 | 廣告邊界 pause | AUTOMATED_PASS | **AUTOMATED_PASS** | `aPlayerPausedJustBeforeAnAdSkipsItOnlyOnceItPlaysIntoIt` |
| AD-16 | 原生 | AVPlayer 跳過 | SIMULATOR_PASS | **SIMULATOR_PASS** | AD-09；真機只有 `0.1.22 (23)` 的「不到約 1 秒」（未計秒） |
| AD-17 | MPV | MPV 跳過 | SIMULATOR_PASS | **SIMULATOR_PASS** | AD-09；25-2 之後沒有真機回報 |
| AD-18 | 雙向 | 關閉智慧去廣 | SIMULATOR_PASS | **SIMULATOR_PASS** | 36C：關閉時不讀計畫（沒有 `[adskip] plan` 行） |
| AD-19 | 雙向 | timeline anomaly fail closed（25-5 MPV timeline-jump） | SIMULATOR_PASS | **SIMULATOR_PASS** | 36C：B（無 DISC、廣告自帶 PTS）`stopped on MPV: timeline-jump`，不跳、不吃正片 |

### Session／歷史（12 項）

| ID | 核心 | 項目 | 36 前 | 36 後 | 證據 |
|---|---|---|---|---|---|
| SH-01 | 雙向 | 同集 resume | AUTOMATED_PASS | **SIMULATOR_PASS** | 36.1 降級：真機 23 T9（`0.1.20 (21)`，未分核心）在 26-1（原生精確起點）與 36 D7 之前；36 前是 5R 的續播測試；36C：原生從 85.041 s、93.741 s 續播，MPV 依 request 起點開播見 DE-09（同一個 `startSeconds`） |
| SH-02 | 雙向 | 新集從頭 | SIMULATOR_PASS | **SIMULATOR_PASS** | 21 §驗證；36C：G、H 從 0 播到 24 s |
| SH-03 | 雙向 | 上一集／下一集按鈕 | SIMULATOR_PASS | **SIMULATOR_PASS** | 35 T1～T6；36C：第一集的「上一集」變灰 |
| SH-04 | 雙向 | 最後一集結束關閉播放器 | UNVERIFIED | **SIMULATOR_PASS** | 14 與 8L 記錄互相矛盾，保守記 UNVERIFIED；36C：`no next episode after … H短片二 — closing`（兩個核心） |
| SH-05 | 雙向 | opening＋resume | AUTOMATED_PASS | **AUTOMATED_PASS** | `theOpeningWinsWhenItIsPastWhereTheViewerStopped` 等 |
| SH-06 | 雙向 | ending＋auto-next | AUTOMATED_PASS | **AUTOMATED_PASS** | 5S-2＋`PlaybackEndGate`（36.1 起 loop 也經過它）；模擬器沒有設定片尾 |
| SH-07 | 雙向 | 切引擎後 history | UNVERIFIED | **SIMULATOR_PASS** | DE-17 |
| SH-08 | 雙向 | background 後 history | UNVERIFIED | **UNVERIFIED** | 5R R5R-3；36C 用 `simctl terminate`，沒有經過進背景寫入 |
| SH-09 | 雙向 | 畫質切換後 history | AUTOMATED_PASS | **AUTOMATED_PASS** | `aRememberedQualityDecidesWhereTheMenuOpens` |
| SH-10 | 雙向 | 結束原因（完成／片尾／停止／錯誤）可判定 | UNVERIFIED | **SIMULATOR_PASS** | 36C：`finished (end)`、`no next episode … closing`、`summary`；錯誤結束沿用既有訊息，未在 36C 觸發 |
| SH-11 | 雙向 | 下一集預解析 | SIMULATOR_PASS | **SIMULATOR_PASS** | 15C；36C：`resolve G短片一 prefetched 0ms` |
| SH-12 | 雙向 | 一個 item 只交接一次（片尾＋真正結束） | DEFECT | **AUTOMATED_PASS** | D1；36.1 D8 補 loop：`underLoopTheViewersEndingThenTheRealEndReplayOnce`、`underLoopTheRealEndThenTheViewersEndingReplayOnce`、`aReplayBackAtItsStartMayEndAgain` |

### PiP／音訊／生命週期（14 項）

| ID | 核心 | 項目 | 36 前 | 36 後 | 證據 |
|---|---|---|---|---|---|
| PL-01 | MPV | MPV PiP first frame（進 PiP 不黑） | RELEASE_BUILD_ONLY | **RELEASE_BUILD_ONLY** | MPV-10 |
| PL-02 | MPV | 回 App 不閃舊格 | RELEASE_BUILD_ONLY | **RELEASE_BUILD_ONLY** | MPV-12 |
| PL-03 | 雙向 | 回前景不重複 stop | AUTOMATED_PASS | **AUTOMATED_PASS** | `PictureInPictureForegroundRestoreStateTests` 四條；17H-4 模擬器事件順序 |
| PL-04 | 雙向 | 播放中背景／前景 | RELEASE_BUILD_ONLY | **RELEASE_BUILD_ONLY** | 36.1 降級：23 T4 真機只有一次且未分核心（`0.1.20 (21)`），雙向缺一個核心；之後 24-2 改了音訊工作階段 |
| PL-05 | 雙向 | 暫停中背景／前景 | RELEASE_BUILD_ONLY | **RELEASE_BUILD_ONLY** | 36.1 降級，同 AV-13、MPV-14：真機 23 T1～T3 兩個核心都在 24-2、36 之前；36C 模擬器 20 秒沒有觸發暫停執行，reload 路徑只有 build |
| PL-06 | 雙向 | 電話 interruption | UNVERIFIED | **UNVERIFIED** | 24 AC6 |
| PL-07 | 雙向 | Siri interruption | UNVERIFIED | **UNVERIFIED** | 24 AC6 |
| PL-08 | 雙向 | 其他 App 音訊 interruption | UNVERIFIED | **UNVERIFIED** | 24 AC1 |
| PL-09 | 雙向 | AVAudioSession 由 App 擁有（mpv 不碰） | AUTOMATED_PASS | **AUTOMATED_PASS** | 24 CI 比對 binary 含 `skip-session-management` |
| PL-10 | 雙向 | 外部音樂共存規則 | KNOWN_LIMITATION | **KNOWN_LIMITATION** | 24 §九之3：啟動時啟用不混音工作階段會中斷其他 App（為了 PiP，不改）；中斷結束不自動續播（24-3，刻意） |
| PL-11 | 原生 | AVPlayer PiP 回 App 結束 PiP | AUTOMATED_PASS | **AUTOMATED_PASS** | 36.1 降級：23 T5 真機通過但未分核心；原生 `PlayerSurface.Coordinator` 的回前景規則在 `0.1.20 (21)` 後沒改，由 `PictureInPictureForegroundRestoreStateTests` 覆蓋 |
| PL-12 | MPV | MPV PiP 內按播放有聲音 | UNVERIFIED | **UNVERIFIED** | 24 AC5 |
| PL-13 | MPV | PiP 內暫停後的 fallback 保持暫停 | UNVERIFIED | **AUTOMATED_PASS** | D4（PiP 的播放／暫停改走 session） |
| PL-14 | 雙向 | PiP 在背景關閉後才被暫停執行，回來會 reload | DEFECT | **DEFECT** | 23 §十一之4 缺口 1，仍開啟（見第九節） |

### 控制列與診斷（3 項）

| ID | 核心 | 項目 | 36 前 | 36 後 | 證據 |
|---|---|---|---|---|---|
| UI-01 | 雙向 | 控制列按鍵依意圖、端點按鈕變灰 | AUTOMATED_PASS | **SIMULATOR_PASS** | 27A 測試；36C 截圖 |
| UI-02 | 雙向 | `[playback]` 可區分 startup／seek requested／landed／handoff／fallback reason／finished／auto-next | UNVERIFIED | **SIMULATOR_PASS** | 36C log（見第六節） |
| UI-03 | 雙向 | `[audio] interruption`、`[pip] native` 診斷 | UNVERIFIED | **RELEASE_BUILD_ONLY** | 模擬器無法產生中斷、iPhone 模擬器沒有 PiP |

矩陣說明：

- 36 前 6 項 `DEFECT` 裡，DE-10（RC2）、DE-19（RC4）、PL-14 在 IOS-POC-26／23 已有記錄但沒修；DE-12、DE-18、SH-12 是本任務讀程式時找到、並對照 IOS-POC-23 §十之2 與 17F 的已知風險確認的。MPV-06 是模擬器上測出來的（36 前記 `UNVERIFIED`）。
- 36 後唯一的 `DEFECT` 是 PL-14（見第九節）。
- `REAL_DEVICE_PASS` 只剩 MPV-01。36.1 依三條規則重新稽核原本的 15 項（兩欄都套用，36 前一欄對照 36 前的程式）：(1) 一列有多個子項（倍率、兩個核心、有沒有被暫停執行）時，每個子項都要有真機證據，否則整列取證據最弱的子項；(2) 單一核心的列，真機證據要記錄核心（或當時只有那個核心），IOS-POC-23 的 T4～T12、T14、T15 都是「未分核心」；(3) 真機證據之後改過該列驗證的程式路徑時，記目前程式上最強的證據，舊的真機結果留在證據欄。降級項目的目標狀態沿用本表慣例：已出貨但只有編譯的記 `RELEASE_BUILD_ONLY`（同 MPV-15）。第十節把這些項目的真機驗收列在清單裡。

## 五、Real-device evidence

| 日期／版本 | 使用者回報 | 對應矩陣 |
|---|---|---|
| 2026-09-22～23，`0.1.1 (2)`～`0.1.2 (3)` | 麻豆(js) 可播、荐片篩選列、auto-next（8L §7.1） | AV-01、AV-19 |
| 2026-09-24，`0.1.10 (11)` | MPV 有畫面；旋轉跑版；沒有 PiP | MPV-01（其餘已修，未再驗） |
| 2026-09-24，`0.1.11 (12)` | MPV PiP 解析度變低（代表有畫面） | 17H，已修 |
| 2026-09-25，`0.1.20 (21)` | IOS-POC-23 T1～T15 全部符合（T1～T3 兩個核心各一次） | AV-02／07／12～15、MPV-02／14、SH-01、PL-04／05／11 |
| 2026-09-26，`0.1.22 (23)` | 原生去廣「不到約 1 秒」才跳走（沒計秒、沒 log） | AD-16 仍為 SIMULATOR_PASS |
| 2026-09-29～30，`0.1.31 (32)`～`0.1.35 (36)` | MPV PiP 放回時放大、閃一格；進 PiP 先黑（錄影） | MPV-10／12／13，修正在 `0.1.36 (37)`，未再驗 |

本任務沒有取得新的真機證據（沒有安裝到使用者的 iPhone）。

## 六、Simulator evidence（36C）

環境：iPhone 17 Pro Max 模擬器（iOS 26.3）、Debug build（控制列自動隱藏暫時改成 600 秒以便工具操作，build 後原始碼立即還原，未 commit）、本機 CMS＋HLS server（`scripts/ios_adskip_sim/server.py` 的複本，port 8766，fixture 沿用 IOS-POC-25 的 A～E，另加 F（無廣告 130 秒）、G／H（各 24 秒））。證據是 `log stream --predicate 'subsystem == "com.webhtv.ios.poc"'` 的 `[playback]`／`[adskip]`／`[audio]` 行。

| 項目 | 觀察（log 摘錄） |
|---|---|
| 原生首次開播、resume | `F無廣告 on 原生 from 85.041000s exact=no autoplay=yes reason=open`；`started … in 751ms after open` |
| 原生連續 ±10 | `seek requested 116.3s from 106.3s`、`126.3s from 116.3s`、84 ms 後 `116.3s from 126.3s`；`seek landed 116.3s asked 116.3s finished=true`（前兩次 `finished=false`） |
| auto-next、最後一集 | `F無廣告 finished (end) on 原生 at 129s/130s` → `resolve G短片一 prefetched 0ms` → `started … G短片一 … in 202ms`；G→H `live, prefetch miss: notRequested`；`H短片二 finished (end)` → `no next episode after 廣告測試 H短片二 — closing` |
| AV→MPV 播放中 | `on MPV from 25.794876s exact=yes autoplay=yes reason=viewer` |
| MPV 連續 ±10（修正前） | 2 ms 內三次：`105.3s from 95.3s`、`105.3s from 95.3s`、`85.3s from 95.3s`（第二次沒有累加） |
| MPV 連續 ±10（修正後） | `103.3s from 93.3s`、`113.3s from 103.3s`、`103.3s from 113.3s`；最終版再測 `20.8→30.8→20.8`，`seek landed 20.8s asked 20.8s on MPV` |
| 3× 交給 MPV、MPV auto-next | `G短片一 on MPV from 22.000000s exact=yes … reason=viewer`、`at 3.0× — AVPlayer cannot play above 2×`、`started … on MPV in 183ms after the switch (viewer)`；`G短片一 finished (end) on MPV` → H 在 MPV 開播 |
| MPV→原生暫停中 | `on 原生 from 103.261333s exact=yes autoplay=no reason=viewer`（1.5× 保留） |
| 換引擎後 history | 在 MPV 上寫入的位置，重開後 `on 原生 from 93.741000s` |
| 原生去廣 | `plan exo-hls-detector ranges=30000-40000,100000-110000 discontinuity=yes`；`skip from=30011ms to=40000ms on 原生`、`seek landed 40.0s asked 40.0s`；`seek into an ad at 101606ms lands at 110000ms` |
| MPV 去廣（A，有 DISC） | `seek into an ad at 35181ms lands at 39900ms`；`skip from=100261ms to=109900ms on MPV`、`seek landed 109.9s` |
| F1 防護（B，無 DISC） | `stopped on MPV: timeline-jump`，沒有 skip |
| 無廣告 | F／G／H `plan no-ads ranges=none` |
| 開播逾時＋去廣關閉 | 每段延遲 8 秒：`on MPV from 0.000000s … reason=startup-timeout`、`not started on 原生 after 5s — trying MPV`、`native start given up: reason=neverReady`；`started … on MPV in 8617ms after the switch (startup-timeout)`；關閉去廣時沒有 `[adskip] plan` |
| 暫停中背景 20 秒 | 回來仍暫停、同一格；模擬器沒有觸發暫停執行，所以沒有走 reload（真機 23 T1～T3 是走 reload 的那條） |

模擬器做不到或這次沒做：PiP（iPhone 模擬器 `isPictureInPictureSupported()` 是 false，iPad 的 sample-buffer 視窗全黑）、旋轉、音訊中斷、AirPlay、外部音樂、片頭／片尾面板操作、畫質選單（沒有多畫質來源）、拖曳進度條手勢、MPV 真實網路失敗（D5 靠單元測試）。

## 七、Automated test coverage

- 基準 578 → **586**。新增 8 條：`PlaybackEngineTests` 的 `aPausePressedWhileStartingIsKeptByTheFallback`、`playPressedAfterAPausedReloadIsKeptByTheFallback`、`theViewersIntentChangesNothingElseInTheRequest`、`anEngineThatFailedMidPlayHandsOverWhereItFailed`、`everySwitchSaysWhyForTheLog`、`aRetiredEngineCannotEndTheItem`；`PlaybackActivityTests` 的 `theViewersEndingAndTheRealEndAdvanceOnce`、`theNextItemMayEndAgainAndSoMayAReplay`。既有 `playPressedDuringAReloadThenAFallbackComesBackPaused` 只更新註解（行為契約不變）。
- 36 前的覆蓋盤點（306 條播放相關）：router／fallback／逾時、HLS 去廣（86 條＋26 golden）、緩衝策略、history 資料層都完整；空白集中在 App target：`finished()`／`playNext` 的交接、audio interruption、零容差 seek、AVKit PiP 接線、控制列互動。
- 36.1：610 → **613**（中間 24 條是 IOS-POC-39 的 `XBPQRuleTests`）。新增 `underLoopTheViewersEndingThenTheRealEndReplayOnce`、`underLoopTheRealEndThenTheViewersEndingReplayOnce`、`aReplayBackAtItsStartMayEndAgain`；D1 的兩條改用 `end(looping: false)`，期望不變。
- 本任務能抽成純狀態的都抽了（`PlaybackEndGate`、`PlayerRouter.setIntendsToPlay`／`switchReason`、交接位置）；AVPlayer 的通知過濾（D2）、MPV 的上一檔 EOF（D3）與暫存 seek（D6）、session 的位置補值（D7）留在 App target，證據是 build＋第六節。

## 八、Confirmed defects、root cause、修正、回歸風險

| # | 重現條件 | Root cause | 修正 | 驗證 | 回歸風險 |
|---|---|---|---|---|---|
| D1 | 設了片尾，且片尾離結尾比「解析下一集」還近（例如片尾 5 秒、下一集要嗅探 8 秒）：取樣器在片尾交接一次，真正結尾又交接一次，第二次從已換好的 `playingEpisode` 再往後，**跳過一集**。上一集／下一集按到一半遇到結尾也會同時啟動兩次 | `PlaybackSession.finished()` 有兩個呼叫者（`reachedEnding` 取樣、engine `onEnded`），沒有「這個 item 已交接」的狀態 | `PlaybackEndGate`：`load()` 與 `replay` 標新 item，`finished` 每個 item 只過一次；有上一集／下一集在進行中時不另外交接；被擋下時寫 `ignored: already moving on` | `theViewersEndingAndTheRealEndAdvanceOnce`、`theNextItemMayEndAgainAndSoMayAReplay` | 同一個 item 的第二次結尾不再交接（除了 `replay`／loop，已處理） |
| D2 | 下一集換上 item 之後，前一個 item 遲到的 `didPlayToEndTime`／`failedToPlayToEndTime` 才送到 main actor | `AVPlayerEngine` 以 `object: nil` 觀察，送達時只看「目前的 item」，把舊 item 的結尾當新 item 的 → 又換一集；舊 item 的失敗 → 把好好的新 item 換到 MPV | 通知帶的 item 必須是目前的 `currentItem`（`isCurrent`） | build；程式路徑 | 無：AVFoundation 以 item 為 `object` 發這兩個通知 |
| D3 | 同一個 MPV 核心上 `loadfile … replace` 下一集時，上一檔的 EOF 事件晚到（IOS-POC-23 §十之2 記錄的風險） | `MPVEngine.handle(.ended)` 沒有 load 世代 | 下一檔還在 loading 時的 `.ended` 視為上一檔的，丟棄並記 log | build；程式路徑 | loading 中不可能有這一檔的 EOF |
| D4 | 開播中按暫停（或 PiP 小視窗暫停、來電中斷暫停）之後這個 item 失敗 → fallback 的核心自己開始播放；反過來，暫停 reload 後按播放再失敗會回到暫停（17F、23 §十之2） | router 的 `request.autoplay` 只在 open／reload 時設定；`engineFailed` 用它，但使用者的播放／暫停直接打到 engine，AVPlayer 失敗時 rate 已經是 0 也讀不到 | `PlayerRouter.setIntendsToPlay`；`control("play"/"pause")`、`replay` 通知 router；音訊中斷與 MPV PiP 的播放／暫停改走 `control` | 3 條 router 測試 | **使用者可見**：失敗 fallback 依使用者最後的播放／暫停；AVKit 原生 PiP 小視窗的播放鍵直接操作 AVPlayer，不經 router（見第九節） |
| D5 | MPV 播放中途失敗（網路斷、token 過期）→ 換原生時回到當初開啟的位置（IOS-POC-26 RC2） | mpv 失敗時 `loaded=false` 先於失敗事件，`handOff` 只接受 `isLoaded` 的位置 | router 不再看 `isLoaded`；MPV 記住已載入檔案最後回報的位置（`reached`），失敗後回報它；載入中一律回報 0（不會帶到上一檔的位置） | `anEngineThatFailedMidPlayHandsOverWhereItFailed` | AVPlayer 無影響（沒有 item 時 `currentTime` 為 0） |
| D6 | 快速連按 ±10 秒：MPV 在 `time-pos` 更新前，第二次從舊位置起算（模擬器 2 ms 內三次：95.3→105.3、95.3→105.3、95.3→85.3）；控制列本身用的是每 0.25 秒更新一次的畫面位置 | ±10 以 UI 的讀值為基準；MPV 的位置在 mpv 執行 seek 前不含要求的目標 | ±10 改用 `PlaybackSession.skip(by:)`（engine 當下位置）；MPV 在 `PLAYBACK_RESTART` 前回報要求的目標，最多 2 秒（mpv 拒絕的 seek，例如直播，不會卡住） | 第六節修正前後對照 | 去廣的落點檢查本來就預期 mpv 在 restart 前回報目標值（`HLSAdSkipper` 註解），模擬器 A／B 重測沒有退步 |
| D7 | 切換核心後、新核心回報前，控制列讀到 0:00，這時按 ±10 會 seek 到開頭附近（IOS-POC-26 RC4） | `position` 只讀 engine | 新核心沒有位置也沒有長度時，`PlaybackSession.position` 用 request 的起點；AVPlayer 的 periodic observer 讀到 0 時也用它。使用者自己拖到 0:00 時已有長度，讀 0 | Debug／Release build | 直播（長度為 0）開頭讀的是 request 起點（0） |
| D8（36.1） | loop 開著（只有 WebHome 的 `player.control` 會開）：片尾觸發 replay 後，舊一段播放的真正結尾才送到；或真正結尾觸發 replay 後，取樣器在 rewind 落地前讀到舊位置的片尾 | `finished` 在 loop 時 `control("replay")` 直接 return，不經 `PlaybackEndGate`；`replay` 一送出就 `itemLoaded()`，所以遲到的結束被當成新一段的：再 replay 一次，若這時 loop 已關則交接、跳到下一集 | loop 也經過 gate（`end(looping:)` 回 `.handOver`／`.replay`／`.ignore`）；replay 的 seek 落地才重新上膛（`PlaybackEngine.seek(toSeconds:landed:)`：AVPlayer 的 seek completion、MPV 的 `PLAYBACK_RESTART`）；上一集／下一集進行中時 loop 也不另外 replay | 三條 loop 測試（先以舊語意重現為紅，第十四節之 2）；D1 兩條 | replay 的 seek 若一直不落地（MPV 已 EOF、檔案已卸載），這個 item 之後的結束都會被忽略，而那時 replay 本來就無效（第九節）；下一個 `load` 重新上膛 |

**補的診斷（Release-safe，只寫 log，不改時序）**：`seek requested … from …`、`seek landed … asked …`（兩個核心）、換核心時的 `autoplay=` 與 `reason=`、換核心後在新核心開始播放的 `started … after the switch (reason)`、`finished (end|ending)`、`… ignored: already moving on`、`no next episode … closing`、`mpv end of the previous file ignored`、`[audio] interruption began|ended … shouldResume=`、`[pip] native will start|did stop`。新增的輪詢只有換核心後一個最多 60 秒、每 0.1 秒讀一次 `isPlaying` 的 log 監看（與既有 `watchStartup` 相同做法），不做任何切換。

## 九、Known limitations（fail-safe 行為）

- **PL-14（DEFECT，未修）**：播放中進 PiP、在小視窗暫停、在背景把小視窗關掉，之後才被系統暫停執行：進背景時不符合「暫停在畫面上」的條件，所以回來不會 reload（IOS-POC-23 §十一之4）。可能的修法（PiP 結束時重新判斷）要靠 PiP 與背景的時序，iPhone 模擬器沒有 PiP 無法驗證，先不改；fail-safe 是使用者關掉播放器重開。
- AVKit 原生 PiP 小視窗的播放／暫停直接操作 AVPlayer，不經 `control`，所以 D4 的意圖不含它（小視窗開著時核心失敗換到 MPV 也會結束 PiP，情況罕見）。
- IOS-POC-25：原生相接廣告露出 0.218 s（目標 0.2 s）；MPV 在有 DISC 的清單上進入廣告 0.25 s 後才跳（25-2 的設計）；H1、U1（上游 FFmpeg）；目標沒緩衝時停在廣告畫面直到下載完成。
- IOS-POC-17H-4 C：iPhone 放回動畫放大到整個 App 視窗，App 無法指定。
- IOS-POC-24：App 啟動就啟用不混音工作階段，會中斷其他 App 的音樂（為了 PiP，不改）；中斷結束不自動續播（與 AVPlayer 相同，刻意）；暫停中 reload 的那一集可能只輸出雙聲道。
- MPV 沒有 Now Playing／遠端控制、沒有 AirPlay 影片。
- 換到 MPV（2.5×／3×）後這個 session 都留在 MPV。
- MPV 播到 EOF 後 `time-pos` 變 0，所以結尾那一刻不會再寫一次 history（取樣器最後一次寫入在結尾前 5 秒內，下次開同一集會落在 near-ending 範圍而從頭播）；觀察到，未改。
- 暫停 10 秒～1 分鐘後按播放要等幾秒（IOS-POC-23 T13，使用者決定先不處理）。
- MPV 在真正結尾之後 loop 無效：沒有設 `keep-open`，結尾時 mpv 已卸載檔案，`replay` 的 seek／play 沒有東西可播（讀程式推斷，未實測；36.1 前後相同，未改）。片尾觸發的 loop 在檔案還載入時發生，不受影響。

## 十、Real-device acceptance：一次性清單

請用下一個發布版本、一個有廣告的 HLS 站（例如之前的 FF 線路）和一個一般 HLS 站，照順序做完再一起回報「第幾項：正常／不正常＋一句描述」。每項都兩個核心各一次的，會寫明。

1. **切換與位置**：同一集原生播到約 10 分鐘 → 切 MPV → 等 10 秒 → 切回原生 → 再切 MPV。三次畫面都接在同一時刻、不往回退，速度 1.5× 保留（DE-09、DE-13）。
2. **連按 ±10**：兩個核心各快速連按「前進 10 秒」三次，應前進 30 秒；再連按倒退三次回原處（AV-05、MPV-06）。
3. **暫停後切換**：暫停中切換核心，切過去仍是暫停（DE-11）。
4. **高倍速**：原生選 2.5×、3×，自動換到 MPV，聲音與畫面正常（AV-08）。
5. **去廣**：有廣告的集數兩個核心各看過一次廣告位置：廣告被跳過、正片沒少、拖進廣告會落在廣告後（AD-13、AD-16、AD-17）。
6. **片尾＋下一集**：把某一集的「片尾」設在結尾前約 5～10 秒，看到結尾：只換到**下一集**，沒有跳過一集（D1、SH-06）。
7. **最後一集**：看完一條線的最後一集，播放器自動關閉（SH-04）。
8. **MPV PiP**：MPV 播放中回主畫面：小視窗一出現就有畫面（不先黑）；在小視窗暫停、再播放，有聲音；按「回到 App」多試幾次，不閃舊畫面、不變形（MPV-10～13、PL-12）。
9. **MPV 旋轉**：MPV 播放中、暫停中各轉直↔橫一次，畫面不跑版、暫停保持（MPV-08／09）。
10. **音樂與中斷**：先開「音樂」播放，再用 MPV 播影片：音樂停止；MPV 播放中打一通電話或叫 Siri，結束後按播放有聲音（MPV-19／20、PL-06／07）。
11. **MPV 常亮與音軌字幕**：MPV 播放 2 分鐘不碰螢幕不會變暗；有多音軌或字幕的片子切換一次（MPV-15～17）。
12. **暫停後背景**：兩個核心各暫停後鎖螢幕 1 分鐘再回來：仍暫停、同一格，按播放 5 秒內開始（AV-13、MPV-14）。
13. **原生 PiP／AirPlay 下一集**：原生 PiP 小視窗中讓它自動播到下一集（開播慢的站）：不會 5 秒就被換到 MPV（AV-11）。
14. **36.1 降級的原生項目**（確認控制列顯示的是原生）：依序選 0.5×、1.5×、2× 各播 10 秒；播放中回主畫面 30 秒，聲音持續、回來不跳位置；進子母畫面再回 App；有多音軌或字幕的片子切換一次；關掉播放器再從觀看記錄開同一集，從剛才的位置續播。MPV 再做一次「播放中回主畫面」與「續播」（AV-07、AV-12、AV-14、AV-15、PL-04、PL-11、SH-01）。

可以的話，接 Mac 用 Console.app 過濾 `[playback]`，把第 1、2、6 項的 log 一起給我，比畫面描述更能判定。

## 十一、使用者可見的行為變更

- **有（刻意）**：D4 — 核心失敗而自動換到另一個核心時，依使用者最後一次的播放／暫停（以前一律照開啟時的 autoplay，暫停中失敗也會自己播放；暫停 reload 後按了播放再失敗會回到暫停）。
- 其餘是修正：D1（不再跳過一集）、D5（MPV 中途失敗接在失敗處）、D6（連按 ±10 累加）、D7（切換瞬間不從 0 起算）；D2、D3 平常看不到。
- 36.1（D8）：loop 開著時，同一段播放只 replay 一次；上一集／下一集進行中遇到結尾交給進行中的換集，不再同時 replay。

## 十二、Rollback

- 單一 commit，`git revert` 即可；不涉及 lock、patch、二進位、`project.pbxproj`、設定鍵或資料格式。
- 分開回退：D4 是 `PlayerRouter.setIntendsToPlay` 與 `PlaybackSession.control` 的兩行；D6 的 MPV 部分是 `MPVEngine.seekAsked`；D1 是 `PlaybackEndGate` 與 `finished(reason:)` 的 guard。
- 36.1 是另一個 commit，可單獨 revert：`PlaybackEndGate.end(looping:)`、`PlaybackEngine.seek(toSeconds:landed:)` 與兩個引擎的實作、`finished`／`replay`、測試與文件；revert 後回到 36 的 loop 行為（loop 不經 gate）。

## 十三、驗證紀錄

- `swift test --package-path ios`：586／586（worktree，`0f9b05cf` 加本任務變更）。
- 模擬器 Debug build（`platform=iOS Simulator,id=05934376…`）：BUILD SUCCEEDED，本任務檔案 0 新 warning。
- Release 裝置 build（`generic/platform=iOS`、`CODE_SIGNING_ALLOWED=NO EXPANDED_CODE_SIGN_IDENTITY=-`）：BUILD SUCCEEDED。第一次沒帶 `EXPANDED_CODE_SIGN_IDENTITY=-` 時，上游 `install_python` 簽 framework 失敗（`no identity found`），屬呼叫方式，與 17H-4 記錄的指令相同後通過。
- 模擬器驗收：第六節。
- Ponytail：未執行（選配，本任務略過）。
- 36.1 的驗證見第十四節之 4。

## 十四、IOS-POC-36.1 收尾（2026-09-30）

### 1. 起始狀態

- 17:16 CST `git fetch`：HEAD＝`origin/ios-poc`＝`78324ef3`（`docs(ios): handoff for a new session after 0.1.40 (41)`），工作區乾淨，沒有進行中的 task guard。36 的 `2840c2e4` 包含在 tag `ios-v0.1.39-b40` 與 `ios-v0.1.40-b41`。
- 只做 36.1：沒有碰 IOS-POC-39／XBPQ，沒有改播放器架構，沒有 bump、tag 或發布。

### 2. D8：loop 下同一段播放只處理一次結束

- **重現**：先把 App 當時的 loop 語意原樣搬進 core（`end(looping: true)` 一律回 `.replay` 並立刻重新上膛，等於 `finished` 的 `if looping { control("replay"); return }` 加上 `replay` 立刻 `itemLoaded()`），新測試 3 條共 4 個期望失敗：ending→EOF 的第二個結束又 replay；EOF→ending 的第二個結束又 replay，關掉 loop 後則交接（跳一集）；replay 送出後、rewind 落地前的結束又 replay。D1 兩條照樣通過。**這是在抽出的決策模型上重現**；模擬器與真機沒有重現——loop 只有 WebHome 頁面的 `player.control("loop")` 會開，App 自己的控制列沒有 loop。
- **Root cause**：見第八節 D8。會發生的時間窗（讀程式）：AVPlayer 的 `didPlayToEndTime` 由 AVFoundation 從別的 thread 發出，經 `queue: .main` 與 `Task { @MainActor }` 兩次轉送才到 `finished`；取樣器每 5 秒在 `persist`、`prefetchNextIfDue` 兩個 await 之後才看片尾，讀到的 `rate` 還沒變 0、位置已過片尾時，已排隊的結尾通知會在 replay 之後送到。MPV 的 `.ended` 也是排隊送到的事件。
- **修法**：
  1. `PlaybackEndGate.end(looping:)` 取代 `end()`：第一個結束依 loop 回 `.replay` 或 `.handOver`，之後回 `.ignore`，直到 `itemLoaded()`。gate 仍是 `PlaybackSession` 的一個欄位，只記目前這個 item／這段播放，不是 global。
  2. `finished(reason:)`：上一集／下一集進行中時 `.ignore`，否則問 gate；`.replay` 才 `control("replay")`。
  3. `control("replay")`：不再送出時就 `itemLoaded()`，改在 seek 落地時。
  4. `PlaybackEngine.seek(toSeconds:landed:)`：AVPlayer 在 seek completion 回呼（不論 `finished`：被取代的 seek 一樣把播放頭帶離結尾）；MPV 在下一個 `PLAYBACK_RESTART` 回呼，`load` 清掉還沒落地的；protocol extension 的預設是送出就算落地（只有測試的 `FakeEngine` 用到）。
- **沒有引入延遲**：replay 照舊立刻 seek＋play；等 seek 落地只決定「什麼時候允許下一次結束」，沒有計時器或 sleep。
- **為什麼不用取樣器、時間或位置判斷**：取樣器 5 秒一次，短於 5 秒的片子 loop 會停；以「離 replay 多久」判斷，replay 後馬上拖到結尾前會被誤擋；MPV 結尾後位置讀 0，AVPlayer 結尾時位置與長度差多少沒有保證。seek 落地是兩個核心都已經有、而且就是 rewind 本身的訊號。
- **殘餘風險**：(a) 舊的結尾通知若比 seek completion 還晚送到 main actor，仍會被當成新一段的（要比一次網路 seek 還慢，機率很低）；(b) MPV 真正結尾後 loop 本來就無效（第九節），36.1 後該 item 之後的結束被忽略，使用者看到的一樣是停在結尾；(c) 上一集／下一集進行中遇到結尾時 loop 不再 replay（刻意，第十一節）。

### 3. 矩陣證據稽核

規則在第四節的矩陣說明。原本 15 項 `REAL_DEVICE_PASS`（RD）逐項結果（SIM＝`SIMULATOR_PASS`、AUTO＝`AUTOMATED_PASS`、RBO＝`RELEASE_BUILD_ONLY`）：

| ID | 36.1 後（36 前／36 後） | 主要原因 |
|---|---|---|
| AV-01 | SIM／SIM | 真機只在 `0.1.1 (2)`～`0.1.2 (3)`，之後 17、26-1、27A、36 改過開播路徑 |
| AV-02 | AUTO／SIM | 真機在 24-2、27A、36 D4 之前 |
| AV-07 | RBO／RBO | 0.5× 沒有任何紀錄；1.5×／2× 的真機未分核心 |
| AV-12 | RBO／RBO | 真機未分核心；24-2 改了音訊工作階段 |
| AV-13 | RBO／RBO | 真機在 24-2、36 D4／D7 之前；模擬器沒走 reload |
| AV-14 | RBO／RBO | 真機未分核心（當時 MPV 也有 PiP） |
| AV-15 | RBO／RBO | 真機未分核心；切換本身只有 build |
| AV-19 | SIM／SIM | 真機在 35、36 D1／D2 之前；T10 未分核心 |
| MPV-01 | RD／RD（保留） | `0.1.35 (36)` 錄影仍有畫面，之後沒改首格路徑 |
| MPV-02 | AUTO／SIM | 真機在 24-2、27A、36 D4 之前 |
| MPV-14 | RBO／RBO | 真機在 24-2、17H-2～4、36 之前 |
| SH-01 | AUTO／SIM | 真機未分核心，在 26-1、36 D7 之前 |
| PL-04 | RBO／RBO | 真機只有一次、未分核心；24-2 |
| PL-05 | RBO／RBO | 真機在 24-2、36 之前；模擬器沒走 reload |
| PL-11 | AUTO／AUTO | 真機未分核心；回前景規則有單元測試 |

- 重新計數（兩欄都從表格逐列統計，總數維持 107，沒有拆列）：36 前 1／24／30／15／29／2／6，36 後 1／47／27／17／12／2／1（依序 RD、SIM、AUTO、RBO、UNVERIFIED、KNOWN_LIMITATION、DEFECT）。
- 只稽核了原本的 `REAL_DEVICE_PASS` 列，以及 36.1 改到的 AV-18、SH-06、SH-12 證據欄；其他狀態沒有重新稽核。
- 降級項目的真機驗收：第十節第 1、3、4、6、8、12、13 項原本就涵蓋一部分，第 14 項補上其餘的原生項目。

### 4. 驗證

- 紅：只用舊語意跑 `swift test --filter "Once|MayEndAgain|MayAReplay"`，22 項中 3 項失敗（4 個期望），D1 兩條通過。
- `swift test --package-path ios`：**613／613**（5.2 秒）。
- 模擬器 Debug build（`platform=iOS Simulator,id=05934376…`）：BUILD SUCCEEDED（最終版本 27 秒）；本次改動的程式沒有新 warning（build log 裡的 warning 都在 `WebHTVApp.swift` 第 5411～5413、5547 行，既有）。
- Release 裝置 build（`generic/platform=iOS`、`CODE_SIGNING_ALLOWED=NO EXPANDED_CODE_SIGN_IDENTITY=-`）：BUILD SUCCEEDED（最終版本 31 秒）。
- 模擬器操作驗證：沒有做（loop 沒有 App 內的入口）。真機：未驗證。D8 已隨 `0.1.41 (42)` 發布（run `36698521242`，tag `ios-v0.1.41-b42` → `46c0d36d`）。
- Ponytail：未執行（選配）。
