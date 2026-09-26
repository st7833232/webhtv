# IOS-POC-26 — MPV／原生切換與 MPV seek 的位置正確性

- 狀態：**26-1 已隨 `0.1.22 (23)` 發布（Release build 編譯通過、單元測試未執行、真機未驗證）；26-2 研究完成，使用者 2026-09-26 核准 26-2b（自建 iOS FFmpeg），進行中**。
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
| 編譯 | 發版 workflow run `36205981537` 的 Release device build 第一次編譯即成功（`0.1.22 (23)`，2026-09-26） |
| 靜態複查 | 已逐一核對 `resumed` 的三個呼叫端、`PlaybackLoadRequest` 的唯一 App 建構點（`PlaybackSession.load`，使用預設值）、測試 harness 的假引擎語意 |
| 真機 | 未驗證（見第七節） |

### 已知限制

- 就緒前的零容差 seek 是否一定被 AVPlayer 採用，沒有文件保證；若真機顯示仍落在分段開頭，下一步是「就緒後補一次精確 seek」。
- 精確起播會多一段從關鍵影格解碼到目標的時間，只發生在切換與 reload。
- RC3 在有廣告的影片上會讓兩個核心差上廣告長度，這不是容差能修的，由 26-2 處理。

## 五、回滾

- 26-1：revert 本任務的 commit。`exactStart` 只有 router 與 `loadNative` 讀取，沒有持久化，回滾不影響觀看記錄。

## 六、26-2：MPV 在有廣告的 HLS 上 seek 回到片頭、之後無法播放

- 狀態：**研究完成，等使用者決定**（2026-09-25）。以 workflow 進行：四條證據線（真實串流、mpv／FFmpeg 原始碼、Android、iOS 卡死路徑），綜合設計後兩個審查角度反駁。
- 結論：兩個症狀同一個根因。**iOS 用的是未修改的 FFmpeg n8.1.2（MPVKit 1.0.0 prebuilt），`hls.c` 完全不處理 `EXT-X-DISCONTINUITY`；Android 用的 FongMi FFmpeg `177f090e` 帶有 FongMi 自己的 commit `5805f9364c2e9a5f6ce625c9077b308c3ed4014d`（`avformat/hls: normalize timestamps across discontinuities`），會把封包時間戳對到播放清單時間軸，並在每次 seek 後重新對齊。** Android 的 Java 端直接用 `time-pos` 當播放清單時間，正確性完全來自這個 FFmpeg 修正。

### 1. 證據

| 來源 | 版本 | 等級 | 結論 |
|---|---|---|---|
| FFmpeg `libavformat/hls.c` | n8.1.2 `38b88335` | A | 沒有任何 discontinuity 處理；seek 用 `first_timestamp` 加 EXTINF 累加選分段（`find_timestamp_in_playlist`），再在同一次 `av_read_frame` 內丟棄封包直到 `dts` 追上目標 |
| mpv `demux/demux_lavf.c`、`player/playloop.c`、`player/command.c` | v0.41.0 `41f6a645` | A | `time-pos` 是封包 PTS 減起始時間；seek 未完成時回報目標值、`paused-for-cache=no`、沒有 `PLAYBACK_RESTART`；之後的 seek 排在進行中的讀取後面 |
| FongMi/FFmpeg `libavformat/hls_timestamp.c` 與 `5805f936` | `177f090e` | A | 偵測廣告拼接造成的時間戳重設並修正；seek 後把第一個封包對到所選分段的播放清單起點 |
| FFmpeg 上游 `e27ad576`、`caa3fa6a` | master | A | seek 丟棄改以各 playlist 的 DTS 基準比較；目標在第一個時間戳之前時改為夾住，不再回 EIO。FongMi 修正依賴它們 |
| Android `MpvPlayer`、`MpvHlsProxy`、`HlsAdTimeline` | `origin/main` `5856232` | A | 所有位置、seek、廣告區間、歷史與換核心都用原始 `time-pos`，沒有任何換算 |
| 實際 FFmpeg 8.1.2 的模擬（PyAV 18.1.0 內含 FFmpeg 8.1.2）加上四種 PTS 配置的合成 HLS | 本機產生 | B | 廣告自帶 PTS 時，廣告內的 `time-pos` 是廣告自己的 0～十幾秒（例：播放清單 68 秒處讀到 8.02 秒）；由此按 +10 秒，FFmpeg 落在片頭 18 秒附近 |
| 使用者設定中的真實串流 | — | — | **無法量測**：本環境的 proxy 擋掉設定裡全部 22 個 CMS 主機，沒有繞過 |

