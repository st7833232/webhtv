# IOS-POC-17H — MPV 子母畫面（Picture in Picture）

- 狀態（2026-09-24 14:50 CST）：**實作完成、模擬器能驗的部分都已驗證、真機未驗證**；commit `8824c8ee`，**已於 2026-09-24 以 `0.1.11 (12)` 發布**（run `35968750165`）。
  PiP 視窗在模擬器上全黑＝模擬器對 sample-buffer PiP 的已知限制，不是本實作的錯（第六節之二的對照實驗）；PiP 畫面、自動 PiP、PiP 控制都要真機驗。
- 授權：使用者 2026-09-24「MPV的pip 我要直接實作完成」——即 IOS-POC-17 第十四節 MPV parity **P6**，直接實作，不先停在 spike。
- Lane：`standard`（新的使用者功能，renderer 路徑有變動）。基線 HEAD `257553f2`（IOS-POC-17G，當時本機、未 push）。
- 範圍：`ios/WebHTVApp/Sources/MPVEngine.swift`、`ios/WebHTVApp/Sources/WebHTVApp.swift`（只有 MPV surface 接上 PiP 狀態）、本文件、IOS-POC-17 文件與交接文件。
  **不含**：AVPlayer 的 PiP（不動）、手動 PiP 按鈕（使用者先前決定不要）、背景音訊／鎖屏／remote command（P5）、AirPlay（P7）、libmpv 重編。

## 一、要做到的行為（與 AVPlayer 現行 PiP 對齊）

AVPlayer 路徑的既有產品決定（`PlayerSurface`，IOS-POC-10H／10G）：
- **沒有手動 PiP 按鈕**（使用者要求不畫）；**離開 App 時自動進入 PiP**（`canStartPictureInPictureAutomaticallyFromInline = true`）。
- **回到 App 就結束 PiP**，回到原本的播放畫面（`PictureInPictureForegroundRestoreState`）。
- PiP 期間關閉播放畫面不得暫停／拆掉播放（`PlayerView.onDisappear` 讀 `pictureInPicture`）。

MPV 版要同樣：MPV 播放中滑回主畫面 → 自動出現 PiP 視窗、持續出畫面與聲音；PiP 視窗的播放／暫停／快轉倒轉可用；回到 App → PiP 結束、MPV 在原位置繼續以原本畫面播放。

## 二、研究（2026-09-24 實際讀過的來源）

