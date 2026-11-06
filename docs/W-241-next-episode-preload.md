# W-241 — 看當集時預載入下一集（評估，不實作）

- 狀態：**評估完成，待 Reviewer 審查；未實作、未改任何程式或設定**。
- 需求來源：使用者 2026-11-06（Manager #6151、#6152 派工）。希望切到下一集時（自動連播或按「下一集」）幾乎立刻開播。
- 範圍：以 iOS App 為主。Android（FongMi）只盤點現況。
- 基線：`origin/ios-poc` `ddeedd7c`（0.1.92 (93)）；分支 `task/W-241`。
- 證據等級：**本文所有時間數字都來自 Simulator 的 App log，沒有一筆是真機量測**。

## 〇、一句話結論

iOS **已經做了「預先解析下一集網址」**（IOS-POC-15C/15D，片尾前 90 秒），所以換集時花在解析的時間已經接近 0。
剩下的時間是「拿到網址之後到開始播放」：Simulator 中位數，原生播放器約 1.0 秒、MPV 約 1.5 秒。
**建議：先做「第 0 步：把起播時間拆開量」（只加 log），再依真機數據決定要不要做方案 C′。**
C′ 是在現有預解析成功後，替原生播放器預先建立下一集的 `AVURLAsset` 並載入屬性。
依 Apple WWDC16 503，這樣只會先抓 **master 播放清單**，variant 播放清單和影片片段仍要等開播後才抓。所以 C′ 最多省一次往返，估 0.1～0.3 秒，風險低、收益也小。
能把約 1 秒起播整個省掉的只有方案 D（完整預建播放器）。但 D 要改「一個 AVPlayer＋一個 MPV」的架構，回歸面大；成熟播放器（Kodi、Plex、Infuse）也都沒有預先開啟下一集的串流。所以 D 不建議，理由見第五節。

## 一、現況：iOS 換集流程與耗時

### 1.1 流程與程式位置

| 步驟 | 位置 | 說明 |
|---|---|---|
| 觸發預解析 | `ios/WebHTVApp/Sources/WebHTVApp.swift:6210` `prefetchNextIfDue()` | sampler 每 5 秒一次；條件由 `PlaybackPrefetchGate.shouldPrefetch` 決定 |
| 閘門 | `ios/Sources/WebHTVCore/PlaybackNetworkPolicy.swift:410` `PlaybackPrefetchGate` | 已播 ≥ 20 秒、網路狀態 ≥ `.normal`、距交棒點 ≤ 90 秒（交棒點＝片長 − 使用者設的片尾）、片長是有限正數、每集只問一次 |
| 預解析 | `WebHTVApp.swift:3302` `prefetchNextEpisode(flag:)` | 和正常播放走同一個出口 `SourceClient.playbackURL(for:flag:)`：`playerContent`、CSP／Python／drpy、probe、sniff、headers 全部沿用。已下載的下一集跳過；YouTube 不預解析（W-212） |
| 暫存 | `ios/Sources/WebHTVCore/NextPlaybackTarget.swift` `PlaybackTargetPrefetch` | 最多存一集；身分 6 欄位（設定、站 `Site.id`、vodId、線路、集的位址、畫質）全部要吻合；最多存 5 分鐘（`maximumAge`） |
| 交棒 | `WebHTVApp.swift:6533` `finished(reason:)` → `advance` → `WebHTVApp.swift:3373` `start(_:flag:usingPrefetch:)` | 先等進行中的預解析完成（避免兩個 sniff 互相取消）；`take` 命中就用，沒命中照原路解析；預解析的位址開播前失敗會重新解析一次（`retry`） |
| 手動下一集 | `WebHTVApp.swift:3340` `step(forward:)` | 控制列「下一集」也會用預解析結果；「上一集」不會 |
| 失效 | `play()`（手動選集／換線路）、`selectQuality`（換畫質）、關閉播放器、身分不符、逾時 | 見 IOS-POC-15 第五節失效規則 |
| 開播（原生） | `WebHTVApp.swift:6891` `loadNative` | `AVURLAsset`（帶 headers）→ `AVPlayerItem` → `replaceCurrentItem`；`preferredForwardBufferDuration` 在片長可讀之後才由 sampler 設定（IOS-POC-15A） |
| 開播（MPV） | `ios/WebHTVApp/Sources/MPVEngine.swift:601` | `loadfile <url> replace`（部分情況帶 `cache-secs=10,demuxer-readahead-secs=10`） |
| 去廣告計畫 | `WebHTVApp.swift:6679` `watchAds` | 開播**之後**才讀播放清單兩次、算出廣告區段，不擋起播 |
| 起播量測 | `WebHTVApp.swift:6810` | `[playback] started <集> on <engine> in <n>ms after open; resolve <n>ms (<方式>)` |

