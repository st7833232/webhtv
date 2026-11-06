# W-241 — 看當集時預載入下一集（評估，不實作）

- 狀態：**第一輪（W-241）已核准；第二輪（W-242，第十一節）評估完成，待審。未實作、未改任何程式或設定**。第十一節的建議取代第七節。
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

## 十一、第二輪（W-242）：預先載入下一集的影片內容

- 起因：使用者 2026-11-06 回覆（Manager #6172）：慢的是換集之後的**影片載入**（起播、緩衝），要的是真的預先抓好下一集的影片，不只是預解析網址。第一輪的 C′ 只省 master 播放清單一次往返，不夠。
- **使用者已決定（Manager #6180）：採用 E（本機快取代理），行動網路也要預抓，不限 Wi-Fi**；保留合理的單集上限和取消條件。Reviewer 核准本節後即可實作，不必再請使用者決定。
- 本節**取代第七節的建議**。第一～六節的現況、數據和來源仍然有效；第 0 步的分段 log 併進本節的實作版本，不再單獨發一版。
- 仍然只是設計，沒有改程式。

### 11.1 一句話設計

預解析下一集成功後，App 自己把下一集**起播點之後約 15 秒的片段**抓進暫存資料夾，並改寫播放清單：只有這幾段指向 `http://127.0.0.1`，後面的片段照樣指向來源。
交棒時，AVPlayer 和 MPV 都改開這個本機網址：先從本機讀已存的片段，後面的片段直接向來源抓，App 不轉送後面的內容。

### 11.2 預抓多少、上限、取消

| 項目 | 規則 | 理由 |
|---|---|---|
| 從哪裡開始 | 和實際開播**同一個來源**：`WatchHistory.startPosition(resuming: false)`（`ios/Sources/WebHTVCore/WatchHistory.swift:206`），用 `open(url:…)` 合併後的同一筆紀錄（`WebHTVApp.swift:5820-5826`）。自動連播和「下一集」都是 `resuming: false`，所以結果是片頭跳過秒數，沒設就是 0；換集不會沿用上一集的續播位置 | 預抓的片段必須正好是開播時 seek 到的地方 |
| 第 0 段 | `loadNative` 先 `replaceCurrentItem` 再 `seek`（`WebHTVApp.swift:6924`、`6930-6940`），seek 要等 item ready 才生效。AVPlayer 有可能先向來源抓第 0 段。**實作時先在 Simulator 用本機伺服器的 log 確認**；如果會先抓第 0 段，就把第 0 段也納入預抓（仍算在 20 MB 內） | 否則起播仍要等一次網路請求 |
| 預抓長度 | 累計片段長度到 **15 秒** 為止 | AVPlayer 起播只需要幾秒的緩衝；15 秒足夠在背景接上來源 |
| 單集上限 | **20 MB**，和 15 秒先到先停；第一段就超過 20 MB 時整個不做 | 1080p 每秒約 0.5～1 MB，15 秒大約 8～15 MB |
| 網路 | **Wi-Fi 和行動網路都做**（使用者決定，#6180）。不加設定開關 | 失敗本來就退回現行路徑 |
| 低數據模式 | **跳過預抓、只預解析**（Manager #6199 採用 Reviewer 和我的建議）。系統開了「低數據模式」（`NWPath.isConstrained`）時生效 | 低數據模式是使用者在系統裡明確要求省流量，和「只限 Wi-Fi」不同；兩種決定都只差一行 |
| 何時開始 | 第一輪的預解析存入之後立刻開始，沿用同一個閘門：已播 ≥ 20 秒、距交棒點 ≤ 90 秒、網路狀態 ≥ `.normal`、片長是有限正數 | 不另立一套觸發條件 |
| 同時存放 | 最多一集 | 和 `PlaybackTargetPrefetch` 一致 |
| 存放位置 | `Caches/next-episode-prefetch/<預解析身分>/`，不放記憶體 | 系統空間不足時可清；App 啟動時清掉殘留 |
| 取消並刪除 | 沿用所有 `prefetch.invalidate()` 的呼叫點：手動選集、換線路、換畫質、關閉播放器；另外是身分不符、超過 5 分鐘。取消時**先 `cancel()` 進行中的 `URLSessionTask`**，再刪資料夾 | 和第一輪的失效規則一致；只刪資料夾的話，下載還會繼續花流量 |
| 啟動清理 | App 啟動時刪掉整個 `next-episode-prefetch` 資料夾 | 閃退或被系統終止後留下的殘留 |
| 用完刪除 | 用這份內容開播的那一集被換掉、或播放器關閉時才刪 | 播放中往回拖到開頭，仍可從本機讀 |

