# IOS-POC-36 — Playback Acceptance & Stability Consolidation

**狀態（2026-10-01，36.3 之後）**：開發完成，0 個已確認缺陷，只剩真機驗收。36.3（第十六節）對未發布範圍做 release-candidate 驗收，找到並修正 D10（失敗之後原地開的下一個 item 仍顯示上一個的失敗訊息），判定 `PASS_WITH_DEVICE_ACCEPTANCE_PENDING`。D1～D7（第八節）已隨 `0.1.39 (40)` 發布，`0.1.40 (41)` 亦包含；36.1（D8 與矩陣證據稽核，第十四節）已隨 `0.1.41 (42)` 發布；36.2（D9：PiP 在背景關閉後的暫停 reload＝PL-14，第十五節）已 commit、尚未發布。矩陣 107 項：`REAL_DEVICE_PASS` 1、`SIMULATOR_PASS` 47（36C 實測 44 項，其餘 3 項沿用 17F／25）、`AUTOMATED_PASS` 28、`RELEASE_BUILD_ONLY` 17、`UNVERIFIED` 12、`KNOWN_LIMITATION` 2、`DEFECT` 0。**D1～D9 都沒有真機驗證。**

## Recovery anchor

- 目標：AVPlayer＋MPV 既有功能的正式 acceptance baseline，修掉找到的 root cause，不新增第三核心、不擴充功能。
- 範圍：`ios/Sources/WebHTVCore`、`ios/WebHTVApp/Sources`、`ios/Tests/WebHTVCoreTests`、`docs`。task guard `IOS-POC-36`（`standard`）。
- 工作位置：36A～36D 在獨立 worktree `/Users/chengchenchih/GIT/webhtv-ios36`（本機分支 `ios-poc-36`，已 push 到 `origin/ios-poc`），因為當時主 checkout 有另一個 session 的 task guard；36.1 在主 checkout `/Users/chengchenchih/GIT/webhtv`（task guard `IOS-POC-36.1`，`quick-fix`）。模擬器用 `05934376-5757-40E5-9FAF-202594565656`（iPhone 17 Pro Max、iOS 26.3），不碰另一個 session 的 `E0A41D48`。
- 已完成：第四節矩陣（107 項，36.1 重新稽核證據強度）、第八節 D1～D10 修正與測試、第六節與第十六節模擬器證據。
- 未驗證：全部真機項目（第十節）；D7（切換瞬間 0:00）只有 build 證據；D8 只有單元測試與 build（已隨 `0.1.41 (42)` 發布）；D9 的決策有單元測試、App 接線只有 build，還不在任何發布版本裡。
- 回滾：`git revert <本任務 commit>`（36 是 `2840c2e4`，36.1 是 `ea96268f`，36.2 是 `fc4a3282`／`f6d1bf30`，36.3 的修正是 `2244dd3a`）；只有 Swift 原始碼、測試與文件，沒有二進位、lock 或設定變更。
- 下一步（唯一）：使用者決定是否發布含 `fc4a3282` 到 HEAD 的下一版；發布後跑第十六節之 8 的一次性真機清單，結果逐項填回第四節（`0.1.41 (42)` 上仍可先跑第十節第 1～14 項）。

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
| AUTOMATED_PASS | 30 | 28 |
| RELEASE_BUILD_ONLY | 15 | 17 |
| UNVERIFIED | 29 | 12 |
| KNOWN_LIMITATION | 2 | 2 |
| DEFECT | 6 | 0 |
| 合計 | 107 | 107 |

36.1 稽核前兩欄是 15／22／26／7／29／2／6 與 15／42／26／9／12／2／1；原本的 15 項 `REAL_DEVICE_PASS` 有 14 項降級，規則與逐項原因在第十四節之 3。36.2 只改 PL-14（`DEFECT` → `AUTOMATED_PASS`，第十五節），36 後一欄因此是 1／47／28／17／12／2／0。36.3 驗收時 SH-03 找到 D10，先降為 `DEFECT`，修正後在模擬器重驗通過，回到 `SIMULATOR_PASS`（第十六節之 3），所以數字不變。



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
| AV-13 | 原生 | 暫停後背景、回來 resume | RELEASE_BUILD_ONLY | **RELEASE_BUILD_ONLY** | 36.1 降級：真機 23 T1～T3（`0.1.20 (21)`，原生一次，走暫停執行後 reload）在 24-2（回來不啟用工作階段、播放時才啟用）與 36 D4／D7 之前；36C 模擬器只驗到沒被暫停執行的返回（仍暫停、同一格），reload 路徑在目前程式只有 build；36.2 把判斷改成兩個核心共用的規則、使用者按的暫停也算（第十五節） |
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
| MPV-14 | MPV | background／foreground | RELEASE_BUILD_ONLY | **RELEASE_BUILD_ONLY** | 36.1 降級：真機 23 T1～T3（`0.1.20 (21)`，MPV 一次）在 24-2（Libmpv 換版、工作階段改由 App 擁有）、17H-2～4（回前景的畫面還原）、36 D3／D5 之前；36C 的暫停中背景沒有記錄核心，也沒有觸發 reload；36.2 把判斷改成兩個核心共用的規則、使用者按的暫停也算（第十五節） |
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
| SH-03 | 雙向 | 上一集／下一集按鈕 | SIMULATOR_PASS | **SIMULATOR_PASS** | 35 T1～T6；36C：第一集的「上一集」變灰；36.3：D10（兩個核心都失敗後按下一集，新的一集仍蓋著上一集的失敗訊息）重現後修正，修正後模擬器重驗：`started … G短片一 on MPV`、沒有訊息；F↔G 上一集／下一集、同一部片沿用 1.5× |
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
| PL-05 | 雙向 | 暫停中背景／前景 | RELEASE_BUILD_ONLY | **RELEASE_BUILD_ONLY** | 36.1 降級，同 AV-13、MPV-14：真機 23 T1～T3 兩個核心都在 24-2、36 之前；36C 模擬器 20 秒沒有觸發暫停執行，reload 路徑只有 build；36.2 把判斷改成兩個核心共用的規則、使用者按的暫停也算（第十五節） |
| PL-06 | 雙向 | 電話 interruption | UNVERIFIED | **UNVERIFIED** | 24 AC6 |
| PL-07 | 雙向 | Siri interruption | UNVERIFIED | **UNVERIFIED** | 24 AC6 |
| PL-08 | 雙向 | 其他 App 音訊 interruption | UNVERIFIED | **UNVERIFIED** | 24 AC1 |
| PL-09 | 雙向 | AVAudioSession 由 App 擁有（mpv 不碰） | AUTOMATED_PASS | **AUTOMATED_PASS** | 24 CI 比對 binary 含 `skip-session-management` |
| PL-10 | 雙向 | 外部音樂共存規則 | KNOWN_LIMITATION | **KNOWN_LIMITATION** | 24 §九之3：啟動時啟用不混音工作階段會中斷其他 App（為了 PiP，不改）；中斷結束不自動續播（24-3，刻意） |
| PL-11 | 原生 | AVPlayer PiP 回 App 結束 PiP | AUTOMATED_PASS | **AUTOMATED_PASS** | 36.1 降級：23 T5 真機通過但未分核心；原生 `PlayerSurface.Coordinator` 的回前景規則在 `0.1.20 (21)` 後沒改，由 `PictureInPictureForegroundRestoreStateTests` 覆蓋 |
| PL-12 | MPV | MPV PiP 內按播放有聲音 | UNVERIFIED | **UNVERIFIED** | 24 AC5 |
| PL-13 | MPV | PiP 內暫停後的 fallback 保持暫停 | UNVERIFIED | **AUTOMATED_PASS** | D4（PiP 的播放／暫停改走 session） |
| PL-14 | 雙向 | PiP 在背景關閉後才被暫停執行，回來會 reload | DEFECT | **AUTOMATED_PASS** | 36.2 D9（第十五節）：舊邏輯以回歸測試重現（3 條紅）後修正，`PausedBackgroundReloadTests` 9 條；App 接線（兩個核心的 PiP 結束、暫停、AVPlayer rate）只有 Debug／Release build；模擬器沒有 PiP 也不會暫停執行 App，**真機未驗證** |

