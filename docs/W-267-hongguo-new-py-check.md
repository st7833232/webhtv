# W-267 新版紅果 PY 在 iOS 的播放實測

只量測，不改腳本、不改 App、不保存解密後影片、不看簽章／解密邏輯、不測 bvc2 集數。

## Recovery anchor

- 目標：新版 `py/红果短剧.py`（GitLab recha `7d846b6`，本次下載的檔 sha256 `c7beaf1930147132a8d6ceb0e3390db64ac8219223798e02643aae7d53d9eb65`）在 iOS 的起播／換集時間、失敗次數、實際走的路徑，與舊版紀錄（W-245）比較。
- 狀態：量測完成，reviewer-2 已核准（#6990）。
- 下一步：依審查意見補量；是否處理「腳本自有服務繞過 App 代理」由 Manager 交使用者決定。

## 環境

- Simulator webhtv-w185（iOS 27.0，Debug），設定 GitLab `wang-movie.json`（正式來源）的「紅果 • 短劇」，劇「裝窮提親，娶到全家嫌棄的她」標準畫質，第 8→9→10 集連播（W-252 時這幾集就是 H.264，避開 bvc2）。
- App 為 task/W-262 工作區的建置（含 W-262 的代理判斷；本次路徑不經 App 代理，所以不影響量測）。啟動帶 `WEBHTV_PREFETCH_IGNORE_LOW_DATA=1`（Simulator 被系統當成低數據模式，W-252 同樣做法）。
- 每集：播 25 秒 → 拖到約 60% → 等 18 秒（讓下一集預解析）→ 拖到片尾 → 自動換下一集。
- 紀錄：`.herdr-synapse/webhtv-dev/artifacts/w267/native-run.log`、`mpv-run.log`（只含 `[playback]`／`[proxy]` 行）。

## 結果

| 播放器 | 集 | 開法 | 起播 | 解析 | 備註 |
| --- | --- | --- | --- | --- | --- |
| 原生 | 8 | 冷開（點選集數） | 3216 ms | live 415 ms | `content=miss: notRequested` |
| 原生 | 9 | 自動換集 | 1385 ms | prefetched 0 ms | `content-prefetch 9 skipped: localProxy` |
| 原生 | 10 | 自動換集 | 1339 ms | prefetched 0 ms | 同上 |
| MPV | 8 | 冷開 | 961 ms | live 62 ms | |
| MPV | 9 | 自動換集 | 913 ms | prefetched 0 ms | `skipped: localProxy` |
| MPV | 10 | 自動換集 | 740 ms | prefetched 0 ms | 同上 |

- 失敗：0 次；兩輪都沒有 stall、沒有 `not started`、沒有換播放器。
- 走的路徑：**腳本自己的 127.0.0.1 串流服務**。依據：①兩輪都沒有任何一行 App 代理的 `[proxy]` 紀錄（經 App 代理時每個請求都會記一行，W-252／W-262 的紀錄可對照）；②下一集內容預抓都是 `skipped: localProxy`，這個判斷就是「網址主機是 127.0.0.1/localhost」（`NextEpisodeContent.eligible`）。所以 W-240 分段、W-245 下一集整集預熱（`content-warm`）、W-252 合併呼叫都沒有發生；只有 IOS-POC-15D 的「下一集位址預解析」（`resolve … prefetched 0ms`）仍有效。
- 腳本自有服務在 iOS Python 可以啟動並正常供片（六次起播都成功）。

## 與舊版比較（W-245 紀錄）

| | 舊版（經 App 代理＋W-245 預熱） | 新版（腳本自有服務） |
| --- | --- | --- |
| 原生換集 | warm 190～598 ms；沒預熱的冷換集 2.7～4.7 秒 | 1.34～1.39 秒 |
| MPV 換集 | 246～371 ms | 0.74～0.91 秒 |
| 冷開 | 原生 3.4～9.2 秒（W-252，熱點冷下載） | 原生 3.2 秒、MPV 0.96 秒 |

- 新版換集比舊版的「冷換集」快（腳本服務邊下邊供、App 已預解析位址），但比舊版有預熱的換集慢約 0.8～1.1 秒（原生）與 0.4～0.6 秒（MPV），因為 W-245 的整集預熱不再生效。
- 這是單次 Simulator 量測、單一部劇，網路為 Mac 熱點；數字是量級比較，不是統計結論。

## 對 W-262（bvc2）的影響

- Manager #6969 比對新舊腳本：新版不再避開 bvc2，會把 bvc2 集數交給 App；新版走自有服務時不經 App 代理，W-262 第二段「代理讀 stsd、起播前換 MPV」不會觸發。
- 結果（推論，reviewer #6972 同意）：同一個播放 session 第一個 bvc2 集數要等原生起播逾時（約 10 秒）再換 MPV；之後的集數因 session 已在 MPV 直接用 MPV。前提是 W-262 的新 FFmpeg 已上線，否則 MPV 也解不出畫面。
- 本次三集原生都能起播，代表它們不是 bvc2（AVPlayer 解不了 VVC）。**沒有逐集讀出實際 fourcc**：新版的播放網址帶腳本產生的參數，Log 只記主機與副檔名，我拿不到完整網址，不另外去探測腳本服務。

## 建議（不改程式，交使用者決定）

1. 若要恢復「換集 < 0.6 秒」的體驗：請腳本作者讓 App 代理（`getProxyUrl`）維持主要路徑，或 App 另案支援「對 127.0.0.1 MP4 先用 Range 讀前段找 moov」（同時能讓腳本服務的 bvc2 也直接起 MPV，reviewer #6972 的建議）。
2. 若接受目前速度：不需動作；只有 bvc2 集數第一次要多等約 10 秒（W-262 上線後）。

## 量測過程附註

- 量測途中我曾為了找腳本服務的連接埠，對一個 127.0.0.1 埠發了一次 2 位元組的讀取請求，事後確認那個埠屬於 claude-dev 的 Simulator（webhtv-w202）App，回 404，沒有其他動作，也沒有再碰。

## 審查

- 2026-11-09 15:28 reviewer-2 核准 ed48bc32（#6989、#6990）：紀錄與表格一致。補充：W-245 的對照數字（原生 warm 190～598 ms）是 W-247 之前的舊起播時點，原生約早記 100～200 ms；本次是新時點，所以實際退化比表上略小，交使用者時一併說明。