### 11.3 哪些來源適用、哪些排除

| 來源 | 處理 | 理由 |
|---|---|---|
| 單一 variant 的 HLS VOD（或直接就是 media 播放清單） | **預抓** | 設定檔中大部分 CMS 來源屬於這類 |
| 多 variant 的 master | 第一版不預抓，只預解析 | AVPlayer 起播選哪一條，官方沒有明說（11.12 #R7）；猜錯就是白抓 20 MB。設定檔裡目前幾乎沒有這類來源 |
| master 帶 `#EXT-X-MEDIA` 且有 `URI=`（獨立音軌或字幕清單），或帶 `#EXT-X-I-FRAME-STREAM-INF` 且有 `URI=` | 不預抓，只預解析（適用所有 HLS，含可可影視） | 改寫成本機 master 後，這些相對網址會壞掉。跳過最簡單，和 W-237 處理可可影視的方式一致 |
| 明文 AES-128 加密的 HLS（`METHOD=AES-128`，沒有 `KEYFORMAT` 或 `KEYFORMAT="identity"`） | **預抓片段，金鑰不存**：`#EXT-X-KEY` 的 URI 改成來源的絕對網址，播放器開播時自己向來源抓金鑰 | Reviewer 要求 App 不存金鑰。代價是起播時多一次向來源抓金鑰的請求（通常整份播放清單只用一把）。`#EXT-X-MEDIA-SEQUENCE` 和 `#EXT-X-DISCONTINUITY-SEQUENCE` 不變，因為沒寫 `IV` 時，片段序號就是 IV（RFC 8216 §5.2） |
| SAMPLE-AES、`skd://`（FairPlay）、`KEYFORMAT` 不是 `identity` | 不預抓，只預解析 | 不碰授權；判斷沿用 `HLSKey.isDRM` 和 `OfflinePackageBuilder.validate` |
| 帶 headers 的來源（Referer、User-Agent、Cookie） | **預抓**。App 抓片段時帶同樣的 headers；帶憑證的 headers 只送同源，轉址時重新判斷（`OfflineRequestPolicy`） | 播放器向來源抓後面的片段時，headers 照現在的方式帶，不變：AVPlayer 用 `AVURLAssetHTTPHeaderFieldsKey`（`WebHTVApp.swift:6956` `asset(for:headers:)`，作用於這個 asset 發出的所有請求，現有需要 Referer 的 HLS 來源就是靠它抓片段）；MPV 每次載入前重設 `http-header-fields`（`MPVEngine.swift:592-593`），套用到這個檔案的每個 HTTP 請求 |
| 帶時效的簽名網址 | **預抓** | 已存的片段不會過期；後面的片段仍用原網址，曝險時間和現在一樣（90 秒窗口＋5 分鐘上限） |
| 可可影視（kkys）的去廣告代理網址（`127.0.0.1` 的 `SpiderProxyServer`，`type=adm3u8`） | **預抓**（W-243 使用者追加） | 刪過廣告的清單在預解析時已經進了 Python 快取；做法見 11.14 |
| 其他 Python 本機代理網址（bili 的 DASH、YouTube 等） | 不預抓，只預解析 | 不是 HLS，或本來就不預解析 |
| 302 退路 | 不受影響 | 本機代理網址直接跳過，它的 302 退路完全照舊。一般來源的轉址由 App 的下載跟著走，改寫時以轉址後的最終網址為基準 |
| MP4 | 第一版不預抓 | 單一檔案沒辦法「前段在本機、後段在來源」；要做就得由 App 轉送整個檔案（可參考 `SpiderProxyServer` 的分段轉送），工作量和風險都大，列為第二版 |
| DASH（Bili）、直播 | 不預抓 | 沒有 `#EXT-X-ENDLIST`，或不是 HLS |
| YouTube | 不預抓 | W-212 本來就不預解析 |
| 下一集已下載 | 不預抓 | 直接離線播放（IOS-POC-47） |
| 交棒時正在用 AirPlay | 不用本機網址，改用來源網址 | 電視收到 `127.0.0.1` 會連不回手機（11.12 #R8，C 級） |