### 控制列與診斷（3 項）

| ID | 核心 | 項目 | 36 前 | 36 後 | 證據 |
|---|---|---|---|---|---|
| UI-01 | 雙向 | 控制列按鍵依意圖、端點按鈕變灰 | AUTOMATED_PASS | **SIMULATOR_PASS** | 27A 測試；36C 截圖 |
| UI-02 | 雙向 | `[playback]` 可區分 startup／seek requested／landed／handoff／fallback reason／finished／auto-next | UNVERIFIED | **SIMULATOR_PASS** | 36C log（見第六節） |
| UI-03 | 雙向 | `[audio] interruption`、`[pip] native` 診斷 | UNVERIFIED | **RELEASE_BUILD_ONLY** | 模擬器無法產生中斷、iPhone 模擬器沒有 PiP |

矩陣說明：

- 36 前 6 項 `DEFECT` 裡，DE-10（RC2）、DE-19（RC4）、PL-14 在 IOS-POC-26／23 已有記錄但沒修；DE-12、DE-18、SH-12 是本任務讀程式時找到、並對照 IOS-POC-23 §十之2 與 17F 的已知風險確認的。MPV-06 是模擬器上測出來的（36 前記 `UNVERIFIED`）。
- 36 後唯一的 `DEFECT` 是 PL-14（見第九節）；36.2 修正後 36 後一欄沒有 `DEFECT`。
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
- 36.2：613 → **622**，`PausedBackgroundReloadTests` 新增 9 條（第十五節之 5）。
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
| D9（36.2） | 播放中進 PiP → 在小視窗暫停（或在背景按 ✕ 關掉播放中的小視窗）→ App 仍在背景時小視窗結束 → 之後被系統暫停執行 → 回到 App（PL-14） | 「回來要不要 reload」只在 `didEnterBackground` 那一刻判斷一次；那時 PiP 開著、還在播放，所以沒有記錄、沒有心跳。之後小視窗結束與暫停都沒有人再判斷，回來沒有記錄，留下被暫停執行過、按播放沒反應的 engine。session 的 PiP 狀態又只經 SwiftUI `onChange` 同步，背景中何時更新沒有保證 | 判斷抽成兩個核心共用的 `PausedBackgroundReload.eligible`；新增 `eligibilityChanged`：App 在背景時，PiP 開關、`control("pause")`、AVPlayer `rate` 任一變化就重新判斷，第一次符合就以當下位置記錄並開始同一個心跳，之後照舊由 `becameActive` 依有沒有被暫停執行決定 reload；回到前景後不再記錄。兩個 PiP 的開始／結束直接通知 session；MPV 關窗的暫停改走 `control("pause")`；「已暫停」也算使用者經 session 按的暫停（mpv 要等屬性事件才回報） | `PausedBackgroundReloadTests` 9 條（舊邏輯 3 條紅、6 個期望） | 背景中任何暫停（鎖定畫面、來電）之後被暫停執行，回來也會 reload——與 23 相同的處理；沒有被暫停執行就不 reload |
| D10（36.3） | 一個 item 在兩個核心都失敗（顯示「無法播放」）後，按下一集／上一集、換畫質，或 WebHome 頁面再呼叫 `player.playUrl`（`f26ccae6` 起原地換片）：新的 item 在 session 已退到的同一個核心上開播，畫面仍蓋著上一個 item 的失敗訊息 | `PlayerView` 的 `failure` 只在 `.task` 開場與 `onEngineChange` 清掉；`PlayerRouter.open` 在 session 的核心上開新 item 不換核心，所以不發 `onEngineChange` | `PlaybackSession.load(_:)`（每個新 item 都經過、唯一呼叫 `router.open` 的地方）呼叫 `onFailure?(nil)`；`onFailure` 改收 optional，`PlayerView` 設 `failure = $0?.message` | 修正前模擬器重現（VodView 與 WebHome 兩條路徑）；修正後兩條路徑重驗沒有訊息；router 層 `anItemOpenedOverAFailedOneStartsCleanOnTheSessionsEngine` | 無：新 item 本來就沒有失敗；prefetch 的重試失敗仍照舊顯示 |

**補的診斷（Release-safe，只寫 log，不改時序）**：`seek requested … from …`、`seek landed … asked …`（兩個核心）、換核心時的 `autoplay=` 與 `reason=`、換核心後在新核心開始播放的 `started … after the switch (reason)`、`finished (end|ending)`、`… ignored: already moving on`、`no next episode … closing`、`mpv end of the previous file ignored`、`[audio] interruption began|ended … shouldResume=`、`[pip] native will start|did stop`。新增的輪詢只有換核心後一個最多 60 秒、每 0.1 秒讀一次 `isPlaying` 的 log 監看（與既有 `watchStartup` 相同做法），不做任何切換。

