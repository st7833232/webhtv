# W-268 本機代理來源的離線下載修正（方案 C）

- 工單：herdr W-268（使用者 11-09 選完整修正）。依據：`docs/W-264-offline-download-proxy.md`（task/W-264 `551e9270`）的方案 C。
- 分支：`task/W-268`，自 ios-poc `36ad84a7`（W-267 文件；程式與 `302438d0` 相同）。
- 不為紅果專做：測試用自寫的非紅果本機代理爬蟲（`artifacts/w268/srv/py/w268.py`、`w268b.py`），不保存、不分析任何解密邏輯。

## Recovery anchor

- 目標：本機代理（`getProxyUrl()`→`localProxy`）來源的離線下載，在 App 重開、慢腳本、暫停後代理換埠、下載中播別的 Python 站時都能完成，失敗時看得到原因。非本機代理來源的下載行為不變；播放的代理 20 秒上限不變。
- 狀態：實作＋單元測試完成；Simulator 實測見下方。
- 下一步：見文末「狀態」。

## 改了什麼

| # | W-264 方案 C 的項目 | 做法 | 位置 |
|---|---|---|---|
| 1 | 本機代理單元一律走前景 session | `request(for:)` 把本機代理單元標成 `credentialed`（走 App 內的 default session，跟著 App 停、回前景由 `resubmitRunning` 重送），也算進 F10 的同時進行窗口；不用 resume data（它會重播舊代理位址） | `OfflineDownloadManager.request(for:asset:plan:proxy:)`、`isCredentialed` |
| 2 | 送出時改寫成當下代理位址 | 計畫照舊存當時的位址，但凡是本機代理位址（Android 的 `127.0.0.1:9978/proxy`，或任何一次啟動的 `127.0.0.1:<port>/<token>/proxy`）在**每次送出**（第一次、重送、補位、重試）和準備時的探測都改寫成這次啟動的代理 base，並加上 `webhtv-download-site=<站 id>`。舊版存下的計畫也一樣能改寫，所以既有卡住的下載也會恢復 | `OfflineLocalProxy.matches/rewrite`（`OfflineTransport.swift`）；`submitMissing`、`feedCredentialed`、`transferFailed` 重試、`prepare` |
| 3 | 重開後重建爬蟲 session | App 提供 `setLocalProxy`：代理沒有這個站的爬蟲時，用已載入的設定建一個（`SourceClient.make`），交給代理。設定還沒載入（背景啟動）時，本機代理單元先等，不判失敗；設定載入後（`resolverBecameReady`）重送。建不起來就標「需要處理」：「無法啟動這個站的本機代理，請重新載入設定後重試」 | `OfflineDownloadManager.setLocalProxy`、`noLocalProxy`、`pump`；`OfflineAppContext.localProxy`（`WebHTVApp.swift`）；`SpiderProxyServer.downloadBase` |
| 4 | 啟動時取消指向舊代理的任務 | `start()` 的過期任務清單加入「本機代理單元」：上一次啟動的代理已經不在，留著的 background 任務（舊版建的）會讓 `reconnect` 以為還在傳而不重送 → 取消後由 `reconnect` 重送 | `OfflineDownloadManager.start()` |
| 5 | 代理依網址分派爬蟲 | 代理記住每個站的爬蟲（`sites[site.id]`）：播放時 `serve` 登記，下載送出時用 App 目前的爬蟲（`SpiderSessionStore`，所以爬蟲包更新後用新腳本）更新；App 拿不到時沿用最後播放的那個。帶 `webhtv-download-site` 的請求交給該站的爬蟲（參數本身不交給爬蟲）；不認得的站回 404，不會交給最近播放的爬蟲。沒帶的（播放）照舊交給最近一次播放的 Python 爬蟲 | `SpiderProxyServer.respond`、`serve`、`downloadBase` |
| 6 | 只放寬下載請求的代理上限 | 帶站別的請求用 `downloadTimeout`＝120 秒（W-252：bvc2 冷快取最長 37 秒），其他請求仍是 `callTimeout`＝20 秒（W-253 依賴）。前景 session 30 秒的請求逾時對本機代理請求改成 150 秒（請求自己的 `timeoutInterval` 會蓋過 session 設定，已在 macOS 實測：session 3 秒＋請求 10 秒，6 秒回應成功；沒設則 3 秒逾時）；準備時探測用的 fetcher（20 秒）對本機代理也改 150 秒 | `SpiderProxyServer.timed`、`downloading`（TaskLocal）；`OfflineTransferRequest.urlRequest`；`OfflineHTTP.fetcher` |