#### 第一版會跳過的來源大概佔多少（Manager #6183）

依據：
- 使用者主設定檔的最後一份本機副本：`.herdr-synapse/webhtv-dev/artifacts/wang-movie-gitlab/wang-movie.20261028-0926.json`，共 171 站，其中 Python 站 46 個。
- 先前 Simulator 測試的 App log：原生播放的每集摘要行，共 134 集。
- 本機有副本的 Python 腳本。

| 跳過的類別 | 估計多常見 | 依據與限制 |
|---|---|---|
| 多 variant 的 HLS | **很少，可能沒有**：134 集原生播放中，107 集沒有 master（`variants=0`，直接是 media 播放清單或 MP4），27 集的 master 只有一條 variant，**0 集是多 variant** | 只涵蓋測過的站，不是全部 171 站；IOS-POC-15 第七節也記錄設定檔裡沒有多 variant 的來源 |
| 透過 Python 本機代理播放 | **很少**：本機有副本的腳本中，`playerContent` 回傳本機代理網址的只有**可可影視**（`kkys.py`，開了去廣告時）、bili（`哔哩.py`，DASH）和 YouTube（`油管-6.py`）。後兩個本來就因為 DASH、YouTube 而排除。其他有 `localProxy` 的腳本（`lxyy.py`、`sotvla.py`、`zndy.py`、`永乐视频修复搜索.py` 等），`playerContent` 都沒有回傳本機代理 | 46 個 Python 站中，只有大約一半的腳本在本機有副本；其餘沒有檢查 |
| MP4 | **未知**：上面 107 集 `variants=0` 的裡面混著 MP4 和直接的 media 播放清單，現有 log 分不出來 | 實作版的分段 log 會記 `skipped: mp4`，上線後就能知道比例 |
| DASH、直播、YouTube、DRM | 少數特定站 | 本來就各有專屬的播放路徑 |

**結論**：第一版涵蓋的「單一 variant HLS VOD」看起來是常用站的主流。可可影視原本是唯一明確會常用到、卻被跳過的站，W-243 已依使用者要求納入（11.14）。MP4 的比例要等上線後的 log 才知道。

### 11.4 做法

1. 預解析存入後，`PlaybackSession` 啟動一個預抓工作，跟第一輪預解析用同一個身分，也一起失效。
2. 用 App 的 `URLSession` 抓播放清單，headers 依 `OfflineRequestPolicy`，跟著轉址並記下最終網址。若是 master：只有一條 variant 才繼續，接著抓那條 media 播放清單。
3. 用 `OfflinePackageBuilder.validate` 檢查。DRM、SAMPLE-AES、直播一律停止。
4. 從起播點所在的片段開始往後累加，直到 15 秒或 20 MB（第 0 段依 11.2 的規則決定是否納入）；需要時加上 `#EXT-X-MAP` 初始化片段。金鑰不抓。依序下載，第一段失敗就整個放棄；後面失敗就只用已經連續抓到的那幾段。
5. 改寫播放清單：沿用 `OfflinePackageBuilder.rewrite`（`ios/Sources/WebHTVCore/Offline/OfflinePackage.swift:272`）的輸出，加一個參數「只把已存的片段和它們用到的 `#EXT-X-MAP` 指到本機；其他片段和所有 `#EXT-X-KEY` 寫成來源的絕對網址」。**整份播放清單的標籤和片段順序全部保留**，不刪掉起播點之前的片段。`#EXT-X-DISCONTINUITY`、序號、片段長度一律不動（RFC 8216 §6.2.1 不允許改變 media 播放清單的內容，11.12 #R4）。原本有 master 的話，再沿用 `localMaster` 寫一份只指向本機 media 播放清單的 master。
6. 用 `OfflineMediaServer` 交出這個資料夾（給它一個預抓專用的 root）。只綁 loopback、每次啟動用亂數 token、只讀資料夾內的檔案、支援 Range、IOS-POC-58 的健康檢查，全部沿用。
7. 交棒時，`start(_:flag:usingPrefetch:)` 拿到預解析結果後，若預抓內容已備妥、身分相符、本機伺服器有回應、不在 AirPlay 中，就把 `PlaybackTarget` 的網址換成本機網址，headers 保留。**只有播放器載入用本機網址，其他地方一律用原始網址**：廣告計畫（`watchAds`）、來源字幕的 `SourceSubtitleProvider(mediaURL:)` 和線上字幕的 `OnlineSubtitleIdentity(address:)`（`WebHTVApp.swift:6620-6632`）、`self.url`（觀看紀錄），以及換畫質、重新載入時的網址。
8. MPV 用本機網址開檔時帶 `cache=yes`（11.12 #R9：`cache=auto` 可能把 `127.0.0.1` 當成本機檔案而預讀太少，這是推論）。

