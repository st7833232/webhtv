# IOS-POC-23 — 暫停後離開 App 再回來，兩個播放核心都卡住

- 狀態：**第一階段已實作（2026-09-25，使用者核准）**，含 MPV snapshot 修正（第十一節之四，使用者同意納入範圍）；已以 `0.1.20 (21)` 發布，CI 第一次編譯即成功；單元測試未執行。**真機驗收通過（2026-09-25，T1～T15 全部符合，第十二節）**。
- 使用者原始提問（2026-09-25，`0.1.19 (20)` 之前的版本）：「暫停後跳出 App 再恢復播放，容易有問題，是不是連線沒有重新建立？」
- 本文件依 AGENTS.md §7 記錄最佳實務研究、現況審查、方案比較、建議、驗收標準與回滾。核准前不實作。

## 一、症狀（使用者 2026-09-25 選擇題回答）

| 項目 | 回答 |
|---|---|
| 播放核心 | 原生（AVPlayer）與 MPV 都會 |
| 症狀 | 黑畫面、沒有聲音；按播放鍵圖示沒有變化 |
| 背景時間 | 1 分鐘內 |
| 背景期間 | 只回主畫面或鎖螢幕，沒有開其他會發聲的 App，沒有通話 |
| 子母畫面 | 離開時沒有出現小視窗 |
| 播放中離開 | 不會發生，只有先暫停再離開才會 |
| 拖進度條 | 拖了也不會恢復 |
| 怎樣恢復 | 關掉播放器重開才恢復 |
| 特定來源 | 不確定 |
| 按播放後等 2 分鐘 | 還沒試，之後回報 |

## 二、診斷

### 1. App 自己沒有連線可以重建

App 沒有本地代理或 HTTP server；AVPlayer（`AVURLAsset`＋headers）與 mpv（`loadfile`＋`http-header-fields`）都直接連遠端（`ios/WebHTVApp/Sources/MPVEngine.swift:352-364`）。連線與重連由各播放器負責。App 在回前景時：

1. AVPlayer 路徑只做子母畫面還原（`ios/WebHTVApp/Sources/WebHTVApp.swift:3859-3872`）。
2. MPV 路徑只設 `vid=auto`（`MPVEngine.swift:64-72`）。
3. 兩者都不重新載入，開播後也沒有任何卡住偵測：`watchStartup` 在第一次 `isPlaying` 就結束（`WebHTVApp.swift:2704-2727`）。

### 2. 「按播放沒反應」＝播放器收到指令但在等資料

1. 播放鍵直接呼叫 engine，沒有條件擋住（`WebHTVApp.swift:2576-2578`、`MPVEngine.swift:92-95`）。
2. 圖示只在真正播放時才變成暫停鍵：
   - AVPlayer 看 `timeControlStatus == .playing`（`WebHTVApp.swift:4128`、`:3373-3374`）；
   - MPV 的 `isPlaying` 排除 `paused-for-cache`（`MPVEngine.swift:107`）。
3. Apple 文件：按播放時沒有足夠資料，會進入 `waitingToPlayAtSpecifiedRate`（見第三節 A4）。所以等待資料的狀態在畫面上就是「按了沒反應」，沒有轉圈。

### 3. 只在暫停時發生＝App 被系統暫停執行（suspend）

1. App 宣告背景音訊（`ios/WebHTVApp/Info.plist:10-13`），啟動時啟用一次 `.playback` 音訊工作階段（`WebHTVApp.swift:27-28`），之後不再處理。
2. 播放中離開，音訊持續，App 不會被暫停執行；暫停後離開沒有聲音輸出，系統很快就暫停執行 App（第三節 N1、N3）。鎖螢幕也一樣（N2）。
3. 暫停執行期間，系統可以收回 socket，或讓連線變成收不到資料的「聾」連線（N1、N2）。
4. Apple 文件：系統暫停 App 時，會停用它的音訊工作階段；App 恢復時會收到 `interruptionNotification`，原因為 `appWasSuspended`（第三節 A7）。WebHTV 沒有處理這個通知。
5. 背景不到 1 分鐘就發生，網址過期與 NAT 閒置逾時都不是主因（N6）。

### 4. 拖進度條救不回來的原因

1. **MPV（信心中高）**：
   - seek 只設旗標再喚醒 demux thread，不會中斷正在阻塞的讀取（mpv v0.41.0 `demux/demux.c:3809-3817`、`:3865-3869`）。
   - demux thread 在 `read_packet` 內放開鎖進行讀取，讀完才檢查 seeking（`demux.c:2257-2274`、`:2542-2544`）。
   - FFmpeg 的讀取等待最長為 `network-timeout`（預設 60 秒），以 100 ms 為一段輪詢，只有 cancel 能提早中止（FFmpeg n8.1.2 `libavformat/tcp.c:174-176`、`libavformat/network.c:66-93`）。
   - 所以回前景時的 refresh seek（`vid=auto` 觸發，`demux.c:4026-4032`）和使用者的 seek，都排在一個可能阻塞 60 秒以上的讀取後面。
   - `vid=no` 已經清掉快取裡的影像資料（`demux.c:895-911`），無法只靠快取恢復。
2. **AVPlayer（信心低到中，機制未證實）**：
   - Apple 論壇多則回報與 WebHTV 症狀一致：暫停超過約 1 分鐘後不再播放，`rate` 停在 1、`status` 不變成 failed，只有重建 `AVPlayerItem` 才恢復（第三節 F1～F3）。
   - Apple 標頭：失敗的 item 無法再播放，要建立新的 instance（A1）。
   - AVPlayer 的 HTTP 請求在 mediaserverd 執行（B 級，2017 年資料），所以 socket 收回不一定是直接原因；音訊工作階段被停用是另一個候選。

### 5. 關掉播放器重開能恢復的原因

