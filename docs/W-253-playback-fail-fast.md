# W-253 已知無法播放的集數直接提示、失敗不再卡轉圈

- 工單：herdr W-253（Manager 派，依賴 W-252）；分支 `task/W-253`，自 ios-poc `7fccd89f`。
- 來源：W-252 現場紀錄 `.herdr-synapse/webhtv-dev/artifacts/w252/b2-key.txt`（紅果短劇 bvc2 集數，預熱每次 HTTP 500）。
- 範圍：通用，不寫死站名，不改爬蟲腳本。

## 問題

- (a) 預熱已經知道下一集回 500，換集時仍照樣試：原生 10 秒 → MPV → 即時重解析 → 再一輪，最後停在轉圈 45 秒以上。
- (b) b2-key.txt 10:54:01 之後：MPV 失敗退回原生（本次嘗試的備援已用掉），原生 `item=0`（一直沒準備好）、`waiting=AVPlayerWaitingWithNoItemToPlayReason`。10 秒起播逾時到了，但 `PlayerRouter.startupTimedOut()` 因為沒有備援而回 false，舊碼在這種情況什麼都不做（「慢起播不是錯誤」），所以永遠轉圈、沒有錯誤訊息。`-1008` 只出現在字幕清單的 asset 載入，從未變成 item failure。

## 判斷依據（確定性失敗）

`NextEpisodeContent.warmVerdict(_ statuses: [Int?])`（WebHTVCore，純函式）：

| 預熱回應（依序） | 判定 | 交棒時 |
| --- | --- | --- |
| 最後一次 200／206 | ok | 照常 |
| 一次 5xx（非 504） | askAgain：隔 5 秒再問一次 | — |
| 連續兩次 5xx（非 504） | failed(最後狀態碼) | 直接顯示原因，不開引擎、不重解析 |
| 504、逾時／傳輸錯誤（nil）、4xx、5xx 後接 504 或 nil | unsure | 照常（舊行為） |

理由：W-246 的腳本冷快取 500 第二次就成功（`[500, 200]` → ok）；504 是代理放棄慢腳本，腳本仍會寫進快取；bvc2 每次都是 500。只有「同一來源連兩次明確 5xx」才被當成確定性失敗。

## 實作

- `ios/Sources/WebHTVCore/NextEpisodeContent.swift`：`WarmVerdict`、`warmVerdict`。
- `ios/Sources/WebHTVCore/PlaybackActivity.swift`：`PlaybackStartupReason.givenUp` — 沒有備援時，`http`／`neverReady` 才放棄並顯示；`tooSlow`／`evaluating`（已就緒、資料在來）／`unknown` 照舊繼續等。
- `ios/Sources/WebHTVCore/PlaybackEngine.swift`：`PlayerRouter.giveUp(_:)` — 停掉引擎、設 `failure`、走 `onUnrecoverable`（與引擎無法恢復的失敗同一條顯示路徑；`failure` 有值時轉圈不顯示）。
- `ios/WebHTVApp/Sources/WebHTVApp.swift`：
  - `NextEpisodePrefetch.warm`：依 `warmVerdict` 最多問兩次；每次記 `content-warm … (ask n, verdict)`。
  - `take`：判定 failed 時記下該位址，miss 記 `warm failed twice: HTTP n`；`knownFailure(for:)` 只對交棒的同一位址成立，`engineURL` 會清掉。
  - `PlaybackSession.load`：已知失敗 → 取消起播監看、清掉 `retryWithoutPrefetch`、`router.giveUp(.source("無法播放：這一集的來源連續兩次回應 HTTP n"))`，log `not opened: its source answered HTTP n twice while warming`。
  - `watchStartup`：起播逾時且 `startupTimedOut()` 回 false（兩個引擎都試過）→ 依原因 `givenUp` 呼叫 `router.giveUp`，log `… and no engine left — shown failed`。若該集仍有預解析位址的重試（IOS-POC-15D），照舊先即時重解析一次。
- 沒做：依自動下一集設定跳過（工單寫「或」，先只顯示原因）。

## 行為變更與風險

- 兩個引擎都試過、原生 10 秒仍 `neverReady`（或錯誤紀錄有 HTTP 4xx/5xx）、MPV 20 秒仍 `preparing`：以前繼續等，現在顯示失敗。直播頻道在這種情況會較早回報 `.failed` 換線。
- 預熱多一次請求（只在第一次 5xx 時），腳本多跑一次；只發生在已經失敗的集數上。

## 驗證

- 單元測試：`swift test --filter 'NextEpisodeContentTests|PlaybackEngineTests|PlaybackActivityTests'` 88/88 通過。新增 `onlyTwoFiveHundredsInARowMeanTheEpisodeFails`、`onlyAStartThatIsNotComingIsGivenUpOn`、`aStartGivenUpOnIsShownAndReleased`。
- App 編譯：Debug、iOS Simulator（webhtv-w202 F628B6F4）BUILD SUCCEEDED。
- Simulator 失敗注入（證據 `.herdr-synapse/webhtv-dev/artifacts/w253/`）：測試用 py 爬蟲 `artifacts/w243/work/srv/py/w253.py`，設定 `w253-test.json`（18445），兩部劇都是 60 秒整集 MP4 走本機代理。第 2 集在「確定失敗」劇裡每次都回 500；在「暫時失敗」劇裡第一次回 500，之後都正常。
  - 確定失敗（`f1-key.txt`、`f1-end.png`）：預熱 `500 (ask 1, askAgain)` → 5 秒後 `500 (ask 2, failed(500))`。第 1 集 12:21:55.819 結束，**12:21:55.880（61 ms 後）** `第2集 not opened`。畫面只顯示「無法播放：這一集的來源連續兩次回應 HTTP 500」，沒有轉圈；之後沒有任何代理請求。
  - 暫時失敗（`t1-key.txt`、`t1-end.png`）：預熱 `500 (ask 1, askAgain)` → `200 (ask 2, ok)`。第 2 集照常交棒，`started 第2集 on 原生 in 217ms … content=warm`，沒被誤判。
  - (b) 真實站（紅果 bvc2 第 5 集，`a1-key.txt`）：這次第二次預熱回 504（腳本超過 20 秒）→ `unsure`，依規則照舊嘗試。MPV 20 秒沒起播 → `no engine left — shown failed` → 預解析重試即時重解析一次 → MPV 失敗退回原生 → 原生 `item-error=NSURLErrorDomain -1008`、10 秒 → **12:09:23 `not started on 原生 after 10s and no engine left — shown failed`**。W-252 那次停在這裡一直轉圈，現在結束並顯示錯誤。
- 觀察（不在本工單範圍）：紅果 bvc2 的即時重解析等了 70 秒（`resolve 5 live … 70163ms`），是腳本排隊；W-254／W-256 解碼方案處理後這類集數才可能播放。
- 未驗證：真機。

## Ponytail

`ponytail:ponytail-review` 審最終 diff：Looks good. Ship。沒有需要修改的發現（檢查了呼叫端、取消、直播換線、預解析重試路徑）。

## 狀態

已送審（Reviewer：webhtv-dev-codex-reviewer-2）。
