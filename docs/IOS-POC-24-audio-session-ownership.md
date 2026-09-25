# IOS-POC-24 — mpv 與 App 搶音訊工作階段（audio session）

- 狀態：**使用者 2026-09-25 選定 O3（修改 Libmpv）**，實作分兩個單元（第六節之二）。第六節的 O1＋O2 是原建議，未採用。
- 起因：IOS-POC-23 第十節之三記錄的衝突；使用者 2026-09-25 要求修正。
- 本文件依 AGENTS.md §7 記錄最佳實務研究、現況審查、方案比較、建議、驗收標準與回滾。

## 一、問題

iOS 一個 App 只有一個音訊工作階段（`AVAudioSession.sharedInstance()`），兩個播放核心共用。

1. **App 的設定**：啟動時設成 `.playback`＋`.moviePlayback`，不與其他 App 混音，並啟用（`ios/WebHTVApp/Sources/WebHTVApp.swift:27-28`）。之後只有 IOS-POC-23 在「偵測到被系統暫停執行」後，按播放前再 `setActive(true)`（`WebHTVApp.swift:2681-2689`），從不重設類別。
2. **mpv 的做法**（v0.41.0 `ao_audiounit.m`）：
   - 每次建立音訊輸出：把整個 App 設成 `.playback`＋**與其他 App 混音（MixWithOthers）**＋`.moviePlayback`，再 `setActive(YES)`（`:118-125`）；
   - 每次拆掉音訊輸出：把整個 App 的工作階段 `setActive(NO)`，並通知其他 App 可以恢復播放（`:238-241`）；
   - 沒有任何選項能關掉這兩件事。
3. **使用者會遇到的結果**：
   - MPV 播放時，其他 App 的音樂不會停，和影片混在一起；原生播放不會這樣，兩個核心行為不一致。
   - 用過 MPV 之後，App 的類別一直停在「混音」，直到 App 重開。之後的原生播放也變成混音，而且失去鎖定畫面／控制中心「正在播放」的資格（第三節 A3）。
   - **MPV 換到原生時可能被停掉**：`PlayerRouter.run` 先拆 MPV 再建原生並開始播放（`ios/Sources/WebHTVCore/PlaybackEngine.swift:459-478`），但 MPV 是在背景執行緒銷毀（`ios/WebHTVApp/Sources/MPVEngine.swift:432-443`）。mpv 的 `setActive(NO)` 可能在原生開始出聲之後才到；Apple 文件寫明，這時正在播放的音訊物件會被停掉（A1）。media_kit 有完全相同情境的實地回報（F4）。
   - 每集播完、MPV 進入 idle，或換成音訊格式不同的一集時，mpv 都會先停用、再以混音重新啟用（第四節之 3）。

## 二、判斷過程中確認的事實（mpv v0.41.0 `41f6a645068483470267271e1d09966ca3b9f413`）

| # | 事實 | 證據 |
|---|---|---|
| M1 | 建立音訊輸出時設類別、混音與啟用，所有錯誤都忽略 | `audio/out/ao_audiounit.m:118-126` |
| M2 | 拆掉時 `setActive:NO`＋`NotifyOthersOnDeactivation`，不還原類別；driver 沒有子選項、沒有 control、不監聽通知；整個 mpv 只有 `ao_audiounit.m` 與 `ao_avfoundation.m` 碰 `AVAudioSession` | `ao_audiounit.m:231-242`、`:257-265` |
| M4 | 會拆掉音訊輸出（＝停用整個工作階段）的時機：mpv 銷毀、播完進入 idle（libmpv 預設 `idle=yes`）、`stop`、換成音訊格式不同的檔案（預設 `gapless-audio=weak`）、檔案沒有音軌、`aid=no`、執行中改音訊選項 | `player/main.c:177-182`、`player/playloop.c:1336-1342`、`player/audio.c:385-411`、`:547-553`、`player/loadfile.c:719-723`、`:1945-1946`、`etc/builtin.conf:21-23` |
| M4 | **不會**拆掉：暫停／繼續、`paused-for-cache`、seek、`vid=no`／`vid=auto`、PiP 切換 vo、同格式的 `loadfile replace` | `player/audio.c:385-395` 等 |
| M6 | 以暫停狀態載入也會建立音訊輸出並啟用工作階段 | `player/playloop.c:1272`、`player/audio.c:869-889`、`:497-498` |
| M7 | `audio-exclusive=yes` 在 iOS 只讓 `ao_audiounit` 不加 MixWithOthers，其餘（啟用、停用）不變；執行中改會重建音訊輸出，所以要在 `mpv_initialize` 前設 | `player/audio.c:429`、`ao_audiounit.m:118-121`、`options/options.c:748`（`UPDATE_AUDIO`） |
| M8 | WebHTV 的 Libmpv 同時編入 `ao_audiounit` 與 `ao_avfoundation`；預設選 audiounit，avfoundation 只在 audiounit 失敗時接手 | MPVKit recipe `9d057f9c19fa704e242b199d26bc6c5cf23dd5d6` 的 meson 參數與 patch `0003-enable-avfoundation-ao-tvos.patch` |
| M9 | `ao_avfoundation` 設不混音的 `.playback`，但拆掉時同樣 `setActive:NO`＋通知其他 App | `ao_avfoundation.m:223-230`、`:322-327`、`:346-351` |

