# IOS-POC-26 — MPV／原生切換與 MPV seek 的位置正確性

- 狀態：**26-1 已實作（未編譯、未執行測試、真機未驗證）；26-2 研究中**（2026-09-25）。
- Lane：`standard`。Ponytail：unavailable / skipped。
- 編號說明：原本預定用 IOS-POC-25，因使用者另開 session 把 IOS-POC-25 給「HLS 串流中段跳廣告」，本任務改為 IOS-POC-26。
- 並行開發：另一個 session 同時在 `ios-poc` 開發 IOS-POC-25。本任務只做一般 push，push 前先 pull 並 merge，不 force push（使用者 2026-09-25 規定）。

## 一、使用者回報（2026-09-25，`0.1.21 (22)`，SideStore）

1. 「在 mpv 跟原生互切時會發生播放不是在切換的看的當下時間。我在影集的哪一個時間切換，換過去的播放器也應該從哪裡開始。」
2. 「MPV 在影片有廣告的時候使用快轉或倒退會有問題」。追問後的補充：「目前會將影片重頭，多操作幾次 mpv 會沒辦法播放，必須要重啟 app」。使用者決定併入本任務（選項「併入本 session IOS-POC-26」）。

對應 `docs/IOS-POC-8L-core-real-device-acceptance.md` 的 ⑲「原生 ↔ MPV 切換保留位置」：**真機結果 ❌**。

## 二、根因

調查以 workflow 進行：四條獨立調查線（程式路徑、AVFoundation、mpv／FFmpeg 原始碼、其他雙核心播放器），綜合後由三個審查角度反駁。第二則回報之後，另開一個 workflow 量測真實廣告串流（26-2，見第六節）。

| 編號 | 原因 | 方向 | 影響大小 | 信心 |
|---|---|---|---|---|
| RC1 | `PlaybackSession.loadNative` 用 `player.seek(to:)` 預設容差套用起播位置。Apple 文件說這等同無限容差，AVPlayer 可以落在目標之前的關鍵影格或 HLS 分段開頭。`PlayerRouter.handOff` 交出去的位置本身是對的 | MPV→原生；落點誤差之後再被帶回 MPV | 最多一個 GOP／分段（模擬器紀錄 04:07→04:00） | 高 |
| RC3 | 有 `EXT-X-DISCONTINUITY` 的 HLS（插播廣告）上兩個核心的時間軸不同：AVPlayer 用播放清單時間（EXTINF 累加，RFC 8216），mpv 的 `time-pos` 跟著封包 PTS，只在檔案開頭 rebase 一次。FFmpeg n8.1.2 `hls.c` 完全沒有處理 discontinuity | 雙向 | 每段廣告約 15～17 秒並累加；在廣告內切換可能落到片頭附近 | 第一則回報時為低；**第二則回報後提高**，26-2 量測中 |
| RC2 | MPV 播放中失敗時，`END_FILE` 錯誤先把 `loaded` 設成 false，`handOff` 因此改用 `request.startSeconds`（開播點），不是當下位置 | MPV→原生（自動 fallback） | 可能回到開播點 | 中 |
| RC4 | 切換後一瞬間控制列讀到 0:00，這時按 ±10 秒會以 0 為基準 | 雙向 | 回到片頭附近 | 低（既有） |
| A1 | 控制列切換帶的是 `engine.isPlaying`，緩衝中切換會以暫停狀態載入 | — | 播放狀態，不是位置 | 中（既有） |

MPV 一側在沒有 discontinuity 時是精確的：mpv v0.41.0 `loadfile.c:1908-1909` 以 `MPSEEK_ABSOLUTE` 排入 `start`，`playloop.c:335-338` 在預設 `hr_seek=2`（`options.c:1021`）下改為 hr-seek；FFmpeg `hls.c:2719-2724` 把 BACKWARD 的影像 seek 移到分段開頭，再解碼到目標。

## 三、最佳實務研究（2026-09-25 讀取）