### 1.2 現有實測數據（Simulator，從 artifacts 的 App log 擷取）

擷取方式：掃描 `.herdr-synapse/webhtv-dev/artifacts/` 與 `docs/` 中所有 `started … after open; resolve …` 行並去除重複，共 175 筆。
來源是先前各工單的 Simulator GUI 測試（W-72、W-74、W-77、W-83、W-86、W-103、W-105、W-202、W-210、W-233 等）。腳本放在 scratchpad，只讀不寫。

| 引擎 | 解析方式 | 筆數 | 起播（open 之後）中位數 | P10 | P90 | 解析中位數 | 解析 P90 |
|---|---|---|---|---|---|---|---|
| 原生 AVPlayer | 現場解析 | 133 | 1985 ms | 732 ms | 4517 ms | 384 ms | 2808 ms |
| 原生 AVPlayer | **預解析命中** | 9 | **966 ms** | 338 ms | 1736 ms | 0 ms | 19 ms |
| MPV | 現場解析 | 28 | 2411 ms | 1192 ms | 13493 ms | 94 ms | 2691 ms |
| MPV | **預解析命中** | 5 | **1542 ms** | 1422 ms | 14702 ms | 2 ms | 4 ms |

另有 51 筆 `prefetched <集> in <n>ms`（背景預解析本身的耗時）：中位數 119 ms，P90 1968 ms。

讀法與限制：
- 換集總耗時 ≈ 解析 ＋ 起播。預解析命中後，解析已接近 0，**剩下的全是起播**。
- 命中組與現場組**不是同一批來源**，不能直接相減當成「預解析省了多少」。可以確定的是：命中後仍有約 1 秒（原生）到 1.5 秒（MPV）的起播。
- MPV 命中組的 P90 是一筆 14.7 秒的極端值（W-83），樣本太少，只看中位數。
- 全部來自 Simulator 和開發機網路，**真機數字未知**。IOS-POC-15 第八節的真機量測至今仍欠著。

### 1.3 已知缺口（和本需求有關）

- 起播時間沒有再細分：無法從現有 log 分出「抓播放清單」「抓第一段」「解碼出第一格」各花多久。這是建議的第 0 步。
- 手動在選集清單跳到任意一集（不是下一集）不會預解析，這是設計上的取捨（猜不到使用者會點哪一集）。
- 預解析命中率在真機上是 0 次實測。

## 二、Android（FongMi）現況盤點

- 換集：`app/src/leanback/java/com/fongmi/android/tv/ui/activity/VideoActivity.java:3087` `onNext` → `onItemClick`，每次都完整呼叫 `playerContent` 再開播。**沒有下一集預解析或預載。**
- 名字裡有 preload 的是另一件事：
  - `app/src/main/java/com/fongmi/android/tv/player/PreloadPausePolicy.java`：暫停時是否繼續預讀**目前這一集**的緩衝（可設成只在 Wi-Fi）。
  - `app/src/main/java/com/fongmi/android/tv/player/mpv/MpvPreloadController.java`：MPV 對**目前這一集**的代理預讀（遲滯控制）。
- 程式碼裡沒有用到 mpv 的 `prefetch-playlist`。
- 結論：Android 目前沒有同類功能。本工單不評估 Android 實作。

## 三、可以預載到哪一層

