# IOS-POC-25 — HLS 串流中段廣告自動跳過（Android parity）

- 狀態（2026-09-26）：**已隨 `0.1.22 (23)` 發布**（使用者 2026-09-26 在發版 session 選「現在發，連 IOS-POC-25 一起」，見 `docs/IOS-POC-11-sidestore-release.md` 第二十三次發布）。Release build 編譯通過；單元測試未執行。第一次真機回報：原生仍露出不到約 1 秒的廣告開頭，正片未察覺缺少；MPV 未察覺廣告。診斷與待回報的免建置檢查見第二十節之二。
- IOS-POC-25-2（2026-09-26）：MPV 在有 `#EXT-X-DISCONTINUITY` 的播放清單上也自動跳廣告（進入區間 0.25 秒後才觸發），以連結期檢查綁定 WebHTV `Libavformat`（`45be83c4`）。**已隨 `0.1.24 (25)` 發布**（run `36230882448`，Release build 第一次即編譯、連結成功，見 `docs/IOS-POC-11-sidestore-release.md` 第二十五次發布）；單元測試未執行，真機未驗證。見第二十二節。
- 開始：2026-09-25 15:10 UTC。Lane：`standard`。Task guard：`IOS-POC-25`（`--no-tag`）。
- 授權：使用者 2026-09-25 明確要求建立並開發本項目，一次完成文件、實作、測試、commit 與 push（本任務的核准，AGENTS.md §7 的實作前核准在此成立）。不含 bump 版號、tag、SideStore release、IPA、安裝到 iPhone。
- 並行：另一個 session 同時開發 IOS-POC-26（MPV／原生切換位置）與 `0.1.22 (23)` 發布。本任務在 IOS-POC-26-1（`a6652cc3`）之上開發（第十三節記錄兩者的互動）。
- Ponytail：unavailable／skipped。

## 一、開始時的 Git 狀態

| 項目 | 值 |
|---|---|
| 工作分支 | `claude/ios-poc-25-hls-midstream-ad-skip-hmw1hc`，開始時等於 `main` 的 `5856232743d2b8ddd5b3730e676b197ff2c0a264`，worktree clean |
| `origin/ios-poc`（`git fetch` 後） | `0b0d0b5f3be990a89998c933a34ecd638c6256be`（`docs(ios): record the 0.1.21 (22) release`） |
| 處理 | 工作分支重設到 `origin/ios-poc`（沒有任何獨有 commit，不會遺失內容） |
| 開發中 `origin/ios-poc` 前進 | 另一個 session push `a6652cc3`（IOS-POC-26-1）；本任務尚未改動 `WebHTVApp.swift`，以 `git merge --ff-only` 前進後重新開啟 guard |
| 雲端環境 | 沒有 Swift／Xcode（`download.swift.org` 被 egress policy 擋，apt 沒有套件）；有 JDK 21，用來執行 Android 原始碼產生 golden（第十六節） |

## 二、Android 現行 HLS ad skip 真實資料流（`origin/main` `5856232743d2b8ddd5b3730e676b197ff2c0a264`）

### 1. 開關

`Setting.isAdblock()`（`app/src/main/java/com/fongmi/android/tv/setting/Setting.java:720`）讀 `Prefers.getBoolean("adblock", true)`，**預設開啟**；手機與電視設定頁的「智慧去廣」切換它。它同時控制 ExoPlayer、IJK 與 MPV 三條路徑，與設定檔的 `ads`、`rules` 無關。

### 2. ExoPlayer：直接播過濾後的 playlist

1. `ExoUtil.getMediaItem`（`ExoUtil.java:285`）呼叫 `builder.setAdblock(Setting.isAdblock())`。
2. Media3 fork 的 `HlsMediaSource`（`third_party/maven/androidx/media3/media3-exoplayer-hls/1.11.0-alpha01-fongmi/…-sources.jar`）把 `mediaItem.adblock` 交給 `DefaultHlsPlaylistParserFactory.setAdblock`。
3. `HlsPlaylistParser.parse`（sources jar `:375-381`）在解析任何 playlist 前，把整份文字交給 `HlsAdsParser.process(m3u8)`，之後解析的是**過濾後**的文字。
4. Exo 能安全刪 segment，是因為 `HlsMediaChunk` 依 `discontinuitySequence` 取得 `TimestampAdjuster`，把每個不連續區塊對齊到 playlist 累積時間（P10 文件第 1 節）。

### 3. `HlsAdsParser.process` 的判斷語意

來源：FongMi/media `13fbfd88d312de6c4f10fedd2b085cb2710b88ae`（2026-05-22，`release-1.11.0-fongmi`），WebHTV jar 內容相同。

1. 沒有 `#EXT-X-ENDLIST`（直播）就原樣回傳。
2. **第一段：檔名與路徑**。把 segment 行分組：絕對網址用 `scheme://host`，相對網址用目錄，沒有斜線用 `NO_PATH`。
   - 有 2～10 組、最大組超過一半：比最大組小的所有組都是廣告。沒有長度、數量或 discontinuity 的限制。
   - 分組不適合時改前綴分析：長度 5 到「最短行 − 4」，找出 2～10 組且最大組 ≥ 85% 的最佳長度，其餘組是廣告。
3. **第二段：不連續區塊**（第一段沒找到時）。以 `#EXT-X-DISCONTINUITY` 切塊，**最後一塊不分析**。
   - 取眾數區塊大小（同頻率取大者）；小於眾數 × 0.75 的區塊是廣告。
   - 沒有這種區塊且眾數 × 2 小於最大區塊：不大於眾數的區塊都是廣告。
   - 廣告區塊數要在 1～上限之間，上限依總長：≤30 分 3、≤60 分 4、≤90 分 5，其餘 6。否則不判定。
4. 重建：刪除廣告的 `#EXTINF` 到 URI 之間的所有行（它之前的 key、discontinuity 保留），再刪孤立的 `#EXT-X-DISCONTINUITY`。

### 4. MPV：保留原始 playlist，只記錄 source-time 區間

`MpvHlsProxy.applyAdblock`（`MpvHlsProxy.java:809-842`）：

1. 只處理 `isVodPlaylist`（大寫後含 `#EXT-X-ENDLIST`）的**影像** playlist：直接的 media playlist，或 master 裡 `VARIANT_PLAYLIST` 角色、kind 為 `STREAM` 的 variant。音軌、字幕、I-frame playlist 不產生計畫。
2. `filtered = HlsAdsParser.process(text)`，`HlsAdTimeline.from(text, filtered)` 算出區間。直接 playlist 存到 `directAdTimeline`；variant 存到 `adTimelines`，同一 variant 再讀一次時切點不同就變 `NONE`（`merge`）。
3. **回傳原文**（註解：「Keep timestamps, implicit AES IVs, byte ranges and rendition synchronization intact; MpvPlayer skips the detected time ranges」）。任何例外都回原文。

`HlsAdTimeline.from`（`HlsAdTimeline.java`）：

1. 兩份 playlist 都要能解析：以 `#EXTM3U` 開頭、有 `#EXT-X-ENDLIST`、沒有 `STREAM-INF`／`PART`／`SKIP`／`I-FRAMES-ONLY`、每個 URI 前都有合法 `#EXTINF`（`BigDecimal`，scale −12～18，四捨五入到微秒，必須 > 0）、最多 100,000 段、總長不溢位。
2. 過濾後的 segment（URI、微秒長度、`BYTERANGE` 字串三者相同）必須是原清單的子序列，而且**最早與最晚的對應必須是同一組**，否則 `ambiguous-segments`，整份不跳。
3. 被刪的連續 segment 在原時間軸上成為區間；遇到保留的 segment 或 discontinuity 就先結束一個區塊，**每個區塊單獨檢查 ≤ 120 秒**，超過就保留不跳（`exo-hls-detector-long-blocks-preserved`），通過的相鄰區塊再合併。
4. 取整向內：起點進位、終點捨去到毫秒。

### 5. `MpvPlayer` 怎麼跳

| 函式 | 行為 |
|---|---|
| `adTimeline(selectedBitsPerSecond)` | `kernel == MPV && Setting.isAdblock()` 且 session 是 VOD 才有；`resolveAdTimeline(direct, variants, selected, declared)` |
| `resolveAdTimeline` | direct 優先；否則只看 `STREAM` variant，已知選擇時只看頻寬相符者，所有被看的計畫必須 `sameCuts`；**選擇未知時，每個宣告的一般影像 variant 都要有計畫而且一致**（「Probing a rendition does not mean it is selected」） |
| `resolveHlsAdSeekTarget` | 使用者 seek、起播位置落在區間內，改到區間終點 |
| `maybeSkipHlsAd` | `time-pos` 更新時，`fileLoaded && playbackRestarted && playWhenReady` 才判斷；`SkipState` 讓同一區間只 seek 一次 |
| 清除 | 手動 seek、`START_FILE`、`stopInternal`、換媒體時清除 `SkipState` 與邊界 |
| 選擇的位元率 | `cachedSelectedHlsBitrate`：選中影像軌的 `track-list/N/hls-bitrate` |

### 6. native-output-boundary（`MpvHlsAdBoundaryState`，`8dd32cb9`）

1. 把下一個廣告起點寫進 `file-local-options/end`，同時 `keep-open=always`、`keep-open-pause=no`、`loop-file=no`。mpv 的 `get_play_end_pts` 在畫面輸出前就丟掉邊界之後的影格，所以廣告第一格不會閃出來。
2. `eof-reached` 在廣告起點 ±250 ms、沒有手動 seek 時才算廣告邊界；先設好下一個邊界，再精確 seek 到廣告終點。終點在片尾時當成真正結束或循環。
3. 使用者自己設了 `end`、`length` 或 AB loop 時不接管。只還原自己寫過的選項。
4. 真機（vivo V2453A）：色塊測試 661 格、廣告紅格 0；真實網址在 496301 ms 截停、跳到 512786 ms。

### 7. 為什麼 MPV 不刪 segment

歷史：`914b7a74`（2026-07-09）讓 MPV 播刪過的 playlist；`b5f4129e`（2026-08-07）因 `mpv-ts-timestamp-integrity` 改回原文；`80fea003`、`76a78c34`、`8dd32cb9`（2026-09-17）改成 source-time seek、區塊驗證與 120 秒、native boundary。理由（P10 文件與 mpv／FFmpeg 原始碼）：

