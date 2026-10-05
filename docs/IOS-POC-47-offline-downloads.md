# IOS-POC-47 離線下載／離線播放

## Recovery anchor

- **目標**：使用者可把單集下載到 iPhone，成為一份 ≤1080p 的 `OfflineAsset`（智慧選擇＋所選音軌／字幕），AVPlayer 與 MPV 離線共用同一份播放；所有狀態都能手動刪除；真正播放完成且開啟「看完後自動刪除」時，於播放器釋放後刪除。
- **分支**：`ios-poc`；開工前 HEAD `f2f7fac407043e5c55a0a6abcd80361f7ea6e20e`。task guard `IOS-POC-47`（`standard`）。
- **狀態**：見第 11 節（驗證）與第 12 節（待真機項目）。
- **下一步**：見文末「目前狀態」。

## 1. 需求與驗收標準

1. 智慧選擇：永不下載寬或高超過 1920／1080 的版本；同解析度 HEVC 優先；SDR 優先；24／30fps 優先；智慧 1080p 取合理最低位元率；最省空間最高 720p；1080p 高畫質同解析度取高位元率。
2. 一份資料兩個引擎：切換播放器不重新下載、不複製；DRM 只能 AVPlayer，且不得為 MPV 解密。
3. 身分：`WatchHistory.key`（`Site.id` + vod id）+ 線路 + 集數（`Episode.url`），不用解析後的簽章網址；換畫質、簽章更新、換引擎都不會產生第二份。
4. 每個狀態（排隊、準備、下載中、暫停、失敗、完成）都能手動刪除；失敗不自動隱藏、不自動刪；刪除走同一個入口並釋放實際空間。
5. 看完自動刪除只認 AVPlayer `AVPlayerItemDidPlayToEndTime`、MPV `MPV_END_FILE_REASON_EOF`、既有「片尾自動跳下一集」；seek 到片尾、錯誤、停止、換引擎、換畫質、背景、鎖屏、crash 都不算；刪除在播放器釋放後才執行，crash 中斷由下次啟動完成。
6. 下載完成後離線播放不發任何媒體網路請求；HLS 完成前驗證每個本機引用都存在且沒有遠端 URI。
7. 下載可在背景繼續，App 重開後接回；空間不足時乾淨地進入 `failed(.insufficientStorage)`。
8. 使用者補充（2026-10-04）：**從觀看記錄刪除作品時，該作品已下載的集數一併刪除（影集刪除整個系列的下載）**。60 天自動清理記錄不會刪任何下載。

## 2. Best-practice review

研究以一個子任務完成（2026-10-04 存取）。`rfc-editor.org`、`ietf.org`、`datatracker` 等 RFC 主站從雲端 session 回 `403 connect_rejected`，RFC 8216 原文未能直接讀取，相關規則改以 FFmpeg 實作與 Apple HLS Authoring Spec 佐證，並在下表標明。

| # | 來源 | 等級 | 支持的結論 | 對 WebHTV 的影響 |
|---|---|---|---|---|
| E1 | developer.apple.com：`AVAssetDownloadURLSession`、`urlSession(_:assetDownloadTask:didFinishDownloadingTo:)` | A | 必須用 background session；下載結果「must remain at the system-provided URL」；強制關閉 App 時系統取消下載；只有 VOD 支援離線 | `.movpkg` 位置與格式由 AVFoundation 管理，沒有公開格式文件，MPV 無法讀；只適合作為 DRM（AVPlayer-only）路線 |
| E2 | Apple Developer Forums thread 69357（Apple Media Engineer） | B | 「you can't get m3u8 from the local filesystem」 | AVPlayer 不能直接以 `file://` 播本機 HLS |
| E3 | Apple Developer Forums thread 113063（Apple Systems Engineer） | B | Resource loader 對 segment 只接受 redirect 到 HTTP，`respondWithData` 會被拒 | 自製 resource loader 不能提供 segment，loopback HTTP server 是 AVPlayer 可用的本機路徑（推論，Apple 未明文背書） |
| E4 | `willPerformHTTPRedirection` 文件、「Downloading files in the background」 | A | background session 不呼叫 redirect delegate，自動跟隨 redirect；背景中啟動的 task 會被延遲且延遲遞增；大量小 task 不建議；background 永遠等待連線 | 帶 Cookie／Authorization 的請求不走 background session（避免 redirect 外洩）；segment 在前景一次全部送出，避免背景中逐批送出被限速 |
| E5 | `cancel(byProducingResumeData:)`、`didFinishDownloadingTo` 文件 | A | resume data 需要 ETag／Last-Modified 與 Range；檔案必須在 delegate 回傳前移走 | progressive 檔以 resume data 續傳，沒有就從頭；transport 在 delegate 內同步搬檔 |
| E6 | FFmpeg `libavformat/hls.c`（master，2026-10-04） | A（FFmpeg 行為） | 相對 URI 以 playlist URL 解析；缺 IV 時以 media sequence 當 IV；BYTERANGE 省略 offset 時接續前一段；支援 EXT-X-MEDIA AUDIO／SUBTITLES；`extension_picky` 拒絕副檔名與格式不符的 segment；`allowed_extensions` 只限 `file://` | 本機檔名依內容命名（`.ts`／`.m4s`／`.mp4`／`.aac`／`.vtt`），保留 media sequence 與 IV；MPV 走 HTTP 不受 `allowed_extensions` 影響 |
| E7 | Apple HLS Authoring Specification（2025-06-26 版） | A | CODECS、RESOLUTION、FRAME-RATE、AVERAGE-BANDWIDTH 為 MUST；非全 SDR 時必須有 VIDEO-RANGE；FairPlay 為 `SAMPLE-AES` + `com.apple.streamingkeydelivery`；fMP4 必須有 EXT-X-MAP；建議 `hvc1` | 選擇器以這些屬性判斷；缺 RESOLUTION 的來源另以位元率保守處理；FairPlay 一律判為 DRM |
| E8 | 「Optimizing your app's data for iCloud backup」 | A | 下載供離線觀看的影片應設 `isExcludedFromBackup`；tmp／Caches 會被系統清除，不可存放不可清除的資料；每次存檔都重設 | 永久資料放 `Application Support/OfflineMedia/`，每個資產資料夾建立時標記排除備份；只有傳輸中的檔案放 tmp |