| # | 來源 | 版本／存取 | 等級 | 支撐的事實 | 對決策的影響 |
|---|---|---|---|---|---|
| R1 | Apple「Preparing your Metal app to run in the background」 | developer.apple.com 文件 JSON，2026-09-24 | 官方文件 | 「iOS and tvOS restrict a background app's access to the GPU…the system prevents those commands from executing」 | PiP 通常在 App 進背景時啟動；**現行 Metal／MoltenVK 路徑在背景不能出畫面**，PiP 的畫面必須在 CPU 上產生 |
| R2 | Apple `AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)`、`AVPictureInPictureSampleBufferPlaybackDelegate` | 同上 | 官方文件 | 自訂播放器的 PiP 內容來源是 `AVSampleBufferDisplayLayer`；delegate 五個必要方法：`setPlaying`、`timeRangeForPlayback`、`isPlaybackPaused`、`didTransitionToRenderSize`、`skipByInterval` | 唯一公開的非 AVPlayer PiP 路徑 |
| R3 | Apple `canStartPictureInPictureAutomaticallyFromInline` | 同上 | 官方文件 | 「starts automatically when the controller embeds its content inline and the app transitions to the background」 | 自動 PiP 需要 sample buffer layer **平常就在畫面裡（inline）**，不能等到要進背景才建立 |
| R4 | MPVKit `Libmpv.xcframework` `mpv/render.h` | MPVKit `1.0.0`（`288527dffbc6d3e63cce147fc7b520c64a791603`），本機 SPM artifact | 上游標頭 | render API 只有 `opengl` 與 `sw`；SW：`rgb0/bgr0/0bgr/0rgb`，「0」那一個 byte 是垃圾值；stride／pointer 建議 64 對齊；整個色彩轉換、縮放、OSD 都在 CPU 單執行緒，**大尺寸與字幕會太慢**，`sw-fast` 有幫助；render 函式不可在 wakeup／update callback 內呼叫；render 執行緒不能等待一般 libmpv API；同一 core 只能有一個 render context；`mpv_render_context_free` 必須在 core 銷毀前 | PiP 視窗很小，以 PiP 尺寸（上限 960 寬）做 SW render；alpha 自己補 255；獨立 render queue |
| R5 | mpv `video/out/vo_libmpv.c` | tag `v0.41.0`，raw GitHub | 上游原始碼 | `preinit` 取不到 render context 就 `No render context set.` 失敗 | 必須先建 render context，再把 `vo` 切成 `libmpv` |
| R6 | mpv `player/command.c`（`UPDATE_VO`）、`options/m_config_core.c` | 同上 | 上游原始碼 | 設定 `vo` 會同步 `uninit_video_out` → 重建 VO → exact seek；相同值不觸發 | PiP 開始／結束各切一次 `vo`（`gpu-next` ↔ `libmpv`）；代價是一次 exact seek |
| R7 | mpv `audio/out/ao_audiounit.m` | 同上 | 上游原始碼 | 除非 `audio-exclusive`，AO 會把 session 設成 `playback`＋`mixWithOthers`、`moviePlayback` | 可混音的 session 可能影響 PiP／Now Playing 資格：**先實測**，不行才加 `audio-exclusive=yes` |
| R8 | VLC `modules/video_output/apple/VLCSampleBufferDisplay.m` | `master`，code.videolan.org raw，2026-09-24 | 成熟專案原始碼 | VLC 4 在 Apple 平台用 `AVSampleBufferDisplayLayer` 顯示 CVPixelBuffer 並接 PiP controller；PTS 以 `CACurrentMediaTime` 為基準；layer `status == failed` 且 `requiresFlushToResumeDecoding` 時在回前景／通知時 flush 復原 | 同一條路已被成熟播放器採用；照抄 flush 復原 |
| R9 | harflabs/SwiftVLC `Sources/SwiftVLC/PiP/PiPVideoView+iOSNative.swift`、`ARCHITECTURE.md`（Physical-device Validation）、`PictureInPicture.md` | `main` `0ec31e4ecd31d08189b5aa64f86dc00f1434c978`，2026-09-24（研究 workflow 讀原文） | 上游原始碼＋維護者文件 | 程式註解：模擬器「can report active sample-buffer PiP while rendering a black window」；`targetEnvironment(simulator)` 直接關掉 sample-buffer PiP；端到端 PiP 需真機 | **本任務的黑畫面就是這個症狀**；模擬器只能驗狀態流程與影格送達，不能驗 PiP 畫面 |
| R10 | Soupy-dev/MPVKit `README.md` L151-153、`Sources/MPVKitSampleBuffer/MPVMetalSampleBufferRenderer.swift` | branch `eclipse-mpv-metal` `aeabc06e7a55475a46793fb71b6b4103b26d1f0d`，2026-09-24 | 上游原始碼（最接近的同類：libmpv → IOSurface → sample buffer PiP） | README：模擬器只做編譯與狀態流程驗證，「PiP black-frame, timing … acceptance require physical devices」；`bgr0` 第四 byte 會被 iPad PiP compositor 當 alpha；control timebase 只在偏差 >1 秒時重新定錨 | 確認 alpha 補 255 是必要的（已做）；timebase 改成偏差 >1 秒才校正 |
| R11 | kingslay/KSPlayer `Sources/KSPlayer/MEPlayer/MetalPlayView.swift` L304-363、`KSMEPlayer.swift` | `main` `92c18fae716f63a080541c4bcc77247ade181426`，2026-09-24 | 成熟專案原始碼（已出貨） | `DisplayImmediately = true` 搭配以播放位置設定的 `controlTimebase`，`displayLayer.enqueue`；`requiresFlushToResumeDecoding` 或 `.failed` 時 flush | SDK 標頭說這種搭配「not recommended」，但已出貨的播放器就是這樣用；本任務保留此搭配（理由見 R12 與第六節） |
| R12 | Apple SDK 標頭 `AVSampleBufferVideoRenderer.h`、`AVSampleBufferDisplayLayer.h`（Xcode 27，iPhoneOS27.0 SDK） | 本機 SDK，2026-09-24 | 官方標頭 | 非 NULL control timebase 與 `DisplayImmediately` 併用「is not recommended」；`DisplayImmediately` 的影格「displayed as soon as possible, replacing all previously enqueued images」；CVPixelBuffer 必須 IOSurface-backed | 實測改成「PTS＝timebase 現在時間、不加 `DisplayImmediately`」後，SW 影格被我們每 0.5 秒輪詢的 timebase 節流到約每秒 2 張（第六節之二），所以保留 `DisplayImmediately`；IOSurface 已滿足 |
| R13 | Apple Developer Forums thread 745840 | 2026-09-24 | 論壇（無 Apple 回覆） | 真機鎖屏約 30 秒後 sample-buffer PiP 變黑，之前 `requiresFlushToResumeDecoding` 變 true；flush 後恢復 | `show()` 在 `.failed` **或** `requiresFlushToResumeDecoding` 時 flush |
| R14 | uakihir0/UIPiPView README、issue #17 | `main` `55994ac410ec29d81958f689b22eae0917445da9`，2026-09-24 | 維護者文件＋issue | README：PiP 只在真機可用；#17：`timeRangeForPlayback` 回 (-∞, +∞) 在 iOS 16.1+ 讓 AVKit 的 timer 吃 CPU | 直播／未知長度改回 Apple 文件的形式 `[0, +∞)` |
| R15 | VLC `modules/video_output/apple/VLCPictureInPictureController.m` | `master` `1b92ac6ce09a94f69cac98bf0c5b9de5289a1e73`，2026-09-24 | 成熟專案原始碼 | PiP 開啟時 AVKit 不會自己重讀時間範圍，VLC 在 will-start 呼叫 `invalidatePlaybackState()` | `willStart` 補一次 `invalidatePlaybackState()` |

