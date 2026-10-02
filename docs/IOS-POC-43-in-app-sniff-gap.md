# IOS-POC-43 — App 內「檢查來源」的嗅探結果和 Mac 不一致（assessment）

## Recovery anchor

- 目標：使用者 2026-10-02「開始 IOS-POC-43 assessment」。起因是 IOS-POC-42 第 16 節：模擬器 App 內「檢查來源」把 300分类、xgroovy、亞洲情色網判成「取不到播放網址」，同時段 Mac 的 sweep 卻能播放，原因未查。
- 範圍：只做 assessment，**不改程式**。診斷用的探測測試、插樁與原型都在 session scratchpad 的副本，不 commit。task guard `IOS-POC-43`（`assessment`），路徑：本文件、`docs/current-task-state.md`。
- 結論：根因已重現並確認（第 3 節），建議與待決定事項見第 6、9 節。
- 唯一下一步：等使用者核准第 9 節；沒有核准前不改程式。

## 1. 問題

- IOS-POC-42 的模擬器「檢查來源」（62 項）中，影片網址要靠 WebView 嗅探（spider 回 `parse:1`）的站，在 App 裡都是「取不到播放網址」；靜態就取得到網址的站（`parse:0`）都正常。
- 「檢查來源」的結論會寫進 41B 的站點健康記錄（`SiteHealthStore.record(_:source:)`，停在哪一階段就記哪一階段失敗）。誤判的站會被記成播放失敗，來源清單的圓點與「站點健康排序」跟著變差。

## 2. 實驗與證據（2026-10-02，熱點）

探測都走 App 的同一段程式（`SourceClient`、`SourceCheck`、`MediaSniffer`），只差執行環境與並行方式。

| # | 環境 | 做法 | 結果 |
|---|---|---|---|
| E1 | macOS `swift test` | 300分类、xgroovy、亞洲情色網、18AV、AirAV、PPP、鲨鱼av，**一次一站** | `parse:1` 的三站都嗅探成功（1.0～1.6 秒）；其餘四站是 `parse:0`，不經嗅探 |
| E2 | macOS | E1 的三站，嗅探 WebView 改用 iOS 的 `mediaTypesRequiringUserActionForPlayback = .all` | 三站仍成功：**不是自動播放限制** |
| E3 | macOS | E2 再加 iPhone UA | 三站仍成功：**不是 UA** |
| E4 | iOS 模擬器 `xcodebuild test`（WKWebView 不在任何 window） | E1 的三站＋鲨鱼av，一次一站 | 全部成功（300分类 5.6 秒，是第一個 WebView 的啟動成本；其餘約 2.2 秒）：**不是 iOS WebKit 嗅探不到，也不是 off-window 被暫停** |
| E5 | 模擬器 App | 設定只有虎牙（type-1）＋300分类，「檢查來源」 | 300分类「取不到播放網址」；log 顯示 0.8 秒內建了兩個嗅探 WebView，第一個被拆掉 |
| E6 | iOS 模擬器 `xcodebuild test`，`SourceCheck.run`（width 8） | 300分类×2、xgroovy、亞洲情色網 | 前三個依序 `noPlayURL`，**只有最後開始的亞洲情色網成功** |
| E7 | 同 E6，`MediaSniffer` 插樁 | 同 E6 | 每次 `[sniff] start` 前都有 `[sniff] cancel previous`；被取消的站全部 `noPlayURL`，最後一個 `found …mp4` |
| E8 | 同 E7 | 虎牙＋300分类 | 虎牙這次的播放網址是 `…/play/elYp7P5a`（沒有副檔名），探測是網頁所以**也嗅探**；300分类 開始嗅探時取消了它，虎牙變成「播放網址不是影片」 |

## 3. 根因