1. **implicit AES IV**：沒有 `IV` 屬性時 IV 是 media sequence number（RFC 8216 §5.2；FFmpeg `hls.c:871-884`）。刪段會讓後面每一段的 IV 位移，解密出錯。
2. **byte range**：沒有 `@offset` 的 `EXT-X-BYTERANGE` 接在前一段之後（RFC 8216 §4.3.2.2；`hls.c:990-997`）。刪段會讓後面每一段的偏移錯位。
3. **timestamp**：FFmpeg 不依 discontinuity 重新對齊時間戳；刪段留下的缺口會讓 MPV 的時間軸錯亂。
4. **rendition 同步**：FFmpeg 開檔時讀每個 variant 與 rendition，依 DTS 交錯輸出（`hls.c:2172-2186`、`:2601-2616`）；只刪某一條會讓音畫在 seek 或換軌時失去同步。

### 8. fail-safe 條件（Android）

VOD 以外、任何解析失敗、非子序列、對應不唯一、區塊 > 120 秒、variant 不一致或不齊、選擇未知且缺 variant、開關關閉、例外，都是「沒有區間」，照常播放。

## 三、舊 IOS-POC-5S 文件為何已不足以代表 Android 現況

`docs/IOS-POC-5S-ads-and-skip.md`（2026-09-22／23）寫的是：

> m3u8 廣告規則：在這個 Android app 裡沒有消費者……所以「不實作 HLS mid-stream 廣告」不只是保守，是根本沒有契約可以移植。

1. **當時的結論只對設定檔 `rules` 成立**：`wang-sex.json` 的 9 條 `#EXT-X-DISCONTINUITY`／`15.1666`／`16.63` regex，消費者確實只有 `Sniffer`，拿來比對網址永遠不命中。這一點現在仍然成立，本任務也沒有改變它（`theRulesNeverTouchAPlaylist` 照舊）。
2. **但它把「設定檔規則沒有消費者」寫成「Android 沒有 m3u8 廣告處理」**。實際上 Android 有一條與設定檔無關的內建路徑：Media3 fork 的 `HlsAdsParser`（2026-07-05 起 vendored）加 `Setting.isAdblock()`；而 MPV 的 source-time 跳過、120 秒保留與 native boundary 在 2026-09-17 才加入（第二節之七），比 5S 文件晚，也從未被 iOS 文件記錄。
3. 因此本項目的規格來源是 Android 內建 detector 與 MPV 的時間軸語意，**不是**那 9 條 regex；那些 regex 依使用者要求維持 inert，沒有被重新定義成 playlist 規則。

## 四、最佳實務研究（2026-09-25 讀取）

以三條並行研究線與本機程式碼完成。等級：A＝規格、官方文件或原始碼；B＝維護者討論或 PR；C＝成熟專案程式碼；D＝論壇或部落格。

### 1. 上游原始碼與測試

| # | 來源與版本 | 等級 | 支持的論點 | 對決策的影響 |
|---|---|---|---|---|
| S1 | Android `HlsAdsParser.java`（Media3 fork jar，FongMi/media `13fbfd88`） | A | 第二節之三的完整判斷語意 | Swift 逐條移植，不另創演算法 |
| S2 | Android `HlsAdTimeline.java`、`MpvHlsProxy.java`、`MpvPlayer.java`、`MpvHlsAdBoundaryState.java`、`HlsPlaylistRewriter.java`（`origin/main` `5856232`） | A | 第二節之四到之六 | 時間軸、variant、跳過規則照 Android |
| S3 | Android 測試 `HlsAdTimelineTest`（13）、`MpvHlsAdblockTest`（6）、`MpvHlsAdBoundaryStateTest`（6） | A | Android 自己的期望數字 | 全部移植成 Swift 測試 |
| S4 | FFmpeg `libavformat/hls.c` n8.1.2 `38b88335`（MPVKit 1.0.0 使用，未修改） | A | 整份檔案沒有任何 discontinuity 處理；seek 以 `first_timestamp` 加 EXTINF 選段，再丟棄封包直到**原始** DTS ≥ 目標（`:2575-2598`、`:2677-2760`） | 有 discontinuity 的 playlist 上，MPV 的 `time-pos` 不是 source time，source-time seek 會丟掉正片 |
| S5 | FongMi/FFmpeg `177f090e`（Android 用，9.0.1-fongmi）`libavformat/hls_timestamp.c` | A | Android 的 FFmpeg 會把 discontinuity 後的時間戳對到 playlist 時間軸 | Android MPV 的前提在 iOS 不成立 |
| S6 | FFmpeg master `848fb754`、`e27ad576`、`f6fa0d3f`、`caa3fa6a`（不在 n8.1.2） | A／B | n8.1.2 seek 到分段邊界時，若第一個關鍵影格的 DTS 略小於 EXTINF 起點，會被丟掉並晚一整段 | MPV 落點改在廣告最後一段內（終點前 0.1 秒） |
| S7 | mpv v0.41.0 `41f6a645`：`DOCS/man/options.rst`（`end`、`keep-open`）、`player/playloop.c:983-1004`、`:1226-1247`、`player/video.c:512-519`、`player/command.c:3807-3809` | A | `end` 在 `keep-open=no` 時到點就 `END_FILE(EOF)`；`keep-open=always` 抑制真正片尾的 `END_FILE`；`end` 比較的是解碼後 PTS；`file-local-options` 每檔還原 | native boundary 在 iOS 需要改寫 MPV 的結束契約（第十一節） |
| S8 | mpv `demux/demux_lavf.c:1278-1301`、`player/playloop.c:340-346` | A | `time-pos` 是原始 PTS 減起始時間；`ts_resets_possible` 不會重新對齊 | 同 S4 |

### 2. 規格與官方文件

| # | 來源 | 等級 | 支持的論點 | 對決策的影響 |
|---|---|---|---|---|
| R1 | RFC 8216（鏡像 kim-company/membrane_hls_plugin `1158436d` 與 shiguredo/m3u8-rs `bf997230`，兩份 SHA-256 相同 `954910a5…`；rfc-editor.org 被擋）§4.3.2.1、§4.3.2.2、§4.3.2.3、§4.3.3.4、§5.2、§6.2.4、§6.3.2 | A | EXTINF 累加即播放清單時間；BYTERANGE 隱含偏移；discontinuity 用於時間戳或格式改變；VOD 不再變；隱含 IV；variant 內容與時間戳一致；跨 variant 以播放清單時間定位 | 區間以 EXTINF 累加表示；不刪段；VOD 限定 |
| R2 | draft-pantos-hls-rfc8216bis-wwdc2026（Apple 提供的 PDF）§4.4.4.9、§4.4.5.2、§4.4.5.3 | A | `PART`、`SKIP`、`PRELOAD-HINT` 屬 LL-HLS | 看到就 fail closed |
| R3 | Apple `AVPlayerItem.duration`、`addBoundaryTimeObserver`、`addPeriodicTimeObserver`、`seek(to:toleranceBefore:toleranceAfter:)`、`forwardPlaybackEndTime`、`AVPlayerItemAccessLogEvent.playbackType`（DocC JSON；AVFoundation 標頭 MacOSX11.3.sdk） | A | boundary observer 不保證觸發、應以 `currentTime` 判斷；`forwardPlaybackEndTime` 到點會送 `DidPlayToEndTime`（會觸發 auto-next）；duration 不保證等於 EXTINF 總和 | 不用 `forwardPlaybackEndTime`；以位置判斷；**執行期比對 duration** |
| R4 | Apple HLS Authoring Specification（2025-06-26）3.1、7.1、8.1、8.15；Incorporating Ads into a Playlist | A | 廣告以 discontinuity 插入 media playlist；EXTINF 累加要在一格內準確；所有 variant 的 discontinuity 同時出現 | AVPlayer 以播放清單時間播放插播廣告，是本設計的前提 |

### 3. 成熟專案

| # | 來源 | 等級 | 支持的論點 | 對決策的影響 |
|---|---|---|---|---|
| P1 | Kodi `VideoPlayer.cpp:2734-2866`（`495c12af`） | C | 只在音畫同步後判斷，每個區段只跳一次 | 「引擎確實在播」才判斷（第九節的前進檢查） |
| P2 | po5/mpv_sponsorblock `sponsorblock.lua`（`7785c147`） | C | 觀察 `time-pos`、跳到終點、記錄已跳、換檔清除 | 與 Android `SkipState` 同型 |
| P3 | GiZGY/LibreTV PR #26（2026-09-05 合併）、`48cfe79a` | B／C | 刪除 discontinuity 破壞時間戳、提早結束，已停用過濾 | 支持不改 playlist |
| P4 | luoxiaohei/dongguatv `89c2a99f` `ad-filter.js` 註解 | C | CDN 每次請求插入不同廣告，計畫只對讀到的那份有效 | iOS 讀兩次必須一致、並比對引擎 duration |
| P5 | Decohererk/DecoTV `c02a9db1` `ad-filter.ts:125`、`:183` | C | 預計移除過多（35%）時退回、有保底 | iOS 的比例上限（採更保守的 25%） |
| P6 | Chongjian528/MoonTV `d95b3657`（PR #1、#2、#5） | B／C | 120 秒以上的群組不當廣告；隨機雜湊檔名曾造成誤判 | 與 Android 120 秒一致；誤判風險真實存在 |

### 4. 論文與部落格

沿用 Android P10 第 3 節已讀的 Ramires 等（2018，音訊廣告偵測）與 SponsorBlock 作者部落格（2019-07-18）：論文方法需要解碼與訓練資料，不適用於 playlist 偵測；部落格的「區間合併、避免重複跳」已由 `SkipState` 涵蓋。本任務沒有會被新論文改變的決策，因此不另外檢索。

### 5. 無法取得的來源（沒有繞過）

rfc-editor.org、datatracker.ietf.org、trac.ffmpeg.org、code.ffmpeg.org、greasyfork.org、codeberg.org、developers.google.com 被 proxy 回 403；非本 session 範圍的 GitHub issue 頁面被拒。RFC 8216 改讀兩份一致的鏡像；其餘列為未讀。

## 五、iOS 現況審查（接點）