**不適用而未查**：論文、benchmark——決策由平台限制（R1）與 libmpv 可用 API（R4）決定，沒有會被效能文章改變的選項；
真機 CPU 負載要靠實測，本輪無法取得。R9–R15 是 2026-09-24 第二個 session 為了黑畫面另跑的研究 workflow（三個方向：成熟專案原始碼、
官方文件／論壇、模擬器限制），逐一讀過原文；沒有 Apple 第一方聲明說模擬器不支援，所以結論仍標「真機未驗證」。

## 三、方案比較

| 方案 | 內容 | 結論 |
|---|---|---|
| no change | MPV 不支援 PiP | 不採用：使用者要求 |
| 上游原樣 | libmpv 沒有 PiP；MPVKit demo 也沒有 | 無可照抄的上游實作 |
| 全程改 OpenGL render API → IOSurface pixel buffer → sample buffer layer | inline 與 PiP 同一條路 | 不採用：背景不能用 GPU（R1），PiP 一進背景就停格；而且 renderer 大改、HDR／效能回歸風險 |
| 全程 SW render | inline 也走 CPU | 不採用：1080p／4K、字幕時太慢（R4），inline 畫質與耗電回歸 |
| **採用：inline 維持 Metal，PiP 期間切 SW** | MPV view 內多一個 `AVSampleBufferDisplayLayer`（在 Metal layer 下方），平常先放一張黑色影格讓 PiP「可能」；`willStartPictureInPicture` 時建 SW render context、`vo=libmpv`，在獨立 render queue 以 PiP 尺寸畫進 BGRA CVPixelBuffer（alpha 補 255）送進 layer；`didStop` 時切回 `vo=gpu-next`（在背景就先 `vid=no`，回前景由既有流程建 Metal VO）再釋放 render context | 不動 inline 畫質與效能；背景只用 CPU；代價：PiP 開始與結束各一次 exact seek（短暫停頓）；PiP 剛出現時可能先看到黑畫面，直到第一張 SW 影格 |