重開並不會建立新的播放器物件，而是在**同一個 engine instance** 上做一次新的 load：

1. MPV：`loadfile … replace`（`MPVEngine.swift:363`）。停止舊檔時，mpv 等待 `demuxer-termination-timeout`（預設 0.1 秒）後觸發 `mp_cancel`（`player/loadfile.c:158-178`、`demux/demux.c:1135-1151`），FFmpeg 在下一個 100 ms 輪詢段中止讀取（`network.c:81-82`）。新的 audio output 初始化時會自己 `setActive(YES)`（mpv `audio/out/ao_audiounit.m:123-125`）。
2. AVPlayer：以新的 `AVPlayerItem` 呼叫 `replaceCurrentItem`（`WebHTVApp.swift:2787-2800`）。
3. 重開還會重新解析網址（VodView），並從觀看紀錄續播。所以目前無法分辨「同一網址重新載入」是否足夠；背景不到 1 分鐘，過期的可能性低。

### 6. 候選機制與信心

| 機制 | 核心 | 信心 | 依據 |
|---|---|---|---|
| 暫停執行後連線失效，seek 排在阻塞讀取後面 | MPV | 中高 | 第二節 4-1、N1、N2、M1～M4 |
| 暫停執行後 item 卡死，只有新 item 能恢復 | AVPlayer | 低到中 | A1、F1～F3 |
| 系統停用音訊工作階段，App 沒有重新啟用 | 兩者 | 中（「沒有聲音」的直接候選，但單獨不能解釋 seek 無效） | A7、`WebHTVApp.swift:28` 是唯一的 `setActive` |
| 網址過期（403） | 兩者 | 低（背景不到 1 分鐘） | N6 |
| 讀取失敗轉成 EOF，接著自動下一集 | MPV | 低（使用者沒有回報換集） | `stream/stream.c:507-511`、`MPVEngine.swift:478-479` |

### 7. 待裝置確認

1. 按播放後等 2 分鐘會不會恢復（使用者之後回報）。
   - MPV 約 60～130 秒恢復：表示是聾連線，讀取有上限。
   - 永遠不恢復：表示重連放棄，或進入 EOF／卡死狀態，只有重新載入能救。
   - 不論哪種結果，第一階段都需要；這個結果只決定是否值得做後續階段。
2. 失敗的來源是 HLS（m3u8）還是單一檔案（mp4），以及當時是 Wi-Fi 還是行動網路。
3. 沒有 Mac 時沒有 Console log，所有測試只能看畫面判斷。

## 三、最佳實務研究（2026-09-25 讀取）

評級：A＝原始碼、規格或官方文件；B＝維護者或 Apple DTS 討論；C＝成熟專案程式碼；D＝論壇或 issue 回報。

### 1. 上游原始碼（mpv v0.41.0 `41f6a645068483470267271e1d09966ca3b9f413`、FFmpeg n8.1.2 `38b88335f99e76ed89ff3c93f877fdefce736c13`）

| # | 來源 | 級 | 支持的論點 | 對決策的影響 |
|---|---|---|---|---|
| M1 | mpv `demux/demux.c:2252-2274`、`:2520-2545`、`:3804-3818`、`:3862-3870` | A | seek 不會中斷阻塞中的讀取，要等讀取返回 | seek 類修正無效，必須重新載入或 cancel |
| M2 | mpv `player/loadfile.c:158-178`、`demux/demux.c:1135-1151`、`options/options.c:1031`（選項宣告在 `:659`） | A | `stop`／`loadfile replace` 在 0.1 秒後以 `mp_cancel` 強制中止 | 重新載入可以在約 0.2 秒內脫離卡住狀態 |
| M3 | FFmpeg `libavformat/tcp.c:174-176`、`:184-186`、`:275`；`libavformat/network.c:66-93` | A | `timeout`（mpv `network-timeout` 60 秒）限制每次連線與每次讀寫等待；DNS 沒有上限 | 只靠逾時要等 60 秒以上 |
| M4 | FFmpeg `libavformat/http.c:340-348`、`:1848-1891`、`:2164-2172` | A | 讀取途中的重連需要已知長度且非 streamed，退避 0、1、3、7 秒後回 EIO；seek 建立的新連線，沒有 `reconnect_on_network_error` 就不重試；seek 失敗會把舊連線放回去 | O1 只能縮短等待，不能消除 |
| M5 | FFmpeg `libavformat/hls.c:707-720`、`:1743-1763` | A | HLS segment 只帶 headers／UA／cookies／rw_timeout，沒有 reconnect；segment 讀取失敗會跳到下一段 | HLS 也要等阻塞讀取返回 |
| M6 | mpv commit `48e6c35c0e056d9e4ff04b98e012416697736d8a`（2026-07-26 合併，v0.41.0 之後；commit message 以 git 讀取，PR #18304 頁面未讀） | A | 讓 demux_lavf 的 AVIO 中斷回呼檢查 seeking，使 seek 能中止阻塞的網路 I/O；只涵蓋 demux_lavf（HLS），`stream_lavf` 不變 | 上游確認問題存在；反向移植只能修 HLS，列為延後 |
| M7 | mpv `audio/out/ao_audiounit.m:118-125`、`:238-241` | A | ao 初始化時設 `.playback`＋`MixWithOthers` 並 `setActive(YES)`；uninit 時 `setActive(NO)` | 重新載入會讓 MPV 重新啟用音訊；另見第十節的工作階段設定衝突 |

上游測試：mpv 與 FFmpeg FATE 沒有涵蓋「程序被暫停執行後的 socket」情境（需要作業系統配合），所以不列入；決策只依賴上表的程式路徑。上游 revert：mpv-android 的 `vo=null` 改動（C3）之後沒有被 revert；mpv 的網路逾時（`5a99015acf184a2989ea7ebf50ab2c990be41125`）沿用至今。