### 2. 機制

1. **「影片重頭」**：控制列的 ±10 秒以 `time-pos` 為基準（`WebHTVApp.swift` 控制列的 `shown`）。在廣告內，`time-pos` 是廣告自己的小數值，+10 秒變成對片頭附近的絕對 seek，FFmpeg 依播放清單時間選到開頭的分段。若正片區塊的 PTS 也在廣告後重設，之後每一次 ±10 都會落回第一個區塊。
2. **「多操作幾次無法播放」**（每一環都在程式碼中找得到，但沒有真機 log，無法確定是哪一環）：
   - 目標 PTS 永遠追不到時，一次 `hls_read_packet` 會下載並丟棄播放清單剩下的全部內容，期間畫面凍結、App 仍顯示播放中，之後的 seek 都排在後面不動作。
   - 丟到檔尾時 mpv 回報 `END_FILE(EOF)`，App 當成整集播完，自動換下一集或關閉播放器，觀看記錄也被改寫。
   - 預設播放器是 MPV 時，`PlayerRouter.endSession` 不釋放 MPV 核心，同一個核心會被之後每一集、每一次開啟重複使用。
3. 其他受影響的路徑：MPV 的位置寫進觀看記錄時可能是廣告自己的時間；切換到原生時交出去的也是這個值（第二節 RC3）。

### 3. 方案比較

| 方案 | 內容 | 能修 | 不能修／風險 | 二進位變更 |
|---|---|---|---|---|
| 不改 | — | — | 全部症狀留著 | 否 |
| 只移植 Android 的 Java 邏輯 | source-time seek、`end` 邊界等 | 核心重建一項 | 前提是 FFmpeg 已對齊，在 iOS 上會跳過正片 | 否 |
| Swift 邏輯位置層 | 偵測 `time-pos` 重設，自己維護播放清單位置 | 線性播放時的顯示與記錄 | FFmpeg 的 seek 本身仍以 PTS 選段，多數配置下 seek 仍錯；安全性取決於量不到的 PTS 配置 | 否 |
| mpv EDL | 每個 discontinuity 區塊一個 part | 時間軸完全正確 | 開播時逐一開啟每個 part（ffzy 約 61 段），每個邊界重建解碼器；需要本機 HTTP server | 否 |
| 改寫播放清單給 mpv | 刪廣告或每次 seek 改成重新載入 | 部分配置 | 刪錯會永久跳過正片；每次 seek 都重新載入 | 否 |
| **FFmpeg 對齊（26-2b，建議）** | 以 n8.1.2 加上游 `e27ad576`、`caa3fa6a` 與 FongMi `5805f936` 自建 iOS FFmpeg | 所有配置：`time-pos` 等於播放清單時間，±10、拖曳、記錄、快取、換核心都正確；IOS-POC-25 的 MPV 跳廣告也能開啟 | 自建 FFmpeg 的 CI 與鎖定工作；從 FongMi 的 9.0 分支移植到 n8.1.2 需要驗證；授權與來源紀錄 | **是**，需要使用者核准 |
| 有廣告的串流交給原生 | 偵測到 discontinuity 或時間戳重設就換原生 | 這些影片的 seek 立即正確 | 違反使用者選的核心；部分站台幾乎每集都有 discontinuity | 否 |
| Swift 保護層（26-2a） | seek 監看、假 EOF 保護、壞核心不重用、位置不採用廣告時間 | MPV 卡住後可以恢復，不用重啟 App | **不能修「影片重頭」本身**；審查找出 12 個具體問題（慢網路誤判、PiP 被拆、位置可能超前觀眾等），照原設計不能出貨 | 否 |

### 4. 決定（使用者 2026-09-26 回覆）

- 26-2b：**核准**。
- `0.1.22 (23)`：**現在發布，連 IOS-POC-25 一起**（已發布，見 `docs/IOS-POC-11-sidestore-release.md` 第二十三次發布）。
- 重現情況：**同一集從頭播**（不是跳到下一集），符合第二節的主要機制。

原本列出的待決事項：