未能取得：RFC 8216 原文（網路政策），VIDEO-RANGE 值與 BANDWIDTH／AVERAGE-BANDWIDTH 的 RFC 原文定義未逐字核對；`AVERAGE-BANDWIDTH` 是否已含音訊 rendition 依 RFC 8216 §4.3.4.2 的既有理解（「playable combination of Renditions」），容量預估因此不再另加音訊位元率，並在第 7 節標示。

## 3. 現有實作盤點（以 `f2f7fac4` 為準）

- `SourceClient.playbackURL` → `PlaybackTarget`（`ios/Sources/WebHTVCore/SourceClient.swift`）：URL、headers、qualities、`subtitles`。
- `PlayerRouter`／`PlaybackEngine`（`PlaybackEngine.swift`）：引擎切換與 fallback 只交接同一個 `PlaybackLoadRequest`，不重新解析；`onEnded` 是引擎真正結束的唯一事件。
- `AVPlayerEngine`（`WebHTVApp.swift`）：`didPlayToEndTimeNotification` 只認目前 item。
- `MPVEngine`／`MPVPlayerCore.drain`（`MPVEngine.swift`）：`MPV_EVENT_END_FILE` 只有 `MPV_END_FILE_REASON_EOF` 才發 `.ended`，`ERROR` 發 `.failed`，`STOP`／`QUIT`／`REDIRECT` 都不發；換檔時舊檔的 EOF 被忽略。**不需要改 MPVEngine。**
- `PlaybackSession.finished(reason:)`：`"end"`（引擎 EOF）與 `"ending"`（使用者設定的片尾，正式自動下一集）共用一條路徑，`PlaybackEndGate` 保證一次。
- `PlaybackSession.closePlayer()`：關閉播放畫面只暫停，item 仍在 AVPlayer 上（WebHome 橋接需要）。
- `WatchHistory`／`WatchHistoryStore`：key 為 `Site.id@@@vodId`，`episodeUrl` 為集數身分。
- 片源字幕 header 規則：`SourceSubtitleProvider.forwarded`（User-Agent、Referer 可送任何 host，其他只送同 origin，不由 https 降為 http）。
- 串流快取：沒有獨立的串流快取層（`URLCache` 已關閉，IOS-POC-10L），線上字幕暫存在 `tmp/WebHTVOnlineSubtitles/session-*`。離線資料使用獨立命名空間，與兩者都不共用。
- 現有沒有任何下載服務、store 或 storage 抽象可延伸，因此新建 `Offline/` 層。

## 4. 方案比較與決策

| 方案 | 兩引擎共用 | 優點 | 缺點／風險 | 結論 |
|---|---|---|---|---|
| 不做 | — | 無風險 | 不滿足需求 | 否決 |
| A. 以 `AVAssetDownloadURLSession` 為中心 | 否（`.movpkg` 只給 AVFoundation，E1） | Apple 官方背景下載、FairPlay 持久金鑰 | MPV 讀不了，必須另存第二份；格式不公開 | 只保留為 DRM 路線的語意（`avPlayerOnly`），本版不實作 FairPlay（來源沒有授權伺服器） |
| B. WebHTV 自管 HLS package | 是 | 一份資料、兩引擎同一入口；保留 discontinuity、AES-128、fMP4、字幕 rendition；智慧去廣仍可讀本機 playlist | AVPlayer 需 loopback server（E2、E3）；background session 對大量 segment 有限速風險（E4） | **採用（HLS）** |
| C. 單檔 progressive | 是（`file://`） | 最簡單，兩引擎直接讀 | 只適用來源本身是單檔；HLS remux 成 MP4 需要 FFmpeg、雙倍暫存空間，discontinuity／廣告段的時間軸處理風險高 | **採用（來源本身是單檔時）**；不做 HLS remux |
| D. 混合（B＋C，DRM 標記 A） | 是 | 依來源格式選最小可靠的路徑 | 兩種 package 格式 | **最終決策** |

AVPlayer 本機 HLS 入口比較：

| 方式 | AVPlayer | MPV | 背景／耗電 | 安全 |
|---|---|---|---|---|
| `file://` playlist | 不支援（E2） | 可 | — | — |
| `AVAssetResourceLoaderDelegate` | segment 只能 redirect 到 HTTP（E3） | 不適用（另一套） | — | 只在 AVPlayer 內 |
| loopback HTTP server | 可 | 可（同一 URL） | 只在播放離線 HLS 時啟動，閒置無耗電 | 綁 127.0.0.1、每次啟動隨機 token、只讀資產資料夾內的一般檔案 |

決策：**loopback server（`OfflineMediaServer`）**，兩個引擎拿同一個 `http://127.0.0.1:<port>/<token>/<asset-id>/playlists/index.m3u8`；progressive 則兩個引擎拿同一個 `file://` 路徑。

## 5. 架構

需求中的名稱與實作對應（`ios/Sources/WebHTVCore/Offline/`）：

| 需求名稱 | 實作 | 職責 |
|---|---|---|
| OfflineDownloadManager | `OfflineDownloadManager`（actor） | 排程（一次一個；IOS-POC-50 起最多同時 3 個）、開始、暫停、繼續、重試、失敗、唯一刪除入口、看完事件、重開後接回 |
| OfflineAssetStore | `OfflineAssetStore`（由 manager 獨占的 class） | 每個資產一個 `metadata.json`，原子寫入、版本、migration、不可讀時保守保留 |
| OfflineMediaSelector | `OfflineMediaSelector` | 第 7 節規則 |
| OfflineStorageManager | `OfflineStorage`、`OfflineStorageLayout` | 路徑、排除 iCloud 備份、實際占用、可用空間、safety margin、原子寫入、暫存清理 |
| OfflinePlaybackResolver | `OfflinePlaybackResolver` | 完成的資產 → 本機 `PlaybackTarget`，兩引擎同一 URL；AVPlayer-only 不給 MPV |
| OfflineCompletionPolicy | `OfflineCompletionPolicy` | 只認真正結束；釋放後才刪 |
| — | `HLSPlaylist`／`OfflinePackageBuilder`／`OfflinePackageVerifier` | 解析、改寫成本機 package、完成前驗證 |
| — | `OfflineTransport`／`URLSessionOfflineTransport` | background session（無憑證）＋前景 session（帶憑證，redirect 時移除憑證） |
| — | `OfflineMediaServer` | loopback HTTP（GET／HEAD、Range） |
| — | `OfflineLibrary` | UI 用的 MainActor 快照 |