| 層次 | 做什麼 | 省掉什麼 | iOS 現況 |
|---|---|---|---|
| L1 預解析網址 | 先跑 `playerContent`／sniff，拿到網址＋headers | 解析時間（現場中位數 384 ms，P90 約 2.8 秒） | **已做**（15C/15D） |
| L2 預熱連線／CDN | 用 `URLSession` 先抓播放清單和第一段 | 只有 DNS 快取和 CDN 邊緣快取變熱。AVPlayer 應該不會用到 App 的 `URLSession` 連線池和快取（**推論，沒有官方來源**，見第五節） | 沒做 |
| L3 預載 asset | 建立下一集的 `AVURLAsset`，先載入 `duration` 等屬性，換集時用這個 asset 建 item | **只有 master 播放清單一次往返**；variant 播放清單和片段仍要開播後才抓（WWDC16 503） | 沒做（15C 明寫「等量到解析不再是主因才評估」，現在 Simulator 數據已經顯示是如此） |
| L4 預建播放器 | `AVQueuePlayer` 排入下一個 item，或第二個 `AVPlayer` 先 preroll；MPV 用 `loadfile append`＋`prefetch-playlist` | 幾乎全部起播時間 | 沒做 |

## 四、觸發時機與取消條件

**沿用現有閘門，不另立一套**：已播 ≥ 20 秒、距交棒點 ≤ 90 秒、網路 ≥ `.normal`、片長是有限正數、每集一次。
L3 只在 L1 成功存入之後才開始，同樣由 sampler 觸發。

取消（全部沿用 `prefetch.invalidate()` 的呼叫點，L3 多做一件事：`asset.cancelLoading()`）：

| 事件 | 處理 |
|---|---|
| 手動選集、換線路 | `play()` → invalidate |
| 換畫質 | `selectQuality` → invalidate，並允許重新預解析 |
| 往回拖到交棒窗口之外 | 不取消，留著（5 分鐘上限會擋）；拖過片尾直接交棒 |
| 關閉播放器 | `onDismiss` → invalidate |
| 暫停很久、PiP、鎖螢幕 | 5 分鐘 `maximumAge` 擋 |
| 換到 MPV 播放 | L3 只對原生有效；交棒時目標若要走 MPV，就丟掉 asset、只用 L1 的網址 |

## 五、方案比較

外部來源（官方文件、成熟播放器）見第六節。

| | A 不做 | B 只預解析（＝現況） | C 預解析＋預熱首段（`URLSession`） | **C′ 預解析＋預載 asset（建議）** | D 完整預建播放器 |
|---|---|---|---|---|---|
| 做什麼 | 什麼都不加 | 15C/15D 照舊 | 額外用 `URLSession` 抓 m3u8 和第一段 | 額外建立 `AVURLAsset` 並載入屬性，交棒時重用 | `AVQueuePlayer`／第二個 player／MPV `prefetch-playlist` |
| 預估省多少 | 0 | 已省下解析時間 | 很少（**推論**，見下）：AVPlayer 應該不共用 App 的連線池和快取，只剩 DNS／CDN 邊緣快取 | master 播放清單一次往返，估 0.1～0.3 秒／集（原生 HLS；MP4 幾乎沒有）；**未量測** | 起播接近 0（原生約 1 秒、MPV 約 1.5 秒全省） |
| 額外流量 | 0 | 每集一次解析請求 | 每集多 1～4 MB（第一段），沒看下一集就浪費 | 每集多幾 KB～幾十 KB（播放清單） | 多抓好幾段（數 MB～數十 MB） |
| 記憶體 | 0 | 可忽略 | 小 | 小（一個 asset 和播放清單） | 大：兩份緩衝同時存在 |
| 爬蟲請求 | 0 | 不變 | 對 CDN 多 1～2 次；**本機代理網址會多呼叫一次 Python `localProxy`** | 本機代理網址同樣會多一次；可直接排除本機代理網址 | 本機代理會被當成正式播放一樣地讀 |
| 和現有架構 | — | — | 獨立 | 只改 `loadNative` 收 asset 的入口＋暫存一個 asset；仍然是一個 `AVPlayer` | 要改單一 `AVPlayer` 架構、片頭片尾跳過、去廣告、字幕時鐘、`retry`、`PlaybackEndGate`；MPV 另做一套 |
| MPV | — | 已適用 | 同 C 的限制 | **不適用**（MPV 照 B） | `prefetch-playlist` 對 HLS 無效，而且要等目前這集讀完才開始；iOS MPV 目前用 `loadfile … replace` |
| 網址過期 | — | 90 秒窗口＋5 分鐘上限 | 同 B | 同 B；asset 失敗走既有 `retry`（重新解析一次） | 預建越早，過期風險越高 |
| 實作量（Claude） | 0 | 0 | 約 2 小時，但收益不明 | 約 3～4 小時（含 Simulator 驗證） | 數天，回歸面大 |
| 回退 | — | — | revert 一個 commit | revert 一個 commit | 難 |