1. 26-2b（FFmpeg 對齊）要不要做。
2. `0.1.22 (23)` 是只帶 26-1 先發，還是等 26-2b。
3. 26-2b 完成前，含廣告的影片建議改用原生播放器；IOS-POC-25 已在有 discontinuity 的播放清單上停用 MPV 的自動跳廣告（`docs/IOS-POC-25-hls-midstream-ad-skip.md` 第十一節），兩者結論一致。

### 5. 26-2b：自建 iOS FFmpeg（Libavformat）

#### 5.1 移植範圍（FFmpeg n8.1.2 `38b88335f99e76ed89ff3c93f877fdefce736c13`）

FongMi 的 FFmpeg 是 8.2 開發版（`177f090e0503b7e013922ca903bde14b1c375f18`），不能整份換進 iOS：其他 FFmpeg 函式庫都是 MPVKit 1.0.0 的 n8.1.2，混用不同版本的 libavformat 有內部 ABI 風險。所以只在 n8.1.2 上移植最少的必要 commit。n8.1 分支點（`67c886222f5fcb4c53d6f5a8b41faec8668b6229`）之後到 `177f090e`，動到 `hls.c` 的 commit 共 16 個：

| commit | 處理 |
|---|---|
| `caa3fa6af070c1eeee59da027fdcde326fc64a89` seek 到第一個時間戳之前 | **需要**：5805f936 依它回傳的分段起點重新對齊；少了它，上游 `fate-seek-hls` 有 11 次 seek 失敗 |
| `e27ad5760c0c8eca7c95bb907dc6e4e62dbf129b` seek 丟棄門檻改以各 playlist 的 DTS 基準 | **需要**：新增 5805f936 讀取的 `ts_offset`；兩處衝突手動解決（`new_playlist` 保留 n8.1.2 寫法；`hls_read_packet` 不帶 `6d98a9a2` 的 EVENT 專用行） |
| `5805f9364c2e9a5f6ce625c9077b308c3ed4014d` FongMi 時間戳正規化 | **目標**，每一行與原 commit 相同；`hls_timestamp.{c,h}` 與測試與 FongMi 逐 byte 相同 |
| `59094859a8affb9f8715a003d9fa3d0c13041d56`、`c2047918e627dd0e2e83df8faf6f1e9c69e68514` | n8.1.2 已有 backport（`69ca310f`、`61ffafe9`） |
| `6d98a9a2e8757d6eb616501ade06877389a31597`、`d768bd564ee66a57d1ebd828d05fa1347ca94f12`、`17bc88e67feb841cd342eba33df7a93d9a05819f`、`e8cfe912f48b30077d8df87abeb09d39bf93fe37`、`54f0296dfefd43858ad607a3e5499f5fce35cf92`、`0616685b1eefefdb5794b9334b40510377df92af`、`50209cd0c025af07dff4dafbb1ac747c6287a248`、`0e6eef35517af086419c5157980e926a81070c2a`、`01044d04536eec6e2f5f48ef404cf45d15feb461` | 不需要：與本修正無關，或只是文字上的前後文。`17bc88e6`、`01044d04` 是另外可以考慮的強化 |
| `e8392b0b0fb0ae6a827fa65f678cd4d6827f6f74`、`e640443a24dc89993042a99ade8a02a4d5ac2a81`（FongMi 自己的功能） | 不需要；`e640443a` 會改公開的 `avformat.h`，本來就排除 |

另帶兩個只含測試的上游 commit（`f699b3a8f52c151f61318b757abf04cab0811724`、`c3ca443969af0ef075fff5636c8516e21a1924d6`），讓 `tests/ref/seek/hls` 有檔可套。

#### 5.2 WebHTV 調整（patch 0006）

忠實移植在合成素材上重現了 FongMi／Android 的已知缺陷：時間戳跳動必須超過 `max(2×TARGETDURATION, 1 秒)` 才修正，較小的往回跳一律夾住。片頭廣告後正片從 0 附近重新開始、中段廣告時正片時間跳過廣告、兩段廣告各自的時鐘，這些常見配置下，線性播放會差 15～28 秒，並出現數百個被夾成同一值的時間戳；seek 還會把 AVPlayer 的播放清單位置 seek 到 PTS 時間軸上的錯誤位置。另有捨入缺陷：約一半的分段邊界（EXTINF 15.166667、16.633333、6.666667 等）seek 時會丟掉該段的關鍵影格，晚一個 GOP 才落地。

