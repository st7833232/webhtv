# IOS-POC-17H — MPV 子母畫面（Picture in Picture）

- 狀態（2026-09-24 14:50 CST）：**實作完成、模擬器能驗的部分都已驗證、真機未驗證**；commit `8824c8ee`，**已於 2026-09-24 以 `0.1.11 (12)` 發布**（run `35968750165`）。
  PiP 視窗在模擬器上全黑＝模擬器對 sample-buffer PiP 的已知限制，不是本實作的錯（第六節之二的對照實驗）；PiP 畫面、自動 PiP、PiP 控制都要真機驗。
  （2026-09-25 更正：使用者在 `0.1.11 (12)` 真機回報 PiP 解析度降低，表示真機 PiP 視窗有畫面（第六節之六，已由 `5613517a` 修正）；
  在 `0.1.18 (19)` 另回報解除 PiP 回到 App 時畫面放大、進度往回，使用者決定暫不修改（「真機回報：解除子母畫面時放大、進度往回」一節）。其餘項目仍未在真機驗證。）
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

### 六之六、真機回報：PiP 時解析度降低（使用者 2026-09-24，`0.1.11 (12)`）

- 回報：「MPV PIP時解析度會降低」。（這也表示真機的 PiP 視窗**有畫面**；自動 PiP、控制、回 App 恢復等其他項目使用者尚未回報。）
- 根因：`pictureInPictureController(_:didTransitionToRenderSize:)` 的標頭寫「in pixels」，**實際給的是點**——iPad 模擬器上 327.5 點寬的
  視窗回報 330、308 點的回報 308×141（2× 螢幕）。`MPVSoftwareRenderer` 把它當像素，所以 PiP 影格只有視窗像素的 1/2（iPad）或
  1/3（3× iPhone），被系統放大後就糊了。
- 同時查到的既有問題：影格寬高取偶數會讓比例差一點，視窗跟著改形狀又回報新尺寸——**每秒約 15 次、311↔313 點來回跳**，
  每張影格都重建 buffer pool。
- 修正（本 commit）：render size × `UIScreen.main.nativeScale` 換成像素；`setWindowWidth` 只接受變化超過一成的新寬度（真的縮放視窗才算）；
  上限由 960 改為 1280 px（`maximumWidth`）。影格寬度＝min(視窗像素寬, 影片寬, 1280)；3× iPhone 的 PiP 視窗最寬約 400 點＝約 1200 px，
  所以**在 iPhone 上這個上限不會起作用**，只限制 iPad 的大視窗。
- 模擬器驗證（iPad mini，暫時 log，之後移除）：修正前 PiP 影格 312×142、render size 回呼 ~150 次／10 秒；修正後 616×282（308 點 × 2）、
  回呼 4 次／10 秒，每秒 30 張；final Simulator Debug build 成功、`MPVEngine.swift` 0 warning、binary 無 `TEMP-17H`。
- 真機未驗證：修正後的 PiP 清晰度與 CPU。已於 2026-09-24 以 `0.1.12 (13)` 發布（run `35971952291`）。

## 真機回報：解除子母畫面時放大、進度往回（使用者 2026-09-25，`0.1.18 (19)`）

