# W-270 離線下載本機代理修正的三個收尾

- 工單：herdr W-270（W-268 Reviewer #7049 的三個不阻擋事項）。分支 `task/W-270`，自 ios-poc `dbebbedd`。
- 不改 W-268 已核准的行為；播放的代理 20 秒上限（W-253 依賴）不動。

## Recovery anchor

- 目標：①App 丟掉爬蟲 session（換設定、換爬蟲包）時，代理為下載留住的各站爬蟲一起放掉；②下載確認頁（和「全部下載」自己的讀取）經代理時當下載請求，用下載上限；③確認頁對本機代理來源的說明改成正確說法。
- 狀態：實作＋單元測試＋截圖完成，送審。

## 改了什麼

| # | 做法 | 位置 |
|---|---|---|
| 1 | `SpiderSessionStore.reset()`（重新載入設定、更新爬蟲包時呼叫）同時呼叫 `SpiderProxyServer.forgetSites()`，清掉代理的各站爬蟲表。最近一次播放的那個（`session`）不清：播放器可能還在讀。下載下次送出時照 W-268 由 `downloadBase` 從 store 重建 | `SourceClient.swift` `SpiderSessionStore.reset`、`SpiderProxyServer.forgetSites` |
| 2 | 新增 `OfflineLocalProxy.downloadTarget(_:siteID:)`：本機代理位址改成同一個代理、帶站別（其他位址不變）。確認頁讀取前用它（`VodView.prepareDownload`），「全部下載」在 `prepare` 讀取前也用它。於是這些讀取在代理端走 120 秒的下載上限，fetcher 也已是 150 秒（W-268）。播放請求不帶站別，仍是 20 秒 | `OfflineTransport.swift`、`OfflineDownloadManager.prepare`、`WebHTVApp.swift` |
| 3 | 確認頁說明：本機代理來源改成「這個來源要開著 App 才會下載；離開 App 會暫停，回到 App 後自動繼續。」（W-268 起這種下載跟著 App 停、回前景重送）。其他來源維持「離開 App 或鎖定螢幕時，iOS 會在允許時繼續下載。」。Wi-Fi／行動網路那句不變 | `OfflineLocalProxy.backgroundNote(for:)`、確認頁 footer |

## 測試

| 測試 | 證明 |
|---|---|
| `SpiderProxyServerTests.aSessionResetFreesTheSpidersKeptForDownloads` | 驗收①：下載登記的爬蟲在 `SpiderSessionStore.reset()` 後被釋放（weak 參照變 nil），之後帶該站別的請求 404。拿掉 `forgetSites()` 呼叫時此測試失敗 |
| `OfflineLocalProxyTests.theSheetAndDownloadAllReadTheProxyAsADownload` | 驗收②：確認頁的讀取與「全部下載」的讀取，送出的每個請求都帶站別（即代理的下載上限）；CDN 目標不變；`SpiderProxyServer().callTimeout` 仍是 20 秒。拿掉 `prepare` 裡的 `downloadTarget` 時此測試失敗 |
| `OfflineLocalProxyTests.theSheetSaysALoopbackProxyDownloadNeedsTheAppOpen` | 驗收③：本機代理位址用新說法，其他位址用原說法 |
| 既有 `onlyADownloadGetsTheLongerLimit`（W-268） | 帶站別 → 下載上限；不帶 → 播放的 20 秒 |

`swift test` 全量 1503/1503。

## 截圖

Simulator webhtv-w185（本分支 Debug build），本機代理來源 `KIT｜bvc2`（`artifacts/w262/kit`）第 1 集的下載確認頁：讀取經代理成功（720p、7 MB），說明為「只在 Wi-Fi 下載（可在「設定」開啟行動網路）。這個來源要開著 App 才會下載；離開 App 會暫停，回到 App 後自動繼續。」——`.herdr-synapse/webhtv-dev/artifacts/w268/gui/w270-sheet-proxy.png`。非本機代理來源的原說法由單元測試涵蓋。

## Ponytail 審查

已跑（`ponytail:ponytail-review`，最終 diff）：沒有發現。檢查了 reset 只清各站表、不清正在播放用的 `session`（啟動時的設定刷新就會 reset，播放器可能正在讀）；清掉後下載由 `downloadBase` 從 store 重建（W-268 既有路徑）；`downloadTarget` 只動本機代理位址，用的站別與 `prepare` 的 `siteID(of:)` 同一個 `site.id`。

## 沒驗到

- 換爬蟲包當下有下載進行中：單元測試只證明舊爬蟲被釋放與下一次重建；沒在 Simulator 實際換包。

## 核准後補修：清表後排隊中的請求要能重試（reviewer-2 #7144 的追問）

Reviewer 指出每次啟動 `refreshSpiderPack` 都會 reset，清表後的下一個請求會 404，「靠重試重建」。但 `OfflineDownloadManager.transferFailed` 對 HTTP 401／403／404／410 是**直接判失敗、不重試**。具體情況：HLS 下載一次送出多個分段，超過連線數的會在 URLSession 裡排隊；排隊中發生 reset，之後才到代理的分段拿到 404 → 整個下載變「需要處理」。

修正：代理收到帶站別、但站表裡沒有的下載請求時回 **503**（不是 404）。503 走一般重試，重試時 `localProxyBase` → `downloadBase` 重新建立該站爬蟲；真的建不起來就照 W-268 標 `noLocalProxy`。播放請求（不帶站別）不受影響。

測試：`aDownloadIsAnsweredByItsOwnSitesSpiderNotTheOneThatPlayedLast` 改為期待 503；釋放測試拆成兩個——`forgettingTheSitesFreesTheSpidersKeptForDownloads`（獨立的代理實體：留住 → 清表後釋放 → 503）與 `aSessionResetFreesTheSpidersKeptForDownloads`（共用代理：`reset()` 後釋放；原版在全量平行跑時會被 `SpiderGoldenTests` 同時呼叫的 reset 干擾，改成只檢查結果）；新增 `OfflineLocalProxyTests.aTransferTheProxyLetGoOfIsRetriedWithItsSpiderMadeAgain`：傳輸收到 503 後同一單元重送到同一位址、`localProxy` 被重新呼叫、資產仍在下載中。相關 190/190；全量連跑 3 次，本單的測試每次都過，第 3 次全綠（另兩次失敗的是已知平行不穩的 `theFetcherStopsReadingAtTheLimit`——基準版也會失敗——與 WebView 廣告擋除測試）。

## 回退

`git revert` 本單的提交。無資料格式改動。