| 位置 | 現況 | 本任務 |
|---|---|---|
| `PlaybackSession.load(_:autoplay:)` | 每個新項目（開片、下一集、換畫質、WebHome 內嵌、重播清單）都經過它，組 `PlaybackLoadRequest` 交給 `router.open` | 開始這個項目的廣告監看 |
| `PlaybackSession.seek(toSeconds:)` | 控制列 scrubber、±10 秒、拖曳手勢都經過它 | 落在廣告內時改到終點 |
| `control("replay")`、`control("stop")` | 循環重播直接呼叫 `engine.seek(0)`；停止拆掉 engine | 重播視為使用者 seek；停止時結束監看 |
| `router.onEngineChange`、`reloadPaused` | 手動切換、fallback、IOS-POC-22 高倍速交接、17F 逾時、IOS-POC-23 暫停重載 | 忘記「已跳過哪些區間」 |
| 5 秒 sampler | `persist`、網路狀態、預解析、片尾（`reachedEnding` → `finished()`） | 不改；片尾判斷的優先權見第十四節 |
| `AVPlayerEngine`、`MPVEngine`、`PlayerRouter` | IOS-POC-26 正在修改交接位置 | **完全不改**；只讀 `currentTime`、`duration`、`rate`、`isPlaying`、`kind`，只呼叫 `seek` |
| 設定頁「預設播放器」 | 既有 | 下方新增「智慧去廣」開關 |
| IOS-POC-5S-1／5S-3 | 嗅探 WebView 的 `ads`、`rules` | 不相關，不改 |

## 六、方案比較

| 方案 | 內容 | 正確性與風險 | 結論 |
|---|---|---|---|
| A 不改 | iOS 照播廣告 | 沒有回歸；不滿足需求 | 否決 |
| B 上游原樣（Exo 做法） | 以 `AVAssetResourceLoader` 或本機 proxy 把過濾後的 playlist 交給播放器 | 要重寫 AVPlayer 的載入（使用者禁止）；MPV 刪段破壞 IV、byte range、時間戳（第二節之七）；誤判會永久刪掉正片 | 否決 |
| C 上游原樣（Android MPV 做法全套） | source-time seek 加 native-output-boundary，兩個核心同樣行為 | AVPlayer 可行；**MPV 在 iOS 的 FFmpeg 上不成立**：有 discontinuity 時 `time-pos` 不是 source time，source-time seek 會丟正片（S4、S5）；native boundary 需要改寫 MPVEngine 的結束契約（第十一節） | 部分採用 |
| **D WebHTV 調整版（採用）** | 同一份 Swift detector／timeline／計畫；兩個核心都以既有位置讀值與既有 `seek` 跳過；iOS 自己讀 playlist，加上執行期證據與更保守的保護；MPV 只在時間軸可證明一致時動作 | 對 AVPlayer 等同 Android 的 MPV 語意；對 MPV 只在安全子集動作；任何不確定都不跳 | **採用** |
| E D 加 MPV 選擇位元率 | 讀 MPV `track-list` 的 `hls-bitrate` 縮小 variant 範圍 | 只能讓 MPV 多跳；要改 `MPVEngine`（與 IOS-POC-26 重疊）；AVPlayer 會自動切換 variant，無法採用 | 暫緩 |

判斷：Android 的方案要**補充**（iOS 分開讀 playlist 的風險）與**修正**（MPV 在 iOS 時間軸不同），不能原樣移植。

## 七、Android／iOS 功能差異

| 項目 | Android | iOS（本任務） | 方向 |
|---|---|---|---|
| detector | `HlsAdsParser` | 逐條移植（`HLSAdsParser`），26 筆語料與 Android 輸出逐位元組比對 | 相同 |
| 時間軸 | `HlsAdTimeline` | 逐條移植（`HLSAdTimeline`） | 相同 |
| 讀 playlist 的人 | 播放器經過本機 proxy，分析的就是播放器讀到的那份 | App 在引擎開啟媒體後另外讀；**有區間時讀兩次必須一致**；引擎 duration 必須與計畫相差 ≤ 1 秒 | iOS 更保守 |
| variant | 已知選擇時只看相符者；未知時全部一致 | **永遠要求全部一致**（AVPlayer 會自動切換 variant，不存在「已選那一條」）；最多讀 8 個 variant | iOS 更保守 |
| 計畫合理性 | 無 | 跳過總長 > 25% 或區間數超過 detector 自己的斷點上限（3／4／5／6）就不採用 | iOS 更保守 |
| 判斷時機 | `time-pos` 事件，`playbackRestarted` 之後 | 引擎無關的監看：0.1 秒（距下一個起點不到 0.1 秒時睡到起點），且必須看到播放頭以播放速率前進 | 等價 |
| 手動 seek 進廣告 | 改到終點 | 改到終點；之後等播放頭到達新位置才恢復自動判斷 | 相同，加保護 |
| 自動跳過後 | 無檢查 | 落點不在目標附近（早 0.25 秒以上或晚 1.5 秒以上）就停止該核心本項目的跳過 | iOS 更保守 |
| MPV 時間軸 | FongMi FFmpeg 對齊 discontinuity | FFmpeg n8.1.2 不對齊：**playlist 有 `#EXT-X-DISCONTINUITY` 時 MPV 不跳**；其餘落點在終點前 0.1 秒。IOS-POC-25-2 起改為進入區間 0.25 秒後才跳（第二十二節） | iOS 更保守 |
| native-output-boundary | 有 | **沒有**（第十一節） | iOS 可能露出廣告最初約 0.1 秒 |
| ExoPlayer 刪段 | 有 | 不適用（iOS 沒有 Exo，也不刪段） | — |
| 片尾（ending）| 各自獨立 | 片尾之後的範圍交給片尾處理，跨過片尾的廣告只跳到片尾點 | iOS 明確定義 |
| 開關 | `Setting.isAdblock()`，預設開 | `HLSAdSkipPreference`（`webhtv.playback.hlsAdSkip`），預設開；設定頁「智慧去廣」 | 相同 |
| 選擇未知時的 `resolveAdTimeline` 參數 | `cachedSelectedHlsBitrate` | 固定 0 | 見方案 E |
| `EXTINF` 數字 | `BigDecimal` 接受任何 Unicode 數字 | 只接受 ASCII 數字 | iOS 更保守 |
| 秒轉毫秒 | `Math.round` | 捨去（進入區間最多晚 1 毫秒） | iOS 更保守 |

## 八、Swift detector 設計（`ios/Sources/WebHTVCore/HLSAdsParser.swift`）

1. `HLSAdsParser.process(_:)` 對應 `HlsAdsParser.process`：兩段策略、所有常數、同頻率取大者的眾數、最後一塊不分析、門檻表、重建與孤立 discontinuity 規則全部照 Java。
2. **Java 字串語意**：每一行以 UTF-16 code unit 陣列處理。
   - 分組與前綴長度用 UTF-16 單位（Java `length()`／`substring`），分組鍵是 `[UInt16]`，等值比較等同 `String.equals`。Swift `String` 的比較採 canonical equivalence，會把 Java 視為不同的網址合併，所以不能直接用。
   - `trim()` 是去掉 U+0020 以下的字元，不是 Unicode 空白。
   - 切行等同 `split("\\r?\\n", -1)`。
3. `JavaText.parseDouble` 對應 `Double.parseDouble`（只用於門檻表的總長）：前後 U+0020 以下字元、`NaN`、`Infinity`、`f`／`d` 後綴、十六進位浮點都照 Java。
4. 沒有會丟例外的路徑；任何無法判斷的情況都回傳原文。

## 九、共用 ad timeline 模型（`HLSAdTimeline.swift`、`HLSAdSkip.swift`）

1. `HLSAdTimeline.from(original:filtered:)`：第二節之四的每一條規則，含 `ambiguous-segments`、`not-a-subsequence`、120 秒（含）的區塊檢查、向內取整、相鄰區塊合併，reason 字串與 Android 相同（寫進 log）。
2. `JavaBigDecimal.microseconds`：以整數計算 `BigDecimal` → scale 檢查 → `movePointRight(6).setScale(0, HALF_UP).longValueExact()`，不經過 `Double`。
3. `SkipState`、`skipTargetMs`、`nextRange`、`range(at:)` 與 Android 相同（半開區間 `[start, end)`）。
4. `Variant`、`declaredVariantCount`（`buildVariantLadder` 的數量）、`resolve`（`resolveAdTimeline`）照 Android；以固定順序走訪，只讓 log 的 reason 與雜湊無關。
5. `HLSAdPlan`：一個項目的計畫＝時間軸＋「背後任一 media playlist 是否有 `#EXT-X-DISCONTINUITY`」。`timeline(for:)` 決定哪個核心可以用。
6. `HLSAdPlanner`：讀 playlist、解析 master（`HlsPlaylistRewriter` 的 `STREAM-INF`＋URI 配對與 `attributeValue` 語意，含它在引號內逗號也會切開的行為）、讀兩次、合理性上限。
7. `HLSAdSkipper`：一個項目的所有決策，純值型別，兩個核心共用。

## 十、AVPlayer integration

1. `PlaybackSession.load` 在 `router.open` 之後呼叫 `watchAds(url)`：開始新的 generation，網址不含 `m3u8` 就立刻結束（行為與以前完全相同）。
2. 監看 Task 每 0.25 秒看一次，直到引擎回報 duration（AVPlayer 在 `readyToPlay` 之後，也就是 AVPlayer 自己已經讀過 playlist 之後），才以相同網址與 headers 在背景讀 playlist（一次性網址會先被播放器用掉，不會被 App 搶先）。
3. 計畫沒有區間就結束監看。有區間時每 0.1 秒讀 `currentTime`、`duration`、`rate`、`isPlaying`；距下一個廣告起點不到 0.1 秒就睡到起點。
4. 播放頭在區間內而且確實在播 → `engine.seek(toSeconds: 終點)`，也就是既有 `AVPlayerEngine.seek` 的零容差 seek；AVPlayer 架構、`loadNative`、`AVPlayerEngine` 都沒有改。
5. 不用 `forwardPlaybackEndTime`（到點會觸發 auto-next，R3），也不用 boundary observer（不保證觸發，R3）。
6. 尾端廣告：終點就是片長，seek 到片長讓 AVPlayer 自己播完，走既有的 `didPlayToEndTime` → `finished()`。

## 十一、MPV integration

### 1. 做了什麼