### 2. 官方文件與規格

| # | 來源 | 級 | 支持的論點 | 對決策的影響 |
|---|---|---|---|---|
| A1 | `AVPlayerItem.h:177-180`（theos/sdks `0222fd5413cf4b9af096f37b4621afa2688572f7`，iPhoneOS 16.5 SDK 的第三方鏡像，未以本機 Xcode SDK 核對）；https://developer.apple.com/documentation/avfoundation/avplayer/status-swift.property | A（有鏡像來源的保留） | failed 的 player／item 無法再用，要建立新的 instance | AVPlayer 的恢復方式是新 item |
| A2 | https://developer.apple.com/documentation/avfoundation/avplayeritem/playbackstallednotification | A | 串流在取得足夠資料後才會繼續；檔案播放不會繼續 | App 必須自己設上限，不能等 AVPlayer 報錯 |
| A3 | https://developer.apple.com/documentation/avfoundation/avplayer/automaticallywaitstominimizestalling ；`playImmediately(atRate:)` | A | 資料不足時進入等待，不發出錯誤 | 解釋「按了沒反應」 |
| A4 | https://developer.apple.com/documentation/avfoundation/avplayer/timecontrolstatus-swift.enum/waitingtoplayatspecifiedrate ；`reasonForWaitingToPlay` | A | 從 0 變成非 0 速率但資料不足時進入等待 | log 時要記錄 `reasonForWaitingToPlay` |
| A5 | https://developer.apple.com/videos/play/wwdc2017/514/ | A | HLS 時 AVPlayer 會自行重試與切換 variant，全部失敗才 failed | 永久等待而不報錯不在 Apple 描述的模型內 |
| A6 | MediaPlaybackGuide（archive，2018-01-16） | A | 把 AVPlayer 與畫面分離只用於背景繼續播放聲音 | 不採用「分離再接回」作為修正 |
| A7 | https://developer.apple.com/documentation/avfaudio/avaudiosession/interruptionnotification ；https://developer.apple.com/documentation/avfaudio/avaudiosession/interruptionreason/appwassuspended （iOS 14.5+） | A | 「Starting in iOS 10, the system deactivates an app's audio session when it suspends the app process.」恢復時收到中斷通知，原因為 `appWasSuspended`。非 mixable 的工作階段（`.playback` 預設），Apple 建議不在使用音訊時進背景前自行停用 | 按播放前要重新啟用音訊。**更正（2026-09-25）**：`appWasSuspended` 自 iOS 16.0 停用（「wasSuspended reason no longer present」），部署目標 17.0 收不到，不能當觸發條件（第十一節） |
| A8 | https://developer.apple.com/documentation/avfoundation/configuring-your-app-for-media-playback | A | 建議把 `setActive` 延到開始播放時 | 重新啟用音訊放在按播放時，不放在回前景時（避免打斷別的 App 的聲音） |
| A9 | `mediaServicesWereResetNotification` 文件 | A | 媒體服務重設時要重建音訊物件 | 只記錄；若出現，需要重建 AVPlayer 而不只是 item |
| N1 | TN2277「Networking and Multitasking」（archive，2011-03-30）https://developer.apple.com/library/archive/technotes/tn2277/_index.html | A（已停止更新） | 暫停執行期間系統可以收回 socket；恢復後對該 socket 的操作都會失敗 | 回前景後要把播放器的連線視為不可用 |
| N3 | https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time 等生命週期文件 | A | 進背景後很快就被暫停執行 | 背景不到 1 分鐘也足以觸發 |
| N4 | `URLSessionConfiguration.waitsForConnectivity`、`timeoutIntervalForRequest`；QA1941；`NWConnection.betterPathUpdateHandler` | A | Apple 的重連指引一律是建立新連線，不是修復舊連線；idempotent 請求可直接重試 | 支持「重新載入」而不是「修補舊連線」 |
| N5 | RFC 9293 §3.5.1、§3.8.3；RFC 1122 §4.2.3.6（經 GitHub 鏡像 kesara/watcher `4be005ec9b445e89ab5ae8ddb005e848aec4bf18` 讀取，rfc-editor.org 被 proxy 擋） | A | 只接收資料的半開連線不會被 TCP 自己偵測；keepalive 預設關閉且間隔至少 2 小時 | 聾連線只能靠應用層逾時或主動重開 |
| N6 | RFC 5382 REQ-5、RFC 7857 §2.1（同上鏡像） | A | NAT 的 established 閒置逾時不得少於 2 小時 4 分 | 1 分鐘內的問題不是 NAT 造成 |

### 3. 維護者與 Apple DTS 討論

| # | 來源 | 級 | 支持的論點 |
|---|---|---|---|
| N2 | https://developer.apple.com/forums/thread/757385 （DTS，2024）；https://developer.apple.com/forums/thread/765841 （Quinn，2024） | B | 暫停執行時連線可能變「聾」（等到逾時）或被 defunct（對方看到關閉）；鎖螢幕也會讓 App 進背景並可能被暫停執行 |
| N7 | https://developer.apple.com/forums/thread/734361 （Quinn，2023） | B | 裝置睡眠（通常鎖螢幕後不久）時 iOS 可能離開 Wi-Fi，喚醒後才重新加入；剛解鎖時網路可能還沒好 |
| B1 | https://developer.apple.com/forums/thread/75328 （Quinn，2017／2022） | B | AVPlayer 的 HTTP 請求在 mediaserverd 執行；時間較舊，未確認目前 iOS 是否仍然如此 |
| C3 | mpv-android `e185cdf53429653e3923a16f7453d7c523310319`、`4e7916ea995e07ad09eb4285c2b2f23c4f891cd1`（維護者 sfan5） | B | 背景改用 `vo=null`，因為它「doesn't throw away the cache or switch tracks. Generally this seems to be less buggy」 |
| C4 | mpv `185e63a3e2a84fe4d006054960481460072a8243`、`5a99015acf184a2989ea7ebf50ab2c990be41125`（wm4） | B | `reconnect_delay_max=7` 約 11 秒；網路逾時設 1 分鐘，因為 FFmpeg 預設「apparently infinite」 |

