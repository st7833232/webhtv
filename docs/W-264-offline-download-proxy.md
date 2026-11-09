# W-264 iOS 離線下載對本機代理來源是否共通失敗：診斷

- 工單：herdr W-264（使用者 11-09 選 1）。只診斷、不改程式；不碰紅果腳本、不測試保存解密內容。
- 分支：`task/W-264`，自 ios-poc `4fba7c09`（只有本文件）。
- 測試 App：W-263 的 Debug build（`task/W-263`）。W-263 沒有改離線下載和代理的程式，下載路徑與 ios-poc 相同。
- 本機代理來源：測試爬蟲 `artifacts/w243/work/srv/py/w263.py`。播放網址是 `getProxyUrl()`＋`localProxy`，回整集 MP4，和紅果同型。沒有用紅果。

## 結論

**是共通問題，但不是「一律失敗」。** 前景、短時間內就能下載完的本機代理來源可以成功。只要下載的時間跨過下列任一情況，所有本機代理來源都會失敗或卡住，跟是哪個站無關：

1. **App 被關掉或重開**：下載永遠卡在「進行中 0%」，不會失敗，也不會恢復（實測）。
2. **代理呼叫爬蟲超過 20 秒**：代理回 504，重試一次後顯示「需要處理」（實測，用注入延遲觸發）。
3. **App 被系統暫停後代理換了埠號**：已排隊或要重送的下載都打到舊網址（讀程式碼推論，Simulator 無法重現暫停）。
4. **下載途中播了另一個 Python 站**：代理只服務「最近一次播放的 Python 爬蟲」，下載請求會交給別的爬蟲處理（讀程式碼推論，沒有實測）。

紅果的整集檔案大、腳本慢（W-252：冷快取一集 3.7～5.2 秒，bvc2 集數 10～37 秒才回 500），又通常是一次下載多集，所以很容易碰到 1、2、4。

## 下載流程的程式位置

| 步驟 | 位置 | 對本機代理來源的影響 |
|---|---|---|
| 解析網址 | `VodView.prepareDownload`（`WebHTVApp.swift`）→ `SourceClient.playbackURL` | 爬蟲回的 `http://127.0.0.1:9978/proxy?...` 被 `SpiderProxyServer.serve` 改寫成 `http://127.0.0.1:<隨機埠>/<每次啟動不同的 token>/proxy?...` |
| 讀串流（下載確認頁） | `OfflineDownloadManager.options` → 前景 fetcher | 在 App 行程內，能連到代理（實測 OK） |
| 排隊、存計畫 | `OfflineDownloadManager`：計畫（plan）存下每個單元的 `remoteURL` | **把含埠號和 token 的代理網址永久存下來** |
| 傳輸 | `URLSessionOfflineTransport.submit`（`OfflineRuntime.swift:178`）：`credentialed` → 前景 session，其餘 → **background session** | 本機代理網址沒有帶憑證，走 background session（系統的 nsurlsessiond，在 App 行程外） |
| App 回來 | `resubmitRunning`／`reconnect`（`OfflineDownloadManager.swift:255`、`:275`）：只重送 session 已經沒有的單元，用的是計畫裡的舊網址 | background session 還留著的任務不重送；重送也是打舊埠號＋舊 token |
| 代理 | `SpiderProxyServer`：`port: .any`、`token = UUID()`（每次啟動）、`respond` 只交給最近一次 `serve` 的 `session`、`callTimeout = 20 s` | 網址只在同一次執行、代理活著、而且同一個 Python 爬蟲時有效 |

## 實測（Simulator webhtv-w202，2026-11-09 15:08–15:27）

證據在 `.herdr-synapse/webhtv-dev/artifacts/w264/`。

| # | 情境 | 結果 | 證據 |
|---|---|---|---|
| 1 | 線路2 第1集（整集 MP4 2.78 MB，經代理），App 一直在前景 | 確認頁正常（360p H.264、3 MB）；`queued` → `submit` → 1 秒後 `completed bytes=2789376` | `dl1-key.txt`、`w264-sheet.png` |
| 2 | 線路2 第3集，傳輸請求故意慢 20 秒；送出 5 秒後關掉 App，25 秒後重開 | 重開後 `launch loaded=2`，**沒有任何 submit／failed／completed**。下載頁顯示「進行中」、詳情頁「第3集 0%」，6 分鐘以上都沒變。重開後只有新 App 在 `127.0.0.1:10010` 監聽，nsurlsessiond 沒有任何連線 | `kill-key.txt`、`kill-relaunch-ep3-stuck-0pct.png`、`w264-final.png` |
| 3 | 線路2 第2集，傳輸請求慢 20 秒；送出 3 秒後切到「設定」40 秒再回來 | 模擬器上 App 在背景仍在跑（15:24:31 代理有回應），所以**沒有重現暫停**。20 秒延遲剛好碰到代理上限：`→ none`（逾時）→ 回前景時 `submit`（任務已不在）→ `retry attempt=2` → 再逾時 → `failed kind=httpStatus status=504`，顯示「需要處理」 | `bg-key.txt` |

第 3 項的 504 是注入延遲造成的，但它表示：只要爬蟲的 `localProxy` 一次呼叫超過 20 秒，下載就會失敗（播放也有同一個 20 秒上限，W-252）。

## 修正方案（另開單，需核准）

| 方案 | 做法 | 估時 | 優缺點 |
|---|---|---|---|
| A 不做 | — | 0 | 本機代理來源只能在前景、短時間內下載 |
| B 明確拒絕 | `prepareDownload` 遇到代理網址（`SpiderProxyServer.serves(_:)`）就說「這個來源不支援離線下載」 | S（<1h） | 不會再出現永遠卡住的下載；但連目前能成功的短下載也不能用 |
| C 能下就下、失敗看得到（建議） | 1. 本機代理單元一律走前景 session（照 `credentialed` 處理：跟著 App 停、回前景重送）。2. 計畫存原始的 `127.0.0.1:9978/proxy?...`，送出時才用目前的代理 base 改寫。3. 重開後代理沒有這個站的爬蟲 session 時，先用該站重建 session，建不起來就標「需要處理」並說明原因。4. 啟動時取消 background session 裡指向舊代理網址的任務 | M（約 3～4h，含單元測試和 Simulator 重開／背景情境） | 下載只在 App 開著時進行，但不會再卡住；第 4 項（換 Python 站）要另外處理：代理改成依網址分派到下載建立時的爬蟲，約再 +1h |

另外不論選哪一個方案：代理 20 秒上限對整集下載太短，可以讓下載請求用較長的上限（S）。

建議 **C**（或先做 B 止血）。依使用者 11-09 的決定，不為紅果專門做下載。C 是對所有本機代理來源的修正，讓下載和其他來源一樣可靠；它不保存任何站特有的解密邏輯，存下來的是爬蟲本來就交給播放器的影片資料。

## 未驗證

- 真機上 App 被暫停後代理換埠號（情況 3）：Simulator 沒有暫停 App。
- 下載中播另一個 Python 站（情況 4）：只讀了程式碼（`SpiderProxyServer.respond` 只用最近的 `session`）。
- 紅果本身：依工單限制沒有測。

## 回退

只有文件，刪除本文件即可。