App 端（`WebHTVApp.swift`）：`PlaybackSession.open(offline:)`、`load` 中的釋放與離線字幕、`finished`／`closePlayer`／`stop` 呼叫 policy；`VodView` 每集狀態與選單、下載前 sheet、管理下載；「下載」分頁；設定頁「離線下載」；觀看記錄刪除時一併刪下載。

## 6. 離線 package 格式

```
Application Support/OfflineMedia/<asset-id>/
  metadata.json                 OfflineAsset（schemaVersion 1）
  download-plan.json            只在未完成時存在：遠端位址與 headers，完成即刪
  download-request.json         同上：解析後的網址、headers、使用者選擇
  playlists/index.m3u8          本機 master：1 個 variant、1 個音軌 rendition、所選字幕
  playlists/video.m3u8          本機 media playlist
  playlists/audio.m3u8          所選音軌 rendition（音訊另有 playlist 時）
  playlists/sub-N.m3u8          所選 WebVTT 字幕 rendition
  media/v00001.ts|.m4s          影片 segment；fMP4 時 media/v-init1.mp4
  audio/a00001.aac|.ts|.m4s     音軌 segment
  subtitles/s1-00001.vtt        WebVTT segment；片源字幕為 subtitles/session-…/1-<name>.srt
  keys/k1.key                   一般 AES-128 key（非 DRM）
  partial/unit-0.resume         progressive 中斷時的 resume data
```

- playlist 由解析後的模型重新產生，只輸出 VOD 需要的 tag（VERSION、TARGETDURATION、MEDIA-SEQUENCE、DISCONTINUITY-SEQUENCE、PLAYLIST-TYPE、INDEPENDENT-SEGMENTS、KEY、MAP、DISCONTINUITY、PROGRAM-DATE-TIME、EXTINF、ENDLIST），所有 URI 都是 `../` 開頭的相對路徑。
- BYTERANGE segment 與 init map 各自存成獨立檔案，本機 playlist 不再有 BYTERANGE。
- 同一個（位址、range）只下載一次。
- `EXT-X-GAP` 段落不下載，下一段標 DISCONTINUITY（FFmpeg 不認得 GAP）。
- 拒絕：FairPlay／其他 DRM（`drmProtected`）、非 DRM 的 SAMPLE-AES（`unsupported`）、沒有 ENDLIST 的直播。
- 完成前驗證：每個 unit 檔存在且大小正確、每個 playlist 引用都是相對路徑、留在資產資料夾內、檔案存在。

## 7. Smart Download Selection

依序：

1. 框：長邊 ≤ 1920 且短邊 ≤ 1080（最省空間 1280／720），直式 1080×1920 視為 1080p。
2. SDR 優先；只有 HDR 時才選並標示 `hdrOnly`。
3. 最高解析度。
4. 24／25／30fps 優先；設定「下載 60fps 高幀率版本」時反過來。
5. HEVC > H.264 > 未標示 > AV1／VP9（後兩者硬體解碼支援較少）。
6. 位元率（AVERAGE-BANDWIDTH，沒有則 BANDWIDTH）：智慧 1080p 取「不低於合理下限」的最低者（HEVC 0.025、H.264 0.04 bits/pixel/frame × 寬 × 高 × fps，1080p HEVC 約 1.56 Mbps），全部低於下限時取其中最高；最省空間取最低；1080p 高畫質取最高。
7. 整個 master 都沒有 RESOLUTION：以位元率保守判斷，超過 12 Mbps 視為可能高於 1080p 而排除（除非只剩它），並標示「解析度未標示」。

音軌：只下載一個 rendition；依目前播放語言／名稱，否則 DEFAULT，否則第一個；最省空間在同語言有 stereo rendition 時選 stereo（只選來源既有的，不 downmix）。音軌包含在影片內時不另外下載。

字幕：HLS 字幕 rendition 與片源字幕檔（`subs`）都可選；預設選使用者語言（中文時繁體優先）。

容量預估：segment 全有 BYTERANGE 時為精確值；否則 AVERAGE-BANDWIDTH × 時長（標「約」）；只有 BANDWIDTH 時標「最多約」；progressive 用 `Content-Range`／`Content-Length` 精確值。依 RFC 8216，variant 的 bandwidth 已包含所搭配的 rendition，因此**不再另加音訊位元率**（與需求原文「加選定 audio bitrate」不同，避免重複計算）。完成後以磁碟實際占用寫入 `actualBytes`，預估值另存，畫面分開顯示。

## 8. 生命週期

