# W-333 離線播放 VVC／ByteVC2 下載檔改用 MPV

- 分支 `claude/kind-dirac-ojjljm`，從 ios-poc `8f188f9e`（0.1.109 發版 commit）開。
- Lane：quick-fix。沿用 W-262／W-269 已確立的「VVC 交給 MPV」設計，只把它延伸到離線檔，屬於 `AGENTS.md` §7 的既有設計局部修正。

## 1. 問題

使用者回報（2026-11-20，附下載頁截圖）：《大佬修仙滿級回現代，我讓全家橫著走》的下載裡，編碼標成「未標示」的集數只有聲音、沒有畫面；第 14 集標成 HEVC。

## 2. 原因

- 「未標示」：下載完成後用 AVFoundation 讀影片的 fourCC（`OfflineRuntime.swift` `OfflineVideoInfo.read`）。`OfflineVideoCodec(codecs:)` 只認得 HEVC、H.264、AV1、VP9，`bvc2`、`vvc1`、`vvi1` 都會變成 `.unknown`。
- 線上播放：`PlayerRouter.needsMPV` 會因 `SpiderProxyServer.prefersMPV`（W-262）或 `LoopbackMP4Probe.isVVC`（W-269）改用 MPV。
- 離線播放：開啟的是 `file://…/video.mp4`，上面兩個判斷都只認網址，不會讀本機檔，所以 VVC 檔交給 AVPlayer，結果只有聲音、沒有畫面，也不會失敗或觸發改用另一個播放器。W-269 已記錄過同樣的症狀。
- 推論的限制：我沒有讀到使用者裝置上的檔案，「未標示＝VVC／ByteVC2」是由程式路徑和 W-269 的症狀推得。

## 3. 做法

- `MP4SampleEntry.videoFourCC(file:)`：逐一讀檔案最上層 box 的標頭，找到 `moov` 後只讀這個 box（上限 16 MB），交給既有的 `videoFourCC(_:)` 解析。`moov` 在檔頭或檔尾都讀得到；只支援 `file:` URL。
- `PlayerRouter.needsMPV`：`file:` URL 的影片 fourCC 屬於 `MP4SampleEntry.needsMPV`（`bvc2`、`vvc1`、`vvi1`）時改用 MPV。已經下載的檔案也適用，不需要重新下載。
- 沒有改的部分：下載流程、`OfflineVideoCodec` 的列舉值與顯示文字（仍顯示「未標示」）、HLS 離線包、線上播放的判斷。沒有改列舉值是因為新增 case 會讓舊版 App 讀不了下載記錄。

## 4. 驗證

- 新增測試 `aDownloadedVVCFileOpensOnMPVWhereverItsMoovIs`，涵蓋以下情況：
  - `moov` 在檔頭的 `bvc2`、在檔尾的 `vvc1` 會改用 MPV；`hvc1` 不會。
  - 檔案不存在、不是 MP4、`moov` 被截斷、非 `file:` URL 都回傳 nil。
- 本機沒有 Swift／Xcode，**測試尚未執行，也還沒編譯**，只做了 diff 靜態審查。
- 實機待確認：
  1. 「未標示」的集數離線播放時有畫面，播放器顯示的是 MPV。
  2. HEVC 的集數仍用原本的播放器。
- Ponytail：unavailable / skipped（此環境沒有提供）。

## 5. 風險

- 每次開啟本機檔都會同步讀 `moov`。短劇的 `moov` 約數百 KB，在主執行緒上的成本應可忽略，但沒有實測。
- 如果「未標示」的原因其實不是 VVC（例如檔案仍是加密的 `encv`），這個修正不會改變行為。

## 6. 回復

`git revert <W-333 commit>`，沒有資料格式變更。

## Recovery anchor

- 狀態：程式碼、測試與文件已完成，尚未編譯也尚未執行測試。
- 下一步：取得授權後推送並發佈，在 iOS 26 實機播放「未標示」的下載集數確認有畫面。