- 回報原文：「在解除 pip 回到 App 畫面會突然放大然後又正常，但是進度會往回一點」。
- 診斷（2026-09-25 的 9 個 agent workflow，詳細證據與原始碼行號見 `docs/IOS-POC-17I-mpv-resize-libmpv.md` 第一節所列版本）：
  - 確定的機制一：Metal view 疊在 sample-buffer view 上面，會一直留著子母畫面開始那一刻 mpv 畫的最後一格。gpu-next VO 被銷毀不會清掉它：MoltenVK 只會嘗試把 drawableSize 設成 1×1，而 `MPVMetalLayer` 會忽略。回到 App 時這張舊畫格以 `kCAGravityResize` 拉伸到目前的 bounds，直到 `stopSoftwareOutput` 重建的 Metal 輸出畫出第一格（在它的 exact seek 之後）。常見流程是橫向觀看、回到直向的主畫面、再直向回到 App，此時橫向畫格會被拉滿直向畫面。
  - 確定的機制二（較少發生）：回到 App 時的尺寸變化只排了 300 ms 的 settle。若新的 gpu-next VO 先畫出第一格，會讀到舊的橫向 `drawableSize`，把橫向矩形畫進直向畫布（放大並裁切），直到 settle 觸發第二次重建。
  - 進度往回：mpv 自己的 seek 不會倒退。每次重建的 exact seek 以「正在聽到的音訊」為目標，所以會重播約一段音訊輸出延遲（喇叭約數十 ms，藍牙約 0.1～0.3 秒，未實測），這在切換 VO 的做法下 App 端無法消除；使用者看到的「比較早的畫面」則是上面那張殘留舊畫格。子母畫面 timebase 最多領先 1 秒一事，因 iPhone 的 PiP 視窗沒有時間顯示，不是可見原因。
  - 未能排除：放大也可能是 AVKit 自己的子母畫面放回動畫（閉源，只能由錄影分辨）或系統 App 快照。
- 可行修法（未實作）：子母畫面期間與回到 App 時，以黑色覆蓋層蓋住殘留的 Metal 畫格；重建前先套用最新尺寸，讓輸出只以正確尺寸建一次；若錄影顯示放大發生在 AVKit 放回動畫期間，再把 sample-buffer view 改為影片的等比例矩形。
- **使用者決定（2026-09-25）：「先不改，等有模擬器你再修改」**。本問題保持開啟，等可在模擬器驗證的環境再實作；屆時先加 log 並錄影分辨放大的來源。

## 真機回報的模擬器重現與修法（IOS-POC-17H-2，2026-09-29）

使用者 2026-09-29 要求在 `0.1.30 (31)` 發布後處理「MPV 在子母畫面結束回到 App 會有異常狀態」，症狀確認為「畫面突然放大／變形再恢復」與「進度往回一點」；並提醒「原生進入 PiP，App 的畫面是黑的但有文字，要不要參照原生播放器」。

### 1. 重現（iPad mini (A17 Pro) 模擬器 iOS 26.3、`0.1.30 (31)` 的程式加暫時的旗標檔 hook；iPhone 模擬器的 `isPictureInPictureSupported()` 是 false，iPadOS 26 的視窗模式按 Home 不會進背景，所以以 `tmp/pip-start`、`tmp/pip-stop` 手動開關，hook 未 commit；本機條碼測試片 A、MPV）

| 輪 | 過程 | 錄影逐格結果（`scripts/ios_adskip_sim/analyze.py`） |
|---|---|---|
| a | 播到 9.7 秒開始 PiP，約 23 秒後結束，視窗大小不變 | 子母畫面期間 App 一直顯示 9.68 秒的畫格（進入 PiP 那一刻 Metal 的最後一格）；結束時放回動畫與約 0.43 秒全黑；接著 **9.68 秒的舊畫格再出現約 0.26 秒**；之後跳到 43.32 秒（正確位置：9.7＋23＋跳過的 10 秒廣告）繼續播 |
| b | 再開 PiP，期間把 App 視窗拖成橫向 | 子母畫面期間的舊畫格被壓扁以塞進新的視窗；結束後全黑約 0.3 秒，**被壓扁的舊畫格再出現約兩格**，之後才是比例正確、時間正確的畫面 |

結論：兩個症狀都是第一節「確定的機制一」——Metal view 疊在 sample-buffer view 上，保留進入 PiP 時的最後一格，以 `kCAGravityResize` 拉到目前的 bounds，直到重建的 Metal 輸出畫出第一格。「進度往回」是這張舊畫格（本例早了 33 秒），實際播放位置正確。機制二（舊 `drawableSize`）在 17I-3 之後已不存在（尺寸改變直接設 `drawableSize`，不再重建）。

### 2. 參照原生

AVPlayer 的 PiP 期間，App 裡是 AVKit 的黑底加文字；MPV 的 sample-buffer 來源也會有同樣的 AVKit 畫面（第六節之二 D5：「This video is playing in picture in picture.」），只是被上面的 Metal view 蓋住。另外 `MPVSoftwareRenderer.detach()` 不會清掉 sample-buffer layer，所以 PiP 結束後它仍保留 PiP 最新的一格（`resizeAspect`，比例正確）。