另外：`submitMissing` 改成同一個資產一次只跑一個（期間又被呼叫就在跑完後再跑一次）。因為第 3 項新增「設定載入後重送」，它可能和啟動時的 `reconnect` 交錯：兩者都在送出前讀 session 清單，每個缺的單元會被送兩次（Ponytail 審查發現，有測試證明不加這個會重複送）。

和 W-264 方案原文的差異：第 2 項沒有把計畫改成存 `9978` 原址，而是「存什麼都行、送出時一律改寫」。效果相同，而且舊版已經存下（含舊埠號與 token）的計畫也能直接恢復，不必遷移資料。

## 單元測試

新增 `OfflineLocalProxyTests`（5 項）與 `SpiderProxyServerTests` 的 2 項：

| 測試 | 釘住的行為 |
|---|---|
| `aRelaunchCancelsTheDeadProxysTransferAndSendsItAgain` | **Reviewer 必做①**：重開時舊代理的任務還在 session 清單裡 → 被取消；設定未載入前不送也不判失敗；`resolverBecameReady` 後同一單元重送到新代理位址（新埠、新 token、帶站別）、走前景；完成後資產變 completed |
| `aCDNTransferStillListedAtRelaunchIsLeftRunning` | 對照組，說明「重開後為何沒重送」：session 還列著的任務，`reconnect` 視為傳輸中而不重送。CDN 來源照舊（不取消、不重送） |
| `overlappingResendsSendEachUnitOnce` | 兩次重送重疊（第一次卡在送出中）時每個單元只送一次；拿掉 `submitMissing` 的保護後這個測試失敗（送了 8 次） |
| `aSiteWhoseSpiderCannotBeMadeNeedsAttention` | 建不起爬蟲 → failed，原因是 `noLocalProxy`，沒有送出任何傳輸 |
| `anAddressIsMovedToThisLaunchsProxyForItsSite` | 位址改寫（9978、舊 token、已改寫過的都一樣；站別只有一個）；非本機代理不動；請求逾時大於代理上限 |
| `aDownloadIsAnsweredByItsOwnSitesSpiderNotTheOneThatPlayedLast` | 帶站別的請求交給該站爬蟲，不是最近播放的；爬蟲收不到站別參數；未知站 404；App 給的新爬蟲會取代舊的，拿不到時沿用舊的 |
| `onlyADownloadGetsTheLongerLimit` | **Reviewer 必做②**：同一個慢爬蟲（300 ms），下載請求（上限 5 秒）200，播放請求（上限 50 ms）仍 504 |

結果（最終版）：只跑 Offline＋Proxy 183/183 過。`swift test` 全量 1486 項中 1483 過；失敗的 3 項都在 `OfflineDarwinTests`（真的開本機 HTTP 伺服器與 AVFoundation 的測試），單獨跑 4/4 過、只跑 Offline 時也過；這些測試的網址不是本機代理位址，不經過改動的路徑。基準版（`36ad84a7`，未改）全量對照：1479 項也有 3 個 issue 失敗，同樣在 `OfflineDarwinTests`（`theFetcherStopsReadingAtTheLimit`）→ 這組真實本機伺服器測試在全量平行跑時本來就不穩，不是本改動造成。

## Simulator 實測