不選 D 的主要原因：
1. 本 App 在 IOS-POC-15／17 明確定為「一個 `AVPlayer`＋一個 MPV」，D 要改這個前提，連帶影響片尾交棒（`PlaybackEndGate`）、片頭跳過的起始位置、去廣告跳轉、字幕時鐘和預解析失敗的 `retry`，回歸面太大。
2. 使用者設了片尾時，交棒點在片子真正結束之前，`AVQueuePlayer` 的自動接續用不上，仍要手動 `advanceToNextItem`。
3. 兩份緩衝同時存在，記憶體和流量都翻倍。W-240 的 Reviewer 已經提醒過整檔回應的記憶體風險。
4. MPV 那半要另做，而 mpv 的 `prefetch-playlist` 手冊明寫對 HLS（.m3u8）無效，只在目前這集已經完整讀完時才開下一集的網址。
5. 成熟播放器沒有人這樣做：Kodi 核心的影片播放器沒有實作 `QueueNextFile`（只有音樂播放器有）；Up Next 外掛只跳提示並把下一集排進清單，網址到切換時才解析；Plex、Infuse 找不到預先開啟下一集的官方說明。和本 App 最接近的是 ExoPlayer 的播放清單，它也要等目前這集**整個緩衝完**才開始載下一集。

不選 C 的原因：預熱的連線和快取 AVPlayer 很可能用不到，只剩 CDN 邊緣快取的效果，收益不確定，卻要付出第一段的流量。
「AVPlayer 不共用 App 的 `URLSession` 連線池和快取」是**推論**，第六節沒有官方來源：`AVURLAsset` 的 API 只接受 headers 和 cookie 這類選項，沒有讓 App 傳入 `URLSession` 的入口。要證實，只能在第 0 步用 Charles 或 log 觀察 C 的預熱請求和 AVPlayer 的請求是不是同一條連線。

## 六、外部研究來源

存取日期都是 2026-11-06。等級：A＝官方文件或原始碼；B＝官方內容的第三方轉錄，或維護者的 issue／PR；C＝使用者論壇。