### 3. 方案

| 方案 | 內容 | 結論 |
|---|---|---|
| 不改 | — | 否 |
| 黑色覆蓋層 | 另加一層黑色 view 蓋住 Metal | 否：與原生不同（沒有文字），多一個 view |
| **對齊原生：PiP 期間與回來後、第一格新畫面前隱藏 Metal view**（實施） | `pictureInPictureControllerWillStartPictureInPicture` 時隱藏 Metal view，露出 AVKit 的 PiP 畫面；結束後維持隱藏，等 mpv 的 `MPV_EVENT_PLAYBACK_RESTART`（重建輸出後的精確 seek 完成）才顯示；等不到時，App 回到前景後 1 秒顯示（使用者 2026-09-29 問「為什麼要等 2 秒，原生沒這麼久」，說明 2 秒只是等不到訊號時的上限、平常約 0.4～0.7 秒後，選擇 1 秒） | 實施 |
| 消除重建時的 exact seek | 改 Libmpv 或換輸出方式 | 否：替換二進位、範圍大；只影響數十毫秒 |

### 4. 驗收標準

1. 模擬器重跑 a、b：PiP 期間 App 裡不再出現舊畫格（應為 AVKit 的黑底文字或黑畫面）；結束後不再出現舊畫格或變形畫格，第一個看得到的畫面是比例正確、時間在 PiP 結束位置附近的畫格。
2. PiP 期間暫停再結束：畫面最後會出現（最遲 2 秒），不會一直黑著。
3. 沒有進 PiP 的一般播放、旋轉、換畫質：Metal view 從不被隱藏（行為不變）。
4. 真機：要使用者驗收。

### 5. 回滾

revert 本階段的 commit。

### 6. 實作與驗證（2026-09-29，使用者核准「1 秒，開始實作」）

1. `ios/WebHTVApp/Sources/MPVEngine.swift`：`MPVVideoView.showsMetal`；`MPVPlayerCore.Event.playbackRestarted`（`MPV_EVENT_PLAYBACK_RESTART`）；`MPVEngine.coverMetalForPictureInPicture()`、`revealMetalAfterPictureInPicture()`（先等 App 回到前景，再最多 1 秒）與 `revealMetal()`；`MPVPictureInPicture` 在 will-start 時遮住、在 `ended` 時等候顯示。沒有進 PiP 的路徑都不會呼叫，Metal view 維持顯示。
2. 模擬器（同第一節的環境與 hook；hook 未 commit）：

   | 輪 | 修正前 | 修正後 |
   |---|---|---|
   | PiP 期間 | 顯示進入 PiP 那一刻的舊畫格（視窗改變時被壓扁） | AVKit 的 PiP 圖示與「This video is playing in picture in picture.」，底下是 sample-buffer 的畫面（比例正確）。與原生的全黑底不同：sample-buffer layer 是 PiP 的來源，不能隱藏 |
   | a 結束 | 約 0.43 秒全黑後，舊畫格（早 33 秒）0.26 秒，再跳到現在 | 約 0.43 秒全黑（系統的放回動畫）後，PiP 最新的一格停約 0.2 秒，接著從同一處連續播放；**沒有往回的跳動**（逐格解碼） |
   | b 結束（期間改成橫向視窗） | 全黑後被壓扁的舊畫格約兩格 | 放回動畫後第一個畫面就是比例正確的新畫面 |

3. 未驗證：PiP 期間暫停再結束（模擬器的控制工具一次來回比控制列 5 秒自動隱藏長，無法先叫出控制列再按暫停；等不到訊號時由 1 秒上限顯示）；背景中從 PiP 視窗關閉後再回到 App；真機（旋轉、藍牙耳機的 exact seek 往回量）。
4. 單元測試：本階段只改 App target，WebHTVCore 沒有變更，沒有重跑 `swift test`；Debug 模擬器 build 成功。

### 7. IOS-POC-17H-3：`0.1.31 (32)` 真機仍「放大再縮小、閃一下」（2026-09-29）