未能讀取：mpv #5793／#8529、mpv-android #839／#954／#1076、ExoPlayer #4078 的留言串（WebFetch 只顯示本文，api.github.com 對 mpv-player 回 403）。這些不影響第一階段的建議。

### 4. 成熟相關專案

| # | 來源 | 級 | 做法 | 適用性 |
|---|---|---|---|---|
| C1 | WebHTV Android（本 repo，`e352379cbbfe15b4f31a8807a859412e87e9aa0e`）`app/src/main/java/com/fongmi/android/tv/ui/activity/PlaybackActivity.java:845-878`、`app/src/mobile/java/com/fongmi/android/tv/ui/activity/VideoActivity.java:1867-1872`、`:6193-6199` | C | 背景時保留播放器不動；按播放時若播放器已 idle（出錯或停止）就先 `prepare()` 同一網址，沒有網址就重新解析 | Android 程序不會被暫停執行，所以「什麼都不做」在 Android 可行、在 iOS 不行；可借用的是「按播放時發現壞掉就重新準備」 |
| C2 | WebHTV Android `app/src/main/java/androidx/media3/mpvplayer/MpvPlayer.java:2960-2985` | C | 背景時 `vo=null`＋`force-window=no`，不切換影像軌 | 與 C3 一致；iOS 目前用 `vid=no`，列為延後的 O6 |
| C5 | Media3 1.11.0-alpha01（`aceb0bc9da047b1ddc29ed493af7a0751aeb8acb`）`DefaultLoadErrorHandlingPolicy`、`Loader.java:393-394`、`ExoPlayer.java` stuck detection | A／C | 載入錯誤最少重試 3 次，退避上限 5 秒；卡住緩衝偵測預設 600 秒 | 成熟預設也沒有快速的開播後卡住恢復；若加 O3 必須短得多 |
| C6 | AetherEngine `5b3388df4446e61fd3eaec32e32aa65693efd474` `AetherEngine.swift:711-715`、`:7174-7206`；Dionysus `88416d2fc6493a3bf6d9a4b0bf8442e020c55673` `AetherPlaybackEngine.swift:415-423`、`:534-627`；PR #225 | C（專案年輕，實效接近 D） | 暫停中進背景 15 秒後拆掉播放管線；`didBecomeActive` 時在原位置以暫停狀態重建，失敗就顯示錯誤；PR 記錄「先 autoplay 再 pause」會卡死，必須直接以暫停狀態載入 | 最接近的前例，支持 O2 與 O5；採用「以暫停狀態載入」與「失敗要顯示」 |
| C7 | SRGSSR pillarbox-apple `e6c2cae3ec13a651d9b7ccf01d96c65a3b724371` `Player+Replay.swift:27-51` | C | 出錯後重播＝新的 AVPlayerItem＋起始位置 | 支持以新 item 重新載入 |
| C8 | react-native-video `6dd359f8a4ef034e8e9cf2389d9242aa5bb4d992` `VideoManager.swift:494-528`；Swiftfin `777a5cadedc631154633f8afbf9607aa8648504e`；Flutter video_player_avfoundation `40b7e6446cf69367fc98fd019117ce117f6e6957` | C | 回前景都不重新載入；react-native-video 會在回前景時重新啟用音訊工作階段 | 大多數播放器沒有處理這個情境；支持加入音訊重新啟用 |
| C9 | MPVKit demo `f82e06d4f5ef4fc4aa9faba3782a462dbbef870c` `MPVMetalViewController.swift:97-110`；Flixor、Nuvio | C | 背景 `pause`＋`vid=no`，前景 `vid=auto` | WebHTV 沿用同一做法，同樣沒有處理暫停執行 |

### 5. 論壇與實地回報

| # | 來源 | 級 | 內容 |
|---|---|---|---|
| F1 | https://developer.apple.com/forums/thread/45850 | D | 暫停超過 1 分鐘後不再播放，必須重建 `AVPlayerItem`；`rate` 停在 1、`status` 不變成 failed；有 audio 背景模式也一樣 |
| F2 | https://developer.apple.com/forums/thread/3555 | D | 斷網後 player 維持 ReadyToPlay，切換暫停／播放無效，seek 不可靠，最後重建 player |
| F3 | https://developer.apple.com/forums/thread/88649 | D | 斷網只收到 stalled，之後「does not fail or recover on its own」 |
| F4 | https://developer.apple.com/forums/thread/669258 | D | 回前景後 AVPlayerLayer 與 AVPlayerViewController 都黑畫面，有時無法 seek |
| F5 | mpv #8529（本文） | D | 暫停後伺服器關閉閒置連線，恢復時 mpv 能重連（跳約 20 秒）；表示單純閒置斷線可恢復，額外因素在 iOS 暫停執行 |

論文與量測：NAT 逾時量測論文（IMC 2010、SIGCOMM 2011）的 PDF 主機被 proxy 擋，未讀；N6 的 RFC 下限已足以排除 1 分鐘內的 NAT 因素，這兩篇不會改變決策。

## 四、現況審查（重新載入會碰到的程式）

1. 播放器生命週期
   - 關閉播放器：`onDisappear` 先暫停、存進度再 `closePlayer`（`WebHTVApp.swift:4058-4064`）；`closePlayer` 不停止 engine（`:2162-2167`），`router.endSession` 在下一個 session 用同一核心時保留 engine（`ios/Sources/WebHTVCore/PlaybackEngine.swift:425-435`）。所以「已載入且暫停」不等於「播放器開著」，判斷條件必須用 router 的 session 狀態（`sessionActive`，`PlaybackEngine.swift:357`）。
   - 背景時存進度：`WebHTVApp.swift:2080-2084`。