## 四、驗收標準

1. MPV 播放中回主畫面 → 自動出現 PiP，畫面持續更新（不是定格），聲音繼續。
2. PiP 視窗的播放／暫停、快轉／倒轉有效，進度顯示合理。
3. 回到 App → PiP 結束，MPV 以 Metal 在目前位置繼續，畫面尺寸正確。
4. PiP 中按 X 關閉 → 不崩潰；回到 App 後 MPV 畫面正常。
5. AVPlayer 的 PiP 路徑不變（程式不動）；IOS-POC-17G 旋轉修正仍有效。
6. Simulator Debug build 無新 warning。真機項目一律標「未驗證」。

## 五、回滾

`git revert` 本任務 commit：MPV 回到沒有 PiP、`MPVVideoView` 回到單一 Metal layer；AVPlayer 不受影響，17G 旋轉修正保留。

## 六、實作紀錄（2026-09-24）

### 六之一、程式（本 commit）

- `ios/WebHTVApp/Sources/MPVEngine.swift`
  - `MPVVideoView` 改成容器：上層 `MPVMetalView`（mpv `wid`），下層 `MPVSampleBufferView`（`AVSampleBufferDisplayLayer`，平常被 Metal 蓋住、但在 window 裡，才能 inline 自動進 PiP）；17G 的尺寸處理保留（`onResize` → `rebuildVideoOutput()`）。
  - `MPVEngine`：`onPictureInPictureChange`、持有 `MPVPictureInPicture`；進背景時若 PiP 啟用就不 `vid=no`（那會凍住 PiP）；`teardown` 先 `invalidate`。
  - `MPVPlayerCore`：`videoReconfigured(width:height:)`（讀 `dwidth`／`dheight`）、`profile=sw-fast`（見第六節之五）、`startSoftwareOutput`（先建 SW render context → `vo=libmpv` → `vid=auto`）、`stopSoftwareOutput(keepVideo:)`（在背景先 `vid=no`，再 `vo=gpu-next`，最後釋放 context）、`rebuildVideoOutput` 在 SW 期間不動作、`shutdown` 先釋放 context。
  - `MPVSoftwareRenderer`：獨立 queue；`bgr0` 畫進 64-byte 對齊的 IOSurface BGRA pool，`mpv_render_context_render` 失敗就不送（buffer 內容是 pool 殘留）；第四 byte 補 255；`CMSampleBuffer`＝主機時鐘 PTS＋`DisplayImmediately`；`.failed` 或 `requiresFlushToResumeDecoding` 時 flush；`showPlaceholder()` 黑色影格。
  - `MPVPictureInPicture`：controller＋兩個 delegate、`canStartPictureInPictureAutomaticallyFromInline` **只在已載入、有影片的檔案時為 true**（`setHasVideo`：`load()` 先設 false，`fileLoaded(hasVideo:)` 設成實際值，`ended`／`failed` 設 false）、`PictureInPictureForegroundRestoreState`（回 App 就結束 PiP）、`willStart` 時 `invalidatePlaybackState()`；0.5 秒 tick：timebase 的 rate 跟著「真的在播」（暫停／緩衝＝0），**時間只在與 mpv 位置偏差 >1 秒時才校正**（原本每 0.5 秒硬設一次，CoreMedia log 每 0.5 秒一行 `figlayersync_setLayerTiming`＝layer 時間軸不連續）；時間範圍：沒載入＝`.invalid`、直播／未知長度＝`[0, +∞)`（SDK 標頭的兩種形式）；`isPlaybackPaused` 在沒載入時回 true；背景中 PiP **啟動失敗**不暫停（只有使用者從外面關掉視窗才暫停，同 AVPlayer）；`[pip]` Logger 行、`isPictureInPicturePossible` KVO。