使用者以 `0.1.31 (32)` 真機測試後回報：「回到 APP 還是會放大再縮小，然後有閃一下」。

**診斷**（iPad mini 模擬器，暫時把 `MPVVideoView` 背景改紫色、sample-buffer 層背景改綠色、在 `layoutSubviews` 記錄矩形，加上旗標檔 hook；都未 commit）：

| # | 觀察 | 結論 |
|---|---|---|
| 1 | 放回動畫：黑色的 PiP 視窗從左上角**一路放大到蓋滿整個 App 視窗**（紫色背景全部消失），動畫結束後才換成中間 16:9 的畫面 | 真機上這個視窗就是影片：放大填滿 → 縮回有黑邊的大小。這是 AVKit 的動畫，不是 App 畫的 |
| 2 | 把 sample-buffer 層縮成影片的等比例矩形（log 確認 `sbv={{0, 228}, {375, 211}}`，視窗期間黑邊是紫色不是綠色）後，放回動畫**仍然**蓋滿整個 App 視窗 | 至少在 iPadOS 26 的視窗模式下，AVKit 放回動畫的目標不是這一層的矩形（可能是 scene 的視窗）。iPhone 上是否以這一層為目標，模擬器驗不了（iPhone 模擬器不支援 PiP） |
| 3 | 進入動畫：PiP 視窗從左邊滑入，不是從影片區縮出去 | 進入時不需要對齊 |
| 4 | 17H-2 進入 PiP 時：Metal 一藏，sample-buffer 層先露出黑色佔位畫格一格，軟體輸出的第一格才到 | 17H-2 引入的黑格 |
| 5 | 17H-2 接回時：`videoSizeChanged` 在新輸出重設尺寸時往層裡塞黑色佔位畫格（原本被 Metal 蓋住看不到）；第一版改成等 Metal 回來再補，卻在淡入**開始**時補，Metal 還透明，黑格照樣露出一格 | 「閃一下」至少有這一個來源 |

**修法**（`ios/WebHTVApp/Sources/MPVEngine.swift`，commit 見 Recovery anchor）：

1. `MPVVideoView.videoSize`：sample-buffer 層改為影片的等比例矩形（`AVMakeRect`），由 `.videoReconfigured` 的 `dwidth`/`dheight` 決定（零值＝影片軌被釋放，沿用上一個形狀）。若 iPhone 的 AVKit 以這一層為目標，放回就會正好落在影片上；模擬器上無法證明。限制：`dwidth`/`dheight` 不含 `video-rotate` 的旋轉，有旋轉標記的影片矩形會轉 90°（來源中罕見，未處理）。
2. 進入 PiP：`MPVSoftwareRenderer.onNextFrame`，軟體輸出把第一格送進層之後才 `coverMetalForPictureInPicture()`；`ended` 時取消。
3. 佔位畫格：`MPVPictureInPicture.refreshPlaceholder()` 只在「PiP 不在進行中」且「不在等 Metal 回來」時補；接回時在 0.15 秒淡入**結束**後才補（`fadeMetalIn(completion:)`）。
4. Metal 回來時淡入 0.15 秒（`UIView.animate`），遮掉軟體輸出最後一格與 GPU 第一格之間的差異。

**模擬器驗證**（`pip9`，紫色背景診斷版）：進入時 Metal 藏起來的那一格直接就是軟體輸出的畫面，沒有黑格；接回時序為 系統動畫（黑色視窗蓋滿 App 視窗）→ 子母畫面最後一格（比例正確）→ 淡入 3 格（兩張畫面的條碼混合）→ Metal；沒有黑格、沒有變形、沒有往回的跳動。項目 1 的系統動畫維持原樣。

**真機未驗證**；若 iPhone 上仍放大，下一步只能靠使用者的 iPhone 螢幕錄影（AirDrop 到 Mac 後逐格分析）判斷 AVKit 在 iPhone 上的目標——App 端沒有 API 可以指定放回的矩形。同日另一個 session 在同一個 checkout 做了 IOS-POC-12／13 並撤銷 13（`20fd462e`），本階段的 commit 已重定基底到它之後。