### 11.5 預抓的片段播完後怎麼接回網路

- 播放器看到的是**同一份連續的播放清單**，只是前幾段的網址在本機、後面的在來源，中間不換播放器也不換 item，**也不加 `#EXT-X-DISCONTINUITY`**：內容本來就連續，只是網址的主機不同。HLS 允許每個片段用任意絕對網址（RFC 8216 §4.1）。
- 向來源抓的片段照常帶 headers（見 11.3 的「帶 headers 的來源」一列和它附的程式位置）。
- AVPlayer 開播後會一路往後抓到它的緩衝目標，MPV 也一樣。所以**向來源抓第 k+1 段，在起播當下就同時開始**，比播放進度領先約 15 秒。
- 網路慢到 15 秒內連下一段都抓不到時，會在約 15 秒處卡一下。這和今天的卡頓行為一樣，只是發生得比較晚；既有的網路狀態模型（IOS-POC-15A）照常運作。
- 播放中往回拖到開頭時，資料夾還在，所以仍從本機讀。

### 11.6 失敗時退回現行路徑

| 失敗點 | 處理 |
|---|---|
| 預抓的任何一步失敗、超過上限、被跳過 | 不換網址，照現在用預解析的網址開播；log 記原因 |
| 交棒時預抓還沒完成 | 不等，直接用預解析的網址（和第一輪的 `stillResolving` 一樣，只是一次優化沒命中） |
| 本機伺服器沒回應 | 不換網址 |
| 用本機網址開播前就失敗 | 走既有的 `retry`：以 `usingPrefetch: false` 重新解析一次，走來源網址 |
| 開播後，來源的後續片段失敗（例如簽名過期） | 和今天一樣，當作串流失敗處理 |

### 11.7 分段 log（原本的第 0 步，併入同一版）

- 起播路徑記三個時間點：AVPlayer 是 `asset 屬性載入完成`、`item readyToPlay`、`第一次 playing`；MPV 是 `file-loaded` 和第一次 `playback-restart`。
- 預抓：`[playback] content-prefetch <集> <n> 段 <秒數>s <MB>MB in <ms>ms`，或 `skipped: <原因>`（多 variant、DRM、本機代理、MP4、直播、低數據模式、超過上限、失敗）。
- 交棒：起播行加上 `content=hit|miss: <原因>`、`local=<從本機讀的位元組>`、`net=<網路類型>`。

### 11.8 驗收

開發端（Claude，單元測試＋Simulator）：
1. 單元測試：
   - 改寫：只有已存的片段和它們用到的 MAP 指到本機；其他片段和所有 KEY 都是來源的絕對網址；標籤、片段順序、`MEDIA-SEQUENCE`、`DISCONTINUITY-SEQUENCE`、片段長度都不變。
   - master 帶 `#EXT-X-MEDIA … URI=` 或 `#EXT-X-I-FRAME-STREAM-INF … URI=` 時跳過。
   - 加密：沒寫 IV 的 AES-128 播放清單改寫後，序號不變；SAMPLE-AES、`skd://`、`KEYFORMAT` 不是 identity 的都跳過。
   - 起點：預抓起點和 `WatchHistory.startPosition(resuming: false)` 一致。
   - 會轉址的播放清單：相對網址以最終網址為基準。
   - 15 秒、20 MB 兩個上限都會停；第一段超過 20 MB 時整個不做。
   - 排除條件：多 variant、DRM、SAMPLE-AES、本機代理、MP4、直播、低數據模式、AirPlay 中，都只預解析或改用來源網址。
   - 失效：手動選集、換線路、換畫質、關閉、逾時都會先取消進行中的下載，再刪掉資料夾；啟動時會清掉殘留。