- `ios/WebHTVApp/Sources/WebHTVApp.swift`：`MPVVideoSurface(engine: mpv, pictureInPicture: $pictureInPicture)`（只有這一行；AVPlayer 的 `PlayerSurface` 沒動）。
- 臨時程式 `TEMP-17H`（mpv log、render 計數／影格傾印、layer 狀態 log、旗標檔觸發的 PiP 開關、inline SW 切換、AVPlayer 與最小 sample-buffer PiP 對照組、layer tree 傾印、timebase／enqueue 切換、旋轉旗標）**已全部移除**：`grep -c TEMP` 兩個 Swift 檔都是 0，final build 的 `WebHTVApp.debug.dylib` 裡也沒有 `TEMP-17H` 字串。

### 六之二、黑畫面診斷（iPad mini (A17 Pro) 模擬器 iOS 26.3，`498F41F5-EC2B-4E27-94B4-A6B17E5080EC`，App 以 iPhone 相容模式執行；荐片「欢迎来龙餐馆」枪版，MPV）

| # | 實驗 | 結果 | 結論 |
|---|---|---|---|
| D1 | reboot 模擬器後以旗標檔手動 `startPictureInPicture()` | `[pip] mpv will start`；SW render 每秒約 30 張、`mpv_render_context_render` 回 0（374×170 → 330×150，隨 `didTransitionToRenderSize` 變小）；PiP 視窗全黑 | SW render **有**被呼叫而且成功 |
| D2 | 傾印第 60 張影格（326×150，stride 1344）轉 PNG | 畫面內容正確（人物＋中文字幕），alpha 全為 255 | 影格內容與 alpha 都正確 |
| D3 | layer 狀態＋CoreMedia log | `sampleBufferRenderer.status == .rendering`、無 error；FigVideoQueue 每 6 秒 180 張、`IQ-CA enqueued 181, displayed 181, dropped 0` | 影格有送進而且被顯示 |
| D4 | 不開 PiP、把 Metal view 藏起來、inline 走 SW 輸出 | inline 畫面正確而且持續更新（960×440） | sample buffer layer 本身能正常顯示這些影格 |
| D5 | inline SW 狀態下再開 PiP | App 內顯示 AVKit 的「This video is playing in picture in picture.」，PiP 視窗仍全黑 | 跟 `vo` 切換無關 |
| D6 | 同一個 App、同一台模擬器，另建 AVPlayer＋`AVPlayerLayer` 的 PiP controller（Apple bipbop HLS） | **PiP 視窗有畫面** | 模擬器的 PiP 視窗本身能顯示 AVPlayerLayer 的影片 |
| D7 | 最小 sample-buffer PiP 對照組：獨立 sublayer、無 control timebase、主機時鐘 PTS、**不加** `DisplayImmediately`、主執行緒 `layer.enqueue`、IOSurface BGRA 漸層、時間範圍 `[0, +∞)`（UIPiPView 的做法） | inline 顯示漸層；**PiP 視窗一樣全黑** | 教科書式的 sample-buffer PiP 在這台模擬器也是黑的 ⇒ **模擬器限制**（與 R9 SwiftVLC 記載的症狀相同） |
| D8 | 移除 control timebase／改用 `layer.enqueue` 各試一次 | PiP 仍全黑（移除 timebase 時系統控制列會出現） | 不是 timebase 或 enqueue API 造成 |
| D9 | 改成「PTS＝timebase 現在時間、不加 `DisplayImmediately`」（SDK 標頭建議的形式），inline 走 SW | 剛開播時完全沒有影格；之後每秒約 2 張、mpv 的播放位置 42 秒只前進 1.7 秒 | 影格被我們輪詢的 timebase 節流 ⇒ **不採用**；恢復主機時鐘 PTS＋`DisplayImmediately` 後同一流程每秒 30 張 |
| D10 | 同一次執行內連續 3 次（之後又 2 次）PiP 開→關 | 每次都 `will start` → `did stop`，沒有 `PGPegasusErrorDomain -1003`；關閉後 MPV 回到 Metal、畫面尺寸正確、繼續播放 | 上一個 session 的 `-1003` 是前一個 App 在 PiP 中被 terminate 留下的模擬器狀態，reboot 後不再出現 |
| D11 | timebase 改成偏差 >1 秒才校正後，最後 40 秒（含兩次 PiP 開關）的 `figlayersync_setLayerTiming` | 0 行（修改前每 0.5 秒 1 行） | layer 時間軸不再被週期性打斷 |
| D12 | final 程式＋暫時的旋轉旗標（`requestGeometryUpdate`）：直→橫、橫→直 | 兩個方向 MPV 都以新尺寸重畫、持續播放 | 17G 旋轉修正在新的容器 view 下仍有效（旋轉旗標之後已移除並重新 build） |
| D13 | 審查修正（第六節之五）後，再以暫時 hook 跑一次 | `mpv_set_option_string("profile", "sw-fast")` 回 0；AVKit 的 `alwaysStartsAutomaticallyWhenEnteringBackground`（＝`canStartPictureInPictureAutomaticallyFromInline`）在檔案載入前是 NO、載入有影片的檔案後變 YES；PiP 開→關正常，SW 影格每秒 30 張（960×440 → 310×142）；關閉後回到 Metal 繼續播放 | 修正後行為正確；hook 之後移除並重新 build |

