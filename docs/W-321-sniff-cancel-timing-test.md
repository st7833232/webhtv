# W-321 GlobalParse 嗅探取消測試在負載下偶發失敗

- 分支 `task/W-321`，底 ios-poc `ae662d20e2276b9bd6e5ae7a990860b0351b3fe7`；只改測試 `ios/Tests/WebHTVCoreTests/GlobalParseTests.swift` `aSniffEndsWhenItsCallerGivesUp`。只提交、不推送。手法同 W-319（`docs/W-319-probe-timing-test.md`）。
- 證據在 `.herdr-synapse/webhtv-dev/artifacts/w321/`（不進 git）。

## 根因

這個測試要證明：呼叫端放棄（取消 Task）時，嗅探立刻結束，不會等到自己的逾時（`MediaSniffer.sniffResult` 的 `withTaskCancellationHandler`）。安靜的頁面本來就找不到東西，不論有沒有取消，回傳值都是 `nil`，所以**只有時間能分辨**。原本的門檻是「從建立 sniffer 起算 5 秒內」，錯誤實作要等 20 秒逾時。

W-319 時兩個全套測試同時跑，這個測試 6 次有 2 次失敗（6.32 s、6.48 s）。原因和 W-319 相同：全套剛開始的幾秒，WebView 測試佔住 main actor，這個 `@MainActor` 測試連同 0.5 秒的等待一起被拖慢，5 秒門檻和排隊延遲是同一個量級。產品碼的取消處理沒有問題。

## 修法

- 嗅探逾時從 20 秒改成 120 秒，門檻改成 30 秒，而且**從取消那一刻起算**，不再從建立 sniffer 起算（排隊與 0.5 秒等待不算進去）。
- 拆成兩個斷言：回傳 `nil`；取消後 30 秒內結束。
- 正確實作在雙倍負載下取消後幾秒內結束；忽略取消的實作要等滿 120 秒。

## 驗證

- 反向驗證：暫時把 `withTaskCancellationHandler` 的 `onCancel` 改成什麼都不做（取消不會傳到嗅探），測試在 128.3 s 後失敗（`clock.now - cancelled < 30 s`）；還原後單獨跑 0.52 s 通過（`git status` 只剩測試檔）。
- 雙倍負載：同一份建置複製一份到另一個 scratch path，兩個 `swift test --skip-build` 同時跑，3 輪共 6 次全套，這個測試 6 次全過，整個測試耗時 2.40／3.09／4.09／3.93／4.36／4.21 s（`r1–r3-a/b.log`）。
- 同樣負載下其他失敗（都不在本單範圍、沒有改，已回報 Manager）：
  - `SourceClientTests.theProbeReadsOnlyTheHeadOfABodyThatNeverEnds` 3／6 失敗：這個分支從 ios-poc 開，還沒有 W-319 的修正，屬預期。
  - `AggregateSearchTests.reportsASlowSiteWithoutWaitingForIt` 1／6 失敗：期限只有 50 ms，負載下連快的站也逾時（`outcomes[fast] == "timedOut"`）；同一類計時門檻。
  - `SpiderHostTests.keepsTwoSitesOnTheSameSpiderClassFullyIsolated` 1／6 失敗：`spider_siteA_token` 讀到 `nil`。推測是兩個測試程序同時跑、共用同一個偏好網域互相清掉，單套執行不會發生；沒有再查證。
- Ponytail（本單 diff）：Ship。只動一個測試，原本要證明的行為（取消後立刻結束）仍被驗證，並多了單獨的回傳值斷言。