歷史：啟用／停用自 driver 加入就存在（`3f5b41dfa30ca282fd99176bf879493dd72b3119`，2016，PR #3696）；MixWithOthers 預設與 `audio-exclusive` 對應在 `748fc2b752091ec9d8addbc5c4041d55e877c196`（2024-12-31 合併，PR #15506，mpv 0.40.0 起）。PR 本文說明目的是「OS won't pause other sources of audio when playback starts in MPV」。`ao_audiounit.m`、`ao_avfoundation.m` 在 v0.41.0 之後的 master（`2a4eb8067ca68ec19adf23daf8ccbb1a05afd6ed`）沒有變更。

## 三、最佳實務研究（2026-09-25 讀取）

評級：A＝原始碼、規格或官方文件；B＝維護者或 Apple 工程師；C＝成熟專案程式碼；D＝論壇或 issue 回報。每一條都由另一個代理重新讀原始來源做過反駁驗證；標「更正」的是驗證時修正過細節的。

### 1. Apple 官方文件

| # | 來源 | 級 | 內容 | 對決策的影響 |
|---|---|---|---|---|
| A1 | https://developer.apple.com/documentation/avfaudio/avaudiosession/setactive(_:options:) | A | 「Deactivating an audio session with running audio objects stops the objects, makes the session inactive, and returns an AVAudioSession.ErrorCode.isBusy error.」 | mpv 晚到的 `setActive(NO)` 會停掉已經開始的原生播放；換核心的競態是真的風險 |
| A2 | https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/mixwithothers | A | 「Clearing this option and then activating your session interrupts other audio sessions. If you set this option, your app mixes its audio with audio playing in background apps, such as the Music app.」`.playback` 預設不混音 | MPV 目前會和音樂混音；改成不混音後，啟用時會中斷其他 App |
| A3 | WWDC22 110338、WWDC19 501 逐字稿 | A（更正） | 要成為「正在播放」的 App，iOS 上需要不混音的類別，並至少支援一個遠端控制指令；WWDC22 稱之為系統的判斷條件（heuristics） | 混音類別讓原生播放失去鎖定畫面的資格。MPV 本身沒有遠端控制指令，修好類別也不會讓 MPV 出現在鎖定畫面 |
| A4 | Audio Session Programming Guide「Activating an Audio Session」（archive） | A | AVFoundation 的播放類別會自動啟用工作階段 | 原生播放在工作階段未啟用時會自己啟用；MPV（RemoteIO）不會 |
| A6 | 同上指南 Table 3-2（Handling Audio Interruptions） | A | I/O audio unit 由 App 負責中斷後的重新啟用 | MPV 的重新啟用要由 App 做 |
| A7 | 同上指南 Appendix A「User-Controlled Playback」 | A（更正） | 前景時保持啟用；按播放才啟用；中斷時不要停用。「影片結束就停用並通知其他 App」是給社群類短影片 App 的，不適用長片播放器 | WebHTV 屬於長片播放器：按播放前啟用、之後保持啟用 |
| A8 | https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller 、Adopting Picture in Picture in a standard player | A（更正） | PiP 需要背景音訊模式與 `.playback` 類別，並以 `setActive` 啟用；沒有文件說混音會擋 PiP | 改成不混音與 PiP 的要求一致 |