1. 與 AVPlayer 共用同一份計畫與同一個 `HLSAdSkipper`，讀 `MPVEngine` 既有的 snapshot，呼叫既有的 `seek`（`absolute+exact`）。**`MPVEngine.swift` 沒有任何修改**。
2. MPV 一樣保持原始 playlist；timestamp、implicit IV、byte range、rendition 同步都交給 mpv／FFmpeg 原樣處理。
3. **有 discontinuity 的 playlist 上 MPV 不跳**（手動 seek 也不改寫）。原因見第四節 S4、S5：iOS 的 FFmpeg 不把 discontinuity 後的時間戳對到 playlist 時間軸，`time-pos` 不是 source time；在這種 playlist 上以 source time seek 過廣告，FFmpeg 會丟掉封包直到 DTS 追上目標，等於丟掉約一個廣告長度的正片。IOS-POC-26 的 RC3 也獨立得到相同結論。
4. 沒有 discontinuity 時落點在終點前 0.1 秒（廣告最後一段內），避開 n8.1.2 邊界 seek 晚一段的問題（S6）。代價是最多多看 0.1 秒廣告。
5. 實際效果：插播廣告幾乎都帶 discontinuity，所以**在 iOS 的 MPV 上，大多數含廣告的影片目前不會自動跳過**，改用原生播放器才會跳。要讓 MPV 完全對齊 Android，需要把 FongMi 的 `hls_timestamp.c` 對齊（與 S6 的 seek 修正）移植到 iOS 的 FFmpeg；那是替換二進位的獨立任務，需要使用者核准，也與 IOS-POC-26-2 的研究有關。
6. **IOS-POC-25-2 更新**：`0.1.23 (24)` 起 App 連結 WebHTV `Libavformat`（IOS-POC-26-2b），第 3、5 點的限制已解除，改為進入區間 0.25 秒後才跳，見第二十二節。

### 2. native-output-boundary：本階段不做

研究結論（S7）：iOS 的 Libmpv（mpv v0.41.0）**有** `end`、`keep-open`、`keep-open-pause`、`eof-reached`，技術上可以做；但在目前的 iOS 程式上不能安全地做：

1. `MPVEngine` 唯一的結束訊號是 `END_FILE(EOF)`（`MPVEngine.swift` 的 `drain`）。只設 `end` 而不改 keep-open，到廣告起點就會被當成整集結束並 auto-next；廣告在 0 秒時還會是 `NOTHING_TO_PLAY` 錯誤。
2. 設 `keep-open=always` 之後，真正的片尾也不再送 `END_FILE`，必須另外觀察 `eof-reached` 並自己產生結束，等於改寫 MPV 的結束、auto-next 與 WatchHistory 契約，而且要處理重複 EOF、手動 seek、循環、使用者的 `end`／AB loop 與選項還原（Android 用了一個狀態機與兩輪真機修正）。
3. `end` 比較的是解碼後的 PTS。第 1 點的 gate 只允許沒有 discontinuity 的 playlist，本來就只有這個子集能用；在有 discontinuity 的 playlist 上它和 seek 有同樣的時間軸問題。
4. 本環境沒有 Swift、模擬器或真機，無法做 Android 那樣的逐格驗證；`MPVEngine.swift` 又是 IOS-POC-26 正在修改的檔案。

差異：MPV（與 AVPlayer）在廣告起點後最多約 0.1 秒（監看間隔加 seek 時間）才跳，可能露出廣告最初的畫面。這是 Android 在 `8dd32cb9` 之前的行為。之後若要做，前置條件是 MPV 的 discontinuity 時間軸先解決，並有模擬器或真機可以驗證 `eof-reached` 流程。

## 十二、multi-rendition／selected quality

1. master playlist：讀出所有 `#EXT-X-STREAM-INF` variant（最多 8 個，多於 8 個整份不跳），相對網址以 master 最後的網址（轉址後）解析，每個 variant 各讀（有區間時讀兩次）。
2. `resolve` 固定以「選擇未知」呼叫：**每個宣告的一般影像 variant 都要讀得到，而且切點與總長完全一致**，否則不跳。讀不到、不一致、同一 variant 宣告兩次但切點不同，都不跳。
3. 音軌 rendition（`#EXT-X-MEDIA`）與 I-frame playlist 不讀、不計入，與 Android 相同。
4. 為什麼不照 Android 用「已選位元率」：AVPlayer 會在播放中自動切換 variant，沒有固定的「已選那一條」；要求全部一致後，不論它切到哪一條，區間都成立。MPV 同樣使用這條更保守的規則（方案 E 暫緩）。
5. **畫質（WebHTV 的 `PlaybackQualityChoice`，來源給的多個網址）改變**：`selectQuality` 會以新網址呼叫 `load`，新的 generation 會丟掉舊計畫；舊畫質的計畫即使晚到也不會被採用。

## 十三、seek／pause／resume／engine switching

| 情境 | 行為 |
|---|---|
| 使用者 seek 進廣告 | 落在終點（MPV 為終點前 0.1 秒），片尾範圍內除外 |
| 使用者 seek 到廣告外 | 不改 |
| 任何使用者 seek 之後 | 忘記已跳過哪些區間（往回 seek 會再跳一次）；等播放頭出現在新位置附近（1 秒內）或 3 秒後，才恢復自動判斷，避免 seek 前的舊讀值把播放拉走 |
| 暫停中 | 不跳；按播放、看到播放頭前進後才判斷 |
| 在廣告前暫停、之後播放 | 播到廣告起點時跳過 |
| 從廣告邊界附近續播 | 起點在區間外不動；在區間內，播放一開始就跳到終點 |
| 背景播放、子母畫面 | 監看是 App 內的 Task，App 在執行就照常；不依賴播放畫面 |
| 同一廣告的舊讀值 | `SkipState` 只跳一次；自動跳過後在確認落點前不做下一次跳過。落點要看到播放頭**從目標附近繼續前進**才算確認：mpv 在 seek 後、第一個畫面解碼前會把 seek 目標本身當成位置回報，只有之後的讀值才代表實際落點 |
| 子母畫面的跳秒鍵、系統控制的 seek（不經過 `PlaybackSession.seek`） | 讀值之間出現不是播放造成的跳動（往回超過 0.5 秒，或往前超過速率允許的距離），而且當下沒有自動跳過或使用者 seek 在等待落定，就同樣忘記已跳過的區間；往回跳進已跳過的廣告會再跳一次。這類 seek 不會被改寫到廣告終點，而是播放開始後由自動判斷跳過 |
| 切換核心（手動、fallback、IOS-POC-22、17F 逾時）| `onEngineChange` 清除已跳過的區間與讀值；計畫屬於同一個項目，保留使用；新核心自己的 duration 要再比對一次；MPV 在有 discontinuity 的播放清單上另有 0.25 秒觸發延遲（IOS-POC-25-2，第二十二節） |
| IOS-POC-23 暫停重載 | 同上（`reloadPaused` 清除） |
| 新引擎的預設位置 0 或跳到交接位置 | 不算「在播」，不會觸發片頭廣告的跳過 |
| 下一集、換畫質、換片、WebHome 內嵌下一項、停止 | 新的 generation，上一項的計畫、已跳過的區間、暫停狀態全部清除；停止時結束監看 |

**與 IOS-POC-26 的互動**：IOS-POC-26-1（`a6652cc3`）讓 `handOff` 帶精確的位置與 `exactStart`。IOS-POC-25 不改 `PlayerRouter` 的任何交接語意，只在交接之後、新核心實際在播時判斷：若交接位置落在廣告內，依本任務規則跳到終點；上一個核心的跳過狀態不會帶過去。IOS-POC-26 記錄的 RC3（有 discontinuity 時兩個核心時間軸不同）也是本任務 MPV gate 的原因；IOS-POC-26-2 若解決 MPV 的 discontinuity 時間軸，本任務的 MPV gate 才可以重新評估。

## 十四、opening／ending／auto-next／WatchHistory

1. **片頭（opening）**：起播位置仍是 `max(opening, resume)`（IOS-POC-5S-2），本任務不改。起點若落在廣告內，播放開始後跳到廣告終點。片頭與廣告跳過都只會往前，不會互相拉回，不會 loop。
2. **片尾（ending）**：優先權在片尾。
   - 位置已到「片長 − ending」之後，廣告跳過完全不動作，交給既有 5 秒 sampler 的 `reachedEnding` → `finished()`。
   - 跨過片尾點的廣告，只跳到片尾點。
   - 理由：若跳過直接到片長，播放器的結束通知與 sampler 的片尾判斷可能先後各觸發一次 `finished()`，造成兩次 auto-next。
3. **auto-next**：沒有新的結束路徑。尾端廣告跳到片長後由播放器自然結束，走既有 `finished()`；片尾由既有 sampler 處理。
4. **WatchHistory**：`persist()` 照舊記錄引擎的 `currentTime`；跳過之後記錄的就是廣告終點。`WatchHistory` 的格式與語意沒有改。
5. **重播（`control("replay")`）**：視為使用者 seek 到 0（對齊 Android repeat 的 `seekToPosition(0)`），片頭廣告會再被跳過一次。
6. **播放速度**：判斷只看位置；前進檢查與喚醒時間以速率換算。IOS-POC-14A/14B 與 IOS-POC-22 不受影響。
7. **quality state**：`record.quality` 等不變；換畫質見第十二節之五。

## 十五、fail-closed policy

以下任何一項成立，就不自動跳、不改寫 seek，照原本播放：

1. 網址不是 `http(s)` 或不含 `m3u8`（DASH、MP4、FLV 完全不讀）。
2. 開關關閉（即時生效）。
3. 讀取失敗、非 2xx、超過 8 MiB、開頭不是 `#EXTM3U`。
4. 沒有 `#EXT-X-ENDLIST`；有 `STREAM-INF`（在 media playlist 中）、`PART`、`SKIP`、`I-FRAMES-ONLY`。
5. `#EXTINF` 不合法、非正數、scale 超出範圍、溢位；URI 前沒有 `#EXTINF`；`ENDLIST` 之後還有 segment；超過 100,000 段。
6. 過濾結果不是子序列、對應不唯一、沒有刪任何段、刪光所有段。
7. 單一區塊超過 120 秒（只保留那一塊）。
8. master：沒有 variant、超過 8 個、任一 variant 讀不到、任一不一致。
9. 同一 playlist 讀兩次切點不同，或第二次讀取失敗。
10. 跳過總長超過 25%、區間數超過 detector 的斷點上限。
11. 引擎 duration 與計畫相差超過 1 秒。
12. MPV 且任一 media playlist 有 `#EXT-X-DISCONTINUITY`。IOS-POC-25-2 起不再整份不跳，改為播放頭進入區間 0.25 秒前不自動跳（第二十二節）。
13. 播放頭沒有以播放速率前進（暫停、緩衝、剛載入、剛 seek）。
14. 使用者 seek 還沒落定。
15. 位置在片尾點之後。
16. 自動跳過後落點太早或太晚：該核心本項目停止跳過。