0006 的規則（只用於一開始就有 `EXT-X-ENDLIST` 的播放清單；直播維持 5805f936 原樣）：

1. 逐分段記錄 `EXT-X-DISCONTINUITY`。封包依 `pkt->pos` 歸到它所屬的分段，前一段延遲送出的封包沿用前一段的偏移。
2. 新 discontinuity 序列的第一個封包決定整段的偏移：只有當它和該分段的播放清單起點（`first_timestamp` 加前面的 EXTINF，與 seek 用的值相同）**以及**自己串流的連續值都差超過 1 秒，才對齊到播放清單起點（RFC 8216 §6.3.3，也是 AVPlayer 與 Media3 的做法）。時間戳真的連續的串流（包括每段都有 discontinuity 標記、EXTINF 有捨入誤差的串流）完全不動。
3. 對齊後若會讓串流落後超過一格，改成接在最後一格之後，不再夾出一整段相同的時間戳。
4. seek 之後以 seek 所用串流的第一個封包對齊；丟棄比較改在封包的時間基底上進行，修掉捨入缺陷。

公開 API／ABI 不變：只改 `hls.c` 內部與內部檔 `hls_timestamp.{c,h}`，新增的內部符號共 6 個（`ff_hls_timestamp_*`）。

#### 5.3 Linux 驗證（2026-09-26，原生編譯，不是 iOS）

- 建置：原版 n8.1.2、FongMi `177f090e`、忠實移植、WebHTV 調整版，四份使用相同的 configure。
- FATE：調整版 12／12 通過（含 `fate-hls_timestamp`、`fate-seek-hls`）；原版有其中 10 項，10／10 通過。新增的單元測試有三種故意改壞的版本（不重新對齊、舊捨入、夾住第一個封包），每一種都會讓測試失敗。
- 行為比對：以模擬 mpv `demux_lavf` 的 seek 方式（`av_seek_frame(..., AVSEEK_FLAG_BACKWARD)`，再解碼到 hr-seek 的落點）逐一播放與 seek 合成素材。素材共 20 多種配置：片頭、中段、片尾廣告，兩段連續廣告，時間戳在 10 小時附近，byte range，AES-128 隱含 IV，純音訊，分開的音訊 rendition，每段都有標記但時間戳連續，直播，EVENT。結果：

| 指標 | 原版 n8.1.2 | 忠實移植（＝FongMi／Android） | WebHTV 調整版 |
|---|---|---|---|
| 線性播放與 EXTINF 時間軸的最大差距（點播廣告配置） | 60 秒；時間戳在 10 小時附近時 59,383 秒 | 多數 0.08 秒；片頭或中段重設、兩段廣告時 15～28 秒 | **≤ 0.043 秒** |
| seek 落點 | 廣告內與廣告後偏 16～32 秒，或一路讀到檔尾 | 幾乎都對；A2r 有一處因捨入晚 7.3～8.3 秒 | **全部正確**（最差 0.020 秒，是 hr-seek 的影格量化） |
| 被夾成同一值的時間戳 | 無（但有乾淨的往回跳） | 最多 457 個影像、754 個音訊封包 | 影像 0；音訊每個素材最多 1 個（一格） |
| 沒有廣告的對照組（M0、L4、DALL） | — | L4 有 1 個封包不同 | **與原版逐 byte 相同** |
| 直播、EVENT | — | — | 與忠實移植逐 byte 相同 |

- 未涵蓋：fMP4 在廣告處換 `EXT-X-MAP`、帶 ID3 時間戳的 packed audio、`http_persistent`，以及 mpv 或真機上的實際播放（mpv 的 demuxer cache、`ts_resets_possible` 行為沒有在這裡驗證）。
- 證據檔在 session scratchpad 的 `ff/results/`（`adapted-tables.txt`、`adapted-report.txt`、`tables.md`）。

#### 5.4 iOS 建置管線（26-2b-1）