### 2. 上游原始碼與維護者討論

| # | 來源 | 級 | 內容 |
|---|---|---|---|
| F1 | mpv PR #15506 本文與 `748fc2b752091ec9d8addbc5c4041d55e877c196` | B（更正） | MixWithOthers 是刻意的預設（讓 mpv 不打斷其他音樂），維護者 llyyr 要求對應到既有的 `--audio-exclusive`；沒有討論嵌入 App 的工作階段歸屬 |
| F2 | mpv v0.41.0 與 master `2a4eb806` | A | `audio-exclusive` 只影響類別選項；停用在任何設定下都會發生 |

上游測試：mpv 沒有 iOS 音訊工作階段的測試（需要裝置），不列入。上游沒有 revert。

### 3. 成熟相關專案

| # | 專案（revision） | 級 | 做法 | 適用性 |
|---|---|---|---|---|
| C6／F3 | media_kit：libmpv-darwin-build `aadae8ce295dd15a222839c361c4c984ce9befb2`（patch `159703a6f8b17bdb756d5a687d1ec1e29d90d366`、`763a7fa17a1d66ebf29b8fe2fb46c15769d3a12e`），media-kit PR #1419（2026-06-24 合併） | C／B | 遇到同一個衝突後修改 libmpv：新增 `audiounit-skip-session-management`，開啟時 mpv 完全不碰工作階段，由 App 負責；說明寫「only one of them should own the session」 | 最接近的前例，支持「App 擁有工作階段」；但要改 Libmpv 二進位（方案 O3） |
| C13／F8 | Yattee `2969b086924b1d9f490615fee57ba42761fa8973`（未修改的 mpv 0.41.0，`ao=audiounit`） | C（更正） | App 在 `FILE_LOADED`、`PLAYBACK_RESTART`、`AUDIO_RECONFIG` 與播放開始時，重新設 `.playback`／`.moviePlayback`（不混音）並 `setActive(true)`；Yattee 只有 MPV，沒有換核心的情境 | 支持「不改 Libmpv，由 App 重新設定」（方案 O2）；MPV 的 sample-buffer PiP 在不混音類別下可用 |
| — | Swiftfin `777a5cadedc631154633f8afbf9607aa8648504e`＋MPVUI `794ef73e5fb0fa356a4b488ab98d3cd43903b521` | C | 同時有 mpv 與 AVPlayer；mpv 用 `ao=avfoundation`（不混音），由 App 啟用、停用工作階段，停用延後 0.3 秒 | 成熟的雙核心前例：由 App 決定時機，並避開拆掉時的時序 |
| C9 | react-native-video `6dd359f8a4ef034e8e9cf2389d9242aa5bb4d992` | C | 一個 singleton 管理所有播放器的工作階段；每次播放／暫停都無條件 `setActive(true)`，註解說明沒有公開的 isActive，快取的旗標會在系統暫停 App 後失準 | 支持「每次按播放都啟用」，不要只靠 IOS-POC-23 的旗標 |
| C5 | KSPlayer `92c18fae716f63a080541c4bcc77247ade181426` | C | 每次建立播放器都設 `.playback`／`.moviePlayback`（不混音）並啟用 | 引擎自己設定，但用不混音 |
| C1 | VLC `9e59d4b38f804b33491b332df7643c1f80cc0b57` | C（更正） | 音訊輸出以不混音類別啟用，停止時以參考計數停用並通知其他 App；計數是每個 plugin 各自一份 | 引擎擁有工作階段的做法，WebHTV 不採用 |
| C11 | MPVKit `f82e06d4f5ef4fc4aa9faba3782a462dbbef870c` | C | 從未修改 `ao_audiounit` 的工作階段行為；demo 沒有設定工作階段 | WebHTV 的 Libmpv 繼承 mpv 原樣 |