原則是「寧可漏掉廣告，也不能跳掉正片」。第 9～12、16 條是 iOS 額外加的，只會讓跳過變少。

## 十六、測試矩陣

測試在 `ios/Tests/WebHTVCoreTests/`，Swift Testing。**本環境無法執行**（第十九節）。

### 1. Android 真實輸出（差分測試）

`HLSAdsParserTests.swift` 的 26 筆語料由 JDK 21 執行 Android 的 `HlsAdsParser.java`、`HlsAdTimeline.java`（只 stub `TextUtils`、`Log`、`C`、`Util.split`）產生期望值：輸入的 SHA-256（確認語料相同）、過濾結果的 SHA-256、區間、總長、reason。Swift 端以相同產生器重建語料後逐筆比對。手寫測試的期望值（孤立 discontinuity、`parseDouble`、`BigDecimal`、master variant 解析、兩個不合理計畫）也都先在 JDK 上執行 Android 程式確認；其中一條我原本推算錯誤（孤立 discontinuity 應保留 2 個而不是 1 個），已依 Android 實際輸出修正。

### 2. 使用者要求的情境對應

| 情境 | 測試 |
|---|---|
| 無廣告 HLS 行為不變 | golden `a-no-ads`；`aPlaylistWithNoAdsComesBackAsTheSameString`；`aPlaylistWithoutAdsIsReadOnceAndChangesNothing`；`anAddressThatIsNotHLSIsSettledBeforeAnythingHappens` |
| 單一 ad block | golden `b`、`c`、`d`、`e`、`w`、`x`、`y`；`playbackRunningIntoAnAdJumpsToItsEndExactlyOnce` |
| 多個 ad block | golden `f`、`i`、`z`；`removedSegmentsUseSourceTimeAndAdjacentAdsMerge`；`morePathGroupRangesThanTheDetectorAllowsBreaksIsRefused` |
| 頭部／中段／尾部 | golden `c`／`u`（頭）、`b`（中）、`d`（尾）；`leadingAndTrailingAdsKeepDistinctSourceRanges`；`aTrailingAdJumpsToTheEndSoTheEngineFinishesTheItem` |
| discontinuity 前後 | golden `f`、`u`、`v`；`keyRotationAndDiscontinuityMetadataDoNotChangeSourcePositions`；`longFalsePositiveBeforeAndAfterAnAdRemainsSeekable`；`acceptedAdjacentDiscontinuityBlocksStillMerge`；`theLastDiscontinuityBlockIsNeverTakenForAnAd` |
| repeated segment URI、相同 duration 的重複 segment | golden `j`；`rejectsAmbiguousDuplicateOccurrences`；`repeatedRetainedSegmentsCanStillHaveAnUnambiguousMapping` |
| byte range | golden `k`；`byteRangeIdentitySeparatesSegmentsUsingTheSameUrl` |
| AES／implicit IV 不被破壞 | golden `l-aes-seq37`；`keyRotationAndDiscontinuityMetadataDoNotChangeSourcePositions`；結構保證：引擎收到的永遠是原網址，計畫沒有任何產生 playlist 給播放器的 API |
| 120 秒疑似廣告保留 | golden `p`（121 秒保留）、`q`（120 秒跳過）；`uninterruptedLongCandidateIsPreservedAndLimitIsInclusive`；golden `i` 的長區塊保留 |
| malformed／不完整 playlist | golden `r`、`m`、`n`；`rejectsLiveMalformedNonFiniteAndOverflowingDurations`；`rejectsReorderingOrChangingRetainedMedia`；`liveLowLatencyMalformedAndNonPlaylistBodiesSkipNothing`；`aFailedFirstReadingSkipsNothing`；`aSecondReadingThatFailsSkipsNothing`；`extinfDurationsBecomeMicrosecondsExactlyAsBigDecimalRoundsThem` |
| master 多 rendition 完全一致 | `everyDeclaredVariantAgreeingIsTheOnlyWayAMasterGetsRanges`；`unknownSelectionRequiresEveryDeclaredVariantToAgree` |
| rendition 不一致不跳 | `aVariantThatCutsDifferentlyMeansNothingIsSkipped`；`aVariantThatCannotBeReadMeansNothingIsSkipped`；`matchingBitratesWithConflictingPlansNeverGuess`；`theDeclaredCountIsOneRegularVariantPerPositiveBitrate`；`imageOrIframePlaylistCannotSupplyTheVideoAdPlan`；`audioRenditionsAndIFramePlaylistsAreNeitherReadNorCounted`；`aMasterDeclaringMoreThanEightVariantsIsNotRead`；`streamVariantsAreReadAsAndroidsRewriterReadsThem` |
| selected quality 改變 | `aPlanForThePreviousItemIsNeverAdopted`；`selectedPeakOrAverageBitrateChoosesItsOwnPlan`（Android 語意） |
| 手動 seek 進廣告／越過廣告 | `aViewersSeekIntoAnAdLandsAtItsEndAndAnyOtherSeekIsUntouched`；`seekingBackBeforeASkippedAdSkipsItAgain`；`aReadingFromBeforeAViewersSeekCannotPullPlaybackIntoASkip` |
| 暫停在廣告前 | `aPlayerPausedJustBeforeAnAdSkipsItOnlyOnceItPlaysIntoIt`；`aPausedPlayerInsideAnAdStaysThereUntilItPlays` |
| 廣告邊界附近 resume | `playbackRunningIntoAnAdJumpsToItsEndExactlyOnce`（119.9999 秒不算進入）；`aViewersSeekIntoAnAd…`（終點本身是正片） |
| AVPlayer ↔ MPV 切換 | `anEngineSwitchForgetsWhichAdsWereSkipped`；`mpvNeverActsOnAPlaylistWithDiscontinuities`；`aLoadsPlaceholderZeroAndTheJumpToItsStartAreNotPlayback`；`aSkipThatLandsShortOfItsTargetStopsThatEngineForTheItem`；`mpvLandsATenthOfASecondBeforeTheEnd` |
| auto-next | `aTrailingAdJumpsToTheEndSoTheEngineFinishesTheItem`；`theViewersEndingOwnsTheEndOfTheItem` |
| opening／ending 同時存在 | `anOpeningThatEndsInsideAnAdStartsWhereTheAdEnds`；`theViewersEndingOwnsTheEndOfTheItem` |
| WatchHistory position | 跳過只以 `seek` 移動播放頭，`persist` 不變；目標永遠是區間終點、區間外位置不變（上列 seek 與跳過測試） |
| Live／LL-HLS 不啟用 | golden `m`、`n`；`aLivePlaylistIsNeverAnalysedEvenWithAnObviousAd`；`liveLowLatency…` |
| DASH／MP4 不啟用 | `dashAndMp4AreNeverRequestedAtAll`；`onlyAnHTTPAddressContainingM3u8IsEverACandidate` |
| detector 例外 → 原始播放 | Swift 移植沒有丟例外的路徑；所有失敗都是沒有區間（上列 malformed 與讀取失敗測試） |
| stale callback 不重複跳 | `stalePositionsCannotRepeatSeekAndManualOrMediaResetAllowsReplay`；`playbackRunningIntoAnAd…`（120.1 秒的舊讀值）；`aReadingFromBeforeAViewersSeek…` |
| iOS 額外保護 | `aPlaylistThatCutsDifferentlyWhenReadAgainSkipsNothing`；`aPlanSkippingMoreThanAQuarterOfTheRuntimeIsRefused`；`theEngineMustBePlayingThePlaylistThatWasRead`；`turningTheSwitchOffStopsSkippingAtOnce`；`aSkipThatLandsPastItsTargetStopsSkipping`；`theSwitchIsOnUntilTheViewerTurnsItOff` |

### 3. 不能用單元測試證明的

App 端的接線（`PlaybackSession` 的監看 Task、設定頁）、AVPlayer 與 MPV 實際的 seek 落點、duration 與 EXTINF 總和是否一致、`currentTime` 在 discontinuity 之後是否連續，只能在模擬器或真機確認（第二十節）。

## 十七、驗收標準

1. 無廣告或非 HLS 的影片：行為與以前完全相同（沒有額外請求給非 HLS；無廣告的 HLS 只多一次 playlist 讀取）。
2. 原生播放器：含插播廣告的 HLS VOD 在廣告開始後約 0.1 秒內跳到廣告結束；正片沒有被跳掉；同一廣告只跳一次；往回 seek 越過廣告後再播會再跳。
3. 手動 seek 進廣告落在廣告結束；seek 到正片落點不變。
4. 片尾、auto-next、WatchHistory 續播、播放速度、畫質、暫停、背景、子母畫面、IOS-POC-23 暫停重載、IOS-POC-26 切換都維持既有行為。
5. MPV：有 discontinuity 的廣告影片不跳（照播廣告）且 seek 行為與以前相同；沒有 discontinuity 的可偵測廣告會跳。IOS-POC-25-2 的驗收標準改為第二十二節之七。
6. 關閉「智慧去廣」後立即不再跳。
7. 單元測試全部通過（要在有 Swift 的環境執行）。

## 十八、回滾

1. 單一功能 commit，`git revert` 即可；沒有資料格式、lock、二進位、patch 或 workflow 變更。
2. 不 revert 的關閉方式：設定頁關閉「智慧去廣」；或讓 `HLSAdPlanner.isCandidate` 永遠回 false（完全不讀 playlist、不監看）。
3. 使用者也可以在 SideStore 裝回上一版。偏好 `webhtv.playback.hlsAdSkip` 留在 UserDefaults 不影響舊版。
4. IOS-POC-25-2 的回滾與連結期檢查的順序見第二十二節之八。

## 十九、實作紀錄（2026-09-25）

### 1. 新增與修改的檔案