- `ios/Sources/WebHTVCore/MediaSniffer.swift` `sniff(page:referer:timeout:)`：`MediaSniffer.shared` 一次只跑一個嗅探，**新的嗅探開始時取消正在跑的那一個**（`if let live = collector { live.cancel() }`），被取消的回傳 `nil`。註解寫明這是刻意的：「a second concurrent web view competes for the main actor and the network, and no caller needs it」。
- `ios/Sources/WebHTVCore/SourceCheck.swift` `run(_:resolver:width:limit:)`（41C）同時檢查 8 站，每站在播放階段呼叫 `SourceClient.playbackURL` → `target(from:headers:parse:)` → `MediaSniffer.shared.sniff`。兩站以上同時嗅探時，先開始的被後開始的取消，回 `nil` → `noPlayURL`（`parse:1` 的路徑）或拿到原網頁 → `notMedia`（`parse:0` 探測到網頁的路徑）。
- 41C 是第一個「需要同時嗅探」的呼叫端，和 `MediaSniffer` 的前提衝突。
- Mac 的 sweep 也是同一段程式、同一個問題；只是 Mac 上一次嗅探約 1 秒，重疊的機會小，所以多半看起來正常。iOS 上一次嗅探 2～6 秒，重疊的機會大很多。

## 4. 影響範圍

- **受影響**：
  - App 內「檢查來源」（41C）：嗅探站被誤判，並寫進站點健康記錄（41B）。
  - `swift test` 的 sweep（`sweepsEveryDrivableSourceThroughTheAppPath` 也走 `SourceCheck.run`）：IOS-POC-39／41／42 量到的嗅探站可播數是**下限**，每次會隨機少幾站。
- **不受影響**（逐一看過呼叫端）：
  - 一般播放 `play(_:flag:)`（`WebHTVApp.swift` 約第 2208 行）：一次解析一集；使用者改點別集時取消前一個，正是設計的「最新的優先」。
  - 預取下一集 `prefetchNextEpisode`（約第 2256 行）與自動下一集 `start(_:flag:usingPrefetch:)`（約第 2323 行）：預取被即時解析取消時，只是預取落空（`prefetch.failed()`），照常即時解析。
  - `PythonLiveCheck.survey()`：只在 DEBUG build 啟動後跑 Python 站，Release 沒有。

## 5. 方案比較

（量測見第 7 節）

| 選項 | 內容 | 評估 |
|---|---|---|
| A. 不改 | — | 「檢查來源」持續誤判嗅探站並污染健康記錄。不建議 |
| B. 允許同時多個嗅探 | 拿掉「取消前一個」，每次嗅探各用自己的 WebView（Android 每個解析工作各有一個 WebView） | 檢查時最多 8 個 WKWebView，iOS 上每個都有自己的 WebContent process，記憶體與耗電都重；互動播放失去「最新的優先」，要另外處理取消。不建議 |
| C1. 檢查時播放階段輪流 | `SourceCheck.check` 進入播放階段（`client.playbackURL`）前取得一個全域的順序鎖，一次一站 | 只動 41C 的檔案；`MediaSniffer` 與一般播放完全不變；代價是播放階段排隊，量測見第 7 節 |
| **C2. 嗅探器的排隊模式（建議）** | `MediaSniffer` 加一個 task-local 旗標，檢查時「等前一個結束」而不是取消；一般播放仍是取消 | 只有嗅探排隊，非嗅探站的播放階段仍並行；要改播放共用的元件，但沒有設旗標的呼叫端行為逐字不變 |

## 6. 建議：C2（一段，IOS-POC-43A）

- `MediaSniffer`：
  - 新增 `@TaskLocal nonisolated public static var waitsForTurn = false` 與一個等待佇列。
  - `sniff` 在 `waitsForTurn` 為真時，等前一個嗅探結束再開始（`while collector != nil { await … }`；判斷與佔位之間沒有 `await`，兩個等待者不會同時通過）。不另外處理取消：`SourceCheck.bounded` 用非結構化的 `Task` 跑每一站，停止檢查不會傳到這裡（Ponytail）。
  - 沒有設旗標時維持現在的「取消正在跑的那一個」，一般播放、預取、自動下一集的行為逐字不變。
  - 每次嗅探結束（`defer`）喚醒下一個等待者。
- `SourceCheck.check`：播放階段的 `client.playbackURL` 包在 `MediaSniffer.$waitsForTurn.withValue(true) { … }` 裡。
- `swift test` 的 sweep 走同一個 `SourceCheck`，自動得到正確的嗅探站數。
- 已知限制（記錄，不處理）：檢查進行中若使用者另外開始播放，播放的嗅探仍會取消檢查中的那一個；41C 離開檢查頁就停止檢查，實際上碰不到。