2. Simulator 連播 3 集（AVPlayer 和 MPV 各一次）：log 出現 `content=hit`；第 2、3 集的起播時間比沒有預抓的基線短；廣告計畫和用原始網址算的一樣；有片頭跳過時，開播位置正確。
3. Simulator 確認本機伺服器的 log：AVPlayer 開播時第一批片段請求就是已存的片段，沒有先向來源抓第 0 段（否則依 11.2 把第 0 段納入預抓）。
4. Simulator 播過預抓的 15 秒之後不卡，log 看得到改向來源抓片段的請求。
5. 至少測一個需要 Referer 的 HLS 來源：預抓和之後向來源抓的片段都沒有 403。
6. 不退化：故意讓預抓失敗、本機伺服器不回應、網址過期，都照現在的流程開播；DASH、本機代理來源的行為不變。

真機（請使用者用 SideStore 安裝後回報）：
1. 同一部劇在 **Wi-Fi** 上連播 3 集：換集是否幾乎立刻開始播。接著 Mac 的話，在「主控台」看 `[playback] started` 行，回報第 2、3 集的毫秒數和 `content=` 欄位。
2. 同樣的劇在**行動網路**上連播：同上；另外可在「設定 → 行動服務」看 App 用量，確認每集多出的流量大約不超過 20 MB。
3. 有片頭跳過設定的劇：換集後是否從跳過點開始。
4. 子母畫面中自動換集：是否正常接續。
5. AirPlay 投放中換集：是否照常播放（應該走來源網址）。
6. 有廣告的來源：換集後廣告是否照樣跳過。

### 11.9 回退

單一 commit，`git revert` 即可，不改資料格式或設定；暫存資料夾在 App 下次啟動時會被清掉。
不加設定開關：使用者沒有要求，而且失敗本來就會退回現行路徑。

### 11.10 實作預估（Claude 實際工時，約 1.5 天）

| 部分 | 時間 |
|---|---|
| 預抓下載器：上限、取消、只抓連續的片段 | 3 小時 |
| 部分改寫（擴充 `OfflinePackageBuilder.rewrite`、`localMaster`） | 2 小時 |
| 預抓專用 root、交棒換網址、廣告用原始網址、AirPlay 判斷 | 2 小時 |
| 分段 log | 1 小時 |
| 單元測試 | 2 小時 |
| Simulator 連播（AVPlayer、MPV）、Ponytail、文件 | 2 小時 |

發版由 Manager 處理；真機驗收要等使用者回報。

### 11.11 不選 D 和 F 的理由

- **D（`AVQueuePlayer`，或第二個 `AVPlayer` preroll）**：
  - MPV 沒有對應做法（mpv `prefetch-playlist` 對 HLS 無效，11.12 #R9）。
  - 還沒在播的 item 能不能先 seek 到片頭跳過點，找不到官方說明（11.12 #R6）。
  - 要把 `loadNative` 裡每次換集的設定（時間伸縮演算法、網路監測、速度、起始位置、字幕和音軌、去廣告、`retry`）搬到「item 變成目前項目時」，等於重寫交棒流程。
  - 兩條播放管線同時存在；第二個 `AVPlayer` 的做法還要換畫面層，會牽動子母畫面。
- **F（`AVAssetResourceLoaderDelegate`＋自訂 scheme）**：
  - Apple 工程師明說 HLS 的媒體片段只能轉址到 HTTP 網址，`respondWithData` 會被拒（11.12 #R1）。所以 HLS 終究需要本機 HTTP 伺服器（＝E），F 只是多一層。
  - MPV 用不到自訂 scheme；AirPlay 據報不支援自訂 resource loader（11.12 #R8，C 級）。
  - Apple 在同一串回覆裡建議的替代做法，正是「在裝置上跑一個 HTTP 伺服器」；成熟專案 KTVHTTPCache 也是這樣做（11.12 #R3）。

### 11.12 第二輪外部研究來源

存取日期都是 2026-11-06。等級同第六節。