### 8. IOS-POC-17H-4：真機錄影逐格分析、進入 PiP 的黑畫面與放回時的閃一格（2026-09-30）

使用者 2026-09-30 以 `0.1.35 (36)`（含 17H-3）真機錄影回報「pip有問題」（`ScreenRecording_09-29-2026 19-40-54_1.mp4`，1206×2622、13.95 秒，MPV、2× 倍速；檔案未進 git）。核准「A 和 B 一起改，改完發新版」。

**逐格結果**（`ffmpeg` 抽格、逐格亮度與影格差異）：

| # | 時間 | 現象 | 判斷 |
|---|---|---|---|
| — | 全程 | 播放時間連續（04:47→04:58 在 2× 下約 5.5 秒），PiP 視窗每秒約 33 張不同畫面，音訊持續到按暫停 | 播放、時間、PiP 更新都正常 |
| A | 8.050 秒（第二次放回） | 放回動畫**之前**整個 App 畫面先出現 1 格（約 17 ms），下一格回到主畫面，PiP 視窗才開始放大；第一次放回（2.7 秒）沒有 | 使用者所說「閃一下」。App 回到前景時 `appDidBecomeActive()` 會再呼叫一次 `stopPictureInPicture()`，而系統這時已經在結束 PiP（按了視窗的「回到 App」）；兩次只閃一次，符合時序競爭 |
| B | 6.23–6.40 秒（進入） | App 縮小動畫後段影片區先變黑，PiP 視窗前約 0.15 秒全黑 | 見下方 mpv 原始碼 |
| C | 兩次放回 | 黑框從 PiP 位置放大到**整個螢幕**，影片在框內落到中間 | iOS 的動畫目標是整個 App 視窗，不是 17H-3 縮成影片比例的 sample-buffer 層；17H-3 修法 1 在 iPhone 上沒有作用。App 沒有 API 指定放回矩形，不改 |

**B 的原因**（mpv `v0.41.0` `41f6a645068483470267271e1d09966ca3b9f413`）：換成 `vo=libmpv` 後，新輸出在第一張解碼影格之前只有「重繪」，`vo.c` `do_redraw` 以沒有影像的 dummy frame（`redraw=true`）送出；`libmpv_sw.c` 對 `frame->current == NULL` 做 `mp_image_clear` 並回傳成功。`render()` 把這張黑圖當第一格送進層並觸發 `onNextFrame`，Metal 被藏起、PiP 視窗打開時層裡只有黑圖。模擬器（`hwdec=no`）第一張就是真影格，所以 17H-3 在模擬器上看不到。

**修法**（`ios/WebHTVApp/Sources/MPVEngine.swift`、`ios/Sources/WebHTVCore/PictureInPictureForegroundRestoreState.swift`）：

1. `MPVSoftwareRenderer.render()`：以 `MPV_RENDER_PARAM_NEXT_FRAME_INFO` 讀旗標；新 render context 送出第一張非重繪影格之前，重繪結果不送進層（仍呼叫 `mpv_render_context_render` 消化該格，否則 VO 會等 200 ms 逾時）。`onNextFrame` 改由 `render()` 在送出真影格後觸發，佔位黑格與截圖都不再觸發。
2. `UIApplication.willResignActiveNotification`：可自動 PiP（`canStartPictureInPictureAutomaticallyFromInline`）且 PiP 未進行時，`MPVPlayerCore.showCurrentFrame` 以 `screenshot-raw`（預設含字幕）取目前畫面，縮到 PiP 影格尺寸（`targetSize`，上限 1280 px）放進 sample-buffer 層，取代黑色佔位格，讓 PiP 一出現就有畫面。截圖一律走 CPU（`screenshot-sw=yes`）：模擬器上 gpu-next 的 GPU 截圖在 MoltenVK 讀回時中斷（`pl_tex_download` → `MTLSimDevice newBufferWithLength` → `_xpc_api_misuse`，SIGTRAP，crash report `WebHTVApp-2026-09-30-102315.ips`）。
3. 放回：`pictureInPictureControllerWillStopPictureInPicture` 與 `restoreUserInterface…` 呼叫新的 `PictureInPictureForegroundRestoreState.pictureInPictureWillStop()`（系統已在結束，前景不再要求）；`appDidBecomeActive()` 延後 300 ms 才判斷要不要自己停（系統可能在 App 變成 active 之後才說它在結束）。從 App 圖示回來時 PiP 因此晚約 0.3 秒結束。`ponytail:` 300 ms 是對 iOS 時序的固定估計，實際間隔看 `[pip]` log。
4. 新增 log：`[pip] mpv will stop`、`[pip] mpv restoring the app (app state N)`、`[pip] mpv back in the app with the window open — stopping it`。

