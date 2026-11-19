# W-319 SourceClient probe 計時測試在負載下偶發失敗

- 分支 `task/W-319`，底 ios-poc `ae662d20e2276b9bd6e5ae7a990860b0351b3fe7`；只改測試 `ios/Tests/WebHTVCoreTests/SourceClientTests.swift` `theProbeReadsOnlyTheHeadOfABodyThatNeverEnds`。只提交、不推送。
- 證據在 `.herdr-synapse/webhtv-dev/artifacts/w319/`（不進 git）。

## 根因

這個測試要證明：伺服器不理 `Range`、回一個永遠不結束的 body 時，`MediaProbe.classify` 讀到開頭就停，不會一路讀到請求逾時（IOS-POC-15D）。它用牆上時鐘判斷「5 秒內回來」，而錯誤實作的失敗情況是等 App 共用 session（`URLSession.webHTV`）的 10 秒請求逾時。

量測：

| 執行方式 | 這個測試的耗時 |
|---|---|
| 單獨跑 | 0.04 s |
| 只跑 `SourceClientTests`（20 項） | 0.05 s |
| 全套平行跑（W-315 兩次、底版 ae662d20 一次） | 6.11 s（失敗）、5.41 s（失敗）、5.40 s（邊緣通過） |

同一次全套執行裡，平常幾十毫秒就結束的測試也都花了 5 秒上下（例：`aLateAnswerToAnOlderSearchNeverReplacesTheNewerOne` 5.22 s），WebView 嗅探測試最慢 7.4 s。所以不是 probe 變慢，而是全套一開始的幾秒，整個測試程序被 WKWebView／JS 執行環境的啟動佔滿，這段時間開始的測試都要排隊，牆上時鐘把排隊時間也算進去了。5 秒門檻和這段排隊延遲（5–7 s）是同一個量級，和要分辨的失敗情況（10 s）也只差 2 倍，負載一大就撞線。根因在測試的門檻設計，不在產品碼的逾時設定。

## 修法

- 這個測試改用自己的 session，請求逾時 60 秒；門檻放到 30 秒。
- 正確實作：讀到開頭就取消，負載下實測 6–9 s，離 30 s 很遠。
- 錯誤實作（讀到 body 結束）：要等滿 60 秒請求逾時，然後拋錯回 `.unknown`，`kind == .media` 與時間門檻兩個斷言都失敗。
- 原本要證明的行為（讀完開頭就停、不等永遠不結束的 body）照樣被驗證；斷言數量與內容都沒少。
- 沒有改產品碼；`URLSession.webHTV` 的 10 秒逾時不動。

## 驗證

- 反向驗證：暫時把 `MediaProbe.classify` 改成讀完整個 body 再取前 64 bytes，這個測試在 61.05 s 後兩個斷言都失敗（`kind == .media`、`< 30 s`）；驗證完已還原原始碼（`git status` 只剩測試檔）。
- 並行負載：同一份建置複製一份到另一個 scratch path，兩個 `swift test --skip-build` 同時跑，連跑 3 輪（共 6 次全套）。這個測試 6 次全過，耗時 6.87／7.76／6.27／6.15／8.91／8.88 s（`r1–r3-a/b.log`）。
- 另外發現（不在本單範圍、沒有改）：同樣的雙倍負載下，`GlobalParseTests.aSniffEndsWhenItsCallerGivesUp` 有 2／6 次失敗（6.32 s、6.48 s，門檻也是 5 s 牆上時鐘），是同一種根因。已回報 Manager 決定是否另開單。
- Ponytail（本單 diff）：Ship。只動一個測試；session 用完 `invalidateAndCancel()`，不留連線。