### 六之三、驗證狀態

| 檢查 | 結果 | 等級 |
|---|---|---|
| Simulator Debug build（final，`TEMP-17H` 全部移除後；destination iPhone 17 Pro `7B4E9557-…`） | **BUILD SUCCEEDED**，`MPVEngine.swift` 0 個 warning（`WebHTVApp.swift` 3938–4074 行的 warning 是既有的，不在本次修改範圍） | 模擬器 |
| PiP 開始：`vo` 切到 SW、影格內容／alpha／送達／顯示 | 通過（D1–D4；審查修正後 D13 再確認） | 模擬器 |
| 自動 PiP 只對已載入的影片開放 | AVKit 狀態 log 由 NO 變 YES（D13）；實際「離開 App 自動開」仍要真機 | 模擬器（狀態）|
| PiP 結束：回到 Metal、尺寸正確、繼續播放；重複開關 | 通過（D10） | 模擬器 |
| 17G 旋轉 | 通過（D12） | 模擬器 |
| AVPlayer PiP 路徑 | 程式未改（`git diff` 只有 `MPVVideoSurface` 那一行） | 靜態 |
| **PiP 視窗裡的 MPV 畫面** | 模擬器全黑＝已知限制（D6、D7、R9、R10） | **真機未驗證** |
| **自動 PiP（播放中回主畫面）** | 模擬器連 AVPlayer 都不觸發（iPhone 17 Pro 不支援 PiP；iPad 按 Home 是 `ShouldAutoPiP NO`） | **真機未驗證** |
| PiP 視窗的播放／暫停、快轉／倒轉、進度顯示 | 模擬器的 PiP 視窗不畫控制列（有 timebase 時） | **真機未驗證** |
| 回到 App 自動結束 PiP、MPV 在原位置以 Metal 繼續 | 模擬器無法從背景觸發 | **真機未驗證** |
| 背景中 SW render 的 CPU／耗電、鎖屏後 PiP（R13） | — | **真機未驗證** |

### 六之四、剩下的風險（真機才會知道）