## 九、Known limitations（fail-safe 行為）

- ~~PL-14~~：36.2 已修（第十五節，D9），真機未驗證。原本的 fail-safe（關掉播放器重開）仍然有效。
- AVKit 原生 PiP 小視窗的播放／暫停直接操作 AVPlayer，不經 `control`，所以 D4 的意圖不含它（小視窗開著時核心失敗換到 MPV 也會結束 PiP，情況罕見）。36.2 改由 AVPlayer 的 `rate` 變化讓背景判斷聽到它。
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
15. **PiP 在背景關閉（D9，要含 36.2 的版本）**：兩個核心各一次——播放中回主畫面讓小視窗出現 → 在小視窗按暫停 → 按小視窗的 ✕ 關掉 → 鎖螢幕至少 1 分鐘 → 從 App 圖示回來：畫面停在剛才暫停的地方，按播放 5 秒內開始。再各做一次「小視窗暫停後按『回到 App』」：不應重新載入（不重新緩衝、不跳位置）。可以的話接 Console.app 看 `[lifecycle]` 與 `[pip]` 行（PL-14）。

可以的話，接 Mac 用 Console.app 過濾 `[playback]`，把第 1、2、6 項的 log 一起給我，比畫面描述更能判定。

## 十一、使用者可見的行為變更

- **有（刻意）**：D4 — 核心失敗而自動換到另一個核心時，依使用者最後一次的播放／暫停（以前一律照開啟時的 autoplay，暫停中失敗也會自己播放；暫停 reload 後按了播放再失敗會回到暫停）。
- 其餘是修正：D1（不再跳過一集）、D5（MPV 中途失敗接在失敗處）、D6（連按 ±10 累加）、D7（切換瞬間不從 0 起算）；D2、D3 平常看不到。
- 36.1（D8）：loop 開著時，同一段播放只 replay 一次；上一集／下一集進行中遇到結尾交給進行中的換集，不再同時 replay。
- 36.3（D10）：失敗之後換到下一個 item（下一集／上一集、換畫質、WebHome 再播放）時，上一個 item 的「無法播放」訊息會消失。
- 36.2（D9）：App 在背景時播放器被暫停（在 PiP 小視窗暫停後關掉、按 ✕ 關掉小視窗、鎖定畫面暫停、來電等中斷），之後 App 被系統暫停執行的話，回來會在暫停的位置以暫停狀態重新載入，與 IOS-POC-23 的「暫停後進背景」相同。沒被暫停執行就不重新載入。

## 十二、Rollback

- 單一 commit，`git revert` 即可；不涉及 lock、patch、二進位、`project.pbxproj`、設定鍵或資料格式。
- 分開回退：D4 是 `PlayerRouter.setIntendsToPlay` 與 `PlaybackSession.control` 的兩行；D6 的 MPV 部分是 `MPVEngine.seekAsked`；D1 是 `PlaybackEndGate` 與 `finished(reason:)` 的 guard。
- 36.2 是另一個 commit，可單獨 revert：`PausedBackgroundReload.eligible`／`eligibilityChanged`、`isPausedOnScreen`、`noteBackgroundEligibilityChanged` 與它的四個呼叫點（PiP 開關、`control("pause")`、AVPlayer `rate`）、MPV `ended()` 的暫停改走 session、測試與文件；revert 後回到 PL-14 的 `DEFECT`。
- 36.3 的 D10 是 `2244dd3a`，可單獨 revert（`WebHTVApp.swift` 三處：`onFailure` 的型別、`load(_:)` 的 `onFailure?(nil)`、`PlayerView` 的 `$0?.message`）；36.3 的測試是 `eaa3af75`、`b9ff7e7e` 與本節收尾 commit，只加測試。
- 36.1 是另一個 commit，可單獨 revert：`PlaybackEndGate.end(looping:)`、`PlaybackEngine.seek(toSeconds:landed:)` 與兩個引擎的實作、`finished`／`replay`、測試與文件；revert 後回到 36 的 loop 行為（loop 不經 gate）。

## 十三、驗證紀錄

- `swift test --package-path ios`：586／586（worktree，`0f9b05cf` 加本任務變更）。
- 模擬器 Debug build（`platform=iOS Simulator,id=05934376…`）：BUILD SUCCEEDED，本任務檔案 0 新 warning。
- Release 裝置 build（`generic/platform=iOS`、`CODE_SIGNING_ALLOWED=NO EXPANDED_CODE_SIGN_IDENTITY=-`）：BUILD SUCCEEDED。第一次沒帶 `EXPANDED_CODE_SIGN_IDENTITY=-` 時，上游 `install_python` 簽 framework 失敗（`no identity found`），屬呼叫方式，與 17H-4 記錄的指令相同後通過。
- 模擬器驗收：第六節。
- Ponytail：未執行（當時記為選配、略過）。使用者 2026-10-01 說明「選配」的意思是環境有 ponytail 就一定要執行；36 的 `2840c2e4` 沒有補做，36.1、36.2 的補做見第十五節之 8。
- 36.1 的驗證見第十四節之 4；36.2 見第十五節之 6。

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
  4. `PlaybackEngine.seek(toSeconds:landed:)`：AVPlayer 在 seek completion 回呼（不論 `finished`：被取代的 seek 一樣把播放頭帶離結尾）；MPV 在下一個 `PLAYBACK_RESTART` 回呼，`load` 清掉還沒落地的；原本另有「送出就算落地」的 protocol extension 預設，ponytail review 後改成只有這一個 requirement，`seek(toSeconds:)` 是 extension 的轉呼叫（第十五節之 8）。
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
| AV-13 | RBO／RBO | 真機在 24-2、36 D4／D7 之前；模擬器沒走 reload；36.2 把判斷改成兩個核心共用的規則、使用者按的暫停也算（第十五節） |
| AV-14 | RBO／RBO | 真機未分核心（當時 MPV 也有 PiP） |
| AV-15 | RBO／RBO | 真機未分核心；切換本身只有 build |
| AV-19 | SIM／SIM | 真機在 35、36 D1／D2 之前；T10 未分核心 |
| MPV-01 | RD／RD（保留） | `0.1.35 (36)` 錄影仍有畫面，之後沒改首格路徑 |
| MPV-02 | AUTO／SIM | 真機在 24-2、27A、36 D4 之前 |
| MPV-14 | RBO／RBO | 真機在 24-2、17H-2～4、36 之前；36.2 把判斷改成兩個核心共用的規則、使用者按的暫停也算（第十五節） |
| SH-01 | AUTO／SIM | 真機未分核心，在 26-1、36 D7 之前 |
| PL-04 | RBO／RBO | 真機只有一次、未分核心；24-2 |
| PL-05 | RBO／RBO | 真機在 24-2、36 之前；模擬器沒走 reload；36.2 把判斷改成兩個核心共用的規則、使用者按的暫停也算（第十五節） |
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
- Ponytail：commit 時未執行；2026-10-01 補做，結果與套用見第十五節之 8。