C2 對照 C1：兩者都消除誤判；C2 只讓嗅探排隊，整批檢查多 12%，C1 多 38%（第 7 節）。代價是動到播放共用的 `MediaSniffer`，但只多一個預設關閉的分支，並以單元測試鎖住兩種行為。

## 7. 原型量測（scratchpad 副本，iOS 模擬器 `xcodebuild test`，`SourceCheck.run` width 8，`wang-sex.json` 220 站，同一熱點依序跑）

| | 可以播放 | 整批耗時 | 嗅探次數 | 被取消 | 逾時 |
|---|---:|---:|---:|---:|---:|
| 現行（HEAD `b4560be7` 的程式＋插樁） | 58 | 106 秒 | 14 | **7** | 0 |
| C1 | 58 | 146 秒（+38%） | 14 | 0 | 0 |
| **C2** | **59** | **119 秒（+12%）** | 14 | 0 | 0 |

- 現行版本被取消的 7 次：18jtv、亞洲情色網、IXXXJ、KANAV、ThisAV、OWOAV、AVbebe。
- C2 對照現行的逐站差異：亞洲情色網 取不到 → **可以播放**；KANAV、ThisAV 取不到 → 播放網址不是影片（嗅探這次跑完，判定才是正確的；curl 也看到這兩站是 Cloudflare 403）。其餘 217 站相同。
- C1 對照 C2 只差一区：C1 那一輪 `MediaProbe` 讀不到 CDN（同一個播放網址，`[unknown]`），C2 又可以播放；是 CDN 波動，與順序鎖無關。
- 被取消的是誰取決於時機，所以現行版本每次誤判的站不同：E6／E7 是 300分类×2、xgroovy；IOS-POC-42 的模擬器 App 內檢查是 300分类×2、xgroovy、亞洲情色網（巴士动漫、動漫巴士當時也是「取不到播放網址」，是否同樣是被取消未確認）。**IOS-POC-39／41／42 用 sweep 量到的嗅探站可播數都是下限。**
- 插樁只是 `print`，不影響時序；三輪依序跑，網站狀態可能在幾分鐘內變動。

## 8. 驗收與回滾

- 一個單元測試（離線，`data:` 頁面，延遲送出串流請求讓兩個嗅探重疊），跑兩組（Ponytail：合成一個測試）：
  - `waitsForTurn` 為真時，兩個同時開始的嗅探**都**找到自己的串流；
  - 沒有設旗標時，先開始的回 `nil`、後開始的找到串流（鎖住一般播放的「最新的優先」）。
- `swift test` 全過；模擬器 Debug 與 generic iOS Release build。
- iOS 模擬器 `xcodebuild test` 的 `SourceCheck.run`（同第 7 節）：嗅探被取消 0 次；可以播放不少於同時段的現行版本；耗時增加不超過 20%。
- 模擬器 App 內「檢查來源」：E5 的兩站設定中 300分类 可以播放；IOS-POC-42 的 62 項設定中，嗅探站（300分类、xgroovy、亞洲情色網）不再因被取消而落在「取不到播放網址」。
- 一般播放：模擬器實看一個需要嗅探的站從詳情到播放，再看一個靜態取得網址的站，行為不變。
- 真機：未驗證就寫未驗證。
- 回滾：`git revert` 一個 commit；只動 `MediaSniffer.swift`、`SourceCheck.swift` 與測試。

## 9. 待使用者決定

1. 是否核准 IOS-POC-43A（C2）。建議核准；預估實作與驗證約 1 小時。
2. 是否接受 C2 動到播放共用的 `MediaSniffer`。建議接受，理由在第 6 節；若不接受，改做 C1（只動 `SourceCheck`，整批多約 40 秒）。

## 10. 狀態

- 2026-10-02 assessment 完成，只改文件。等使用者回覆第 9 節。
- Ponytail：`ponytail:ponytail-review` 對第 5～8 節，刪掉醒來時的 `Task.isCancelled` 檢查（不會發生的取消）、兩個測試合成一個，net −4 行，已寫進第 6、8 節。
- 診斷用的探測（`SniffProbeTests`、`CheckProbeTests`）、`MediaSniffer` 插樁與 C1／C2 原型都在 scratchpad 的 `c42` 副本，不 commit；模擬器 App 目前用本機 `127.0.0.1:8766` 的測試設定（伺服器已關），App 本身沒有改。