2. 可參考的重新載入路徑
   - 換畫質 `selectQuality` 在目前位置重新載入另一個網址（`WebHTVApp.swift:2246-2261`）。
   - 換核心 `handOff` 在已播到的位置重新載入（`PlaybackEngine.swift:480-489`）。
   - AVPlayer 載入＝新 item＋`seek(to:)`＋依 `autoplay` 決定是否播放（`WebHTVApp.swift:2787-2800`）。
   - MPV 載入＝設 `start`、`speed`、`pause` 再 `loadfile … replace`（`MPVEngine.swift:352-364`）。
3. 失敗路徑
   - `engineFailed` 以 `request.autoplay` 換核心一次（`PlaybackEngine.swift:469-478`）；以暫停狀態載入時，換過去的核心也是暫停。
   - 開播逾時換核心固定 `autoplay: true`（`PlaybackEngine.swift:409-414`），重新載入不能重新啟動這個逾時。
   - MPV 首幀 watchdog 10 秒（`MPVEngine.swift:154-163`）：重新載入後如果 10 秒內沒有畫面，會走換核心。
4. 子母畫面：MPV 背景時若 PiP 啟用就不設 `vid=no`（`MPVEngine.swift:60`）；AVPlayer 的 PiP 還原在 `didBecomeActive`（`WebHTVApp.swift:3859-3872`）。
5. 前例型別：`ios/Sources/WebHTVCore/PictureInPictureForegroundRestoreState.swift` 是「背景記錄、前景消耗一次」的純邏輯型別，可以照這個形式寫並單元測試。
6. 既有測試：`ios/Tests/WebHTVCoreTests/PlaybackEngineTests.swift:256`（`aPausedPlayerMovesPaused`）旁可加 router 重新載入的測試。

## 五、方案比較

| 方案 | 內容 | 能否修好回報症狀 | 主要風險 |
|---|---|---|---|
| O0 不改 | 使用者自己關掉重開 | 否 | 問題持續 |
| O1 上游參數 | mpv 加 `stream-lavf-o=reconnect_on_network_error=1,…`、調低 `network-timeout`；AVPlayer 不改 | 部分（只有 MPV，而且仍要等逾時） | 太低會在弱網誤判斷線；太高仍然卡；AVPlayer 沒有對應參數 |
| O2 回前景重新載入（建議） | 確認暫停中被暫停執行後，回前景以同一核心、同一網址，在原位置以暫停狀態重新載入 | 是（兩個核心都用「重開」同一條機制） | 同網址可能已過期（第二階段處理）；判斷條件誤判時多一次重新緩衝 |
| O3 開播後卡住偵測 | 想播放但位置不前進超過 N 秒，重新載入一次，再失敗就顯示錯誤 | 部分 | 誤判面最大（弱網、HLS 切換、倍速）；應等第一階段證據 |
| O4 緩衝指示 | 等待資料時顯示轉圈，播放鍵依意圖切換 | 否（只改顯示） | 沒有恢復機制時，永遠轉圈比明確錯誤更差 |
| O5 背景時主動拆除 | 進背景約 15 秒後在 background task 內卸載，回來時重建 | 是 | background task 使用與時序競態；只在 O2 不夠時才考慮 |
| O6 MPV 改用 `vo=null` | 取代 `vid=no`／`vid=auto` | 否（避免清快取，但不能中止阻塞讀取） | 可能回退既有的背景黑畫面修正；iOS 上的安全性未驗證 |
| O7 反向移植 mpv `48e6c35c` | 讓 seek 中止 HLS 的阻塞 I/O | 部分（只有 HLS） | 要改 Libmpv 二進位，成本最高 |
| O8 重新啟用音訊工作階段 | 收到 `appWasSuspended` 後，下一次播放前 `setActive(true)` | 未知（可能修好「沒有聲音」，不能解釋 seek 無效） | 低；在回前景就啟用會打斷別的 App 的聲音，所以放在按播放時 |

判斷：上游做法（O1、O7）只涵蓋 MPV 的一部分，也仍要等待；WebHTV 需要**補充**上游：用 O2 做主要修正，O8 當作 O2 的一部分；其餘在有裝置證據後再決定。

## 六、建議：第一階段＝O2＋O8（單一 guard session、單一 commit）

1. **判斷型別（WebHTVCore，純邏輯，可單元測試）**，形式參考 `PictureInPictureForegroundRestoreState.swift`：
   - `didEnterBackground` 時記錄一次：播放器開著（router `sessionActive`）、已載入、使用者意圖是暫停、PiP 沒有啟用；以及位置、速率、進背景的時間。
   - `didBecomeActive` 時消耗記錄並清除（只決定一次）：記錄符合條件，而且確實被暫停執行過，才重新載入。
   - 偵測方式（實作時更正，見第十一節）：暫停中進背景後每 1 秒記一次「還在執行」；任兩次之間、或最後一次到回前景之間超過 3 秒，就是程序沒有執行（被暫停執行或裝置睡眠）。原本的 A「`appWasSuspended` 中斷」在 iOS 16 已停用，B「背景 ≥ 30 秒」一併移除。
   - 控制中心、通知中心、Face ID 只會觸發 resign／become active，不會觸發 `didEnterBackground`，所以沒有記錄可消耗，不會重新載入。