## 十五、IOS-POC-36.2：PL-14 PiP 在背景關閉後的暫停 reload（2026-10-01）

### 1. 起始狀態

- 09:19 CST `git fetch`：HEAD＝`origin/ios-poc`＝`65a273eb`（`docs(ios): record 0.1.41 (42)`），工作區乾淨。
- `0.1.41 (42)` 已完成：run `36698521242` success（2026-09-30 09:49:05Z → 09:54:59Z，head `46c0d36d`）；tag `ios-v0.1.41-b42` → `46c0d36d`（本機與遠端一致）；GitHub Release `WebHTV 0.1.41 (42)` 不是 draft／prerelease，2026-09-30 09:54:48Z 發布，資產 `WebHTV-0.1.41-42.ipa` 29,344,346 bytes、`sha256:247768a7…8735`、狀態 uploaded；`source.json` 42 筆、第一筆 `0.1.41`、size 相同；下載網址 HEAD 回 200、`content-length` 29,344,346（沒有下載內容）。沒有重新發版。
- 授權：同一個 Claude session 的對話紀錄裡，使用者在 36.1 回報之後下了「發布新版 0.1.41 (42)」，之後才執行版號 commit（Task-Guard `IOS-RELEASE-0.1.41-b42`）與 workflow；記錄在 IOS-POC-11 第四十二次發布。36.1 任務本身的「不要 bump／tag／release」是那個任務的範圍，發布是之後另一則指示。
- 36.1 的 `ea96268f` 沒有重做。

### 2. 重現（舊邏輯）

先把 `eligibilityChanged` 做成什麼都不做（等於舊 App：進背景之後沒有人再判斷），新測試 3 條、6 個期望失敗：`pausedInTheWindowAndClosedThereIsReloadedAfterASuspension`（回來得到 nil，不是 310）、`aWindowClosedBeforeItsPauseArrivesIsArmedByThePause`、`aPlayerPlayedAgainInTheBackgroundIsJudgedAgainWhenItPauses`；防止誤判的 6 條在舊邏輯本來就通過。**只在決策模型上重現**；模擬器沒有重現（iPhone 模擬器沒有 PiP，模擬器也不會暫停執行 App），真機沒有重現。

### 3. Event sequence

PL-14 的情境（數字是發生順序；「舊」是修正前、「新」是修正後）：

| # | 事件 | 原生（AVKit） | MPV（sample-buffer PiP） | 背景判斷 |
|---|---|---|---|---|
| 1 | 播放中回主畫面 | `playerViewControllerWillStartPictureInPicture` → PiP 開 | `pictureInPictureControllerWillStartPictureInPicture` → `setActive(true)` | — |
| 2 | `didEnterBackground` | `noteEnteredBackground`：播放中＋PiP 開 → 不符合，沒有記錄、沒有心跳 | 同左 | 兩者相同 |
| 3 | 在小視窗按暫停 | AVKit 直接暫停 AVPlayer → `rate` KVO 為 0 | `setPlaying(false)` → `control("pause")` → 意圖＝暫停 | 舊：沒有判斷。新：重新判斷，PiP 仍開 → 不記錄 |
| 4 | 在背景按 ✕ 關小視窗 | `playerViewControllerDidStopPictureInPicture` → binding；新：直接設 session 的 PiP 狀態 | `willStop` → `didStop` → `ended()`：先 `setActive(false)`，再暫停（新：經 `control("pause")`） | 舊：SwiftUI `onChange` 之後才更新，沒有判斷。新：暫停＋PiP 關＋session 有效 → **以當下位置記錄，開始心跳**，log `[lifecycle] … paused in the background … reloads on return if suspended` |
| 5 | iOS 暫停執行 App（暫停中的音訊 App 幾秒後） | 心跳停 | 同左 | — |
| 6 | 從 App 圖示回來，`didBecomeActive` | `noteBecameActive` | 同左 | 舊：沒有記錄 → 不 reload，按播放沒反應。新：心跳間隔 > 3 秒 → `reloadPaused(at:)`（既有 23 的路徑，以暫停狀態載入） |

其他順序：

- **播放中直接按 ✕**：MPV 是「PiP 關」在前、「暫停」在後（`ended()` 的順序）——第一次判斷時還在播放、不記錄，暫停那次才記錄。AVKit 是否暫停、`rate` 與 `didStop` 誰先，Apple 沒有寫；兩種順序都會在後到的那個事件記錄。AVKit 若不暫停，App 繼續播放、不會被暫停執行，也就不需要 reload。
- **小視窗的「回到 App」**：`willStop` → `restoreUserInterface…` → `didStop` 與 `didBecomeActive` 先後不定。`didStop` 先到且已暫停：剛記錄就回來，沒有心跳間隔 → 不 reload。`didBecomeActive` 先到：已不在背景 → 不記錄。17H-4 的前景 stop（MPV 300 ms、原生 `consumeForegroundRequest`）沒有改。
- **PiP 一直開著**（23 T6）：PiP 開著就不符合，與以前相同。

### 4. Root cause 與修法