整體趨勢：兩種做法。(a) 引擎擁有工作階段、App 配合（VLC、KSPlayer、原版 mpv）；(b) 只有一個擁有者，其他人退出或配合（media_kit、react-native-video、Swiftfin、Yattee）。同時有兩個核心的 App 都採 (b)。在找到的專案中，沒有任何一個設定 `audio-exclusive`。

### 4. 論壇與實地回報

| # | 來源 | 級 | 內容 |
|---|---|---|---|
| F4 | https://github.com/media-kit/media-kit/issues/1115 | D | 釋放上一個 libmpv 播放器、同時開始下一個時，系統記錄「Deactivating an audio session that has running I/O」，影片被自動暫停；以 PR #1419 的方式修正 |
| F6 | WWDC19 501 | A（更正） | 按播放才啟用；啟用後可以一直保持啟用 |

論文：音訊工作階段的歸屬由 Apple 平台實作決定，找不到相關的學術文獻，判定為不適用。

未能讀取：mpv PR #15506／#3696 的留言串（只拿到 WebFetch 摘要）、MPVKit #71 與 media-kit 部分 issue 的留言、Apple「Becoming a now playable app」範例程式（下載主機被擋）。這些都不影響下面的決策。

## 四、現況審查（HEAD `48cf6654`）

1. App 設定工作階段只有兩處：
   - 啟動時的類別與啟用（`WebHTVApp.swift:27-28`）；
   - `activateAudioSessionIfSuspended()`（`:2681-2689`），只在 IOS-POC-23 偵測到被系統暫停執行後才動作，而且只 `setActive(true)`，不重設類別。
   - 它的呼叫處只有 `control("play")`、`control("replay")` 與 `load(autoplay: true)`（`:2696`、`:2711`、`:2794`）。
2. 繞過上面這三處的播放路徑：
   - 換核心（`select`、失敗換核心、開播逾時）：原生在 `loadNative` 直接 `player.play()`（`:2924-2925`）；
   - MPV 子母畫面的播放鍵：`MPVEngine.swift:953-955` 直接呼叫 `engine?.play()`；
   - AVPlayer 子母畫面的播放鍵：由 AVKit 直接控制 player，但 AVFoundation 會自己啟用工作階段（A4）。
3. `PlayerRouter` 同一時間只有一個 engine。`run()` 先 `teardown()` 舊的，再建新的並 `load`（`PlaybackEngine.swift:459-478`）。會拆掉 MPV 的時機：
   - 換核心（`handOff`）；
   - `stop()`（`:450-454`）；
   - 關閉播放器後下一次預設核心不同（`endSession`，`:438-447`）。
   這三種都以非同步的 `mpv_terminate_destroy` 執行，完成時沒有通知 App。
4. 同一個 MPV core 內，mpv 會在第二節 M4 列出的時機自己停用、再啟用工作階段；App 收得到的只有 `MPV_EVENT_AUDIO_RECONFIG`，而且是在 mpv 動作之後。
5. 子母畫面：兩個核心都不碰工作階段，依賴啟動時的 `.playback` 與背景音訊模式（`Info.plist`）。MPV PiP 在真機、混音狀態下出過畫面（IOS-POC-17H 第六節之六）。
6. App 沒有使用 `MPNowPlayingInfoCenter`／`MPRemoteCommandCenter`。原生靠 `AVPlayerViewController` 的預設值，MPV 沒有「正在播放」（MPV parity P5 未實作）。
7. 另外觀察到、不在本任務範圍：App 啟動時就啟用不混音的工作階段，一開 App 就會中斷其他 App 的音樂；Apple 建議延到按播放時（A7）。這是 IOS-POC-10H 為了 PiP 做的既有行為，本任務不改。

## 五、方案比較