| 來源 | 版本 | 等級 | 支持的結論 | 對決策的影響 |
|---|---|---|---|---|
| Apple `AVPlayer.seek(to:toleranceBefore:toleranceAfter:)` 文件 | 目前版 | A | 預設 `seek(to:)` 等同正無限容差；零容差為逐樣本精確，代價是額外解碼延遲 | RC1 成立；精確只用在交接 |
| `AVPlayerItem.h` `seekableTimeRanges` 說明、Apple QA1820 | 目前版 | A／B | 就緒前的 seek 是否被接受沒有文件保證；目前的預設容差版本在模擬器上可用 | 風險：就緒前的零容差 seek 可能退回分段開頭或 0，需要真機確認 |
| mpv `player/loadfile.c`、`playloop.c`、`options/options.c`、`demux/demux_lavf.c`、`DOCS/man/options.rst` | v0.41.0 `41f6a645` | A | `start` 為精確 hr-seek；`time-pos` 在 FILE_LOADED 前不可用；`demuxer-lavf-linearize-timestamps` 只對 OGG 音訊自動啟用，且文件說 timestamp reset 會破壞 seekable cache | MPV 起播不用改；RC3 需要另外處理 |
| FFmpeg `libavformat/hls.c` | n8.1.2 | A | 沒有任何 discontinuity 處理；seek 以 `first_timestamp` 加 EXTINF 累加選分段，再丟棄封包直到 `dts >= 目標` | RC3 的機制 |
| RFC 8216 §6.3.3 | 鏡像 `tex2e/rfc-translater` `0a0eb3c9` | A | 用戶端必須以播放清單時間與 Discontinuity Sequence Number 定位分段 | AVPlayer 的時間軸是規格要求的那一個 |
| androidx/media `HlsMediaChunk.java`、`SeekParameters` | `8c6678b6` | A | 每個 discontinuity 各有 `TimestampAdjuster`；`SeekParameters.DEFAULT` 為 EXACT | Android（Exo）切換是精確的 |
| WebHTV Android `PlayerManager.switchPlayer` | `origin/main` | A | 切換時 `if (position > 0) seekTo(position)`，沒有 `SeekParameters` | iOS 對齊為精確 |
| Swiftfin、Yattee v1.5.1、KSPlayer、react-native-video | 各 commit 見 workflow 紀錄 | B | 成熟播放器切換或續播時用精確或近乎精確的 seek；有的在 completion 內才播放 | 採精確 seek；不採「completion 內才播放」，因為會讓 IOS-POC-22 的交接變成暫停 |

## 四、26-1：交接時 AVPlayer 精確落點

### 方案比較

| 方案 | 內容 | 結論 |
|---|---|---|
| 不改 | 保留預設容差 | 不採用：使用者回報的就是這個 |
| 上游寫法 | seek 完成後才 `play()` | 不採用：IOS-POC-22 的高倍速交接會落成暫停 |
| **WebHTV 窄版（採用）** | `PlaybackLoadRequest.exactStart`：只有「引擎實際回報過的位置」才標成精確；`loadNative` 對它用零容差 | 開片、續播、片頭略過、換畫質的起播完全不變 |
| 全部精確 | 所有 `startSeconds > 0` 都用零容差 | 不採用：會改變每次續播的起播時間，沒有量測前不做 |
| 就緒後補一次 seek | 就緒時若差距 > 0.5 秒再精確 seek 一次 | 暫不做；真機顯示零容差沒被套用時再做 |

### 實作

- `ios/Sources/WebHTVCore/PlaybackEngine.swift`
  - `PlaybackLoadRequest.exactStart`（預設 `false`）；`resumed(at:rate:autoplay:exact:)` 由呼叫端決定精確與否。
  - `handOff`：引擎已載入且 `currentTime > 0` 才算「回報過的位置」，這時 `exactStart = true`；否則沿用 request 自己的起點與精確度（例如開片 20 秒內沒開始播放的 17F 逾時，起點仍是續播點，不改成精確）。
  - `reload(at:autoplay:)`：位置等於 request 自己的起點時（IOS-POC-23 的「還在準備中」），沿用原本的精確度；其他正值位置是引擎到過的位置，標成精確。
  - `setRate`：保留原本的精確度，不再順手改寫。
- `ios/WebHTVApp/Sources/WebHTVApp.swift`
  - `loadNative`：`exactStart` 時 `seek(to:toleranceBefore: .zero, toleranceAfter: .zero)`，否則維持原本的 `seek(to:)`。仍在 `play()` 之前、不加 completion。
  - `router.onEngineChange`：新增一行 `[playback] <片名> on <核心> from <秒>s exact=<yes|no>`，真機接 Mac Console 時可對照落點。
- `ios/Tests/WebHTVCoreTests/PlaybackEngineTests.swift`：既有的切換、高倍速交接、MPV→原生、fallback、reload 測試各加 `exactStart` 的檢查；新增 `onlyAPositionAnEngineReportedIsLandedOnExactly`（開片不精確、引擎還沒回報前的逾時交接不精確、播過之後的切換精確且保留小數、下一集與原起點 reload 不精確）。