- `.github/workflows/ios-ffmpeg-build.yml`：沿用 libmpv 管線的 recipe、工具鏈與固定版本的依賴（`FFmpeg-all.zip` 除外），把 `third_party/mpv-ios/patches/ffmpeg` 放進 recipe 的 `patch/FFmpeg`，以 `patches/buildscripts/0002-build-ffmpeg-only.patch` 只建 FFmpeg。
- 發布前的比對：
  - 沒有任何 patch 碰到的 `Libavutil` 必須與上游 1.0.0 相同（configure 字串、成員、已定義與未定義的外部符號），證明這條管線重現了 recipe 的建置。
  - `Libavformat` 必須與上游相同，只多 `hls_timestamp.o` 一個成員與 6 個 `ff_hls_timestamp_*` 符號（5805f936 的 4 個與 0006 的 `map_segment`、`reached`）；未定義符號的差異只能來自 `hls.o`、`hls_timestamp.o`。
- 第一次建置（run `36213278635`、`36215262840`，2026-09-26）：`Libavutil` 與上游逐項相同；`Libavformat` 的 configure 與版本字串、新增成員（只有 `hls_timestamp.o`）、新增符號（6 個 `ff_hls_timestamp_*`）都符合。只剩兩項工具鏈差異（本 lane 用 Xcode 26.6，上游用 15.4），使用者 2026-09-26 認可寫成具名例外：
  1. `dashdec.o` 呼叫 `free`／`realloc`，上游呼叫 libxml2 的 `xmlFree`／`xmlRealloc`。Xcode 26.6 SDK 的 libxml2 標頭這樣對應；App 沒有替 libxml2 設定自訂配置器，是同一套配置。條件是兩邊都只有 `dashdec.o` 使用這 4 個符號。
  2. `Headers/config.h` 只容許 `CC_IDENT`、`HAVE_AS_ARCHEXT_DOTPROD_DIRECTIVE`、`HAVE_AS_ARCHEXT_I8MM_DIRECTIVE`、`HAVE_KVTQPMODULATIONLEVEL_DEFAULT` 4 行不同，而且必須是 Xcode 26.6 的值。後三項只影響 libavcodec 的組語與 VideoToolbox 編碼器，App 使用的 libavcodec 仍是上游的。
- 發布：只有在 `ios-poc` 上才發布 prerelease `ffmpeg-n8.1.2-webhtv.1`。App 在 26-2b-2 才改用它，在那之前仍連結上游的 `Libavformat`。
- 鎖定：`third_party/mpv-ios-lock.json` 的 `ffmpeg` 區段記錄來源、每個 patch 的 SHA-256、比對基準與 artifact。

#### 5.5 驗收（真機，發布後）

1. 有插播廣告的影片在 MPV 上：播到廣告時進度條不再掉回 0 附近；在廣告內或廣告後按 +10／-10 秒，前後移動 10 秒，不會回到片頭；拖進度條落在拖到的位置。
2. 多次快轉、倒退後 MPV 仍可播放，不需重啟 App。
3. 同一集在 MPV 與原生之間切換，畫面接在同一個時刻（26-1 加上 26-2b）。
4. 沒有廣告的影片在 MPV 上的開播、seek、背景回來、子母畫面與以前相同。
5. 直播頻道在 MPV 上與以前相同。

#### 5.6 回滾

- 26-2b-1：revert 本 commit；已發布的 prerelease 不影響 App。
- 26-2b-2：把 `ios/Vendor/MPVKit/Package.swift` 的 `Libavformat` 改回 MPVKit 1.0.0 的 URL 與 checksum（即 lock 的 `ffmpeg.reference`：checksum `2afb601375929640e743e7bdaa6c4a88e2b582a07e1c5f2dc95cc7f5b26a0810`），再發一版。

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
- 狀態：26-1 已隨 `0.1.22 (23)` 發布；26-2b 的 FFmpeg patch（0001～0006）已在 Linux 驗證（第六節之五），iOS 建置管線 26-2b-1 已 commit，patch 0006 的獨立審查執行中。
- 目前檔案：`PlaybackEngine.swift`（`PlaybackLoadRequest.exactStart`、`PlayerRouter.handOff`／`reload`／`setRate`）、`WebHTVApp.swift`（`loadNative`、`router.onEngineChange`）、`PlaybackEngineTests.swift`。
- 未解風險：iOS FFmpeg 不對齊 discontinuity（26-2b 待核准）；就緒前零容差 seek 在真機上的行為；真實串流的 PTS 配置未量測。
- 下一步（唯一）：在工作分支 dispatch `ios-ffmpeg-build.yml` 試跑（不發布），通過且審查無阻擋問題後合進 `ios-poc`，發布 prerelease，再做 26-2b-2（App 改用新的 Libavformat）。