| # | 來源 | 等級 | 內容 | 對本案的影響 |
|---|---|---|---|---|
| R1 | Apple 開發者論壇 thread 113063 https://developer.apple.com/forums/thread/113063 （Apple Systems Engineer，2020 年 6、7 月） | B | 「AVPlayer 對 .ts 片段請求唯一接受的回應是轉址到 HTTP 網址，`respondWithData` 會被拒」；TS、fMP4、packed audio、WebVTT 都一樣，因為 AVFoundation 要自己載片段做位元率調整；播放清單可以由 delegate 提供；建議改用 `AVAssetDownloadTask` 或「裝置上的 HTTP 伺服器」 | F 對 HLS 不可行；E 是 Apple 自己提的替代做法 |
| R2 | `AVAssetResourceLoadingContentInformationRequest`、`isByteRangeAccessSupported`、`requestsAllDataToEndOfResource` 文件 https://developer.apple.com/documentation/avfoundation/avassetresourceloadingcontentinformationrequest | A | 要先填好內容資訊；含媒體資料的資源若不支援 byte range，載入可能失敗 | F 做 MP4 的必要條件 |
| R3 | KTVHTTPCache（master `388da9af7891ea081e2631e09483ff5cbb09639b`，tag 3.1.0）https://github.com/ChangbaDevs/KTVHTTPCache ；`KTVHCHLSTool.m` | A | README：支援 HLS，不綁播放器（AVPlayer 或 FFmpeg 系都可），依 Range 比對本機快取；本機伺服器預設只收 localhost，所以 AirPlay 預設無效。原始碼只改寫不以 `#` 開頭的網址行，**沒有改 `#EXT-X-KEY`／`#EXT-X-MAP` 的 URI 屬性** | 成熟專案採用本機代理（＝E）；我們的改寫要補上屬性網址 |
| R4 | RFC 8216 https://www.rfc-editor.org/rfc/rfc8216 ；draft-pantos-hls-rfc8216bis-22 https://datatracker.ietf.org/doc/html/draft-pantos-hls-rfc8216bis | A | §4.1：相對網址以所在播放清單為基準；§4.3.2.4／4.3.2.5：`EXT-X-KEY`、`EXT-X-MAP` 帶 URI；§4.3.2.3、§6.3.3：不連續處要有 `EXT-X-DISCONTINUITY`，用戶端要能重置解碼器；§6.3.1：不支援的 scheme 用戶端必須停止播放；bis §4.4.2.2 `EXT-X-START` 可指定起播點。**沒有規定轉址後用哪個網址當基準** | 改寫規則、轉址測試；`EXT-X-START` 可作為片頭跳過的備案（未測） |
| R5 | Apple 開發者論壇 thread 649810 https://developer.apple.com/forums/thread/649810 （Apple Systems Engineer，2020 年 6 月） | B | `preferredForwardBufferDuration` 可限制「目前沒在播的 item」的預讀量；item 只要還在 player 上就會保留緩衝；記憶體裡很難快取超過 4～6 部影片；經常寫入磁碟快取會增加 NAND 磨耗；`preferredPeakBitRate` 和 `preferredMaximumResolution` 可降低 preroll 的成本 | D2 有方法設上限；E 每集最多 20 MB、用完即刪，磨耗可忽略 |
| R6 | `AVQueuePlayer`、`advanceToNextItem()`、`seek(to:completionHandler:)`、`forwardPlaybackEndTime` 文件 https://developer.apple.com/documentation/avfoundation/avqueueplayer 、https://developer.apple.com/documentation/avfoundation/avplayeritem/forwardplaybackendtime ；論壇 thread 72441（非 Apple 人員） | A／C | 官方沒寫下一個 item 何時開始載；論壇使用者說「只預載佇列中的下一個」；沒有任何文件說還沒在播的 item 能先 seek；`forward/reversePlaybackEndTime` 只設結束點，不能設起點 | D1 的片頭跳過沒有官方做法 |
| R7 | HLS Authoring Specification for Apple Devices https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices | A | 1.32：預設 variant 是 master 中「相容音訊的一組 variant 裡的第一條」；iOS 的預設在 Wi-Fi 應為 2000 kbit/s、行動網路為 730 kbit/s；附錄：「預設行為是選目前可播的最高位元率」，全部有 `SCORE` 時選 SCORE 最高的。**沒有明說 AVPlayer 起播選哪一條** | 第一版不做多 variant |
| R8 | KTVHTTPCache README（同 R3）；GitHub issue https://github.com/superuser404notfound/AetherEngine/issues/86 ；論壇 thread 28101 https://developer.apple.com/forums/thread/28101 | C | AirPlay 會把 `127.0.0.1` 網址交給電視，電視連不到；有人轉述技術支援的說法：自訂 resource loader 不支援影片 AirPlay。Apple 官方沒有說明；子母畫面找不到資料 | E：AirPlay 中改用來源網址；F 對 AirPlay 不利 |
| R9 | mpv 手冊 `options.rst`（master `902818753849d9ad8f0096fad6ca5aeaa37113b9`）https://github.com/mpv-player/mpv/blob/master/DOCS/man/options.rst | A | `--cache=auto` 是判斷是否為網路串流的「不完美啟發式」；`--cache-on-disk` 的檔案在關閉播放時刪除，設計上不能拿回資料；`--prefetch-playlist` 對 HLS 無效 | MPV 用 E 的網址時帶 `cache=yes`（推論）；mpv 自己的快取不能拿來預載 |