2. **Router**：在 `handOff` 旁新增 `reload(at:autoplay:)`（`PlaybackEngine.swift:480-489`）：同一核心、同一 target、不改 selection、不消耗換核心的次數。
3. **PlaybackSession.reloadCurrent**，參考 `selectQuality`（`WebHTVApp.swift:2246-2261`）：
   - 使用目前的網址與 headers，以及記錄的位置（不用 `currentTime`，卡住時可能不準）；
   - 以暫停狀態載入（C6 的教訓：不要先 autoplay 再 pause）；
   - 保留預解析工作（prefetch）；
   - 不重新啟動會強制 `autoplay: true` 的開播逾時；
   - AVPlayer 在 readyToPlay 後重新套用音軌與字幕；
   - 記一行 `[lifecycle]` log，內容是重新載入前的 engine 狀態（AVPlayer 的 `timeControlStatus`／`reasonForWaitingToPlay`，或 mpv 的 snapshot），之後有 Console 時可以直接取證。
4. **音訊工作階段（O8）**：偵測到暫停執行時設旗標；下一次按播放前呼叫 `setActive(true)`，成功後清旗標。MPV 重新載入時 ao 初始化本來就會啟用（`ao_audiounit.m:125`）。
5. **不改**：`vid=no`／`vid=auto`、mpv 網路選項、播放控制列 UI、AVPlayer 物件的擁有方式、Libmpv 二進位。
6. 失敗時沿用既有路徑：重新載入失敗或首幀逾時，會走既有的一次換核心，換過去的核心維持暫停；再失敗就顯示錯誤。不會自動播放。

## 七、驗收標準

1. 兩個核心：暫停後回主畫面或鎖螢幕 10 秒、60 秒、5 分鐘再回來。5 秒內看到暫停的畫面，位置與暫停時相差不超過 5 秒（依關鍵影格而定），不會自己開始播放。按播放後 5 秒內開始播放，圖示變成暫停鍵。
2. 重新載入不會自動播放，不會消耗換核心次數。播放中離開、PiP 啟用中、拉下控制中心或通知中心時，都不會重新載入。
3. 重新載入後，播放速度、選定的音軌與字幕都和離開前相同。
4. 重新載入後關掉播放器，從列表重開，會從暫停的位置續播。
5. 接近片尾時暫停，離開再回來，按播放後仍會自動下一集；預解析不會殘留。
6. 直播：暫停、離開、回來、播放，接近直播最新位置，不會出錯。
7. WebHome 內嵌播放清單：同一集重新載入，不重新解析，不出錯。
8. 既有行為不變：播放中背景繼續播放聲音、PiP 進出、MPV 背景黑畫面修正、換核心、換畫質。
9. 重新載入失敗時（例如回來時網路還沒好），最多走既有的一次換核心，仍維持暫停；之後顯示錯誤，不會靜默卡住，也不會自動播放。
10. `swift test` 通過，並新增判斷型別與 `PlayerRouter.reload` 的測試：同一 instance、不消耗換核心次數、帶入位置與速率、`autoplay` 為 false。這些測試要能在觸發條件或換核心規則被改壞時失敗。

## 八、真機測試（SideStore，無模擬器、無 Console 時以畫面判斷）

1. T0（目前版本，修改前）：暫停、鎖螢幕約 30 秒、回來、按播放，再等 2 分鐘不要碰。記錄會不會恢復、多久恢復。AVPlayer 與 MPV 各一次；知道的話記下是 m3u8 還是 mp4。
2. T1～T3：每個核心在已知時間點暫停，分別回主畫面 10 秒、鎖螢幕 60 秒、鎖螢幕 5 分鐘，回來看畫面與時間點，按播放確認 5 秒內開始。
3. T4：播放中離開 30 秒再回來，背景聲音行為與以前相同，不會重新緩衝或跳位置。
4. T5：播放中進 PiP 再回 App，PiP 照舊結束，不會重新載入或跳位置。
5. T6：在 PiP 小視窗內暫停，回主畫面 60 秒再回來，記錄行為（已知可能的缺口）。
6. T7：設 1.5×，暫停、鎖螢幕 60 秒、回來、播放，仍是 1.5×；MPV 再試 2× 以上。
7. T8：選非預設音軌與字幕，暫停、鎖螢幕 60 秒、回來、播放，兩者都保留。
8. T9：T2 之後關掉播放器，從觀看紀錄重開，從暫停位置續播。
9. T10：片尾前約 30 秒暫停，鎖螢幕 60 秒，回來播放，仍會自動下一集。
10. T11：直播頻道暫停，鎖螢幕 60 秒，回來播放，不出錯。
11. T12：WebHome 內嵌的一集暫停，鎖螢幕 60 秒，回來播放。
12. T13：暫停時拉下控制中心再收起，不會重新緩衝。
13. T14：暫停、開飛航模式、鎖螢幕 60 秒、解鎖前關飛航模式、回來。恢復或顯示錯誤，不會自動播放。
14. T15：暫停後鎖螢幕 30 分鐘以上（網址可能過期），回來播放，記錄是否顯示錯誤。這一項決定是否需要第二階段。

## 九、回滾

第一階段是單一 commit，只改 Swift 原始碼與測試，不動二進位、lock、patch 或 mpv 選項。`git revert` 該 commit 後由發版 workflow 重新建置；使用者也可以直接在 SideStore 裝回上一版。

## 十、未解與後續階段

1. 後續階段（每一項都要有裝置證據才做）：
   - 第二階段：重新載入回 4xx 或逾時，就沿用既有的重新解析路徑（`WebHTVApp.swift:2106-2117` 的 retry 形式）再試一次，處理會過期的網址（T15）。
   - 第三階段：O4 緩衝指示。
   - 第四階段：O3 卡住偵測或 O1 mpv 參數，只在第一階段後仍有缺口時做。
   - O6、O7 延後。