- 狀態：`queued → preparing → downloading → completed`，可轉入 `paused`、`failed`，刪除時 `deleting`（寫入磁碟，crash 後下次啟動完成刪除）。
- **generation**：每次暫停、繼續、重試、失敗、刪除都加一；每個傳輸以 `<asset-id>|<generation>|<unit>` 標記；舊 generation 或已刪除資產的回報一律丟棄（檔案刪除），不會讓刪除的資產復活、不會覆蓋較新狀態。
- 連按下載：manager 是 actor，`enqueue` 在同一個同步區段內「檢查身分＋寫入」，第二次得到 `.existing`。
- 重試／續傳：HLS 已完成的 segment 保留，只送缺的；重試前若 timeline（數量、路徑、range）改變則丟棄舊檔重新開始，不混用兩份。progressive 有 resume data 才續傳，沒有就從頭（不假裝能續）。401／403／404／410 或 CDN 回 HTML 判為「來源網址已失效」，重試時以目前載入的設定重新解析集數（`OfflineEpisodeResolver`）。
- 單一 unit 的網路錯誤、5xx 自動重送 2 次，之後整個下載 `failed`，partial 保留。
- 空間：開始前需要「預估 + max(500 MB, 預估的 10%)」；下載中每完成一個檔案檢查一次，可用空間低於 200 MB 即 `failed(.insufficientStorage)`，partial 保留可刪。
- 唯一刪除入口 `OfflineDownloadManager.delete(_:)`：寫入 `deleting` → 取消該資產所有傳輸 → 刪 staging 檔 → 刪整個資產資料夾（record、playlist、media、audio、subtitles、keys、partial）→ 重新量測占用。單集刪除、失敗刪除、管理下載多選、刪除已看完、刪除失敗下載、刪除本作品全部、下載分頁左滑、觀看記錄刪除、看完自動刪除都走這裡。
- 看完自動刪除：`PlaybackSession.finished` 只有在 `PlaybackEndGate` 判定真正結束（非忽略、非 replay）時呼叫 `OfflineCompletionPolicy.ended`，manager 記錄 `watched` 並在開關開啟時設 `pendingAutoDelete`；載入其他 item、`stop`、或關閉播放器（此時才 unload）時發出 `released`，等 1 秒（mpv 在自己的 queue 關檔）後刪除。
- 為什麼不用 `isNearEnding`：它只看位置，seek 到最後幾秒再離開也會成立；本實作只接受引擎回報的 EOF 與既有正式自動下一集。
- 啟動：讀所有 record（壞的保留為「無法讀取的下載」）、刪掉沒有 record 的孤兒資料夾與自己的 staging 暫存、完成 `deleting`／`pendingAutoDelete`、`preparing` 回到 `queued`、`downloading` 比對 session 仍存在的 task 後補送缺的、`completed` 但入口檔不見時改為 `failed(.integrity)`。

## 9. 安全

- headers：沿用 `SourceSubtitleProvider.forwarded`：User-Agent、Referer 送任何 host，其餘只送同 origin。
- 帶憑證（Cookie、Authorization 等）的傳輸走前景 session，redirect 到其他 host 時移除憑證；只有不帶憑證的傳輸走 background session（E4：background 不會詢問 redirect）。代價是帶 Cookie 的來源只在 App 執行中下載，回到 App 時自動補送。
- log 只有資產 id 前 8 碼、數量、位元組、HTTP 狀態碼、失敗種類，不含 URL、header、cookie、token。
- 簽章網址與 headers 只存在未完成資產的 `download-plan.json`／`download-request.json`，完成即刪。
- DRM：FairPlay 或其他 KEYFORMAT 一律拒絕下載並標記 `avPlayerOnly`；resolver 不會把 AVPlayer-only 資產交給 MPV。不解密、不繞過授權。
- loopback server：只綁 127.0.0.1、每次啟動隨機 token、只允許 UUID 資產 id、拒絕 `..`、`/`、反斜線、絕對路徑、symlink 出資產資料夾。

## 10. UI

- 詳情頁每集：名稱下方狀態（「742 MB」「68%」「已暫停」「下載失敗」），右上角狀態圖示（↓／時鐘／進度環／⏸／⚠／✓），點圖示出現與狀態相符的選單：下載中「暫停」「取消並刪除」；暫停「繼續」「刪除」；失敗「重新下載／繼續」「刪除下載」（附失敗原因）；完成「離線播放」「下載資訊」「看完自動刪除」開關、「刪除下載」。
- 已下載的集數直接點也會離線播放；自動下一集與上一集／下一集遇到已下載的集數也走離線。
- 下載前 sheet：畫質（三種模式）、影片（例如「1080p HEVC SDR」）、音軌、字幕、預估容量、可用空間、看完後自動刪除（預設開）。
- 管理下載（詳情頁「管理下載（N）」）：多選，底部「已選 3 項 · 1.69 GB」＋刪除；選單「刪除已看完」「刪除失敗下載」「刪除本作品全部下載」。
- 「下載」分頁：頂部離線內容占用與裝置可用空間；「正在下載」「需要處理」（暫停、失敗、無法讀取）「已下載」；完成項目顯示解析度、codec、實際大小；左滑「刪除」；「…」選單。
- 刪除一律先確認（不提供假的 undo：檔案確認後立即刪除）。
- 設定頁「離線下載」：預設畫質、看完後自動刪除、允許使用行動網路下載（預設關，只用 Wi-Fi）、下載 60fps 高幀率版本（預設關）。
  - 網路：每個請求依該下載開始時的設定帶 `allowsCellularAccess`。關閉時 Wi-Fi（與有線）照常下載，只有行動網路時任務停在等待連線、不算失敗，連上 Wi-Fi 由系統自動接續；開啟時兩者都下載。
- 觀看記錄：刪除或清除含有下載的作品時，確認後一併刪除該作品所有下載。

## 11. 驗證

### 11.1 Linux（雲端 session，Swift 6.2.3）

- Ubuntu archive 的 `swiftlang 6.2.3` 解壓到 scratchpad（另取 `libxml2-16`；`lib_Testing_Foundation.so` 在該套件缺失，以空 stub 連結）。WebHTVCore 整體在 Linux 編不起來（WebKit、JavaScriptCore），scratch package 只連結 `Offline/` 與其相依檔，`os.Logger`、`PlaybackTarget`、`SniffedSubtitle`、CF 編碼與 `URLSession.bytes` 以 scratch-only shim 取代（不 commit）。Apple 平台專用檔（`OfflineMediaServer`、`URLSessionOfflineTransport`、`OfflineDownloads`）在 Linux 不編譯。
- 結果：62 個新測試全部通過；修正過程中發現並修好的真實缺陷：允許高幀率時仍選 24fps、日期以 ISO8601 存檔丟失小數秒、改用 1970 秒數時仍有浮點誤差（最後採 Foundation 預設編碼，連跑 3 次通過）、probe 對忽略 Range 的伺服器會整檔讀入記憶體（見 11.3）。
- Mutation check（Rule 9）：逐一破壞 15 條規則（尺寸上限、codec 順序、智慧位元率、SDR 優先、generation 防護、不重複下載、刪除時取消傳輸、自動刪除需先 armed、關閉播放器只在結束後 unload、驗證拒絕遠端 URI、失敗保留檔案、下載中空間檢查、重試保留 segment、啟動完成 pendingAutoDelete、只下載所選字幕），15 條都讓測試失敗。