- **Root cause**：IOS-POC-23 的判斷只在 `didEnterBackground` 做一次（`noteEnteredBackground`）。條件裡的「沒有 PiP」與「已暫停」在背景中還會改變，卻沒有任何事件再判斷；session 的 `pictureInPictureActive` 也只靠 PlayerView 的 SwiftUI `.onChange` 同步。
- **修法**（沒有第二套背景狀態機，沒有計時猜測，PiP 結束本身不 reload）：
  1. `PausedBackgroundReload.eligible(sessionOpen:failed:loaded:paused:pictureInPicture:)`：唯一的判斷規則，兩個核心共用；`isPausedOnScreen`（`WebHTVApp.swift` `PlaybackSession`）改用它。
  2. `PausedBackgroundReload.eligibilityChanged(eligible:position:at:)`：只在 `enteredBackground` 到 `becameActive` 之間有作用；符合且還沒有記錄 → 記錄並回傳 true（呼叫端開始同一個心跳）；不符合 → 清掉記錄；已有記錄 → 保留（心跳照算）。
  3. `PlaybackSession.noteBackgroundEligibilityChanged()` 的呼叫點：`pictureInPictureActive` 改變（`didSet`）、`control("pause")`、AVPlayer `rate` KVO（AVKit 小視窗與鎖定畫面不經 session）。
  4. 原生 `PlayerSurface.Coordinator` 的 will start／did stop 與 MPV 的 `onActiveChange` 直接設定 session 的 PiP 狀態；SwiftUI 的 `onChange` 同步在 ponytail review 後刪掉（重複），畫面出現時的 `.task` 同步保留（之 8）。
  5. MPV `ended()` 在背景的暫停從 `engine?.pause()` 改成 `PlaybackSession.shared.control("pause")`：使用者意圖記為暫停（D4 的 fallback 也照它），也會重新判斷。
  6. 「已暫停」＝引擎 `rate` 為 0 **或** router 記錄的意圖是暫停：mpv 對 `pause` 的回報要等下一個屬性事件，暫停後立刻判斷時 `rate` 還不是 0。
- **AVPlayer／MPV**：同一個規則、同一個背景記錄與心跳；差別只在事件來源（原生靠 `rate` KVO 與 AVKit delegate，MPV 靠 `control("pause")` 與 `setActive`）。

### 5. 新增測試（`PausedBackgroundReloadTests`，613 → 622）

| 測試 | 涵蓋 |
|---|---|
| `onlyAnOpenLoadedPausedPlayerOutsideTheWindowIsEligible` | 共用規則的 32 種組合只有一種符合（兩個核心共用） |
| `playingInTheWindowIsNotArmedWhenTheAppLeaves` | 播放中進背景＋PiP 開，不記錄 |
| `pausedInTheWindowAndClosedThereIsReloadedAfterASuspension` | PL-14 主情境：小視窗暫停後在背景關閉 → 記錄 → 被暫停執行 → 回來 reload；重複事件保留原記錄（舊邏輯紅） |
| `aWindowClosedBeforeItsPauseArrivesIsArmedByThePause` | MPV 的順序（先關窗後暫停）也記錄（舊邏輯紅） |
| `aWindowStillOpenIsNeverArmed` | PiP 仍開著不記錄（23 T6 不變） |
| `aWindowClosedWhilePlayingIsNotReloaded` | 播放中關小視窗不記錄 |
| `theWindowsBackToTheAppButtonIsNotABackgroundClose` | 「回到 App」兩種先後都不 reload |
| `aFailureOrAClosedPlayerIsNeverArmed` | 已顯示失敗、session 已關閉都不記錄 |
| `aPlayerPlayedAgainInTheBackgroundIsJudgedAgainWhenItPauses` | 背景中再播放會清掉記錄，再暫停以新位置記錄（舊邏輯紅） |

### 6. 驗證

- `swift test --package-path ios`：**622／622**（5.1 秒）；focused（paused-background 與新測試）40／40。
- 模擬器 Debug build（`platform=iOS Simulator,id=05934376…`）：BUILD SUCCEEDED（31 秒）；本次改動沒有新 warning（列出的 warning 都是既有的：`MPVProbeView.swift`、`PythonBoot.swift`、`PythonSpiderRuntime.swift`，以及 `WebHTVApp.swift` 原本第 5411～5413、5547 行，因加行位移到 5446～5448、5582）。
- Release 裝置 build（`generic/platform=iOS`、`CODE_SIGNING_ALLOWED=NO EXPANDED_CODE_SIGN_IDENTITY=-`）：BUILD SUCCEEDED（44 秒）。
- 模擬器操作：沒有做——iPhone 模擬器沒有 PiP；模擬器不會暫停執行 App，reload 路徑走不到（36C 已記錄）。**真機未驗證**；PL-14 記 `AUTOMATED_PASS`（決策有回歸測試，與 D4、D5 的記法相同），不是真機通過。
- Ponytail：commit 時未執行；2026-10-01 補做，見之 8。

### 7. 殘餘風險

- AVKit 按 ✕ 時是否暫停、事件先後沒有文件；兩種順序都已處理，但真機事件順序要看 `[pip]`／`[lifecycle]` log 才能確認。
- 「已暫停」包含使用者意圖：在 session 暫停後，若 AVKit 小視窗或鎖定畫面直接讓 AVPlayer 播放（不經 session），意圖仍是暫停，背景中可能被記錄；播放中的 App 不會被暫停執行、沒有心跳間隔，所以不會 reload。
- 範圍比 PL-14 稍大：背景中鎖定畫面暫停、來電等中斷暫停之後被暫停執行，回來也會 reload（與 23 相同的處理）；PL-06／07／08 仍 `UNVERIFIED`。
- MPV 在 PiP 之後 reload：17H-2 的 Metal 等 `PLAYBACK_RESTART` 才顯示，reload 會重新載入並產生它；沒有在真機或模擬器跑過這個組合。
- 同一個 session 只有一個背景記錄；PiP 開著時 App 被結束（不是暫停執行）不在本修正範圍。

### 8. Ponytail review（2026-10-01 補做）

使用者說明「Ponytail 選配」＝環境有就一定要執行。這個環境有 `ponytail:ponytail-review`，36.1（`ea96268f`）與 36.2（`fc4a3282`）commit 時卻記成「未執行（選配）」，所以補做，並依使用者指示套用。