研究缺口：WWDC 逐字稿這一輪沒看；沒查 GCDWebServer 類的快取專案；Apple 論壇回覆只有年月沒有日期；AirPlay 的證據最弱（只有 C 級）。

### 11.13 第二輪未驗證事項

- E 能省多少時間是推估（命中時估計剩 0.2～0.5 秒），要靠 11.7 的分段 log 在 Simulator 和真機上確認。
- 行動網路上每集最多多用 20 MB；使用者沒看下一集時，這些流量就浪費了。這是使用者接受的取捨（#6180）。
- AVPlayer 會不會先向來源抓第 0 段，要在 Simulator 確認後才定案（11.2）。
- 金鑰不存在本機，起播時仍多一次向來源抓金鑰的請求；這一點的耗時沒量過。
- AirPlay 和本機網址的衝突只有 C 級來源；子母畫面完全沒有資料。兩者都列入真機驗收。
- 「mpv 把 `127.0.0.1` 當成本機檔案而少預讀」是推論。
- 低數據模式：Manager #6199 決定跳過預抓（11.2 那一列不再是待決定）。
- 多 variant 和 MP4 不在第一版範圍。

### 11.14 可可影視（kkys 本機代理）的預抓（W-243 追加）

- 起因：使用者 2026-11-06 追加（Manager #6199）：可可影視也要納入第一版，並想知道會多花多少時間。Manager 已決定：低數據模式跳過預抓。
- `kkys.py` 不改。依據是已部署的版本：recha `dea21411eec64a62bbe4da9a7abd393cfc3dbe83`，`py/kkys.py` sha256 `e16d818b0262a1a740739a94b8e85687a2dfe531c2cdae0b7d3bc56ae27e851e`。

#### 可可影視現在怎麼播

1. `playerContent` 拿到原始 m3u8 後，交給 `_ad_play_url`（`kkys.py:1305`）。它在背景執行緒裡把 master 和每條 variant 都抓好、刪掉廣告，存進 Python 端的快取（`_ad_answer`，`kkys.py:1279`；600 秒、最多 8 份），用 `join(5)` 最多等 5 秒（`_AD_PREFETCH_TIMEOUT`）。
   - 5 秒內做完：回傳本機代理網址 `…/proxy?do=py&type=adm3u8&url=<原始網址>`。
   - 超過 5 秒或失敗：回傳**原始網址**（直連，廣告照播）。
2. 播放器要 master 時，`SpiderProxyServer` 呼叫 Python `localProxy`（`kkys.py:1330`），它從快取回答：
   - master：白名單網域的 variant 包成本機代理網址，其他照原網址。
   - variant：已刪廣告的 media 播放清單，**片段全是來源的絕對網址**，片段本身不經過代理。
   - 快取沒有、又抓不到時，回 **302** 轉到原始網址（廣告照播）。
   - master 帶有獨立音軌或字幕清單（`#EXT-X-MEDIA` 帶 `URI=`）時，`_ad_answer` 回 None，同樣走 302（W-237）。
3. 從 Simulator log 看到，播放器對同一份 variant 會先後要兩次（`range=bytes=0-1`，接著 `bytes=0-524287`），每次都呼叫一次 `localProxy`。

#### 預抓怎麼接在去廣告後面