| 檔案 | 內容 |
|---|---|
| `ios/Sources/WebHTVCore/HLSAdsParser.swift`（新） | `HLSAdsParser.process`、`JavaText` |
| `ios/Sources/WebHTVCore/HLSAdTimeline.swift`（新） | `HLSAdTimeline`、`SkipState`、`Variant`、`resolve`、`declaredVariantCount`、`JavaBigDecimal`、`JavaText.strip` |
| `ios/Sources/WebHTVCore/HLSAdSkip.swift`（新） | `HLSAdPlan`、`HLSAdPlanner`（讀取、master、讀兩次、合理性上限）、`HLSAdSkipper`、`HLSAdSkipPreference` |
| `ios/Tests/WebHTVCoreTests/HLSAdsParserTests.swift`（新） | 26 筆 Android golden＋detector 意圖測試 |
| `ios/Tests/WebHTVCoreTests/HLSAdTimelineTests.swift`（新） | Android 三個測試類別的移植＋`BigDecimal` 邊界 |
| `ios/Tests/WebHTVCoreTests/HLSAdSkipTests.swift`（新） | planner 與 skipper 的規則 |
| `ios/WebHTVApp/Sources/WebHTVApp.swift` | `PlaybackSession`：`watchAds`／`adTick`／`adoptAdPlan`／`adSeekTarget`、`load` 開始監看、`seek` 改寫、`replay`、`stop`、`onEngineChange`、`reloadPaused`；設定頁「智慧去廣」 |
| `docs/IOS-POC-25-hls-midstream-ad-skip.md`（新）、`docs/current-task-state.md` | 本文件與 roadmap |

`AVPlayerEngine`、`loadNative`、`MPVEngine.swift`、`PlaybackEngine.swift`（`PlayerRouter`）、WatchHistory、5S-1／5S-3 都沒有修改。

### 2. log（`os.Logger`，category `playback`）

- `[adskip] <片名> plan <reason> ranges=<起-終,…|none> discontinuity=<yes|no>`
- `[adskip] <片名> skip from=<ms>ms to=<ms>ms on <核心>`
- `[adskip] <片名> seek into an ad at <ms>ms lands at <ms>ms`
- `[adskip] <片名> stopped on <核心>: landed-past-target|landed-short-of-target`

不記錄網址，只記錄 reason 與區間，與 Android 的 `shortUrl` 做法一致。

### 3. 驗證

| 檢查 | 結果 | 證據等級 |
|---|---|---|
| `swift test` | **未執行**：本環境沒有 Swift 工具鏈（`download.swift.org` 被擋、apt 沒有套件）。沒有另外新增 CI workflow 跑測試：IOS-POC-20 Q6 使用者選擇不跑單元測試，另一個 session 也依此處理；本次指示只要求環境可跑才跑 | — |
| 編譯（WebHTVCore、App） | **未編譯**。唯一的編譯關卡是發版 workflow 的 Release device build，要等使用者授權發布 | — |
| Android 差分：26 筆 golden | JDK 21 執行 Android 的 `HlsAdsParser.java`、`HlsAdTimeline.java` 產生期望值，寫進 `HLSAdsParserTests` | Android 原始碼實際執行 |
| Swift 邏輯的差分模糊測試 | 把本任務的 Swift 程式**逐行轉寫**成 Python（`HLSAdsParser`、`JavaText`、`HLSAdTimeline.from`／`parse`、`JavaBigDecimal`），與 Android Java 比對：golden 26／26 相同；第一輪隨機 playlist 4,000 筆 0 差異（其中 297 筆產生區間、336 筆保留長區塊、2 筆 `ambiguous-segments`）；第二輪偏向廣告結構的產生器 8,000 筆 0 差異（其中 5,147 筆產生區間） | 轉寫版，不是 Swift 編譯結果 |
| master variant 解析差分 | 隨機 master 1,500 筆（屬性順序、大小寫、引號內逗號、`+700`、`-5`、超出 long、錯誤的 RESOLUTION、I-frame、`EXT-X-MEDIA`、中文網址、CRLF），轉寫版與 Android `HlsPlaylistRewriter` 的 STREAM variant 0 差異 | 同上 |
| 手寫測試的期望值 | 孤立 discontinuity、`parseDouble`、`BigDecimal`、master 解析、兩個不合理計畫，都先在 JDK 上執行 Android 程式確認；我原本推算錯的一條已依實際輸出修正 | Android 原始碼實際執行 |
| 多代理審查 | 對 `7530acf9` 做對抗式審查：7 項確認並修正（第十九節之四），4 項駁回（live playlist 會輪詢、緩衝時輪詢、AVPlayer variant 會被先讀、master 帶 `ENDLIST`；其中後兩項分別採納「暫停時 100 ms 讀一次」與「縮小 `planRequest` 註解的承諾」） | 靜態 |
| `HLSAdSkipper` 情境模擬 | 審查修正後的 `HLSAdSkipper` 逐行轉寫成 Python，跑 `HLSAdSkipTests` 中全部 20 組 `Drive` 情境的期望值：全部相符。再把四條規則各自改回舊寫法（落點不需前進、沒有跳動偵測、不看 `playing`、`manualSettle` 不逾時），每一條都至少讓一個新測試失敗 | 轉寫版，不是 Swift 編譯結果 |
| 模擬器、真機 | 未執行（本環境沒有） | — |

### 4. 審查後修正（第二個 commit）

1. `aPlanForThePreviousItemIsNeverAdopted` 在 `#expect` 內呼叫 `mutating` 方法，無法編譯；改為先取值再檢查。
2. 落點確認：原本讀值一進入目標附近就算落定，mpv 回報的 seek 目標本身會被當成落點，之後晚一整段的真實落點不會被發現。改為要看到從目標附近繼續前進才算落定；超過目標 1.5 秒仍立即停止該核心。
3. 子母畫面跳秒鍵（`MPVEngine` 的 PiP `skipByInterval` 直接呼叫 `engine.seek`）與系統控制的 seek 不經過 `adSeekTarget`，已跳過的區間不會被清除。改為在讀值之間偵測跳動（第十三節）。`MPVEngine.swift` 沒有修改。
4. master 中讀不到的 variant 原本只是略過；兩個 entry 的 `BANDWIDTH` 相同時，`declaredVariantCount` 只算一個，略過的那條不會被發現。改為任一 variant 讀不到就整份不跳（`variant-unreadable`），與第十五節第 8 條一致。
5. `aSecondReadingThatFailsSkipsNothing` 的第二次回應其實讀取成功（內容是 HTML），測的是 `unstable-playlist`；改為真的讀取失敗，並檢查 `fetch-failed`。
6. 暫停測試補上「暫停中位置仍往前爬」的讀值，確認只有在播才跳。
7. 補上使用者 seek 的目標一直沒出現時，3 秒後恢復自動判斷的測試。

## 二十、真機驗收（`0.1.22 (23)`）

### 1. 項目

全部**未驗證**。需要一個含插播廣告的 HLS VOD 來源（最好同時有一個有 discontinuity、一個沒有）；有 Mac 時以 Console 過濾 `[adskip]` 對照。

| # | 核心 | 步驟 | 通過條件 |
|---|---|---|---|
| D1 | 原生 | 從頭播到第一個廣告 | 廣告開始後 1 秒內跳到廣告結束，正片開頭沒有少；log 有 `plan exo-hls-detector` 與 `skip` |
| D2 | 原生 | 拖進度條到廣告中間 | 落在廣告結束 |
| D3 | 原生 | 跳過後往回拖到廣告前 | 再播到廣告時再跳一次 |
| D4 | 原生 | 在廣告前 5 秒暫停 30 秒再播 | 到廣告時跳過 |
| D5 | 原生 | 在廣告中切到 MPV | 有 discontinuity：MPV 照播廣告；沒有：跳到廣告結束前 0.1 秒內 |
| D6 | MPV | 從頭播有 discontinuity 的廣告影片 | 不跳、seek 行為與以前相同（log 的 plan 為 `discontinuity=yes`） |
| D7 | 原生 | 設片尾，廣告在片尾範圍內 | 由片尾接下一集，只換一集 |
| D8 | 原生 | 尾端廣告（沒有設片尾） | 跳到片尾後自動下一集，只換一集 |
| D9 | 原生 | 跳過後關閉播放器，從觀看紀錄重開 | 從廣告後的位置續播 |
| D10 | 兩者 | 設定頁關閉「智慧去廣」後播同一集 | 不跳 |
| D11 | 兩者 | 無廣告影片、MP4 | 行為與以前相同 |
| D12 | 原生 | 1.5× 播放到廣告 | 跳過，速度不變 |
| D13 | 原生 | 暫停、鎖螢幕 60 秒、回來（IOS-POC-23）後播到廣告 | 跳過 |

IOS-POC-25-2 之後的版本，D5、D6 的 MPV 部分改用第二十二節之七的 M 項目。

### 2. 第一次真機回報與診斷（2026-09-26）

**回報**（D1、部分 D6）：原生在廣告開始後，畫面在動、有廣告聲音，不到約 1 秒（使用者未計秒）才跳走；跳過後正片沒有察覺缺少。MPV 沒感覺到廣告，不確定進度是否往前跳。沒有裝置 log（沒有 Mac）。

**診斷**（唯讀 workflow `wf_07f68e89-7d8`：程式路徑、AVFoundation、Android 對照、播放清單結構四條線，綜合後由失敗封閉、AVFoundation、回歸三個角度反駁；Ponytail：unavailable／skipped）。結論是**現有證據無法決定原因**：

| 假設 | 內容 | 判斷 |
|---|---|---|
| 程式延遲 | 監看在區間起點醒來，約 11 ms 內呼叫 seek（主執行緒延遲 16 ms 時約 27 ms）；讀值跳動多一次讀取，約 100 ms。以 Python 轉寫版加 `adTick` 排程模擬 | 排除，不到 1 秒的主因 |
| H-A seek 期間仍呈現廣告 | 零容差 seek 完成前 AVPlayer 繼續播出舊內容 | **沒有任何來源支持**；`AVPlayerItem.h` 只說 seek 完成到新畫面的延遲可忽略。要真機觀察 |
| H-C 計畫尚未就緒 | 廣告在計畫採用前開始：片頭或開播不久的廣告、從觀看紀錄續播、切換核心之後。media playlist 讀 2 次、master 讀 1＋2N 次，依序進行 | 只影響這些時機；要問發生位置 |
| H-B AVPlayer 時鐘落後畫面 | `currentTime` 比畫面慢，程式等到時鐘到區間起點才跳 | 第三方證據被誤引；唯一實測（AetherEngine #616）是反方向 |
| H-B' 時鐘領先畫面（反方向） | 會在廣告前**切掉正片**。AetherEngine #616 在 seek 後、分段媒體早於播放清單位置的來源上實測到 | 尚無回報；列為殘餘風險 |
| H-D 分成兩段 | 6 位小數 `EXTINF` 且廣告跨兩個 discontinuity 區塊時，兩個區間相隔 1 ms 不合併（Android Java 實際輸出 `[[600000,608766],[608767,619066]]`），要 seek 兩次 | 可能，會放大 H-A |
| H-V 播放器拿到的 playlist 不同 | AVPlayer 那份的廣告比 App 讀到的早一段：看到廣告開頭，跳過後落點晚一段，**少掉同樣長度的正片**，約 1 秒時觀眾可能察覺不到 | 失敗封閉審查恢復的假設；要真機比對落點 |

