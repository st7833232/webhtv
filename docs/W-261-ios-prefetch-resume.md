# W-261 MPV 副本提早結束從中斷處接續、片尾拖曳不誤重解析

## Recovery anchor

- 目標：W-243 Reviewer 非阻擋兩項（#6318）。①MPV 播下一集預抓副本時提早結束、重新解析後從中斷處接續，不從起播點重播約 16 秒；②在副本窗口內手動拖到片尾造成的結束，不當成副本失敗而多重解析一次。
- 狀態：完成，待 reviewer-2 審。task/W-261 自 origin/ios-poc 1f23437a。
- 下一步：依審查意見修正；之後接 W-262（BVC2）。

## 根因

- ①`PlaybackSession.recoverCopy` 用 `engine.currentTime` 當接續位置。mpv 播完（含提早結束）一個串流後會把 `time-pos` 清成 0，而檔案仍標記為已載入，所以 `MPVEngine.currentTime` 回 0 → `retryResumeSeconds = nil` → 從頭播。引擎其實已經記著最後一次大於 0 的位置（`Snapshot.reached`，IOS-POC-36，每次載入重設），只是沒被用到。
- ②`finished(reason:)` 只要「結束時副本窗口還開著、集長大於窗口＋30 秒」就當成副本失敗，沒有看播放位置；在窗口內拖到片尾播完也符合條件。

## 修正

- `ios/WebHTVApp/Sources/MPVEngine.swift`：公開 `reachedSeconds`（= `Snapshot.reached`）。
- `ios/WebHTVApp/Sources/WebHTVApp.swift`：`lastPlayhead`：`currentTime` 大於 0 就用它，否則用 mpv 的 `reachedSeconds`（原生播放器行為不變）。`recoverCopy` 的接續位置與 `finished` 的判斷都改用它。
- `ios/Sources/WebHTVCore/NextEpisodeContent.swift`：判斷搬成純函式 `endIsCopyFailure(windowOpen:until:duration:playhead:)`，原兩個條件不變，加上「播放位置離片尾還有 5 秒以上」才算副本失敗。
- 不改 W-243／W-253 其他行為（副本窗口長度、`copyFailure`、預熱判斷都沒動）。

## 驗證

- 單元測試 `anEndInsideTheCopyIsAFailureUnlessTheViewerSoughtToTheEnd`（窗口開／關、中段、片尾前 3 秒、片尾、短集）；`NextEpisodeContentTests` 等相關套件 78 項全過。
- Simulator（webhtv-w185，iOS 27.0，Debug，安裝檔 dylib 與建置輸出 sha256 相同）＋ w243-kit `https://[::1]:18243/kit.json`「KIT｜簽名會過期」（3 集各 120 秒、每段 4 秒），預設播放器 MPV，不需外網：
  - ①（run1、run2）：第 2 集用副本開播（`content=hit`），副本後的片段 403 → mpv 在 15 秒處結束 → `fetched copy's source failed … at 15s — resolving live` → 重新開播 `from 15.943222s`（修正前這裡是 0）。兩輪重開的 MPV 都因測試來源仍回 403（run1 注入還沒解除、run2 kit 的重新解析拿到同一條已過期的詳情網址）而由 router 改用原生播放器；接續位置 15.94 秒正是本修正設定的值，run1 原生從 15.94 秒正常播放。
  - ②（run5）：第 2 集用副本播到 13 秒時把進度拖到 118 秒 → `seek landed 118.1s` → `第2集 finished (end)` → 第 3 集照常開播（`content=hit`），**沒有** `fetched copy's source failed`／重新解析。
  - 證據：`.herdr-synapse/webhtv-dev/artifacts/w261/simulator-evidence.txt`（摘要）與 `run1/run2/run5.log`、`.jsonl`（請求紀錄）。另有一輪（run3）預抓被 Simulator 判成低數據模式跳過，無效已刪；②用 `WEBHTV_PREFETCH_IGNORE_LOW_DATA=1` 啟動。
- Ponytail review：Ship，無發現。

## 沒驗到

- 修正前版本沒有在本輪重跑對照（①的「at 0s」來自 W-243 Reviewer #6318 的觀察與程式碼推導）。
- 真機。拖到片尾前 5 秒內後來源才失效的情況會被當成真的播完（換下一集、略過最後幾秒），這是工單給的門檻。