**驗證**：

- `swift test`：578 項全過（含新增 `aSystemInitiatedStopLeavesNoForegroundRequest`）。
- Release 實機 build（`generic/platform=iOS`、`CODE_SIGNING_ALLOWED=NO EXPANDED_CODE_SIGN_IDENTITY=-`）成功，`MPVEngine.swift` 0 warning。
- iPad mini (A17 Pro) 模擬器 iOS 26.3、本機條碼測試片 A、MPV，暫時的旗標檔 hook（`TEMP-17H4`，已移除，`grep -c TEMP` = 0）：
  - 截圖：`screenshot-raw` 回 0、640×360；藏起 Metal 後畫面是該張條碼（顏色、比例正確，不是黑的）；縮放版再驗一次同樣正確。GPU 截圖版在同一步 crash（見上），改 CPU 後不再發生。
  - 開 PiP：第一張軟體影格即真影格（`redraw=0`，flags `PRESENT`）——模擬器沒有黑色重繪，過濾條件未被觸發，只證明它不擋正常影格。
  - 前景延遲 stop：`back in the app … stopping it` → `will stop` → `restoring the app (app state 0)` → `did stop`；App 自己停時的順序是 will stop → restore → did stop。PiP 結束後條碼持續變化（回到 Metal 播放）。
- **真機未驗證**：A 是否不再閃（原本兩次閃一次，需多試）、B 的 PiP 視窗是否一出現就有畫面、真機上 `willResignActive` 截圖的耗時與 `hwdec` 影格下載、字幕是否出現在截圖上、按「回到 App」時 will stop 與 didBecomeActive 的實際先後。AVPlayer 的前景 stop（`WebHTVApp.swift` `PlayerSurface.Coordinator`）未改，是否也閃待使用者以系統播放器比對。

**回滾**：revert 本階段 commit。

## Recovery anchor

- 目標：MPV PiP（P6），行為對齊 AVPlayer 自動 PiP（第一節）。
- Git：基線 HEAD `257553f2`（17G，當時本機、未 push）；本任務 commit `8824c8ee`，已 push 並以 `0.1.11 (12)` 發布。
- 已完成：研究（第二節 R1–R15）、方案（第三節）、程式（第六節之一）、黑畫面診斷（第六節之二）、final-diff review 與四項修正（第六節之五）、`TEMP-17H` 全部移除、final build、IOS-POC-17 第十四節 P6 與交接文件更新。
- 未完成（只能真機）：第六節之三標「真機未驗證」的各項。
- 解析度修正（第六節之六）`5613517a` 已以 `0.1.12 (13)` 發布。
- 下一步（唯一）：使用者在 SideStore 更新到 `0.1.12 (13)` 後，在真機確認 PiP 清晰度，並依第四節驗收標準驗 MPV PiP 其餘項目（先看 `[pip] mpv possible=` 與 `will start` log，再看 PiP 視窗是否有畫面）。
  （2026-09-25 更正：使用者已更新到 `0.1.20 (21)`（目前最新），PiP 清晰度與第四節其餘項目仍未回報；另有開啟中的問題「解除子母畫面時放大、進度往回」，使用者決定等有模擬器再修改，見該節。）
- 2026-09-30 IOS-POC-17H-4（第七節之後的「8.」）：進入 PiP 的黑畫面與放回時的閃一格已修正，模擬器能驗的部分已驗；真機未驗證。下一步（唯一）：使用者在新版真機上以 MPV 反覆「進 PiP → 按回到 App」並錄影，確認 A、B；若仍閃，接 Mac 的 Console 讀 `[pip]` log 的先後順序。