| # | 位置（review 當時） | 標籤 | 發現 | 處理 |
|---|---|---|---|---|
| 1 | `PlaybackEngine.swift` L310-313、L339-345；`WebHTVApp.swift` L3717；`MPVEngine.swift` L125-134；`PlaybackEngineTests.swift` L37 | yagni | `seek(toSeconds:)` 與 `seek(toSeconds:landed:)` 兩個 requirement，外加「送出就算落地」的預設 | 只留 `seek(toSeconds:landed:)`；`seek(toSeconds:)` 是 extension 一行轉呼叫；AVPlayer 的轉呼叫刪掉、MPV 兩個方法合成一個；`FakeEngine` 自己呼叫 `landed()` |
| 2 | `WebHTVApp.swift` L4955-4956 | delete | 36.2 已讓兩個 PiP 直接設定 session，SwiftUI `.onChange(of: pictureInPicture)` 的同步重複 | 刪除；PlayerView 的 `pictureInPicture` 只由這兩個來源的 binding 寫入，兩者都直接設定 session。`.task` 的開場同步保留 |
| — | `MPVEngine.swift` L253-255 | （不採用） | 先複製回呼清單、清空、再逐一呼叫，看似可縮短 | 回呼執行時可能再加入新的 seek，邊跑邊清會把它弄丟，保留 |

- 結果：程式淨減 9 行，行為不變（MPV 的一般 seek 也會放一個空回呼，`PLAYBACK_RESTART` 或下一個 `load` 清掉）。
- 驗證（套用後）：`swift test --package-path ios` 622／622；模擬器 Debug build BUILD SUCCEEDED（27 秒）；generic iOS 不簽章 Release build BUILD SUCCEEDED（42 秒）；沒有新 warning（列出的都是既有的，`WebHTVApp.swift` 的 5442～5444、5578 行只因刪行位移）。
- 真機：未驗證。矩陣不變（107 項，36 後 1／47／28／17／12／2／0）。

## 十六、IOS-POC-36.3：未發布範圍的 release-candidate 驗收（2026-10-01）

### 1. 起始狀態與範圍

- 11:20 CST `git fetch`：HEAD＝`origin/ios-poc`＝`5818b83c`，ahead／behind 0／0，工作區乾淨。最新發布 `0.1.41 (42)`，tag `ios-v0.1.41-b42` → `46c0d36d`。
- 未發布範圍：`46c0d36d..HEAD`。程式從 `fc4a3282`（36.2）開始，包含 ponytail audit 第一批（`8bfe875a`、`f26ccae6`、`736023f8`）、第二批（`1ea1c732`、`3fd68923`、`53de9b61`），以及本節的 `eaa3af75`、`b9ff7e7e`、`2244dd3a` 與收尾 commit；`af6f8b5e`／`65a273eb` 只是 `0.1.41 (42)` 的 `source.json` 與紀錄。
- 只驗收與修 root cause：沒有做 audit 第三批、沒有動 `RuntimePackManifest`、ABI、release workflow 與待決定的 UI／HLS／搜尋項目，沒有 bump、tag 或發布。
- 環境：模擬器 `05934376`（iPhone 17 Pro Max），本機 CMS＋HLS server（`scripts/ios_adskip_sim/server.py` 的 scratchpad 複本，port 8766，A～E 沿用 IOS-POC-25 的 fixture；F 130 秒、G／H 各 24 秒以 ffmpeg 重新產生；另加一條「壞線」：X失敗（404）＋G），證據是 `log stream` 的 `[playback]`／`[adskip]` 行與截圖。

### 2. WebHome A→B 原地換片（`f26ccae6` 的 regression）

- 路徑：`WebHomeView` 的 `onPlay` → `PlaybackSession.open(PlaybackTarget(url:), history: nil)` → `playing = true`（本來就是 true，cover 不動）。`f26ccae6` 之前是 `fullScreenCover(item:)`：新的 id 會讓 SwiftUI 關掉再重開，舊 `PlayerView.onDisappear` 對剛開的 B 送出 `control("pause")`、`persist()` 與 `closePlayer()`（`router.endSession`）。
- 和 VodView 的差別：自動下一集、上一集／下一集走 `VodView.start(_:flag:usingPrefetch:)`，原地 `open`、不碰 presentation；`f26ccae6` 只把 `playNext` 換成 `step(forward: true)`（第 25 項，36C 已驗）。D1～D9 的路徑（`finished`、`PlaybackEndGate`、引擎通知過濾、背景 reload）都沒有被 WebHome 的改動碰到。
- Core：`anItemOpenedOverAFailedOneStartsCleanOnTheSessionsEngine`——B 的 request 整個是 B 的（A 的位置 60 s、headers、history、1.5×、暫停意圖都不帶過去），失敗清掉，fallback 額度重新給，留在 session 的核心上且**不發** `onEngineChange`（D10 的成因）。
- 模擬器：暫時在本機 showcase 頁加兩個動作（播 A，12 秒或 30 秒後由頁面 JS 播 B；「壞A」是 404），控制列自動隱藏暫時改 600 秒以便工具操作；兩者 build 後立即還原，沒有 commit。

| 情境 | 觀察 |
|---|---|
| A→B（原生，修正前 build） | `summary A長片` → 18 ms 後 `started B短片 on 原生`；B 從 0 開始（`seek requested 11.3s from 1.3s`）；沒有第二個 `summary`、B 沒被暫停 → 播放器沒有關掉重開；`B短片 finished (end) on 原生 at 24s/24s` → `no next episode after B短片 — closing` |
| A→B（修正後，重複 4 次） | 同上；頁面計時器在 PlayerView 蓋住頁面時照常觸發 |
| 壞A→B（修正前） | A：原生 404 → `on MPV … reason=failure: 網路錯誤：HTTP 404` → MPV 失敗、顯示「無法播放」；B：`started B短片 on MPV`（session 已退到 MPV）——**A 的訊息蓋在播放中的 B 上**（D10） |
| 壞A→B（修正後） | B 在 MPV 播放、沒有訊息；B 播完關閉 |

- 沒有實測到的：A 遲到的結束／失敗通知落在 B 載入之後（A 都在播完前被換掉）——由引擎過濾（D2 的 `isCurrent`、D3 的 MPV 載入世代），與自動下一集相同；A 已調成其他速度時 bare URL 的 B 回到預設速度——工具的點擊延遲讓速度選單沒有在 A 上生效，程式路徑是 `open(url:)` 對沒有 key 的 history 重設 `chosenRate`、`loadNative` 以 `request.rate` 設 `defaultRate`；有一輪 B 以 2.0× 播放，但 A 期間沒有任何 `[playback] speed` 行（A 已套用過 buffer policy，換速度必定寫這一行），所以是點在 B 上，不是外漏。

### 3. D10：失敗之後原地開的 item 仍顯示上一個的失敗訊息

