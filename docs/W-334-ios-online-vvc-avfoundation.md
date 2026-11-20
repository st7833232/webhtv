# W-334 線上播放：由 AVFoundation 讀出 VVC／ByteVC2 就改用 MPV

- 分支 `claude/kind-dirac-ojjljm`，從 ios-poc `52fc3dfa`（W-333）開。
- Lane：quick-fix，沿用 W-262／W-269 已確立的「VVC 交給 MPV」設計，只新增偵測點。使用者在 2026-11-20 選了「通用修法」。

## 1. 問題

使用者回報（2026-11-20）：紅果線上播放有時只有聲音、沒有畫面，重開一次就正常。

## 2. 原因（三個漏洞）

| 路徑 | 現有偵測 | 漏洞 |
|---|---|---|
| 爬蟲代理（W-262） | 代理收到整集 MP4 時標記 VVC，啟動監看迴圈每 100 ms 檢查，只在 `startupMilliseconds == nil` 時切換 | 標記與 AVPlayer 開始出聲落在同一個檢查間隔時就不會切換。重開時 `PlayerRouter.open` 已知 VVC，直接用 MPV，所以「重開會好」 |
| 腳本自己的本機服務（W-269） | 讀前 512 KB，開始播放後也能切換 | `moov` 在檔尾或大於 512 KB 時讀不到 |
| 其他網址 | 不偵測 | VVC 一定只有聲音 |

「重開會好」符合第一列。另外兩列這次沒有實際觀察到，是讀程式碼推得的漏洞。

## 3. 做法

- `PlaybackSession.loadNative` 建立 `AVPlayerItem` 後呼叫 `moveVVCToMPV`：以 `asset.loadTracks(withMediaType: .video)` 和 `track.load(.formatDescriptions)` 取得影片 fourCC，屬於 `MP4SampleEntry.needsMPV`（`bvc2`、`vvc1`、`vvi1`）就 `router.select(.mpv, playing: true)`。
- 開始播放後也會切換，和 W-269 的規則相同。切換前會確認：仍是同一個 item、引擎仍是 native、網址沒變，避免影響使用者已經換掉的集數。
- 不論網址來源、也不論 `moov` 在檔頭或檔尾都適用；AVPlayer 本來就要解析 `moov`，這裡只是額外讀它的結果。
- 不適用：HLS（`loadTracks` 不會給出 VVC 軌）。
- 既有的 W-262、W-269 偵測保留不動：它們能在 AVPlayer 開始之前就切換。
- 寫法和既有的 `loadVariantCount`、`audioFacts` 相同（`Task { @MainActor … }` 讀 asset 屬性）。

## 4. 驗證

- 本機沒有 Swift／Xcode，**尚未編譯**，只做了 diff 靜態審查，並和既有寫法比對。
- 這段是 App 層的播放流程，沒有單元測試可涵蓋。
- 實機待確認：
  1. 紅果線上播放 VVC 集數，第一次開啟就有畫面。log 會出現 `moved to MPV (AVFoundation track)`，或既有的 W-262、W-269 訊息。
  2. HEVC／H.264 的集數不受影響，仍用原本的播放器。
- Ponytail：unavailable / skipped（此環境沒有提供）。

## 5. 風險

- 切換前可能會先聽到一小段聲音。這是 AVFoundation 載入軌道的時間，通常在播放開始前後一秒內。
- 使用者手動切回 AVPlayer 時，會重新載入 item，同一部 VVC 又會被切回 MPV。這是刻意的：AVPlayer 本來就無法顯示這種畫面。

## 6. 回復

`git revert <W-334 commit>`。

## Recovery anchor

- 狀態：程式碼與文件已完成，尚未編譯。
- 下一步：推送並發佈後，在實機用紅果的 VVC 集數確認第一次開啟就有畫面。