- **硬解**：真機 `hwdec=auto-safe` 走 VideoToolbox；`vo=libmpv`（SW）沒有 VT interop，mpv 重建 decoder 時應退到 `videotoolbox-copy`（`auto-safe` 白名單的下一個）。模擬器是 `hwdec=no`，這條路沒走過。
- **音訊 session**：mpv `ao_audiounit` 預設 `mixWithOthers`（R7）；若真機 PiP 不出現或 Now Playing 不對，第一個要試 `audio-exclusive=yes`（也是 P5 的前提）。
- **切換停頓**：PiP 開始／結束各一次 VO 重建＋exact seek；模擬器上看得到 h264「reference picture missing」之類的解碼警告，畫面在 1 秒內恢復。弱網若 demuxer cache 沒涵蓋目前位置，可能短暫緩衝。
- **CPU**：SW render 以 PiP 視窗寬度、上限 960 px 畫；真機的實際負載未量。

### 六之五、final-diff review（2026-09-24，三個方向各一個 reviewer，每個發現再由一個 verifier 試著反駁）

| 方向 | 發現 | verifier | 處理 |
|---|---|---|---|
| 回歸 | `mpv_set_option_string(handle, "sw-fast", "yes")` 無效：libmpv 0.41 的 `sw-fast` 是內建 **profile**（`sws-scaler=bilinear`、`sws-fast=yes`、`zimg-scaler=bilinear`、`zimg-dither=no`），不是選項，回 `MPV_ERROR_OPTION_NOT_FOUND`；PiP 的 SW render 其實用預設的慢 scaler | 成立（high）；本機 `strings` 也只找到 `[sw-fast]` profile 段落 | 改成 `profile=sw-fast`，D13 確認回 0；只影響軟體 scaler，Metal 的縮放不用它 |
| 回歸 | 背景中自動 PiP **啟動失敗**時 `ended()` 會暫停 MPV；HEAD 在同樣情況下只 `vid=no`、聲音繼續 | 成立（medium） | `ended(pausingInBackground:)`：只有 `didStop`（使用者從外面關掉視窗）才暫停；啟動失敗仍在背景 `vid=no` |
| 回歸／AVKit | 自動 PiP 對純音訊、載入失敗、已播完（mpv idle）的檔案也會開一個黑色視窗；純音訊時關掉它還會暫停背景音訊；時間範圍在沒內容時不是 SDK 規定的 `kCMTimeRangeInvalid`，`isPlaybackPaused` 也不反映「沒載入」 | 成立（medium，兩個 reviewer 各自找到） | `setHasVideo` 控制 `canStartPictureInPictureAutomaticallyFromInline`；沒載入時時間範圍 `.invalid`、`isPlaybackPaused` 回 true；`reported` 多追蹤 `loaded`，載入狀態一變就 `invalidatePlaybackState()` |
| 執行緒／libmpv 生命週期 | 無發現（render context 建立／釋放順序、core queue 與 render queue 的 `sync`、`shutdown` 順序都查過） | — | — |

## Recovery anchor

- 目標：MPV PiP（P6），行為對齊 AVPlayer 自動 PiP（第一節）。
- Git：基線 HEAD `257553f2`（17G，當時本機、未 push）；本任務 commit `8824c8ee`，已 push 並以 `0.1.11 (12)` 發布。
- 已完成：研究（第二節 R1–R15）、方案（第三節）、程式（第六節之一）、黑畫面診斷（第六節之二）、final-diff review 與四項修正（第六節之五）、`TEMP-17H` 全部移除、final build、IOS-POC-17 第十四節 P6 與交接文件更新。
- 未完成（只能真機）：第六節之三標「真機未驗證」的各項。
- 下一步（唯一）：使用者在 SideStore 更新到 `0.1.11 (12)` 後，在真機依第四節驗收標準驗 MPV PiP（先看 `[pip] mpv possible=` 與 `will start` log，再看 PiP 視窗是否有畫面）。