- 規則改成：**本機代理網址中，`type=adm3u8`（可可影視的去廣告清單）納入預抓**；DASH（bili 的 MPD）、YouTube、其他本機代理照舊排除。11.3「可可（kkys）等 Python 本機代理網址」那一列依此修改。
- 第一輪的預解析（片尾前約 90 秒）本來就會呼叫 `playerContent`，所以預抓開始時，**刪過廣告的清單已經在 Python 快取裡**。
- 預抓的步驟和一般 HLS 相同（11.4），差別只在「播放清單從哪裡讀」：
  1. 用 App 的 `URLSession` 向 `127.0.0.1` 的 `SpiderProxyServer` 要 master（代理網址本身帶 token）。`localProxy` 從快取回答，不另外連網。
  2. master 只有一條 variant 才繼續（多 variant 照 11.3 跳過）。那條 variant 的網址也是代理網址，同樣向本機要，拿到刪過廣告的 media 播放清單。
  3. 片段已經是來源的絕對網址，所以從這裡開始和一般 HLS 完全一樣：抓起播點後 15 秒、上限 20 MB；改寫時只有已存的片段指向預抓的本機資料夾，其他片段保持來源網址；金鑰指向來源。
  4. 交棒時，播放器開的是**預抓資料夾裡的 master**，它指向預抓資料夾裡的 media 播放清單。所以**起播路徑上不再呼叫 Python `localProxy`**（現在起播前要呼叫 2～4 次）。開播之後，智慧去廣告（`watchAds`）仍照 11.4 第 7 步用原始網址（對可可影視就是代理網址），讀兩次播放清單，所以開播後仍會有 `type=adm3u8` 的呼叫，只是不擋起播，和現在相同。
- **廣告不會回來**：預抓存的就是 `localProxy` 刪過廣告的清單，片段集合和直接播代理網址時一樣。iOS 的智慧去廣告（`watchAds`）照規定用原始網址，也就是預解析得到的代理網址，和現在相同。
- **302 退路並存**：預抓向代理要清單時若收到 302，`URLSession` 會跟著轉到原始網址，拿到的是**沒刪廣告的原始清單**，和播放器直接遇到 302 時拿到的一樣。所以預抓照常進行，相對網址以轉址後的最終網址為基準（11.4 第 2 步）。行為和現在相同，只是更快開播。
- **5 秒逾時直連並存**：`playerContent` 超過 5 秒時回的是原始網址，不是代理網址，預抓就當一般 HLS 處理（有廣告，和現在一樣）。
- **快取時效**：Python 快取 600 秒，比預解析的 5 分鐘上限長，所以預抓時清單一定還在；萬一不在，`localProxy` 會重新抓一次或回 302，都已涵蓋。
- **Python 佇列**：預抓的 1～2 次 `localProxy` 呼叫發生在當集播放中、交棒前約 90 秒。當集是 VOD，播放清單早在開播時讀完，不會和當集搶 Python。

#### 會多花多少時間

| 項目 | 估計 | 依據 |
|---|---|---|
| **使用者換集時** | **不會變慢，預期更快**：起播前不必再等 `localProxy` 和來源 | Simulator 上可可影視現在的起播中位數是 2163 ms（W-233 log，n=40，全部是現場解析）。預抓命中後估計和其他 HLS 一樣剩 0.2～0.5 秒，真機未量 |
| 預抓時的背景工作 | 多 1～2 次 `localProxy` 呼叫，從快取回答，估計每次數十毫秒；網路流量只有 15 秒的片段（上限 20 MB），和其他來源相同 | 片段本來就是播放器直接向來源抓，預抓只是提早抓 |
| **實作多花** | **約 2～3 小時**：允許 `type=adm3u8` 的本機代理網址當播放清單來源（0.5 小時）、單元測試（代理回 200、代理回 302 轉到原始清單、5 秒逾時回原始網址三種，1 小時）、Simulator 上可可影視連播 3 集（沿用 W-233 的測試設定，1～1.5 小時） | 整個 W-243 的實作預估因此由約 1.5 天變成**約 1.8 天**（Claude 實際工時約 14～15 小時） |

#### 可可影視的驗收（加進 11.8）

- 單元測試：上面三種情況（代理 200、302、逾時回原始網址）都會預抓，而且改寫後的清單沒有被刪掉的廣告片段又跑回來。
- Simulator：可可影視連播 3 集，log 出現 `content=hit`；**起播前**沒有 `[proxy] type=adm3u8` 的呼叫（只在預抓階段有），開播後 `watchAds` 的呼叫照舊；廣告區段仍被刪除。
- 真機（請使用者回報）：可可影視連播時，換集是否幾乎立刻開始播，而且沒有廣告。