- 重現（修正前，HEAD `5818b83c` 的 Debug build）：壞線 X失敗 → 原生 404 → MPV `-13` → 「無法播放：…(mpv error -13.)」→ 按下一集 → `started 廣告測試 G短片一 on MPV`，G 播到 00:05，訊息仍在（11:30）。WebHome 壞A→B 相同（11:34）。
- Root cause、修正、回歸風險：第八節 D10。所有原地開新 item 的路徑都經過 `load(_:)`：下一集／上一集（IOS-POC-35 起就有這個問題）、換畫質、bridge 播放清單、WebHome `playUrl`；`f26ccae6` 之前 WebHome 會重開畫面，所以那條路徑是被 `f26ccae6` 帶出來的。
- 驗證：修正後 WebHome 壞A→B（11:40）；最終乾淨 Debug build 上 VodView X失敗 → 下一集（12:00）：G 在 MPV 播放、沒有訊息。PlayerView 的 `@State` 不在 Core，證據是 build＋模擬器（同 D2、D3）。
- 矩陣：SH-03 `SIMULATOR_PASS` → `DEFECT`（11:30）→ `SIMULATOR_PASS`（12:00）。

### 4. 整合回歸（最終程式）

- Focused：新測試 `carriesEveryFieldOfAVideoAndNoneIntoTheNext`、`anItemOpenedOverAFailedOneStartsCleanOnTheSessionsEngine`、`theJSVisibleHashesMatchCommonCryptoByteForByte`（700 組比對）、`reidentifyingARecordChangesItsKeyAndNothingElse`；MacCMS 5 條在 `f26ccae6^` 的 decoder 上也全過，`reidentified` 測試在 `f26ccae6^` 的 `WatchHistory.swift` 上也過（跑完即還原）。
- `swift test --package-path ios`：起點 `5818b83c` 616／616；修正後 619／619；加上 `reidentified` 測試後 **620／620**（5.0 秒）。
- Build（`2244dd3a` 的程式）：模擬器 Debug（`id=05934376…`）39 秒、generic iOS 不簽章 Release（`CODE_SIGNING_ALLOWED=NO EXPANDED_CODE_SIGN_IDENTITY=-`）47 秒、`WebHTVCore` generic iOS 3 秒，全部 BUILD SUCCEEDED；warning 都是既有的（`WebHTVApp.swift` 5352～5354、5488，`PythonSpiderRuntime.swift:142`，`PythonBoot.swift:24`），沒有出自這次改動的。起點 `5818b83c` 也跑過一次三個 build（27／26／3 秒）。cold build 沒有遇到 module map 問題（DerivedData 已有快取）。

### 5. 功能 smoke

| 區塊 | 證據 |
|---|---|
| MacCMS XML | `MacCMSXMLTests` 5 條：`id/name/pic/note/year/area/type/director/actor/des/dd` 全部比對、第二部影片不帶上一部的欄位（新增） |
| MediaSniffer | `MediaSnifferTests` 11、`SnifferRulesTests` 31（直接媒體、wrapper 解包、排除清單、設定的 `rules`） |
| CryptoHost | MD5／SHA1／SHA256／HMAC 已知向量＋與 CommonCrypto 逐位元比對 700 組（含空 key、64／65／200 bytes key、Unicode、未知演算法名）；AES CBC／ECB、DES、IV 前置的既有測試通過 |
| WatchHistory | `WatchHistoryTests` 44：續播、片頭片尾、身分遷移（`legacyIdentityMigrationKeepsProgress`）、`reidentified` 只換 key（新增） |
| AdBlockList | `AdBlockListTests` 9 |
| Spider registry／pack | `SpiderPackTests` 12（pack 優先於內建、alias `aPackAliasResolvesAConfiguredClassToTheScriptThatDrivesIt`、雜湊不符／HTTP／host 太舊都拒絕、沒有 pack 時跑內建）、`SpiderGoldenTests` 6、`ContractFreezeTests` 4 |
| XBPQ | `XBPQRuleTests` 24（已發布的 S1～S5 規則） |
| Python | `PythonRoutingTests` 8；模擬器 Debug 啟動輸出：`boot running(version: "3.13.15")`、8 項 `deps OK`（requests 2.34.2、ssl／certifi 121 CAs、pycryptodome 3.23.0、RSA、bs4 4.15.0、lxml 6.1.3、pyquery、base.html）、`cache A→B→A OK`（快取每站隔離）、`selfcheck 13/13 methods OK`；`survey` 因測試設定沒有 Python 站而略過 |
| Router／fallback | `PlaybackEngineTests` 43（雙向 fallback、不彈回、每集重新取得額度、手動切換、session 結束回預設、播放中改預設等下一個 session） |
| loop、暫停 fallback | `PlaybackActivityTests` 23（含 D1、D8 的五條）；`aPausePressedWhileStartingIsKeptByTheFallback` 等 |
| PiP lifecycle | `PausedBackgroundReloadTests` 21、`PictureInPictureForegroundRestoreStateTests` 4 |
| HLS 去廣 | `HLSAdSkipTests` 56、`HLSAdTimelineTests` 22、`HLSAdsParserTests` 8；模擬器 F／G／H `plan no-ads ranges=none` |
| 模擬器 UI | 首頁、詳情（兩條線）；設定頁「加入設定來源」對話框（空欄位、取消）；設定頁與播放器內的核心選單只有「原生播放器」「MPV」；F 在原生開播；+10、+10、−10 累加（0.7→10.7→20.7→10.7，`landed 10.7s asked 10.7s finished=true`）；暫停中切 MPV（`from 2.503032s exact=yes autoplay=no reason=viewer`）、播放、1.5×、播放中切回原生（`from 38.463222s exact=yes autoplay=yes`）；下一集 G（`prefetched 0ms`，沿用 1.5×）、上一集 F（`live, previous episode`）；自動下一集 F→G（`prefetched 0ms`）、G→H（live）；最後一集關閉：原生 H、MPV G（壞線）；續播規則：9.9 秒低於 10 秒門檻從頭播（D4 規則，設計如此） |

### 6. 這批 audit 的回歸查核