| # | 來源 | 等級 | 內容 | 對本案的影響 |
|---|---|---|---|---|
| 1 | Apple `AVQueuePlayer` 文件 https://developer.apple.com/documentation/avfoundation/avqueueplayer | A | 只說「播放一串 player item」，沒寫何時預載 | 沒有官方的預載時間點，不能依賴 |
| 2 | WWDC16 503《Advances in AVFoundation Playback》逐字稿 https://nonstrict.eu/wwdcindex/wwdc2016/503/ | B（Apple 原頁已下架；轉錄可能有誤） | 只要夠早知道 item B，AVFoundation 就能在 A 播完前先 preroll 和解碼，工具是 `AVQueuePlayer`；播放佇列是給「近期要播的東西」做最佳化，不是播放清單 | 方案 D 的原生依據；沒有給提前量 |
| 3 | 同上 | B | 「AVURLAsset 是 lazy API」，要求 duration 之類的值才會下載 master 播放清單；「variant 播放清單和片段仍要等按下播放後才載入」；「item 成為目前 item 之前不會建立播放管線」 | **C′ 只省 master 播放清單一次往返**；先建 `AVPlayerItem` 但不放進 player 沒有額外好處 |
| 4 | `AVPlayerItem.status` 文件 https://developer.apple.com/documentation/avfoundation/avplayeritem/status-swift.property | A | item 一交給 `AVPlayer` 就立刻開始排入媒體、準備播放 | 預建 item 就等於開始抓片段，流量和記憶體跟著來 |
| 5 | `preferredForwardBufferDuration` 文件 https://developer.apple.com/documentation/avfoundation/avplayeritem/preferredforwardbufferduration | A | 0 代表由播放器自行決定；值大會增加系統資源需求 | 和預載無直接關係；IOS-POC-15A 的設定方式不變 |
| 6 | `automaticallyWaitsToMinimizeStalling` 文件 https://developer.apple.com/documentation/avfoundation/avplayer/automaticallywaitstominimizestalling | A | iOS 10 以後預設 true | 不變 |
| 7 | `canInsert(_:after:)`、`replaceCurrentItem(with:)` 文件 https://developer.apple.com/documentation/avfoundation/avqueueplayer/caninsert(_:after:) 、https://developer.apple.com/documentation/avfoundation/avplayer/replacecurrentitem(with:) | A | 同一個 item 不能排在佇列裡兩個位置；HLS item 被移除後就停止抓播放清單和片段 | 換集、取消時丟掉預建的 item 就會停止流量 |
| 8 | Apple 關於網址有效期 | — | **找不到**任何談 asset 或 item 能放多久、簽名網址過期的官方說明 | 維持現有的 90 秒窗口＋5 分鐘上限 |
| 9 | mpv 手冊 `--prefetch-playlist`、`--gapless-audio` https://mpv.io/manual/stable/ | A | 「目前這個網址完整讀完後，只是先開下一個播放清單項目的網址」；對 youtube-dl 解析的網址無效；**對 HLS（.m3u8）無效**；不會預測使用者往回跳。`gapless-audio` 只讓音訊裝置保持開啟，不是影片預載 | MPV 不適合做 L4 |
| 10 | mpv 原始碼 `player/loadfile.c`、`DOCS/man/input.rst`（commit `902818753849d9ad8f0096fad6ca5aeaa37113b9`）https://github.com/mpv-player/mpv | A | 目前 demuxer 讀到 EOF 才呼叫 `prefetch_next()`；網址或 demuxer 選項不符就丟棄；`loadfile append` 只是改播放清單 | 同上 |
| 11 | Kodi 原始碼 `xbmc/cores/IPlayer.h`、`paplayer/PAPlayer.h`（commit `41d9b79de57473b2a2645f47cb08866ebdaeca1d`）https://github.com/xbmc/xbmc | A | `QueueNextFile` 預設回 false，只有音樂播放器實作；影片播放器沒有 | 成熟播放器不預開下一集影片 |
| 12 | Kodi Up Next 外掛（commit `70fb3590bc6ebb95f6ca6428b230794a567a6582`）https://github.com/im85288/service.upnext | A | 片尾前 30 秒跳出下一集提示，把下一集排進清單；網址等切換時才解析 | 業界常見做法是「提示＋排隊」，不是預開串流 |
| 13 | Infuse 論壇 https://community.firecore.com/t/speed-up-next-video-with-preloading/14336 、/57195 | C | 只有使用者許願「片尾前 2 分鐘預載」，官方沒有回覆 | 沒有可靠的同類實作 |
| 14 | Plex 論壇 https://forums.plex.tv/t/autoplay-next-episode-netflix-style/92049 、Swiftfin PR #88 https://github.com/jellyfin/Swiftfin/pull/88 | C（只看了搜尋摘要） | 播完後倒數接下一集；Swiftfin 只有「下一集」預覽 | 同上 |
| 15 | Media3 播放清單與 PreloadManager 文件 https://developer.android.com/media/media3/exoplayer/playlists 、https://developer.android.com/media/media3/exoplayer/preloading-media/preloadmanager | A | 播放清單切換是無縫的；`DefaultPreloadManager` 依離目前項目的遠近排優先；官方提醒預載太積極會浪費電和頻寬 | Android 若將來要做，有現成機制可參考 |
| 16 | Media3 原始碼 `MediaPeriodQueue.java`、`DefaultLoadControl.java`、`DefaultPreloadManager.java`（commit `8c6678b657ede1e7883fc164ef73ed483c7796c3`）https://github.com/androidx/media | A | 目前這集**整個緩衝完**才開始載下一集；總緩衝上限 50 秒 | 連 ExoPlayer 也不在播放中途搶頻寬預載 |

研究缺口：WWDC16 503 只讀了第三方逐字稿，沒看影片；Plex 和 Swiftfin 只看了摘要；沒搜 Apple Developer Forums。

## 七、建議方案：C′（分兩步）

### 第 0 步：量測（不改行為，只加 log）