### 11.2 需求測試對照

| 需求編號 | 測試 |
|---|---|
| 1–6 | `OfflineSelectionTests`（另含高幀率、直式、未標示解析度、純音訊 variant） |
| 7–9 | `OfflinePackageTests.onlyTheChosenRenditionsAreInThePackage`、`OfflineManagerTests.sourceSubtitlesAreKeptWithTheDownload` |
| 10、11、36 | `bothEnginesResolveTheSameAssetAndAddress`、`theSameEpisodeIsNeverDownloadedTwice` |
| 12 | `theSameEpisodeIsNeverDownloadedTwice`、`twoTapsAtOnceMakeOneDownload` |
| 13、19、20 | `aDownloadingAssetCanBeDeleted`、`aLateCallbackDoesNotReviveADeletedAsset` |
| 14 | `aPausedAssetCanBeDeleted` |
| 15、29 | `aFailedAssetWithPartialFilesCanBeDeletedAndFreesTheSpace` |
| 16 | `aCompletedAssetCanBeDeleted` |
| 17、18 | `retryKeepsFinishedSegments`、`progressiveRetryUsesResumeDataOnlyWhenThereIsSome`、`retryAfterAnExpiredAddressResolvesAgain` |
| 21、37 | `bulkDeleteTouchesOnlyWhatWasChosenAndCountsTheBytes` |
| 22、23 | `aRealEndThenTheReleaseDeletes`（AVPlayer／MPV 兩種結束）、`closingThePlayerAfterTheEndUnloadsAndDeletes` |
| 24 | `aSeekNearTheEndIsNotCompletion` |
| 25 | `errorsStopsAndEngineSwitchesAreNotCompletion` |
| 26 | `autoDeleteOffKeepsAWatchedEpisode` |
| 27 | `aPendingAutoDeleteFinishesAfterARelaunch` |
| 28 | `insufficientStorageFailsCleanly` |
| 30、31 | `packagePlaylistsHoldNoRemoteAddress`、`verifierFindsAMissingSegmentAndAcceptsAWholePackage`、`aCompletedDownloadIsMeasuredAndLocal`、`aMissingSegmentIsNeverCalledComplete` |
| 32 | `anInterruptedWriteLeavesThePreviousRecord`、`anUnreadableRecordNeverCostsItsMedia`、`aRecordFromANewerBuildIsKeptNotGuessed` |
| 33 | `launchCleansOnlyItsOwnStagingFiles`、`aFolderWithoutARecordIsAnOrphan` |
| 34 | `offlineFoldersAreExcludedFromBackup`（只在 Apple 平台執行） |
| 35 | `fairPlayIsRefusedAsDRM`、`drmIsAVPlayerOnlyAndNeverDownloadedForMPV` |
| 38 | `deleteWatchedSelectsOnlyCompletedWatchedEpisodes` |
| 39 | `aCompletedDownloadIsMeasuredAndLocal` |
| 40 | `offlineTitleInfoKeepsTheWatchHistoryIdentity`；既有 `WatchHistoryTests` 於 macOS CI 全套執行 |
| 其他 | `aRelaunchResubmitsWhatTheSessionNoLongerHas`、`aTransferFromBeforeAPauseChangesNothing`、`credentialsAreSentOnlyToTheOrigin`、`OfflineMediaServerTests`（loopback 實際 GET／Range／路徑逃逸） |

### 11.3 macOS CI（暫時驗證分支）

雲端 session 沒有 Xcode，比照 IOS-POC-45：工作區改動複製到一次性分支 `ci/ios-poc-47-verify`（另一個 git worktree，`ios-poc` 的 HEAD 不動），加一個只在該分支觸發的 workflow，在 `macos-26`（Xcode 26.6、Swift 6.3.3）上跑；驗證後刪除該分支，workflow 不進 `ios-poc`。

- Run 1 `37176748200`（commit `1d5f3a51`）：
  - `swift test --package-path ios`（macOS host）：852 個測試，6 個 issue，全部在既有的 `MediaSnifferTests`（3 個，含字幕名稱亂碼）與 `SourceClientTests.theProbeReadsOnlyTheHeadOfABodyThatNeverEnds`（6.5 s > 5 s）；**Offline 測試在 macOS 上全部通過**，含 loopback server 實際 GET／Range／路徑逃逸與 iCloud 排除。
  - Debug（device，未簽章）：**BUILD SUCCEEDED**；Release（device，未簽章）：**BUILD SUCCEEDED**。
  - 警告：本任務檔案 7 個（`try?` 結果未使用 5、多餘的 `await` 1、send closure 捕獲 `var range` 1），已在 run 2 前修正；`WebHTVApp.swift` 其餘警告是既有的 `UIDevice.current`／`consider using asynchronous alternative`。
  - iOS Simulator（WebHTVCore）：失敗的都是既有 WKWebView／本機 socket 測試（`MediaSnifferTests`、`SnifferRulesTests`、`AdBlockListTests`、`SourceClientTests`），沒有 Offline 測試失敗；是否 base 也失敗見 run 2。
