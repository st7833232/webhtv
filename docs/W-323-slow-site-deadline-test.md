# W-323 AggregateSearch 慢站期限測試偶發失敗＋SpiderHost 隔離測試確認

- 分支 `task/W-323`，底 ios-poc `ae662d20e2276b9bd6e5ae7a990860b0351b3fe7`；只改測試 `ios/Tests/WebHTVCoreTests/AggregateSearchTests.swift` `reportsASlowSiteWithoutWaitingForIt`。只提交、不推送。手法同 W-319／W-321。
- 證據在 `.herdr-synapse/webhtv-dev/artifacts/w323/`（不進 git）。

## 1. `reportsASlowSiteWithoutWaitingForIt`

**要證明的行為**：一個站卡住不回（像爬蟲卡在自己的 HTTP 呼叫裡、不理取消）時，聚合搜尋到期限就把它報成「逾時」，不等它；快的站照常報「找到」；搜尋要等慢站真的回來才結束。

**根因**：每站期限只有 50 ms（從該站開始算）。快站的呼叫要在 50 ms 內被排程並回來才算「找到」。W-321 雙倍負載時 1／6 次快站也被報成逾時（`outcomes[fast] == "timedOut"`）：全套剛開始的幾秒，執行緒池忙到 50 ms 內輪不到它。產品碼的期限機制沒有問題。

**修法**：
- 期限改成 2 秒。快站馬上回答，2 秒內一定輪得到；慢站被閘門擋住，仍然要靠期限才會被報逾時。
- 加上 `.timeLimit(.minutes(1))`：搜尋如果改成等慢站，原本會一直卡住（慢站要到斷言之後才放行），現在會在 1 分鐘時明確失敗。
- 斷言內容不變（快站「找到」、慢站「逾時」、放行後搜尋結束）。代價：這個測試固定多花約 2 秒（全套平行，總時間沒有明顯變長：單套 6.2–6.8 s）。

**反向驗證**：暫時把 `AggregateSearch` 的 `race(work, deadline: deadline)` 改成 `deadline: nil`（不設期限，等慢站），測試在 60 s 時間上限失敗，並記下 `outcomes[slow] == "timedOut"` 不成立（64.0 s）；還原後單獨跑 2.03 s 通過（`git status` 只剩測試檔）。

## 2. `SpiderHostTests.keepsTwoSitesOnTheSameSpiderClassFullyIsolated`（只確認，沒有改）

- **單套多輪**：`swift test` 單獨跑 5 輪，全套 1602 項 5／5 全過，這個測試 5／5 通過（1.53–2.21 s）（`single1–5.log`）。
- **雙倍負載**：3 輪共 6 次，失敗 2 次（`r1-a`、`r3-b`），都是 `spider_siteA_token`／`spider_siteB_token` 讀到 `nil`。
- **判斷**：測試用固定名稱的偏好網域 `UserDefaults(suiteName: "spider.isolation")`（`SpiderHostTests.swift:346`），偏好網域是存在磁碟上、同一使用者共用的；兩個測試程序同時跑時，兩邊寫入、清除同一組鍵，互相蓋掉。單套執行只有一個程序，不會發生。依單子約定「只在單套也會失敗時才改」，所以不改。

## 3. 雙倍負載結果

同一份建置複製到另一個 scratch path，兩個 `swift test --skip-build` 同時跑，3 輪共 6 次（`r1–r3-a/b.log`）：

- **本單測試 6／6 通過**（6.43–11.87 s）。
- 這次雙跑時機器負載很高（`uptime` load average 190，其他成員同時在建置），第 1、2 輪另有大量失敗：`FavoriteOwnershipTests`、`Offline*Tests`、`StorageMaintenanceTests`（下載狀態一直停在 preparing 等），以及 `MediaSnifferTests` 幾項。這些測試讀寫同一使用者的共用檔案／偏好，兩個程序同時跑會互相干擾，加上極端負載，屬雙跑測試法的限制；單套 5 輪全過。`SourceClientTests` probe 與 `GlobalParseTests` 嗅探取消的失敗是因為這個分支從 ios-poc 開，還沒有 W-319／W-321 的修正。
- 結論：「兩個 `swift test` 同時跑」適合驗證單純的計時門檻，但對讀寫共用磁碟狀態的測試不是有效的壓力方法；之後若要更可靠的負載測試，應改成單一程序內加 CPU 負載，而不是兩個測試程序。

## 4. Ponytail

本單 diff：Ship，沒有發現。查過：三個原有斷言都保留；慢站被閘門擋到兩份報告都收到才放行，只能靠期限報逾時；反向驗證在 60 s 上限失敗；多花約 2 s，單套總時間仍 6.2–6.8 s。沒驗到：比 load average 190 更極端的負載（本輪最慢 11.9 s 仍通過）。