| 方案 | 內容 | 能否解決第一節的問題 | 主要缺點與風險 |
|---|---|---|---|
| O0 不改 | — | 否 | 問題持續 |
| O1 `audio-exclusive=yes` | 建立 mpv 時多設一個選項 | 只解決類別（MPV 與之後的原生都不混音） | 停用與換核心的競態仍在；以暫停狀態載入 MPV 也會中斷其他 App 的音樂（M6） |
| O2 App 重新設定 | App 在每次播放前重設類別並啟用；換核心時等 MPV 放掉音訊再讓原生開始 | 搭配 O1 可解決使用者會遇到的問題 | mpv 仍會在每集之間停用再啟用：如果使用者原本在聽別的音樂，換集時音樂可能短暫響一下；多一點 App 程式 |
| O3 修改 Libmpv | 反向移植 media_kit 的 `audiounit-skip-session-management`（也要處理 `ao_avfoundation`），完全由 App 擁有工作階段 | 根本解決，每集之間也不會停用 | 要改 WebHTV 的 Libmpv 建置：workflow 與 lock 目前只支援一個替換 patch；符號比對會因 `setCategory:withOptions:error:` 消失而失敗，需要新的具名例外；要發新的 prerelease 並更新 `Package.swift` 的 checksum，還有授權與出處紀錄。17I 從 push 到發布花了約 25 分鐘（含三次比對腳本修正）。App 也要自己處理中斷後的重新啟用（A6） |
| O4 `ao=avfoundation` | 改用另一個音訊輸出 | 只解決類別 | 拆掉時仍會停用；上游有未解的 issue（mpv #18461 檔尾音訊被截斷、#16346 從 underrun 恢復時掉幀，都是 macOS 回報，但音訊輸出程式碼相同）；會失去 audiounit 的多聲道設定 |

判斷：上游 mpv 的預設（混音、拆掉就停用）是為「只有 mpv 一個播放器」設計的。WebHTV 有兩個核心，需要**補充**上游：讓 App 當唯一的擁有者。O1＋O2 不動二進位就能消除使用者會遇到的問題。O3 是更徹底的修法，但成本與風險高出許多，留到有證據需要時再做。

## 六、原建議：O1＋O2（使用者未採用）

1. **MPV 不再要求混音**：`MPVPlayerCore.init` 在 `mpv_initialize` 前設 `audio-exclusive=yes`（M7）。mpv 設的類別就和 App 相同。
2. **App 在每次播放前確保工作階段正確**：把 `activateAudioSessionIfSuspended()` 改成每次都執行的 `activateAudioSession()`。
   - 類別、模式或選項和 App 的設定不同時，先重設成 `.playback`＋`.moviePlayback`、不混音；
   - 然後 `setActive(true)`，對已啟用的工作階段沒有副作用；失敗只記 log，下次播放再試。
   - 拿掉 IOS-POC-23 的 `audioSessionSuspended` 旗標：不論被系統暫停、被 mpv 停用，還是被中斷，都在下一次播放前恢復（C9）。
   - 仍然只在「開始播放」時啟用，不在回到 App 或以暫停狀態載入時啟用（A7，IOS-POC-23 的設計不變）。
3. **補上繞過的播放路徑**：
   - MPV 子母畫面的播放鍵（`MPVEngine.swift:953`）；
   - 原生在 `loadNative` 自動播放的地方（換核心、下一集、失敗換核心）。
4. **換核心時，等 MPV 放掉音訊再讓原生開始**：
   - MPV 銷毀時記錄「正在釋放」，`mpv_terminate_destroy` 返回後清除；
   - 原生要自動播放時，如果有 MPV 正在釋放，就等它完成（最多 1 秒）再啟用工作階段並播放；
   - 等待期間使用者按暫停、換集或關閉，就不播放。
   - 沒有 MPV 正在釋放時，行為和現在相同（立即播放）。
5. **不改**：Libmpv 二進位、lock、mpv 的其他選項、App 啟動時的設定、IOS-POC-23 的重新載入判斷、子母畫面。
6. **不新增單元測試**：新邏輯都在 App target（AVFoundation、mpv），WebHTVCore 沒有變更；本環境也無法執行 `swift test`。驗證靠發版 workflow 的編譯與真機測試。

## 六之二、使用者選定 O3（2026-09-25）：實作設計

使用者在選擇題中選了「O3 修改 Libmpv」，並知道它要改 Libmpv 建置流程、發布新的 Libmpv prerelease。App 的新版本號、tag 與 SideStore 發布仍要另外詢問。

### 1. 單元 IOS-POC-24-1：Libmpv 加上「由 App 擁有工作階段」的選項