2. 未解：
   - 沒有失敗狀態的裝置 log；AVPlayer 機制未證實。若新 item 在第一階段仍無法恢復，就要考慮 O5 或重建 AVPlayer。
   - 同一網址重新載入是否足夠，要等 T15。
   - `willEnterForeground`（MPV 的 `vid=auto`）與 `didBecomeActive` 的先後沒有官方文件。設計只在 `didBecomeActive` 決定，不依賴先後順序。
   - AVPlayer 重新載入會重設自適應網路狀態與統計（`PlaybackNetworkMonitor`、variant 上限），回來後畫質選擇可能暫時不同。
   - 重新載入期間使用者就按播放：`control("play")` 直接呼叫 engine，會照常播放，但 router 記錄的 `autoplay` 仍是 false；之後若換核心，會回到暫停。影響小，實作時要有測試。
   - MPV 的 END_FILE 沒有 load 世代保護（`MPVEngine.swift:475-483`）；舊檔在 replace 前後送出的 EOF 可能觸發自動下一集。既有的「重開」也有同樣的競態，實作時要確認 replace 時舊檔送出的原因不是 EOF。
3. 另外觀察到的衝突（不在本任務範圍，先記錄）：
   - App 啟動時設 `.playback`／`.moviePlayback`，不可混音（`WebHTVApp.swift:27-28`）；
   - mpv ao 初始化時改成 `MixWithOthers`，uninit 時整個 App 的工作階段 `setActive(NO)`（`ao_audiounit.m:118-125`、`:238-241`）；
   - 用過 MPV 之後，AVPlayer 與 PiP 所依賴的工作階段設定可能已經被改掉。建議另開任務處理。

## 十一、實作紀錄（第一階段，2026-09-25）

使用者核准第一階段，並選擇「回到 App 就載入」。第二～四節的行號指 `e352379c`。

### 1. 與第六節設計的差異（實作與審查時發現）

1. **觸發條件改為背景心跳**：`AVAudioSession.InterruptionReason.appWasSuspended` 在 iOS 16.0 停用（Apple 文件 metadata：`deprecatedAt 16.0`，「wasSuspended reason no longer present」；`AVAudioSessionInterruptionWasSuspendedKey` 在 14.5 停用），App 部署目標是 17.0，這個條件永遠不會成立。
   - 改為：暫停中進背景後，每 1 秒記錄一次「還在執行」；任兩次之間、或最後一次到回前景之間超過 3 秒，視為程序曾經沒有執行，才重新載入。
   - 沒有被暫停執行（程序一直在跑）就不重新載入，避免無謂的重新緩衝。
   - 恢復後，睡著的心跳可能比 `didBecomeActive` 先執行；因此每一次心跳本身也會記下間隔，不會蓋掉證據。
2. **音訊（O8）**：旗標改由同一個偵測設定；`setActive(true)` 成功才清旗標，失敗下一次再試。除了按播放，自動播放的新項目（下一集）與重播也會先重新啟用。
3. **重新載入位置**：
   - 還在準備中的項目，沿用原本要求的起點；
   - 直播（沒有長度）用 0，回到最新位置；
   - 0 是真實位置（使用者拖回開頭），不再被 router 換成原本的續播點。
4. **不重新載入顯示錯誤中的項目**（`router.failure == nil`），避免錯誤訊息蓋在可播放的畫面上。仍在載入中的暫停項目也算（MPV 載入中回報為未載入，所以同時看 `.preparing`）。
5. **換集時清除待恢復的音軌**（`load()`），避免上一集的選擇套到下一集。

### 2. 修改的檔案

1. `ios/Sources/WebHTVCore/PausedBackgroundReload.swift`（新）：判斷型別，以及重新載入後要重選的音軌／字幕（`PlaybackMediaSelection.reselections(after:)`）。
2. `ios/Sources/WebHTVCore/PlaybackEngine.swift`：`PlayerRouter.reload(at:autoplay:)`。
3. `ios/WebHTVApp/Sources/WebHTVApp.swift`：
   - `PlaybackSession`：進背景記錄並啟動心跳、`didBecomeActive` 判斷、`reloadPaused`、音軌恢復、按播放前重新啟用音訊；
   - `PlayerView`：回報子母畫面狀態（`pictureInPictureActive`）。
4. 測試：`PausedBackgroundReloadTests.swift`（新，12 項）、`PlaybackEngineTests.swift`（新增 4 項 router 測試）。

### 3. 驗證

1. 本環境沒有 Swift（download.swift.org 被 proxy 擋，apt 沒有套件）：**未編譯、未執行測試**。第一次編譯會在發版 workflow。
2. 多代理審查兩輪，每個發現都再做一次反駁驗證：
   - 第一輪三個角度（編譯、行為退步、規格與測試），確認 8 項，除 MPV snapshot 外都已修正；
   - 第二輪針對心跳偵測改寫後的 diff，確認 2 項次要問題，修正 1 項（載入中的項目），另 1 項即 T6（見下方待辦）；
   - 第二輪的編譯審查沒有回傳結果，心跳相關程式沒有經過專門的編譯審查。

### 4. MPV snapshot 修正（已修正，第二個 commit `51501cde`）

1. **MPV 暫停重新載入後，App 以為在播放**：`MPVEngine.swift:353` 的 `Snapshot(loading: true, …)` 把 `paused` 重設為 false；mpv 的 `pause` 本來就是 yes，不會再送變更事件，所以 `isPlaying` 變成 true，播放鍵顯示暫停且按了無效。
   - 修正是一行：重設時帶入 `paused: !autoplay`。
   - 同一問題也影響既有的「MPV 暫停中換畫質」。
   - 使用者 2026-09-25 同意把 `MPVEngine.swift` 納入範圍，以第二個 guard session（`IOS-POC-23-MPV`）修正：`MPVPlayerCore.load` 重設 snapshot 時帶入 `paused: !autoplay`。第一個 commit 是 `440d671e`。
2. 已知缺口（不在第一階段範圍）：
   - T6：播放中進子母畫面，在小視窗裡暫停並在背景關掉小視窗，之後才被暫停執行；進背景當下不符合條件，所以不會重新載入。
   - 在 MPV 子母畫面視窗內按播放（`MPVEngine.swift:952`）不經過 session，不會重新啟用音訊。
