# W-269 本機迴路 MP4 先探測前段：bvc2 直接走 MPV

- 工單：herdr W-269（使用者 11-09 選做，Reviewer #6972 提議；Manager #7083：照原計畫做，防真機最壞情況）。
- 分支：`task/W-269`，自 ios-poc（見文末提交）。沿用 W-262 的 `MP4SampleEntry` 判斷，不重寫。不改紅果腳本。

## Recovery anchor

- 目標：播放位址是 127.0.0.1／::1／localhost、不經 App 的 `SpiderProxyServer` 的 MP4（腳本自帶的本機服務）時，讀前段判斷編碼，bvc2／VVC 直接用 MPV；讀不到或不是 MP4 照舊。非 bvc2 與既有 App 代理路徑起播時間不退化。
- 狀態：實作、單元測試、Simulator 量測、Ponytail 完成，送審。

## 先講結論：這個問題比原先估的嚴重

原本以為（#6969／#6972）腳本自有服務的 bvc2 第一集會「原生等 10 秒逾時 → MPV」。實測：

| 測試伺服器 | 原生 AVPlayer 對 bvc2 的反應 | 結果 |
|---|---|---|
| 不支援 Range（Python `http.server`，W-262 用的） | 約 0.2 秒回 `Operation Stopped` | 失敗換手 MPV，0.74 秒起播（W-262 實測）|
| **支援 Range**（真正給播放器用的服務都會支援；`artifacts/w269/srv/range_srv.py`） | **0.29～0.75 秒就「起播」**，但只有聲音、畫面是 QuickTime 佔位圖（`artifacts/w269/base-own-bvc2.png`） | **不會失敗、不會逾時，永遠不會換 MPV**：使用者只聽得到聲音 |

所以 W-269 修的不是「省 10 秒」，而是「有聲音沒畫面、而且不會自己恢復」。

## 做法

| 位置 | 內容 |
|---|---|
| `MP4SampleEntry.swift`：`LoopbackMP4Probe` | `applies(to:)`：http、host 是 127.0.0.1／::1／localhost、不是 `SpiderProxyServer` 的位址、副檔名不是 m3u8／mpd／ts。`probe`：用既有的 `OfflineHTTP.fetcher` 送 `Range: bytes=0-524287`、請求逾時 3 秒、最多讀 512 KB，交給 `MP4SampleEntry.videoFourCC`；結果記在最多 64 筆的集合裡 |
| `PlaybackEngine.swift`：`PlayerRouter.needsMPV` | 已探測為 VVC 的位址也回 true → 同一位址重開直接 MPV |
| `WebHTVApp.swift`：`router.open(...)` 之後 | 原生開啟時，**同時**（不等待）啟動探測；探測說 VVC、而且還是同一集、還在原生 → `router.select(.mpv, playing: true)`。即使原生已經「起播」也換（原生對 VVC 只放聲音） |

探測上限：512 KB（測試的 168 秒 bvc2 一集 moov 206 KB、在第 28 byte 起；moov 在檔尾的檔案探測不到，照舊流程）。逾時 3 秒（迴路位址正常是幾十毫秒；腳本還在抓遠端時放棄探測，不影響播放）。伺服器不理 Range 時讀滿 512 KB 就停。

原本的設計是把結果交給起播監看（W-262 那個迴圈）處理；量測時發現原生 0.3～0.7 秒就「起播」，監看在起播後就結束，探測晚一點回來就沒人處理，所以改成探測自己換。

## 單元測試

`LoopbackMP4ProbeTests`（`MP4SampleEntryTests.swift`）：
- `onlyALoopbackFileTheProxyDoesNotServeIsProbed`：127.0.0.1、[::1] 會探；外部網址、m3u8、App 代理位址不探。
- `aVVCFrontOpensOnMPVAndAnythingElseKeepsTheUsualWay`：bvc2 前段 → true，之後 `PlayerRouter.needsMPV` 為 true；avc1 → false；moov 在檔尾、moov 被截斷 → nil，`needsMPV` 仍 false。

`LoopbackMP4Probe|MP4SampleEntry|SpiderProxyServer|PlaybackEngine|PlayerRouter` 94/94 過。

## Simulator 量測（webhtv-w185，iOS 27.0，Debug，預設播放器原生）

每次都重開 App（記憶體裡沒有先前結果），點同一集；「起播」是 App 自己的 `started … in Xms after open`。設定 `artifacts/w262/kit/kit.json`：`KIT｜bvc2` 經 App 代理；`KIT｜自有服務` 直接用 `http://127.0.0.1:18448/media/…`（支援 Range 的 `range_srv.py`）。基準版是 ios-poc 的程式（W-262 的建置），W-269 版是本分支。紀錄：`artifacts/w269/baseline-applog.txt`、`probe-applog.txt`、整理後 `baseline-*.txt`、`probe-*.txt`。

| 情境 | 基準版（3 次） | W-269（3 次） |
|---|---|---|
| 自有服務 bvc2 第1集 | 原生 287／361／747 ms「起播」，**只有聲音、沒有畫面，不換 MPV** | 探測 22／30／32 ms 判定 VVC → 換 MPV，**有畫面**，起播 443／829／866 ms |
| 自有服務 H.264 第3集 | 原生 340／390／452 ms（中位 390） | 探測 23～38 ms 判定不是 → 照走原生 329／407／589 ms（中位 407） |
| 經 App 代理 H.264 第3集 | 原生 601／708／669 ms（中位 669） | 不探測；原生 594／646／902 ms（中位 646） |

- 「Simulator 原生失敗換手時間」（Manager #7083 要求一併記）：只有在伺服器不支援 Range 時才會失敗換手，約 0.2 秒失敗、0.74 秒 MPV 起播（W-262 紀錄 `artifacts/w262/sim-release-native-applog.txt`）。支援 Range 時原生不會失敗（見上）。
- 非 bvc2 的差異在每次量測的波動範圍內（自有服務中位 +17 ms，代理中位 −23 ms）；探測與原生同時進行，不在起播的路徑上。
- 畫面：基準版 `artifacts/w269/base-own-bvc2.png`（只有 QuickTime 佔位圖），W-269 `artifacts/w269/probe-own-bvc2.png`（有畫面）。

## Ponytail 審查

已跑（`ponytail:ponytail-review`，最終 diff）：沒有發現。檢查了探測上限與失敗時照舊、換 MPV 只對同一集且還在原生、64 筆上限、解析的邊界測試。

## 沒驗到／限制

- 真機：AVPlayer 在 iPhone 上對 VVC 的反應（是否同樣只放聲音）沒測；W-269 不論哪種反應都會換。
- 真站：新版紅果 PY 目前都是 H.264（W-267），沒有 bvc2 可驗。
- moov 在檔尾、或 moov 超過 512 KB 的 bvc2：探測讀不到，照舊（會回到只有聲音的情況）。
- 換到 MPV 後同一次觀看的下一集也留在 MPV（W-202 起的既有規則：使用者或判斷選的引擎沿用到整個 session）。

## 回退

`git revert` 本單的提交。只影響本機迴路、非代理位址的播放；沒有資料格式改動。

## 測試伺服器（重現用）

- `python3 -I artifacts/w269/srv/range_srv.py artifacts/w262/kit 18448`（支援 Range 的自有服務）
- kit 設定與代理用的 `https 18446`、`http 18447` 見 `docs/W-262-bvc2-ios-impl.md`。