**免建置檢查**（使用者 2026-09-26 決定：不在手機上做，等有 Mac 時由 agent 補測，見第二十節之三）：

| # | 做法 | 用來判斷 |
|---|---|---|
| N1 | 關閉「智慧去廣」播到該廣告，記下廣告後正片的第一個畫面或第一句台詞；再開啟播放同一處，確認跳過後落在同一處，不是晚約 1 秒 | H-V、H-B'（正片有沒有少，最重要） |
| N2 | 露出是否也發生在連續播放 1 分鐘以上才遇到的中段廣告（中間沒有拖動、續播、切換核心） | H-C |
| N3 | 原生：進度條往前拖 2 分鐘以上（超出緩衝），看放開後、新畫面出現前，舊畫面與聲音是否還在播；再拖進廣告中間（D2）看同樣的事 | H-A |
| N4 | MPV 播同一個廣告時，時間是否往前跳了約一個廣告長度 | MPV 是否真的跳過，以及該 playlist 有沒有 discontinuity |

**下一個 build 的候選**（依補測結果決定；都要使用者核准，發布也要另外授權）：
1. 裝置上的「智慧去廣紀錄」：設定頁可複製的最近紀錄，記錄 `late=`（觸發時距區間起點）、`sincePlan=`、seek 完成時間、引擎與計畫的 duration 差，並有「只記錄不跳」模式；不改任何行為。
2. 串接落點：兩個區間在微秒上完全相接時一次 seek 到最後一段的終點；`ranges`、Android golden、合理性上限都不變。
3. 暫停式跳過（seek 前暫停、完成後播放）：**暫緩**。三個審查角度都找到回歸：多處以 `rate` 判斷觀眾意圖、PiP 自動啟動、IOS-POC-23 背景暫停重載、尾端廣告的自動下一集。
4. 否決：提早觸發或位移補償（時鐘方向一反就切掉正片）、`forwardPlaybackEndTime`（R3）、boundary observer（輪詢已在起點醒來，且不保證觸發）。

### 3. 有 Mac 時由 agent 補測（使用者 2026-09-26 決定）

使用者不在手機上做 N1～N4，改為有 Mac 時由 agent 自己補測。這項決定也包含第一次執行 Swift 單元測試：這是 agent 的解讀，執行前要向使用者確認一次，因為 IOS-POC-20 Q6 原本決定不跑單元測試。依序：

1. **單元測試**：在 `ios/` 執行 WebHTVCore 的 `swift test`（或 Xcode test），先修本任務測試的編譯或失敗。IOS-POC-25 的測試檔從未編譯過。
2. **模擬器（可重現）**：用 ffmpeg 產生本機 HLS VOD，涵蓋 IOS-POC-26 第六節的四種 PTS 配置（廣告自帶 PTS 或連續 PTS、有或沒有 `#EXT-X-DISCONTINUITY`），再加一組 6 位小數、跨兩個區塊的廣告（H-D）。在原生與 MPV 上以 Console 過濾 `[adskip]`，配合螢幕錄影，量測：
   - `skip from=` 與區間起點的差；
   - seek 發出到新畫面出現的時間，以及這段期間舊畫面與聲音是否繼續播放（H-A、N3）；
   - 關閉「智慧去廣」時，廣告第一個畫面出現時的 `currentTime` 與區間起點的前後關係（H-B、H-B'）。
3. **真機（接 Mac）**：使用者回報的那部影片，用 Console 收 `plan`／`skip` 兩行 log，並比對開關前後的落點畫面（N1、H-V），確認是中段還是開播不久（N2）、MPV 是否跳過（N4）。
4. 依結果決定下一個 build（本節之二的候選），交使用者核准。

## 二十一、已知限制與後續

1. **MPV 在大多數插播廣告影片上不跳**（第十一節之一第 5 點）。IOS-POC-26-2b 已在 `0.1.23 (24)` 對齊時間戳；IOS-POC-25-2 解除限制，剩下的 H1 與 cache 風險見第二十二節之九。
2. **沒有 native-output-boundary**：設計預估兩個核心會露出廣告最初約 0.1 秒；真機原生實測不到約 1 秒，原因未定（第二十節之二）。
3. **偵測本身是 Android 的啟發式**，會繼承它的誤判：例如 golden `h-disc-fallback` 中兩個 4 段的區塊被當成廣告（總長未超過上限時仍會跳）；同一集的正片分散在兩個 CDN 主機、檔名序號進位，也可能被當成廣告。iOS 的比例與區間數上限只能擋住極端情況。
4. **iOS 分開讀 playlist**：伺服器若每次插入位置不同但總長與兩次讀取剛好一致，仍可能對錯位置（機率低，有讀兩次與 duration 比對）。
5. **AVPlayer 的前提待真機確認**：HLS VOD 的 `currentTime` 從 0 開始且跨 discontinuity 連續、`duration` 等於 EXTINF 總和（研究只有 A 級推論與 C 級 SDK 程式，R3、R4）。若 duration 不符，本功能會自動不動作。
6. **MPV 選擇位元率**（方案 E）暫緩。
7. **AVPlayer 的 variant 可能先被本功能讀到**：計畫在引擎開啟媒體後才讀，項目本身的網址一定已被引擎用過；但 AVPlayer 還沒載入的其他 variant，可能由本功能先讀。一次性網址的 variant 若因此失效，AVPlayer 之後切到那條會失敗。尚無案例，真機驗收時留意。
8. **跳動偵測的邊界**：自動跳過或使用者 seek 等待落定的期間，其他來源的 seek 不會被偵測；落定後若引擎回報一次 seek 前的舊位置，可能多做一次跳到同一個廣告終點的 seek（不會跳掉正片）。

## 二十二、IOS-POC-25-2：MPV 在有 discontinuity 的播放清單上跳廣告（2026-09-26）

### 1. 授權與前提

1. 使用者 2026-09-26 讀完評估（方案 A～F）後，選 D，指示「先測試D試試」：在 `0.1.23 (24)` 真機確認 IOS-POC-26 第八節之三的條件之前，先實作供下一版測試。這是使用者對原本「確認之前只能規劃，不能解除」的明確變更。bump 版本、tag、發布仍要先問。
2. Lane `standard`，task guard `IOS-POC-25-2`（`--no-tag`）。Ponytail：unavailable／skipped。
3. 基底：`origin/ios-poc` `07539268`（含 `0.1.23 (24)`：`Package.swift` 的 `Libavformat` 是 `ffmpeg-n8.1.2-webhtv.1`，checksum `ba3e718d…`，`e5f15c73`）。
4. 指定分支 `claude/ios-poc-25-ad-skip-assessment-whmqwu` 開始時是 `main` 的 `58562327`。`main` 有 68 個 commit 不在 `ios-poc`（Android 與 CI），所以無法 fast-forward；本機分支改以 `origin/ios-poc` 為基底（該分支沒有獨有 commit，不會遺失內容）。
5. 不修改 IOS-POC-26 所有的檔案（第八節之五）：`third_party/mpv-ios/patches/ffmpeg/`、`.github/workflows/ios-ffmpeg-build.yml`、lock 的 `ffmpeg` 區段、`Package.swift` 的 `Libavformat`。

### 2. 研究（評估 workflow `wf_17dc2eee-a8c`，2026-09-26 讀取）

| # | 來源 | 等級 | 支持的論點 | 對決策的影響 |
|---|---|---|---|---|
| E1 | IOS-POC-26 文件 5.3a、第八節；patch 0006 的 commit message | A | H1：切點前的編碼音訊領先影像 2048 樣本以上時，之後的序列整段延後。每個切點 +0.044～0.093 秒，兩個時段後 0.232 秒，沒有固定上限。F2、G4 與它同方向 | MPV 的 `time-pos` 比畫面多 d，自動跳過提早 d，丟掉廣告前 d 秒正片 |
| E2 | patch 0006（seek 後重建的狀態） | A（推論） | seek 之後偏移重設，但下一個切點仍套用 H1 的重疊規則 | MPV 落在終點前 0.1 秒後會線性越過「廣告→正片」切點，所以有跳也可能留下 +0.044～0.093 秒 |
| E3 | mpv v0.41.0 `demux/demux.c:2463-2474`、`:3841-3863`、`stream/stream_lavf.c:450`；`MPVEngine.swift` 沒有設 cache 選項 | A | lavf 串流預設開啟 seekable demuxer cache（`cache-secs` 1 小時、前向 150 MiB）；目標在 cache 內時走 `execute_cache_seek`，不呼叫 `hls_read_seek` | 跳廣告的 seek 可能不會把 d 歸零，d 可能隨讀過的切點累加（推論，未驗證）。這與 IOS-POC-26 第八節之二「每次跳廣告本身就是一次 seek，偏差會歸零」衝突，兩邊都是推論 |
| E4 | `HLSAdSkip.swift` 的落點檢查、跳動偵測、duration 比對 | A | 三者都看不到 d：落點看 seek 之後；1× 每 0.1 秒容許 0.45 秒；duration 兩邊都是 EXTINF 總和 | 只能靠設計上的餘量 |
| E5 | IOS-POC-26 第六節；`ios-ffmpeg-build.yml:257-272` | A | 連上游 `Libavformat` 時，廣告自帶 PTS 會讓跳過落錯位置（推論：丟約 15 秒正片或跳回片頭）；duration 分不出兩版；lane 要求版本與 configure 字串和上游相同，執行期沒有公開字串可以分辨 | 解除必須與新 `Libavformat` 綁定，而且綁錯時要 fail loud |
| E6 | Apple ld64 `-u symbol_name`（`man ld`） | A | 指定的符號必須有定義，否則連結失敗 | 連結期耦合 |
| E7 | IOS-POC-26 5.3 表（忠實移植＝FongMi／Android） | A | Android 的 FFmpeg 線性播放多數差 0.08 秒，部分配置 15～28 秒；Android 的 MPV 在區間起點就跳 | iOS 的 0006 加延遲比 Android parity 更保守 |

論文、部落格與上游討論：這一階段的決策只取決於 E1～E6 的原始碼與量測，沒有會被它們改變的問題，不另外檢索。