1. 新 patch：`third_party/mpv-ios/patches/libmpv/0004-ao-app-owned-audio-session.patch`。檔名排在 MPVKit 的 0003 之後，recipe 依檔名排序以 `git apply` 套用（MPVKit `9d057f9c19fa704e242b199d26bc6c5cf23dd5d6` `Sources/BuildScripts/XCFrameworkBuild/base.swift:125-135`）。已在 mpv v0.41.0＋WebHTV 0001＋MPVKit 0002／0003 上以 `git apply --check` 確認可以套用。
   - `ao_audiounit.m`：新增 `audiounit-skip-session-management`（`OPT_BOOL`，預設關閉；做法與命名沿用 media_kit，C6）。開啟時，初始化不設類別、模式，也不 `setActive(YES)`；拆掉時不 `setActive(NO)`。
   - `ao_avfoundation.m`：新增 `avfoundation-skip-session-management`，行為相同，因為它是 audiounit 失敗時的備援（M8）。
   - **與 media_kit 的差異（WebHTV 調整）**：兩者都保留 `setPreferredOutputNumberOfChannels`。WebHTV 的 App 不管理聲道數，保留它才能維持目前接 HDMI 或 AirPlay 時的多聲道輸出。media_kit 較新的版本（`763a7fa17a1d66ebf29b8fe2fb46c15769d3a12e`）把它交給 App 處理。
   - 沒有採用 media_kit 在「不略過」時的參考計數：WebHTV 同一時間只有一個 mpv core，而且一定會開啟略過。
   - 選項預設關閉：沒有設定選項的 mpv 行為和原版完全相同。
   - 選項名稱由 driver 的 `options_prefix` 註冊成全域選項（mpv `options/m_config_core.c:470-473`、`audio/out/ao.c:126`、`:140`），所以可以在 `mpv_initialize` 前用 `mpv_set_option_string` 設定。
2. workflow（`.github/workflows/ios-libmpv-build.yml`）：
   - 驗證新 patch 的 hash，並複製進 recipe 的 patch 目錄；
   - 檢查建置用的原始碼含有新選項；
   - 在比對步驟加一項正向檢查：binary 內有 `skip-session-management` 字串；
   - release notes 提到第二個 patch。
   - 比對規則不用放寬：原本的 `setCategory` 等呼叫還在程式裡（只是加了條件），選項用的 `m_option_type_bool` 本來就被其他成員引用，所以未定義符號的集合不會改變（第五節 O3 提到的例外只在「刪除呼叫」時才需要）。如果比對仍然失敗，停下來把原因寫進本文件，再問使用者。
3. lock、README、MANIFEST：
   - `third_party/mpv-ios-lock.json` 新增 patch 項目；`artifact.release_tag` 改成 `mpvkit-1.0.0-webhtv.2`（workflow 不會覆蓋已發布的 tag）。
   - `third_party/mpv-ios/README.md` 說明第二個 patch，以及 LGPL 對應原始碼包含它。
   - `MANIFEST.sha256` 加上新檔。
4. push 後，workflow 因 patch 路徑變更自動建置，並發布 prerelease `mpvkit-1.0.0-webhtv.2`。17I 每次建置約 3～4 分鐘。

### 2. 單元 IOS-POC-24-2：App 改用新 Libmpv，並成為唯一擁有者

1. `third_party/mpv-ios-lock.json` 的 artifact 欄位，以及 `ios/Vendor/MPVKit/Package.swift` 的 `Libmpv` url 與 checksum，都改成 webhtv.2 的實際值。
2. `MPVEngine.swift`：`MPVPlayerCore.init` 在 `mpv_initialize` 前設這兩個選項。設定失敗（例如 Libmpv 沒有這個選項）時記一行 log，不影響播放。
3. `WebHTVApp.swift`：
   - `activateAudioSessionIfSuspended()` 改成每次都執行的 `activateAudioSession()`，拿掉 IOS-POC-23 的 `audioSessionSuspended` 旗標。
   - 改由 App 自己在 mpv 開始出聲前啟用工作階段。這是因為 mpv 的 RemoteIO 不會自己啟用，被中斷或系統暫停 App 後也不會恢復（A4、A6）。
   - 仍然只在「開始播放」時啟用（A7）；啟動時的設定（`:27-28`）不變。