### 5. 發布

以 `0.1.20 (21)` 發布（run `36100831753`，tag `ios-v0.1.20-b21` → `957dc518`），Release device build 第一次編譯即成功；細節見 `docs/IOS-POC-11-sidestore-release.md` 第二十一次發布。T0 需要舊版，更新後已無法測。

## 十二、真機驗收（`0.1.20 (21)`，2026-09-25）

使用者以 SideStore 安裝 `0.1.20 (21)`，依第八節逐項以選擇題回報。沒有 Mac，沒有 Console log，全部以畫面判斷；裝置型號、iOS 版本、網路（Wi-Fi／行動網路）、來源格式（m3u8／mp4）都沒有記錄。

### 1. 結果

| 項目 | 核心 | 結果 |
|---|---|---|
| T0 | — | 不適用（需要舊版） |
| T1～T3（回主畫面 10 秒、鎖螢幕 60 秒、鎖螢幕 5 分鐘） | 原生、MPV 各一次 | 通過：回來是暫停畫面、位置正確、不會自己播放；按播放 5 秒內開始 |
| T4 播放中離開 30 秒 | 未分核心 | 通過：背景繼續有聲音，不重新緩衝、不跳位置 |
| T5 播放中進子母畫面再回 App | 未分核心 | 通過：小視窗照常結束，不跳位置 |
| T6 在子母畫面小視窗內暫停，回主畫面 60 秒 | 未分核心 | 正常（見下方第 2 點） |
| T7 1.5×／2× | 未分核心 | 通過：速度保留 |
| T8 非預設音軌與字幕 | 未分核心 | 通過：兩者都保留 |
| T9 T2 之後從觀看紀錄重開 | 未分核心 | 通過：從暫停位置續播 |
| T10 片尾前約 30 秒暫停 | 未分核心 | 通過：仍會自動播下一集 |
| T11 直播 | 未分核心 | 通過 |
| T12 WebHome 內嵌 | 未分核心 | 通過 |
| T13 暫停時拉下控制中心再收起 | 兩個核心 | 通過（見下方第 3 點）：控制中心本身不觸發重新載入 |
| T14 飛航模式 | 未分核心 | 通過：回來後恢復正常，沒有自己播放 |
| T15 鎖螢幕 30 分鐘以上 | 未分核心 | 通過：回來可以播放，沒有顯示錯誤 |

### 2. T6 與已知缺口

1. T6 的做法是小視窗仍開著時回到 App。小視窗開著時，App 在背景沒有被暫停執行，所以不需要重新載入，結果正常符合預期。
2. 第十一節之四的缺口是另一種情況：在背景關掉小視窗之後才被暫停執行。T6 沒有涵蓋這個情況，程式也沒有改，所以這個缺口仍然存在，只是這次沒有測到。

### 3. T13 的另一個現象（不在本任務範圍，基準未知）

1. 使用者回報：暫停 10 秒～1 分鐘後按播放，兩個核心都要等幾秒才開始。
2. 對照：暫停同樣久但不拉控制中心，直接按播放，也要等。所以原因是「暫停一段時間後再播放」，和控制中心無關。
3. 不是本修正造成：
   - `ios/` 沒有任何 `willResignActive`、`scenePhase` 或音訊中斷的處理；
   - 本修正只在 `didEnterBackground` 記錄；
   - `didBecomeActive` 時沒有記錄就不動作（`PausedBackgroundReload.becameActive`）。
4. `0.1.19 (20)` 以前是否一樣，已無法用舊版比對；等待秒數沒有量。
5. 候選原因（未驗證）：
   - AVPlayer 恢復播放時會先等到有足夠資料才開始（第三節 A3）；
   - 伺服器關閉閒置連線，按播放時要重新連線（F5）。
6. 與第十節第三階段（緩衝指示）有關。**使用者 2026-09-25 決定先不處理**；之後要處理時另開任務，先量等待秒數再診斷。

### 4. 對第十節後續階段的影響

1. 第二階段（網址過期時重新解析）：T15 通過，依目前證據不需要。
2. 第三階段（緩衝指示）與第四階段（開播後卡住偵測或 mpv 參數）：第一階段之後沒有卡住的回報，沒有觸發的證據。上面第 3 點的等待現象，使用者決定先不處理。
3. O6、O7 維持延後。

## Recovery anchor

- 目標：修正「暫停後離開 App 再回來，兩個核心都卡住」。第一階段＝第六節 O2＋O8，驗收標準見第七節。
- 狀態（2026-09-25）：第一階段（`440d671e`）與 MPV snapshot 修正（`51501cde`）已以 `0.1.20 (21)` 發布，CI 編譯成功；單元測試未執行；**真機驗收 T1～T15 全部通過**（第十二節）。
- 相關檔案：`ios/Sources/WebHTVCore/PlaybackEngine.swift`（`PlayerRouter`）、`ios/WebHTVApp/Sources/WebHTVApp.swift`（`PlaybackSession`、`AVPlayerEngine`）、`ios/WebHTVApp/Sources/MPVEngine.swift`、`ios/Sources/WebHTVCore/PictureInPictureForegroundRestoreState.swift`、`ios/Tests/WebHTVCoreTests/PlaybackEngineTests.swift`。
- 未解：在背景關掉子母畫面小視窗後才被暫停執行不會重新載入（T6 未涵蓋），以及 MPV 子母畫面內按播放不重新啟用音訊（兩者見第十一節之四）；暫停一段時間後按播放要等幾秒（第十二節之三，與本修正無關）。
- 下一步（唯一）：無。第一階段已完成，後續階段依目前證據不需要；第十二節之三的等待現象，使用者 2026-09-25 決定先不處理。