- Run 2 `37177718543`（commit `086fb6e6`，`ios/` 與本任務 commit 逐檔相同）：
  - macOS host：853 個測試，失敗只有既有的 `MediaSnifferTests` 3 個（`capturesADeclaredTrackWithItsMetadata`、`aLaterTrackDeclarationUpgradesMetadataForTheSameURL`、`capturesASubtitleRequestedJustAfterTheMediaURL`）；**base `f2f7fac4` 以同一個 filter 執行，失敗的是同樣 3 個**，不是本任務造成，未修改。Offline 測試全部通過。
  - Debug（device）：**BUILD SUCCEEDED**；Release（device）：**BUILD SUCCEEDED**。
  - 警告：本任務檔案 0 個；`WebHTVApp.swift` 剩下的 7 個都在既有程式（`UIDevice.current`、`evaluateJavaScript`，`f92da1ca`）。
  - iOS Simulator（同一台，base 先跑）：base 與本次失敗的是**同一組 13 個既有測試**（`MediaSnifferTests` 10、`AdBlockListTests` 1、`SnifferRulesTests` 1、`SourceClientTests` 1，都是 CI 模擬器上的 WKWebView／本機 socket）；`OfflineManagerTests`、`OfflineMediaServerTests`、`OfflinePackageTests`、`OfflineSelectionTests`、`OfflineStoreTests` 在模擬器全部通過。
- 暫時分支 `ci/ios-poc-47-verify` 於驗證後刪除。
- run 1 之後、run 2 之前的改動：probe 對忽略 Range 的伺服器只讀 64 KB（原本 `data(for:)` 會把整個檔案讀進記憶體，屬第 4 個真實缺陷，新增 `theProbeNeverReadsAWholeFileIntoMemory`）；移除沒有呼叫者的 `setAllowsCellular`。

## 12. 限制與待真機驗證

1. **真機未驗證**：背景下載（鎖屏、離開 App、iOS 終止後重開接回）、飛航模式下 AVPlayer／MPV 播放本機 package、loopback server 在 App 被暫停後恢復、行動網路開關、可用空間顯示。
2. FairPlay 離線授權未實作：來源沒有授權伺服器，DRM 影片一律拒絕下載（標示 AVPlayer-only 語意與 resolver 規則已就緒）。
3. 本機檔名改為依內容命名後，智慧去廣的「檔名」判斷在離線 package 上可能較弱；以 DISCONTINUITY 判斷的部分不受影響。
4. 帶 Cookie／Authorization 的來源只在 App 執行時下載（安全取捨，第 9 節）。
5. 從詳情頁下載時，播放器未開啟，無法得知「目前播放使用中的音軌」，預設使用來源 DEFAULT rendition（可在 sheet 改）。
6. H.264 → HEVC 重新編碼（Phase 2）未實作。
7. 行動網路設定原本只在加入下載時記錄，之後切換不會套用到已加入的項目（原文寫「暫停再繼續就會套用」是錯的，`resume()` 不會更新）。IOS-POC-49 已改為即時套用到所有未完成的下載，見 `docs/IOS-POC-49-offline-cellular-download-all.md`。連到手機分享的 Wi-Fi 熱點時 iOS 視為 Wi-Fi，關閉行動網路也會下載（實際用的是分享端的行動數據）；「低數據模式」的 Wi-Fi 沒有另外限制。
8. 重開 App 時，若某個 segment 已由系統下載完、事件還在佇列中尚未搬入資產資料夾，接回流程可能再送一次同一個 segment；結果是重複下載（覆寫同一路徑），不影響正確性。
9. background session 的大量 segment task：Apple 建議較少、較大的傳輸（E4）；一集約 300–1000 個 segment，在前景一次送出，實際背景表現需真機觀察。

## 13. Rollback

- 程式：revert 本任務的 commit 即可；`Offline/` 是新目錄，App 端改動只在 `PlaybackSession`（offline 相關分支）、`VodView`、`HistoryView`、設定頁與分頁。
- 資料：舊版 App 不讀 `Application Support/OfflineMedia/`，資料夾會留在裝置上（排除備份）；需要時刪除 App 或在新版「下載」分頁刪除。不影響 `WatchHistory`。

## 14. Ponytail

`Ponytail: unavailable / skipped`——本 runtime 沒有提供 Ponytail（可用 skills 清單中沒有 `ponytail:*`）。

## 15. 審查結果與處置（IOS-POC-52）

- 來源：2026-10-04 對本任務做多面向審查（workflow `wmgturmc6`），42 項經三方驗證，確認 40 項。
- 使用者 2026-10-05 指示「修那40項問題」，以 IOS-POC-52 分 6 批處理；每項的原因、修法與測試細節見 `docs/IOS-POC-52-offline-review-fixes.md` 第 2 節。
- 驗證都在 Linux 雲端 session（Swift 6.2.3）執行 `swift test`；每批另做突變測試，確認新測試能抓到對應的退化。App 端（`WebHTVApp.swift`）在 Linux 無法編譯，只靠發布建置編譯，沒有在真機執行。

### 15.1 批次與 commit

| 批次 | commit | 項目 | Linux 測試 | 突變 |
|---|---|---|---|---|
| 1 | `44d9ee59` | F2、F15 | 84／84 | 未做 |
| 2 | `445ee765` | F5–F9、F16、F17、F20、F26、F27、F28 | 97／97 | 9／9 |
| 3 | `73eb8149` | F3、F4、F10、F11、F14、F18、F19、F29、F30、F34、F39 | 111／111 | 14／14 |
| 4 | `183334aa` | F1、F12、F13、F23 | 122／122（含 IOS-POC-53 的 5 項） | 5／5 |
| 5 | `743a1d42` | F21、F22、F31、F32、F33、F35 | 126／126 | 5／5 |
| 6 | `8b5ba5e4` | F24、F25、F36、F37、F38、F40 | 131／131 | 13／13 |

### 15.2 40 項清單

處置欄：「修」為已修正；「部分」為只修一部分，其餘寫明原因；「不修」寫明原因。驗證欄列出測試名稱，或說明為何沒有單元測試。