### 3. 方案比較

| 方案 | 內容 | 判斷 |
|---|---|---|
| A 不改 | 維持 gate，MPV 照播廣告 | 使用者要先測 |
| B 只刪 gate | 一行 | 否決：丟 d 秒正片；FFmpeg 回滾時無聲跳錯 |
| C B 加連結期耦合 | `-u _ff_hls_timestamp_map_segment` | 可行，但 H1 仍丟正片 |
| **D C 加觸發延遲（採用）** | 只在 MPV 且 `hasDiscontinuity` 時，位置讀到區間起點 0.25 秒後才自動跳 | 使用者選定。d ≤ 0.25 秒時不丟正片（涵蓋 5.3a 所有 H1 量測）；延後是安全方向，第二十節之二第 4 條否決的是提早觸發 |
| E 落點改到終點之後 | margin 0 | 否決：`endMs` 捨去，目標仍可能在廣告最後一段；cache seek 時無效 |
| F 放寬 0006 的音訊重疊 | 改 patch | 不在範圍（IOS-POC-26 所有） |

其他耦合做法：執行期偵測不可行（E5）；發版 workflow 檢查只在發版時生效；只寫文件在回滾時不會報錯。

### 4. 實作

| 檔案 | 內容 |
|---|---|
| `ios/Sources/WebHTVCore/HLSAdSkip.swift` | `HLSAdPlan.timeline(for:)` 不再排除 MPV；新增 `HLSAdSkipper.mpvDiscontinuityEntryDelay = 0.25`；`automaticTarget` 在 `skips.nextTargetMs` **之前**檢查延遲（否則延遲期間的讀值會把區間記成已跳，之後永遠不跳）；`secondsUntilNextRange` 在 `起點 + 延遲` 喚醒；新增 `entryDelayMs`；更新 `hasDiscontinuity`、`timeline(for:)` 與型別說明的註解。手動 seek 不延遲，MPV 落點仍是終點前 0.1 秒 |
| `ios/WebHTVApp/WebHTVApp.xcodeproj/project.pbxproj` | App target 的 Debug 與 Release 加 `OTHER_LDFLAGS = ("$(inherited)", "-Wl,-u,_ff_hls_timestamp_map_segment")`。連到上游 `Libavformat` 時連結失敗 |
| `ios/Tests/WebHTVCoreTests/HLSAdSkipTests.swift` | `mpvNeverActsOnAPlaylistWithDiscontinuities` 改為 `bothEnginesActOnAPlaylistWithDiscontinuities`；新增 `mpvWaitsAQuarterSecondIntoAnAdOnAPlaylistWithDiscontinuities`、`aViewersSeekIntoAnAdOnMpvIsNotDelayed`、`theWatchWakesMpvWhenItsDelayIsOver` |

`WebHTVApp.swift`、`MPVEngine.swift`、`PlaybackEngine.swift`、IOS-POC-26 所有的檔案都沒有修改。

### 5. 行為

| 情境 | 行為 |
|---|---|
| MPV、有 discontinuity、播到廣告 | 位置讀到起點 + 0.25 秒後跳到終點前 0.1 秒 |
| MPV、有 discontinuity、使用者 seek 進廣告 | 落在終點前 0.1 秒（不延遲） |
| MPV、沒有 discontinuity | 與 `0.1.23 (24)` 相同 |
| 原生 | 與 `0.1.23 (24)` 相同 |
| 關閉「智慧去廣」 | 兩個核心都不跳 |

代價與殘留：

1. MPV 在這類影片上每個時段約露出 0.25 秒加監看間隔（≤ 0.1 秒）加 seek 時間的廣告開頭，以及最後 0.1 秒。
2. d 超過 0.25 秒時（cache 讓 d 累加、F2 的長期累加），仍會丟 d − 0.25 秒正片。
3. cache 處理的 seek 落點也會早 d 秒：多看 d 秒廣告，不丟正片。
4. 0.35 秒以下的區間在 MPV 上不會自動跳。
5. 延遲也作用在不需要它的地方：片頭廣告（區間從 0 開始，前面沒有切點）與 H-D 的第二段（前面是廣告，不是正片），各多露出約 0.25 秒廣告。為了規則單純，不另設例外。

### 6. 驗證

| 檢查 | 結果 | 證據等級 |
|---|---|---|
| `swift test` | **未執行**：本環境沒有 Swift 工具鏈 | — |
| 編譯（WebHTVCore、App） | `0.1.24 (25)` 的 Release device build（run `36230882448`）第一次即成功。它不編譯 `WebHTVCoreTests`，測試檔的編譯仍要等有 Mac | CI 編譯 |
| `-u` 連結檢查 | 以 ld64.lld-18 代替 Apple 的連結器，對實際下載的 artifact 連結：新 `Libavformat`（裝置 arm64、模擬器 arm64／x86_64）找得到 `_ff_hls_timestamp_map_segment`（`hls_timestamp.o`，一般的外部符號，patch 沒有 hidden visibility）；上游 MPVKit 1.0.0 的 `Libavformat` 報 `undefined symbol: _ff_hls_timestamp_map_segment`。`hls.o` 本來就引用它，`-u` 不改變連結內容。正向在 Apple 連結器上由 run `36230882448` 的 Release build 確認（連結成功）；反向只以代理連結器驗證 | 代理連結器＋CI 連結 |
| Python 逐行轉寫 `HLSAdSkipper` | 全部 24 個 `Drive` 與喚醒情境：修改後 24／24 通過；`0.1.23 (24)` 的程式 20／24，只在 4 個新或改寫的測試失敗（既有 20 個情境不變）；延遲改在 `nextTargetMs` 之後檢查、喚醒不含延遲，這兩種寫法各被一個新測試抓到 | 轉寫版，不是 Swift 編譯結果 |
| 多代理審查 | workflow `wf_5b11e198-a2f`，三個角度（Swift 編譯、行為與回歸、連結檢查）：沒有 blocker 或 major。1 個 minor（延遲常數與測試的註解寫成 H1 有上限）與 3 個措辭 nit 已修正；「片頭廣告與 H-D 第二段也多等 0.25 秒」記為代價（本節之五）；「cache 內的手動 seek 仍帶偏差」記為已接受的邊界。原生與沒有標記的 MPV 在邏輯上逐條確認不變 | 靜態 |
| 真機 | **未驗證** | — |

### 7. 真機驗收（`0.1.24 (25)`，全部未驗證）

| # | 核心 | 步驟 | 通過條件 |
|---|---|---|---|
| M1 | MPV | 從頭播有插播廣告（有 discontinuity）的影片到第一個廣告 | 廣告開始後約 0.5 秒內跳到廣告尾端 |
| M2 | MPV | 拖進度條到廣告中間 | 落在廣告尾端 |
| M3 | MPV | 不操作，連續播過第一個時段到第二個 | 第二個也跳過；廣告前的正片沒有察覺缺少 |
| M4 | MPV | 關閉「智慧去廣」播同一集 | 照播廣告，seek 與 `0.1.23 (24)` 相同 |
| M5 | 兩者 | 原生播同一集、MPV 播沒有廣告的影片 | 與以前相同 |
| M6 | MPV | 尾端廣告 | 只換一集 |
| M7 | MPV | 1.5× 播到廣告 | 跳過，速度不變 |

有 Mac 時（第二十節之三）另外量測：`[adskip] skip from=` 與區間起點的差、廣告前最後一個正片畫面在開關前後是否相同、cache 內與 cache 外的 seek 是否讓 d 歸零。

### 8. 回滾

1. revert 本階段的 commit：同時恢復 gate、移除延遲與 `-u` 連結檢查。
2. 若 IOS-POC-26-2b-2 要回滾（`Package.swift` 的 `Libavformat` 改回上游），**必須先 revert 本階段**，否則 Release build 會因 `_ff_hls_timestamp_map_segment` undefined 而連結失敗。這是刻意的 fail loud：避免 MPV 在沒有時間戳對齊的 FFmpeg 上跳錯位置。
3. 不 revert 的關閉方式：設定頁關閉「智慧去廣」。

### 9. 未解

1. cache 內的 seek 是否讓 d 累加（E3），只有真機接 Mac 才能判斷。量到 d 超過 0.25 秒時，再決定調整延遲或恢復 gate。
2. 真實串流的 H1 量級未量測（5.3a 是合成素材）。
3. `-u` 的反向（連上游時連結失敗）只以代理連結器（ld64.lld-18）驗證；正向已由 `0.1.24 (25)` 的 Release build 確認。IOS-POC-25 的測試仍從未編譯過。
4. H-D（相隔 1 ms 的兩個區間）在 MPV 上會跳兩次，之間多一個切點；第二十節之二的候選 2 可處理，不在本階段。
5. master 只有一個 rendition 帶標記時影音不同步（IOS-POC-26 第八節之四），本階段不改變。

## Recovery anchor

- 目標：Android main 的 HLS VOD 中段廣告偵測與自動跳過移植到 iOS，AVPlayer 與 MPV 共用同一份 detector／timeline；任何不確定都不跳。驗收標準見第十七節。
- 狀態（2026-09-26）：IOS-POC-25-2（MPV 在有 discontinuity 的播放清單上也跳，進入區間 0.25 秒後才觸發，`-u` 連結期檢查，`45be83c4`）已隨 `0.1.24 (25)` 發布（tag `ios-v0.1.24-b25` → `5da03a4a`，Release build 編譯、連結成功），真機未驗證（第二十二節）。第一階段：實作 `7530acf9`、審查修正 `3243e9e0`，已隨 `0.1.22 (23)` 發布（tag `ios-v0.1.22-b23` → `450bd061`，Release build 編譯通過）；Swift 單元測試未執行。第一次真機回報：原生露出不到約 1 秒的廣告開頭，原因未定（第二十節之二）。
- 相關檔案：第十九節之一。
- 關鍵決策：MPV discontinuity gate（第十一節，IOS-POC-25-2 改為 0.25 秒觸發延遲與 `-u` 連結期檢查，第二十二節）、iOS 額外保護（第七、十五節）、片尾優先（第十四節）、不做 native boundary（第十一節之二）。
- 未解：第二十一節、第二十二節之九。
- 下一步（唯一）：等使用者在 `0.1.24 (25)` 回報第二十二節之七的 M1～M7，逐列填入。有 Mac 時仍依第二十節之三補測（先單元測試，執行前向使用者確認一次），並量測第二十二節之九第 1 項；測到正片變少時先處理該問題。