Simulator `webhtv-w268`（從 W-264 用過的 `webhtv-w202` 複製，保留 W-264 留下的下載紀錄；沒有動 w202）。App：本分支 Debug build（審查修正前那版；審查的兩個修正只有單元測試覆蓋，見「未驗證」）。測試爬蟲 `artifacts/w268/srv/py/w268.py`／`w268b.py`：每次 `localProxy` 都寫進 `artifacts/w268/asked.log`（哪個站的爬蟲、哪一集、range、參數名），檔案 `slow`（只給 w268）／`slow-b`（只給 w268b）存在時每次先睡指定秒數。設定 `https://127.0.0.1:18450/w268-test.json`。證據都在 `.herdr-synapse/webhtv-dev/artifacts/w268/`。

| # | 情境 | 結果 | 證據 |
|---|---|---|---|
| 0 | W-264 留下的「第3集 0% 永遠卡住」（舊版 background 任務指向已死的舊代理），裝新版後啟動 | `launch cancelled stale transfers=1` → 設定載入後 `submit=1` → 0.2 秒後 `completed`；下載頁「W263換線 已下載 2・需要處理 1」（需要處理的是 W-264 第2集的 504，沒動） | `work/s0-offline-key.txt`、`gui/s0-downloads.png` |
| 1 | 傳輸中關 App 重開（腳本每次 25 秒；送出 6 秒後 `simctl terminate`，3 秒後重開） | 重開 → `launch` → `submit=1` → 當下 `completed`；兩集都顯示已下載 | `work/s1-s4-offline-key.txt`（70DA290F）、`gui/s1s2-episodes-completed.png` |
| 2 | 慢腳本（每次 25 秒，App 在前景） | 傳輸請求排在前一個慢呼叫後面，從送出到爬蟲回應約 39 秒（舊版 20 秒就 504），`completed`；存下的檔案與來源 sha256 相同 | `work/s1-s4-offline-key.txt`（3B241D66）、`work/asked.log` |
| 3 | 下載中切到背景 45 秒再回來（腳本每次 25 秒） | 回前景後 `completed`。Simulator 不會真的暫停 App（W-264 也是），所以「暫停後代理換埠」沒有重現；這部分由每次送出都改寫位址（單元測試）和情境 0／1（重開後埠號真的換了）涵蓋 | `work/s1-s4-offline-key.txt`（6BBE2660） |
| 4 | 下載 W268下載 第3集（腳本 30 秒）時播 W268播放 第1集 | 16:31:12 播放的請求由 `w268b` 回答；16:31:38 下載的傳輸請求由 `w268` 回答（不是最近播放的 `w268b`）；播放正常、下載 `completed` | `work/asked.log`、`work/s1-s4-offline-key.txt`（F8480DB4）、`gui/s4-playing.png` |

`asked.log` 的參數名裡沒有 `webhtv-download-site`：爬蟲看不到站別參數。

## Ponytail 審查

已跑（`ponytail:ponytail-review`，最終 diff）。兩項照修：①新增的「設定載入後重送」可能和啟動的 `reconnect` 交錯而重複送出 → `submitMissing` 一次只跑一個，加測試；②代理快取的站別爬蟲在爬蟲包更新後不會換新 → 每次下載送出時用 App 目前的爬蟲。一項只記錄：下載確認頁的說明「離開 App 或鎖定螢幕時，iOS 會在允許時繼續下載」對本機代理來源不再成立（它跟著 App 停、回來再續），文字沒改。

## 未驗證／限制

- 真機暫停後代理換埠：Simulator 不暫停 App。
- 下載確認頁本身讀串流（`options`）仍走播放的 20 秒上限：第一次呼叫就超過 20 秒的腳本會在確認頁失敗（看得到，不會卡住）。通常使用者先播過，腳本已有快取。
- Simulator 跑的是審查修正前的 build；兩個修正只有單元測試證據。App 已用最終程式碼重新建置成功。
- 紅果本身：依工單限制沒測。

## 回退

`git revert` 本單的提交即可。資料不需遷移：計畫檔格式沒變；回退後本機代理的下載回到舊行為（background session、舊位址）。

## 狀態

實作、單元測試、Simulator 五個情境、Ponytail 審查完成，送 reviewer-2 審。