在原生起播路徑多記三個時間點：`AVURLAsset` 屬性載入完成、`AVPlayerItem.status == .readyToPlay`、第一次 `timeControlStatus == .playing`。
用真機（SideStore）跑三種來源各兩次換集：直連 m3u8、需要 headers 的來源、MP4。

**決策條件**：命中預解析時，若「開啟到 asset 屬性載入完成」（約等於 master 播放清單往返）的中位數 ≥ 200 ms，就做第 1 步；否則停在方案 B 並結案。
若量出來大部分時間在第一段下載或解碼，記錄下來交使用者決定：那只有方案 D 能處理，屬於新範圍的架構變更。

### 第 1 步：預載 asset（只限原生）

- L1 預解析成功並存入後，若目標會走原生 AVPlayer，且網址不是本機代理（`127.0.0.1` 的 `SpiderProxyServer`）：建立帶相同 headers 的 `AVURLAsset`，呼叫 `load(.isPlayable, .duration)`。
- 這個 asset 和 `NextPlaybackTarget` 綁在同一個身分上一起存，失效規則完全沿用。
- 交棒時 `take` 命中，而且 asset 的網址＋headers 和最終選定的畫質網址相同，`loadNative` 就用這個 asset 建 `AVPlayerItem`；不同就照原路新建。
- 失敗或還沒載入完：照原路，不等、不報錯（optimization miss）。
- 新增 log：`[playback] asset preload <集> ready in <n>ms`／`missed: <原因>`，起播行加上 `asset=preloaded|fresh`。

### 驗收標準

1. 單元測試：asset 和預解析共用身分，換集、換畫質、關閉、逾時都會丟掉；畫質網址不同時不重用。
2. Simulator：連播 3 集，log 出現 `asset=preloaded`，第 2、3 集的起播時間不高於基線（966 ms 中位數那組來源）。
3. 真機（使用者用 SideStore）：同一來源連播，命中 asset 的起播中位數比第 0 步的基線少，且減少量不小於第 0 步量到的 master 播放清單時間的一半；Bili 等需要 headers 的來源沒有 403；沒有多出 `[proxy]` 呼叫。
4. 不退化：預解析失敗、asset 失敗、網址過期，都照原路開播；MPV 行為不變。

### 回退

單一 commit，`git revert` 即可，不改資料格式或設定。第 0 步的 log 可以保留。

### 實作預估（Claude 實際工時）

- 第 0 步：約 1 小時（加 log＋Simulator 驗證＋發版給使用者真機量測）。真機數據要等使用者回報。
- 第 1 步：約 3～4 小時（實作＋測試＋Simulator 連播驗證＋Ponytail）。

## 八、風險清單

| 風險 | 影響 | 處理 |
|---|---|---|
| 解析出的網址很快過期 | 預載的 asset 開播時 403 | 沿用 90 秒窗口＋5 分鐘上限；開播前失敗走既有 `retry` 重新解析一次 |
| 爬蟲限流、重複請求 | 多打來源 | L1 本來就每集一次；C′ 只碰 CDN 不碰爬蟲；本機代理網址不預載 |
| 流量 | 行動網路多花 | C′ 只抓播放清單（KB 級）；網路狀態不是 `.normal` 時本來就不預解析 |
| 記憶體／電量 | 多一個 asset | 只存一個；交棒或失效就釋放並 `cancelLoading()` |
| AVPlayer 和 MPV 不一致 | MPV 沒有 L3 | 刻意的：MPV 停在 L1，log 會寫 `asset=n/a` |
| 去廣告代理（kkys）和 302 退路 | 本機代理會多一次呼叫 | 本機代理網址排除，照 L1 |
| 畫質選擇 | 交棒時選的畫質和預載的不同 | 網址＋headers 不同就不重用 |

## 九、Ponytail

本工單只產出文件，沒有程式改動，所以不適用 Ponytail 審查。

## 十、未驗證事項

- 全部時間數據來自 Simulator，真機一筆都沒有。
- C′ 能省多少時間是估計值（0.1～0.3 秒），還沒量過；第 0 步就是為了確認這件事。
- 沒有實際寫程式驗證「預先載入屬性的 `AVURLAsset` 交給 `AVPlayerItem` 後不會再抓一次播放清單」；這要在第 1 步用 log 或 Charles 確認。