4. 補上繞過的播放路徑：
   - MPV 子母畫面的播放鍵（`MPVEngine.swift:953`）；
   - 換到 MPV 並自動播放（`MPVEngine.load` 帶 `autoplay`）。
   - 原生由 AVFoundation 自己啟用（A4），不用另外處理。
5. 更新已經過時的註解：`WebHTVApp.swift:2675-2680` 寫「mpv only when it creates its audio output」。
6. 第六節之 4「等 MPV 釋放音訊」不需要了：mpv 不再停用工作階段，換核心沒有競態。
7. 不新增單元測試：WebHTVCore 沒有變更；本環境無法執行 `swift test`。

### 3. 各單元的驗證

1. 24-1：workflow 的 recipe patch 檢查、建置、「建置用的原始碼含新選項」、與上游的比對（含新的正向檢查）全部通過，並發布 prerelease；下載 zip 核對 sha256 與 SwiftPM checksum。
2. 24-2：發版 workflow 編譯成功（需要使用者授權新版本），再以第七節做真機驗收。

## 七、驗收標準（真機，SideStore）

1. 先在「音樂」App 播放音樂，再用 MPV 播影片：音樂停止，和原生播放相同。
2. MPV 播放中，從控制列換到原生：原生在 5 秒內繼續播放而且有聲音，不會自己停下。原生換到 MPV 也一樣。
3. MPV 播放後關閉播放器，改用原生打開另一部影片：有聲音。
4. MPV 自動播下一集：有聲音。
5. MPV 子母畫面內暫停超過 1 分鐘，再按小視窗的播放鍵：有聲音。
6. MPV 播放中被來電或 Siri 打斷，結束後按播放：有聲音。
7. 既有行為不變：IOS-POC-23 T1～T3（兩個核心）、T4（播放中背景有聲音）、T5（子母畫面進出）、2.5×／3× 交給 MPV（IOS-POC-22）、MPV 旋轉。
8. 觀察項目（記錄即可，不是通過條件）：用過 MPV 之後播放原生，鎖定畫面或控制中心是否出現「正在播放」。

## 八、回滾

1. 兩個單元各是一個 commit。`mpvkit-1.0.0-webhtv.1` 仍然保留在 GitHub release。
2. 只 revert 24-2：App 回到 webhtv.1 與原本的工作階段處理，因為 lock 與 `Package.swift` 的 artifact 欄位在 24-2 裡。
3. 24-1 的 patch 與 workflow 可以留著：選項預設關閉，不影響沒有設定它的 App。要完全回到 17I 的狀態，再 revert 24-1；已發布的 webhtv.2 prerelease 留著即可，不必刪除。
4. 使用者也可以直接在 SideStore 裝回上一版。

## 九、未解與後續

1. 工作階段沒有啟用時（例如系統暫停 App 後回來，IOS-POC-23 以暫停狀態重新載入），mpv 建立音訊輸出時設定偏好聲道數會失敗，那一集可能只輸出雙聲道。只影響多聲道輸出（HDMI、AirPlay 環繞聲），先記錄，不處理。
2. 本環境不能編譯 Objective-C／iOS SDK，patch 的第一次編譯在 Libmpv workflow。
3. App 啟動就中斷其他 App 音樂（第四節之 7），另開任務時再評估。
4. MPV 的「正在播放」與鎖定畫面控制是 MPV parity P5，不在本任務範圍。

## Recovery anchor

- 目標：兩個核心共用一個由 App 擁有的音訊工作階段（不混音的 `.playback`，播放時啟用），不再被 mpv 改成混音或在換核心時停掉原生。
- 狀態（2026-09-25）：使用者選定 O3；方案（第六節之二）已記錄。patch 草稿已在 mpv v0.41.0＋0001～0003 上通過 `git apply --check`（sha256 `d00c58303b3233899410d9cb7c559f51f27fd3286cd9257d34d02410ed488f6c`，尚未 commit）。
- 下一步（唯一）：以新的 guard session `IOS-POC-24-1` 實作第六節之二第 1 點（patch、workflow、lock、README、MANIFEST），push 後等 Libmpv workflow 發布 `mpvkit-1.0.0-webhtv.2`。