### 驗證

| 檢查 | 結果 |
|---|---|
| 本機 `swift test` | **未執行**：本環境沒有 Swift 工具鏈；且使用者 2026-09-25 決定不跑單元測試、不新增 push 觸發的 CI（IOS-POC-20 Q6）。測試已寫入 repo |
| 編譯 | **未編譯**。唯一的編譯關卡是發版 workflow 的 Release device build |
| 靜態複查 | 已逐一核對 `resumed` 的三個呼叫端、`PlaybackLoadRequest` 的唯一 App 建構點（`PlaybackSession.load`，使用預設值）、測試 harness 的假引擎語意 |
| 真機 | 未驗證（見第七節） |

### 已知限制

- 就緒前的零容差 seek 是否一定被 AVPlayer 採用，沒有文件保證；若真機顯示仍落在分段開頭，下一步是「就緒後補一次精確 seek」。
- 精確起播會多一段從關鍵影格解碼到目標的時間，只發生在切換與 reload。
- RC3 在有廣告的影片上會讓兩個核心差上廣告長度，這不是容差能修的，由 26-2 處理。

## 五、回滾

- 26-1：revert 本任務的 commit。`exactStart` 只有 router 與 `loadNative` 讀取，沒有持久化，回滾不影響觀看記錄。

## 六、26-2：MPV 在有廣告的 HLS 上 seek 回到片頭、之後無法播放（研究中）

- 目前的假設（待量測確認）：廣告分段帶自己的 PTS。播進廣告後，mpv 的 `time-pos` 掉到廣告自己的小數值（例如 1～17 秒）。這時按 +10 秒，控制列以這個值加 10 做絕對 seek，FFmpeg 依播放清單時間選到片頭附近的分段，結果就是「影片重頭」。
- 「多操作幾次 mpv 無法播放、必須重啟 App」的候選原因：FFmpeg 的丟棄迴圈或 hr-seek 一直到不了目標、mpv 的 seekable cache 被 timestamp reset 打亂，以及 MPV 核心在同一個 App 執行期間跨播放器工作階段重複使用（`PlayerRouter.endSession` 只在下一次預設核心不同時才釋放），壞掉的核心要重啟 App 才會換新。
- 研究內容：抓使用者設定中的真實串流量測 PTS 配置、mpv／FFmpeg 原始碼層級的 seek 行為、Android 目前 MPV 的作法、iOS 卡死路徑，並比較可行方案。結果與決策會補在本節。
- 和 IOS-POC-25 的分工：本任務負責 MPV 時間軸與 seek 的正確性、核心復原；IOS-POC-25 負責偵測與跳過廣告。IOS-POC-25 在 MPV 上依播放清單時間跳廣告，前提就是 MPV 的位置和播放清單時間一致，所以 26-2 的結論會影響它。

## 七、真機驗收（SideStore，待使用者回報）

1. 同一部片、同一集：原生播到一個不是整數的時間（例如 12:34），播放中切到 MPV，應顯示約 12:34 並接著同一個畫面。
2. MPV 播到 15:07，切到原生：應顯示約 15:07（修正前會退到 15:00 之類的時間）。暫停狀態再做一次。
3. 相隔約 10 秒來回切換三次：時間不應越來越往回。
4. 1.5× 下各方向切換一次：速度與位置都保留。
5. 原生選 3×：自動換到 MPV，位置不往回跳。
6. 從「記錄」開一集：起播速度和以前一樣，從記錄的位置附近開始。
7. 暫停後鎖螢幕超過 60 秒再回來：仍是暫停、同一個畫面。
8. 若某些片在兩個方向都差約 15～17 秒，請提供站台、線路、集數（RC3 的特徵）。

## Recovery anchor

- 目標：MPV／原生切換從當下位置接續；MPV 在有廣告的 HLS 上 seek 正確，且不會卡到要重啟 App。
- 狀態：26-1 程式與測試已寫（未編譯、未執行）；26-2 研究 workflow 執行中。
- 目前檔案：`PlaybackEngine.swift`（`PlaybackLoadRequest.exactStart`、`PlayerRouter.handOff`／`reload`／`setRate`）、`WebHTVApp.swift`（`loadNative`、`router.onEngineChange`）、`PlaybackEngineTests.swift`。
- 未解風險：RC3 的影響範圍與修法；就緒前零容差 seek 在真機上的行為。
- 下一步（唯一）：讀 26-2 研究結果，決定並實作可以安全出貨的部分，再依使用者授權發布 `0.1.22 (23)`。