| 項目 | 嚴重度 | 問題 | 處置 | commit | 驗證 |
|---|---|---|---|---|---|
| F1 | 中 | 拖到片尾被當成看完，進而自動刪除 | 修：觀眾拖到片尾 3 秒內之後的檔尾不算看完；片尾自動下一集仍算 | `183334aa` | `aSeekToTheEndIsNotAWatch`、`theFormalAutoNextCountsEvenAfterASeekIntoTheCredits` |
| F2 | 中 | 磁碟滿、紀錄寫不進去時卡在下載中，佇列停止 | 修：先改記憶體再寫檔，寫入失敗的紀錄之後補寫 | `44d9ee59` | `aRecordTheDiskRefusesStillChangesStateAndIsWrittenLater` |
| F3 | 中 | 送出途中暫停、刪除或失敗，之後建立的傳輸沒人取消 | 修：送出後再檢查 generation，不符就取消剛送出的；啟動時取消過時的傳輸 | `73eb8149` | `aPauseDuringASubmitStopsWhatTheSubmitCreatedAfterIt`、`launchCancelsStaleTransfersOnly` |
| F4 | 中 | 強制關閉後重開，剩下的每個片段下載兩次 | 修：目前 generation 的 `.cancelled` 不重試；已在傳輸中的片段不重送 | `73eb8149` | `aCancelledCurrentTransferIsNotRetried`、`aFailureForAUnitAlreadyInFlightIsNotRetried` |
| F5 | 中 | 先刪計畫才寫完成紀錄，中間被終止就無法復原 | 修：先寫完成紀錄，再清理 | `445ee765` | 無單元測試：「在兩步之間被終止」無法在測試中重現，以閱讀程式碼確認；F6 的測試涵蓋復原路徑 |
| F6 | 中 | 檔案遺失的已完成項目無法重新下載 | 修：沒有 request 時從該集重新解析；移除不會執行的分支 | `445ee765` | `aCompletedDownloadWithMissingFilesCanBeDownloadedAgain` |
| F7 | 中 | 金鑰伺服器的錯誤頁被當成 AES-128 金鑰並標為完成 | 修：金鑰不是 16 bytes 就失敗；驗證器也檢查 | `445ee765` | `aKeyThatIsNotSixteenBytesFailsTheDownload`、`theVerifierRefusesAKeyOfTheWrongSize` |
| F8 | 中 | 重寫播放清單時 KEY 移到 MAP 之前，未加密的 init 被當成加密 | 修：MAP 依它宣告時的 KEY 輸出 | `445ee765` | `aMapDeclaredBeforeTheKeyStaysClear` 等 3 項 |
| F9 | 中 | 重新解析後重試，保留不同編碼的舊檔 | 修：比對每段秒數與遠端檔名，不同就重新下載 | `445ee765` | `aReResolveWithOtherDurationsStartsTheFilesOver` |
| F10 | 中 | 需要憑證的傳輸全部排進預設 session，排隊中逾時就讓整集失敗 | 修：一次最多 6 個；連線類錯誤另有 10 次額度；回到前景重送 | `73eb8149` | `credentialedUnitsAreSentThroughAWindow`、`connectivityFailuresHaveTheirOwnBudget` |
| F11 | 中 | 背景 session 的完成通知太早，App 可能在處理途中被暫停 | 部分：等事件處理完（含最多 20 秒的準備）才通知系統。未做：另外向 UIApplication 申請背景執行時間（App 端，雲端無法編譯驗證） | `73eb8149` | `aStagedBodyIsTakenUpAtLaunch`、`theTransportWaitsForPreparingToSettle` |
| F12 | 中 | App 暫停後本機伺服器沒有重開，暫停中的離線 HLS 無法繼續 | 部分：恢復播放前重開伺服器（優先原連接埠）；離片長還有 5 秒以上的檔尾不算看完。未做：連接埠被占用而換埠時重建播放項目（風險較高） | `183334aa` | `anEndOfFileShortOfTheDurationIsNotAWatch`；伺服器重開需真機驗證 |
| F13 | 中 | 關閉「看完後自動刪除」不影響既有下載 | 修：設定關閉時取消所有排定的自動刪除，重開時亦同 | `183334aa` | `theSettingTurnedOffStopsEveryAutoDelete`、`aCrashArmedAutoDeleteWaitsForTheSettingAtLaunch` |
| F14 | 中 | 單一檔案下載途中不檢查空間 | 修：進度回報時檢查剩餘空間 | `73eb8149` | `aSingleFileStopsWhenTheRestNoLongerFits` |
| F15 | 中 | 播放清單數字異常造成閃退，且每次啟動重複閃退 | 修：數字只接受有限、非負、在上限內；必要欄位不合法就拒絕整份清單 | `44d9ee59` | `brokenNumbersFailThePlaylistInsteadOfTrapping` 等 3 項 |
| F16 | 中 | 讀不到計畫、或重試選到不同版本時混入舊檔 | 修：讀不到計畫就丟棄它描述的檔案；版本不同就重新下載 | `445ee765` | `anUnreadablePlanDiscardsTheFilesItDescribed` |
| F17 | 中（安全） | 重新解析後沿用舊續傳資料，舊網址與 Cookie 被再次送出 | 修：重新解析或來源改變時丟棄續傳資料 | `445ee765` | `aReResolvedSingleFileDoesNotResumeTheOldRequest` |
| F18 | 中 | 刪除暫停或失敗的單一檔案下載不釋放空間 | 修：刪除時放棄續傳資料與它指向的系統暫存檔 | `73eb8149` | `deletingGivesUpResumeDataAndSegmentsMakeNone`；系統是否真的刪檔需真機確認 |
| F19 | 中 | 失效的續傳資料一直被重送 | 修：失敗且沒有新續傳資料時刪除舊的 | `73eb8149` | `resumeDataThatFailedIsNotSentAgain` |
| F20 | 中 | 重試時抓不到外掛字幕就把它從下載中拿掉 | 修：已存的字幕保留，不重抓 | `445ee765` | `aSavedSubtitleSurvivesARetryThatCannotFetchItAgain` |
| F21 | 低 | 選「最省空間」但沒有 720p 以下版本時默默下載 1080p，卻記成最省空間 | 修（依使用者決定照常下載 1080p）：表單告知改以「智慧 1080p」下載，紀錄寫實際採用的模式 | `743a1d42` | `downloadAllInSaverModeWithoutA720pVersionRecordsTheModeItUsed`；表單無單元測試 |
| F22 | 低（安全） | 離線外掛字幕轉址時，Cookie／Authorization 被送往其他主機 | 修：字幕改用會在跨 origin 轉址時移除憑證的 session | `743a1d42` | `offlineSubtitleRedirectsKeepTheSourceCredentialsOnItsOrigin`；App 接線只在 Darwin 編譯 |
| F23 | 低 | 「真正結束才算看完」的測試不會失敗 | 修：判斷移到 Core 的 `OfflineCompletionPolicy` 並測它 | `183334aa` | `onlyTheEngineEndAndTheViewersEndingAreEnds` |
| F24 | 低 | SDR 優先、24／30 fps 優先的選片測試因錯誤理由通過 | 修：改用被偏好版本較貴、編碼排序較後的組合，三種模式都檢查 | `8b5ba5e4` | 突變（拿掉 SDR 規則、幀率規則只在要求時生效）會失敗 |
| F25 | 低 | 當機復原與安全網沒有能失敗的測試 | 修：補 3 項測試 | `8b5ba5e4` | `launchFinishesADeleteACrashInterrupted` 等 3 項；3 個突變會失敗 |
| F26 | 低 | 暫停後，過時的解析失敗蓋掉新的狀態 | 修：解析回來後檢查 generation | `445ee765` | `aLateResolverFailureDoesNotOverrideAPause` |
| F27 | 低 | 只有第一份播放清單接受 BOM | 修：所有播放清單都接受 | `445ee765` | `everyPlaylistMayStartWithAByteOrderMark` |
| F28 | 低 | 智慧與高畫質模式選到只有 AV1／VP9 的 1080p，AVPlayer 無法播放 | 修：有其他編碼時不選 AV1／VP9 | `445ee765` | `av1AndVP9AreChosenOnlyWhenNothingElseFits` |
| F29 | 低 | 取消只取消當下的任務快照，送出途中的刪除或暫停留下傳輸 | 修：傳輸層以取消計數保護送出 | `73eb8149` | 無 Linux 單元測試：`URLSessionOfflineTransport` 只在 Darwin 編譯；manager 端由 F3 的測試涵蓋 |
| F30 | 低 | 「離線內容」總量在下載中或失敗後不更新 | 修：即時計算 | `73eb8149` | `usageCountsWhatUnfinishedDownloadsHold` |
| F31 | 低 | 下載中的項目換區時，刪除確認視窗被關掉 | 修：確認視窗改由列表持有 | `743a1d42` | 純 SwiftUI，無單元測試；需真機驗證 |
| F32 | 低 | App 在背景被喚醒、設定尚未載入時，需要重新解析的下載失敗 | 修：設定載入前留在排隊中；移除 IOS-POC-49 的 30 秒等待 | `743a1d42` | `aDownloadThatMustResolveWaitsQueuedUntilTheConfigurationIsLoaded` |
| F33 | 低 | 每集的下載選單點擊範圍只有 26×26 pt | 不修：`c361c637`（IOS-UI-A）已改為與集數按鈕並排的獨立 44×44 pt 元件 | — | 閱讀目前程式碼確認 |
| F34 | 低 | 啟動時沒有清掉 `playlists/`、`partial/` 裡的寫入暫存檔 | 修 | `73eb8149` | `launchRemovesInterruptedWritesInSubfolders` |
| F35 | 低 | 單一檔案與沒有 master 的播放清單不受 1080p 上限，表單文字不正確 | 部分：表單改為說明「只有一種版本、無法確認解析度、可能超過 1080p」。未做：探測實際解析度並拒絕超過 1080p、在紀錄中保存解析度與編碼（需要媒體探測，屬新功能） | `743a1d42` | `aLoneUndeclaredVersionIsToldApartFromAPickedOne` |
| F36 | 低 | probe 不會整個讀進記憶體的測試不會失敗 | 修：測試檢查 Range 與讀取上限 | `8b5ba5e4` | 2 個突變會失敗；`OfflineHTTP.fetcher` 的串流截斷只在 Darwin，未測 |
| F37 | 低 | 等待用的輔助函式逾時不會失敗，取值不足時讓整個測試程序崩潰 | 修：逾時在呼叫位置失敗；`startSimpleDownload` 改為 throws | `8b5ba5e4` | 突變（resume 不重新排程）會失敗 |
| F38 | 低 | 行動網路預設值與傳遞、刪除記錄的範圍沒有測試 | 修：補 2 項測試 | `8b5ba5e4` | `cellularIsOffUntilAllowedAndReachesEveryTransfer`、`aTitlesDownloadsIncludeEveryStateButDeleting`；3 個突變會失敗 |
| F39 | 低 | 準備中刪除時，外掛字幕把資料夾建回來 | 修：字幕完成時若紀錄已不在，刪掉重建的資料夾 | `73eb8149` | `deletingWhilePreparingLeavesNoFolder` |
| F40 | 低 | 離線觀看記錄的測試只測到測試資料本身 | 修：識別與記錄改由 Core helper 建立，App 改用 helper | `8b5ba5e4` | `offlineTitleInfoKeepsTheWatchHistoryIdentity`；2 個突變會失敗 |

### 15.3 仍未驗證或未做

1. 真機：背景下載與喚醒（F10、F11、F32）、伺服器重開（F12）、刪除後空間是否釋放（F18）、刪除確認視窗（F31）、表單文字（F21、F35）。
2. 未做：F11 申請背景執行時間；F12 換埠時重建播放項目；F35 探測解析度與保存編碼資訊。
3. 第 12 節第 8 項「重開後同一 segment 可能再送一次」已由 F4 處理。

## 目前狀態

- 2026-10-04：實作與驗證完成（第 11 節），commit `4b7a00b6`；隨 `0.1.57 (58)` 發布（IOS-POC-11 第五十八次發布，tag `ios-v0.1.57-b58` → `f8dcc555`）。
- 2026-10-05：審查確認的 40 項全部處理完畢（第 15 節）：修 36 項、部分 3 項（F11、F12、F35）、不修 1 項（F33，已由 IOS-UI-A 解決）。commit `44d9ee59`、`445ee765`、`73eb8149`、`183334aa`、`743a1d42`、`8b5ba5e4`。
- 下一步：使用者在真機驗證第 12 節第 1 項與第 15.3 節第 1 項。