| 項目 | 結果 |
|---|---|
| `MPVProbeView`／`MPVBoot`／`PythonLiveCheck.run()`（第 2、5、12 項） | 三者原本只在 `#if DEBUG` 的啟動區塊或 Debug 選單；repo 裡已沒有任何參照；Release 從來沒執行過 |
| 兩個播放器都可選、fallback 雙向（第 13 項、`available`） | 模擬器選單兩項都可選；原生→MPV（404）實際發生；MPV→原生由 `mpvFallsBackToAVPlayerToo`、`theNextEpisodeGetsItsOwnFallback` 覆蓋 |
| `PlaybackEngineSelection.available`／`sessionOverride` | `sessionOverride` 在刪除前只寫不讀；`available` 自 `8bfe875a` 起一律是兩個引擎；default／manual／fallback／reset 由既有 router 測試覆蓋，模擬器上手動切換兩個方向、session 結束後下一部片回預設（原生）都符合 |
| MediaSniffer 拿掉自訂清單（第 23 項） | 改動前的所有呼叫者（`SourceClient` 兩處、`PythonLiveCheck`）只傳 page／referer；兩個測試傳的就是預設清單；設定檔的 `rules` 走 `SnifferRules`，不受影響 |
| MacCMS 字典（第 10 項） | 新測試涵蓋全部欄位，refactor 前的 decoder 也通過 |
| CryptoKit（第 16 項） | 與 CommonCrypto 逐位元相同（700 組） |
| `WatchHistory.reidentified`（第 34 項） | 17 個 stored property 與 init 參數一一對應、init 是逐欄位指派；新測試在 refactor 前後都過 |
| `spider_pack.py`（第 39 項） | `53de9b61^` 版本與 HEAD 版本對同一份 spiders 產出的 pack 逐位元相同（8 支 script＋manifest，manifest SHA-256 `d6c38dee…`） |
| `audit_spider_jars.py`（第 37 項） | 真實 JAR：以前 session 留下的 `xyqxbpq.jar`（SHA-256 `7b732f22…`，與 `DEFAULT_ORIGINS` 相同）組成最小 config＋archive，jadx 1.5.6 反編譯；1 個 dex、沒有 native、11 種 JAR 依賴；XBPQ → `http-crypto`、XYQHiker → `http-json`、不存在的 JAR → `resource-missing`；`53de9b61^` 版本產出的 `audit.json` 完全相同 |

### 7. 矩陣

- 逐列重算（只算六欄的矩陣列）：107 列、107 個不重複 ID（AV 19、MPV 20、DE 20、AD 19、SH 12、PL 14、UI 3）。36 前 1／24／30／15／29／2／6，36 後 **1／47／28／17／12／2／0**。
- PL-14（D9）是 `AUTOMATED_PASS`，不是 `REAL_DEVICE_PASS`；`REAL_DEVICE_PASS` 只有 MPV-01。
- 36.3 唯一的狀態變動是 SH-03 的 D10（之 3），收尾時回到 `SIMULATOR_PASS`。其餘本節模擬器重驗的列（AV-01／03／05、AV-19、MPV-18、DE-01～04、DE-11、DE-13、SH-02～04、SH-11、AD-01、UI-01）原本就是 `SIMULATOR_PASS` 以上，狀態不變。

### 8. 只能真機驗的項目：一次性清單

下一版（含 `fc4a3282` 到 HEAD）裝好後照順序做，回報「第幾項：正常／不正常＋一句」。可以的話接 Console.app 看 `[pip]`、`[lifecycle]`、`[playback]`、`[audio]`。

1. **PiP 背景關閉（PL-14／D9）**：兩個核心各一次——播放中回主畫面 → 小視窗暫停 → 按 ✕ → 鎖螢幕至少 1 分鐘 → 從圖示回來：停在剛才的畫面，按播放 5 秒內開始。再各做一次「小視窗暫停後按『回到 App』」：不重新緩衝、不跳位置。
2. **MPV PiP（MPV-10～13、PL-01／02、PL-12）**：小視窗一出現就有畫面；小視窗內暫停再播放有聲音；「回到 App」多試幾次不閃舊格、不變形。
3. **原生 PiP（AV-14、PL-11、AV-11）**：進出各一次；小視窗中讓開播慢的站自動下一集，不會 5 秒就被換到 MPV。
4. **暫停後背景（AV-13、MPV-14、PL-05）**：兩個核心各暫停後鎖螢幕 1 分鐘：仍暫停、同一格，按播放 5 秒內開始。
5. **播放中背景（AV-12、PL-04）**：兩個核心各播放中回主畫面 30 秒：聲音持續，回來不跳位置。
6. **中斷（PL-06／07／08、MPV-19／20）**：先開「音樂」再用 MPV 播：音樂停止；MPV 播放中來電或叫 Siri，結束後按播放有聲音。
7. **MPV 硬體解碼（`MPVEngine.swift:441` 的 ponytail 註記）**：MPV 播 1080p 以上一段，Console 過濾 `hwdec`，記下 `hwdec-current`。
8. **MPV 旋轉、常亮、音軌字幕（MPV-08／09、MPV-15～17）**：播放中、暫停中各旋轉一次；播 2 分鐘不碰螢幕不變暗；有多音軌／字幕的片子切換一次。
9. **AirPlay（AV-11）**：有接收端時原生播放中送出，回來不被當成開播逾時。
10. **去廣與片尾（AD-13／16／17、D1）**：有廣告的集數兩個核心各看過一次廣告位置；把某集片尾設在結尾前 5～10 秒，看到結尾只換到下一集。

第十節的其他項目（切換位置、連按 ±10、暫停中切換、高倍速、最後一集）本節已在模擬器重驗，真機有空再順便看即可。

### 9. Ponytail

- `2244dd3a`（D10）：`ponytail:ponytail-review` → Lean already；考慮過改由控制列每 0.25 秒讀 `router.failure`，行數相同、prefetch 重試時會閃一下，不採用；`onEngineChange` 裡的 `failure = nil` 仍需要（手動切換與 fallback 不經 `load`）。
- `eaa3af75`、`b9ff7e7e` 與收尾 commit 的測試：Lean already（差異測試裡的 CommonCrypto helper 就是被比對的舊實作）。

### 10. 判定

**`PASS_WITH_DEVICE_ACCEPTANCE_PENDING`**：能在 Mac／模擬器上自動或實際操作驗的都驗了，找到的唯一缺陷 D10 已重現、修正、重驗；沒有已知 regression。之 8 的項目只能真機驗，結果出來前不算 `RELEASE_CANDIDATE_PASS`。發版需要使用者授權。
