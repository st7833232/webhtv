# IOS-POC-15 — 播放緩衝與下一集預解析

- 狀態：**程式已實作，真機效能驗收未完成（code implemented / real-device performance
  verification pending）**。本文件所有數字都來自單元測試與模擬器建置，**沒有任何一項是真機量測**。
- 基線 HEAD `ecebeaa3`（2026-09-23，`origin/ios-poc` 同步，worktree 乾淨）
- Lane：`standard`
- 前身：本文件在 2026-09-22 是一份 **plan only**，明寫「authorizes no functional implementation」。
  該計畫的約束原封不動保留在下面各節，並標註實作是否照做。
- 起因：使用者 2026-09-23 回報三件事——**2.5 倍／3 倍會沒聲音、畫面會跳轉**；
  **網路不好時 UI 操作像卡住**；以及 roadmap 既有的啟播／弱網／換集三個延遲目標。

## 〇、計畫說「先量再調」，而這一輪沒有真機

原計畫第一條是 **Baseline first — do not tune blind**。這一輪**沒有做到**，必須講清楚：

- 專案手邊**沒有可連線的真機**。使用者自 2026-09-22 起透過 SideStore 安裝，一次發布才會到手機上，
  而本輪**未經授權發布任何版本**。
- 因此本階段做的是**把「可量測」這件事本身做出來**：state model、policy、四類 diagnostics、
  以及讓這些全部可被 `swift test` 驅動。**真機 before/after 比較仍然欠著**，見第八節。
- **不准把模擬器或單元測試的結果寫成真機結果。** 本文件每一節的「驗證」欄位都標明證據等級。

計畫裡「a slow provider/CDN cannot be fixed by requesting a larger forward buffer」這句仍然成立，
而且現在是程式裡的一個 case（`PlaybackLimit.cdnThroughput`），不是一句提醒。

## 一、把 AVPlayer 的網路狀況做成可觀測、可測、有界

**不靠 Wi-Fi／5G 類型猜網路品質。** 連線類型說不出「這個 CDN 餵不餵得動這條 variant」，
buffer、stall 與 access log 才說得出。

### 量什麼（`PlaybackNetworkSample`，`ios/Sources/WebHTVCore/PlaybackNetworkPolicy.swift`）

| 欄位 | 來源 |
|---|---|
| `bufferAhead` | `AVPlayerItem.loadedTimeRanges` 中**包含播放頭的那一段**的剩餘秒數 |
| `likelyToKeepUp` | `AVPlayerItem.isPlaybackLikelyToKeepUp` |
| `bufferEmpty` | `AVPlayerItem.isPlaybackBufferEmpty` |
| `playing` / `waitingToPlay` | `AVPlayer.timeControlStatus` 的 `.playing` / `.waitingToPlayAtSpecifiedRate` |
| `rate` | 目前播放速度 |
| `observedBitrate` / `indicatedBitrate` | `AVPlayerItemAccessLog().events.last` |
| `stalls` | `AVPlayerItem.playbackStalledNotification` 計數 |
| `variantCount` | `AVURLAsset.load(.variants).count` |
| `kind` | `.onDemand` / `.liveOrUnknown`，由 item 的 **duration** 決定 |

**`loadedTimeRanges.first` 是錯的，這是實作時抓到的既有缺陷。** seek 之後 player 會同時保留一段以上，
而第一段常常是已經看過的部分——照第一段讀，會在真的沒有 buffer 的那一刻回報一個舒服的數字。
現在兩處（policy 與 IOS-POC-16 的進度條 buffered bar）**都改讀包含播放頭的那一段**，
所以兩者不可能各說各話。

### 為什麼不只看 `observedBitrate / indicatedBitrate`

那個比值只回答「CDN 餵得動目前這條 variant 嗎」，**回答不了「前面還剩多少」**。
一條剛切到低畫質的串流比值會很漂亮，buffer 卻可能只剩兩秒。所以 `level(of:)` 同時看
cushion、`likelyToKeepUp`、`bufferEmpty`、`waitingToPlay` 與比值，**任何一項都不是單獨的判準**。

### 倍速直接進入模型，不是特例

**這就是使用者 3 倍速回報在模型裡的表達方式。** 24 秒的媒體在 1 倍是 24 秒的緩衝，在 3 倍只有 8 秒。
所有門檻比較的是 `bufferAheadPlaybackSeconds = bufferAhead / max(rate, 1)`，
所以高倍速**自己**會把狀態往下推、把 forward buffer target 往上調，
用既有機制而不是在旁邊加第二套。測試：`theCushionIsCountedInPlaybackSecondsSoAFastRateCountsAgainstIt`。

## 二、狀態機與 hysteresis

`good / normal / risk / poor`，起始 `.normal`。

| 規則 | 行為 |
|---|---|
| 還沒播過任何東西 | **任何 sample 都不能移動狀態**。起播時 buffer 本來就小，那不是網路壞掉 |
| 實際 stall，或 buffer empty 且 `!likelyToKeepUp` | **立刻 `.poor`**。這是事件不是讀數，不等 run |
| 其他降級 | 需要**連續 2 個** sample。中間有一個好 sample 就重新計數 |
| 升級 | 需要**連續 6 個**（五秒取樣 ＝ 30 秒），而且**一次只升一級** |

降級可以一次跨多級（證據說在哪就在哪），升級一次一級。
`poor → good` 因此要 3 × 6 = 18 個 sample，約 **90 秒**。
**`1080 → 720 → 1080 → 720` 這種震盪在這個結構下寫不出來。**

門檻全部集中在 `PlaybackNetworkThresholds`，本檔案沒有任何一處比較的數字不在那裡宣告。

## 三、15A — buffer policy

| 狀態 | `preferredForwardBufferDuration` | `preferredMaximumResolution` | `preferredPeakBitRate` |
|---|---:|---|---:|
| `good` / `normal` | **60 s** | 不限制 | **0** |
| `risk` | **90 s** | 1080p（**且僅在 `variantCount > 1`**） | **0** |
| `poor` | **120 s** | 720p（**且僅在 `variantCount > 1`**） | **0** |
| live / duration 未知 | **0（交給系統）** | 不限制 | **0** |

### `preferredPeakBitRate` 永遠是 0，而且這件事是可測的

它是**下載上限**不是加速器；設一個固定低值只會把一條好連線整集釘在爛畫質上。
`PlaybackBufferPolicy` 有 `peakBitRate` 這個欄位**不是為了要調它**，是為了讓「永遠 0」變成斷言：
`noStateEverCapsPeakBitRate` 走過 4 個狀態 × 2 種 kind × 3 種 variantCount，全部斷言為 0。
任何人日後從 policy 回傳非 0，那條測試就會紅。

### `automaticallyWaitsToMinimizeStalling` 明確設定

在 `PlaybackSession.init` 明寫 `= true`。這是既有行為，但現在是**寫出來的**而不是繼承來的預設值。

### `preferredForwardBufferDuration` 刻意**不在** item 建立時設定

item 還沒 ready 之前 duration 未知，而 **live 絕不能繼承一分鐘的 VOD buffer**。
所以第一次 sampler tick（item 已能讀出 runtime）才套用 policy。
附帶效果是**起播路徑一字未改**，所以不可能有「本來開得起來的來源變慢」這種退步。

### 只有真的多 variant 才可能被限制畫質

用 `AVURLAsset.variants` 的**數量**，這是平台自己的答案，**不是解析 master playlist、也不是從副檔名猜**。
direct MP4 回報 0、單一 variant HLS 回報 1，**兩者永遠不套用畫質上限**——
對它們設上限不會讓 player 挑到更小的，只會把僅有的那一條拒絕掉。
在 `AVURLAsset` 回答之前 `variantCount` 維持 0，也就是保守的那一邊。
測試：`aNonAdaptiveStreamIsNeverQualityCapped`。

### 不會動到使用者選定的 quality / line

`PlaybackBufferPolicy` **裡面沒有 URL、沒有 quality、沒有 line**，只有上面那三個旋鈕。
IOS-POC-5Q 的線路與畫質是**不同的 WebHTV 位址**，由使用者選；本階段只能在
**AVPlayer 拿到的那一個 HLS asset 自己的 variants 之內**做 ABR。
`preferredMaximumResolution` 寫成 16:9 的像素框：AVPlayer 挑的是**塞得進框**的最大 variant，
所以同高度的 4:3（960×720 在 1280×720 之內）仍然允許——上限維持是「高度的上限」。

## 四、15B — 四類 diagnostics

`PlaybackNetworkMonitor.limit(of:resolutionSeconds:)` 回答：

| case | 意思 | 判準 |
|---|---|---|
| `.sourceResolution` | 時間花在把一集變成位址（`playerContent`／probe／sniff），根本沒花在媒體上 | 上一次解析 ≥ 2 秒 |
| `.forwardBuffer` | 網路夠快，但播放頭前面留得不夠 | throughput 健康而 cushion 不足 |
| `.cdnThroughput` | provider 餵不動僅有的那一條 | throughput 不足**且** `variantCount <= 1` |
| `.selectedBitrate` | 選到的 variant 對這條連線太大，而且有更小的可選 | throughput 不足**且** `variantCount > 1` |

### log 的節流方式

- `[playback] item variants=N …` — 每個 item 一行。
- `[playback] resolve <集名> live|prefetched <n>ms` — 每次解析一行。
- `[playback] prefetched <集名> in <n>ms` — 每次預解析成功一行。
- `[playback] <舊狀態> → <新狀態> <kind> limit=… buffer=…s/…s@…x keepUp=… stalls=… observed=…k
  indicated=…k variants=… → forward=…s cap=…` — **第一次套用 policy 時一行，之後只有狀態轉換才有**。

**沒有 ring buffer，因為 hysteresis 本身就是節流器**：一次轉換至少要通過 2 個 sample，
所以即使來源真的在抖，最快也只有每兩個 sample（10 秒）一行。
**沒有新增任何遙測伺服器。**

`resolutionSeconds` 是**用過即清**的：它描述的是「這一集怎麼開始的」，
下一次狀態轉換與那件事無關。不清掉的話，它會在二十分鐘後還在宣稱 buffer 不足是因為
`playerContent` 慢，而且會滲進 bridge 那條從不設定它的裸網址播放。
**已知殘留邊界**：WebHome 的 `player.playUrl` 裸網址播放若緊接在一次 VodView 播放之後，
可能沿用到前一次的數字一次，代價是 debug log 裡一個字可能不準。沒有為它再加第三處清除。

## 五、15C — 下一集 PlaybackTarget 預解析

`ios/Sources/WebHTVCore/NextPlaybackTarget.swift`。

### 走同一條 pipeline，不是複製一條

`prefetchNextEpisode` 呼叫的是 **`SourceClient.playbackURL(for:flag:)`**——
就是正常播放用的那一個出口。所以 `playerContent`、CSP／Python／drpy 路由、probe、sniff、
畫質選單與 **request headers** 全部是**沿用**而不是重寫。
**沒有第二個 AVPlayer，沒有 `play()`，沒有背景下載整集。**

### 什麼時候解析：不是「起播即解析」

計畫寫「current item stable → resolve」。**照做，但加了第二個閘門，而且這個閘門是必要的**：

> 在四十分鐘的一集的第 20 秒解析下一集，會讓那個位址在被用到之前放三十九分鐘。

所以 `PlaybackPrefetchGate.shouldPrefetch` 同時要求：

| 條件 | 值 |
|---|---|
| 已播放 | ≥ **20 秒**（stable playback） |
| 網路狀態 | ≥ `.normal`（不讓預解析跟正在掙扎的串流搶頻寬） |
| 距離交棒 | ≤ **90 秒**（`leadSeconds`） |
| duration | **必須是有限正數**。live／未知 **永遠不預解析** |
| 尚未解析過 | 每個 item 只問一次 |

**交棒點是 `duration - 使用者的片尾`**（IOS-POC-5S-2），不是片長——片尾設了九十秒的話，
窗口就早九十秒打開。測試：`theViewersEndingIsWhereTheHandoffActuallyIs`。

### 短效 URL：靠「不要太早製造曝險」，不是靠猜 TTL

**這份設定檔沒有任何來源公布它的 TTL**，所以不猜。
主要防線是上面的 90 秒 lead window；`PlaybackTargetPrefetch.maximumAge = 5 分鐘` 是第二層，
專門擋 gate 擋不到的情況：長時間暫停、PiP 留著、螢幕鎖住。
`take` 會同時檢查 identity 與新鮮度，兩者**並用**而不是二選一。

### 失效規則

`PlaybackTargetIdentity` 六個欄位全部要吻合：

`configID`（`ConfigSource.identity`）、`siteID`（**`Site.id`，不是 site key**，因為這份設定檔有四個重複 key）、
`vodId`、`flag`（線路）、`episodeURL`（**用位址認集，IOS-POC-14 的規則**，因為這裡有線路會把同一個名字印兩次）、
`quality`。

| 事件 | 結果 |
|---|---|
| 任一欄位改變 | `take` 回 nil，並且**連同把它消耗掉**——已經不是要播的那一集就是錯的 |
| 手動點另一集／換線路／換畫質 | `play()` 進來時 `prefetch.invalidate()` |
| 關閉播放器選單、改用外部播放器 | `.sheet(onDismiss:)` 清掉 `prefetchNext` 與 `prefetch` |
| 解析中使用者就移動了 | `store` 發現 `resolving` 已不是它，直接丟棄 |
| 超過 5 分鐘 | `take` 回 nil |
| 解析失敗 | `failed()`，**只是 optimization miss**；`playNext` 照原路解析 |

**auto-advance 絕不會因為 preload failure 而失敗**：`playNext` 是 `take` 命中就用、
沒命中就走原本那段 `SourceClient.make` → `playbackURL`，一行都沒改語意。

### 沒有做 AVURLAsset property preload

計畫寫「A later substage may evaluate lightweight AVURLAsset property preloading **only if** 15C
shows resolution is no longer the dominant handoff cost」。
**那個前提還沒被量到**（沒有真機數字），所以沒有加。沒有明確收益就不加，是計畫自己的條件。

## 六、順帶修掉的一個真缺陷：2.5 倍／3 倍沒有聲音

**這不是 IOS-POC-15 的範圍，是使用者 2026-09-23 同一則訊息裡回報的缺陷**，
而且根因正好在本階段要改的 `AVPlayerItem` 建立處，所以一併修掉，在此明白標示。

`AVAudioTimePitchAlgorithmLowQualityZeroLatency` 支援的速率**恰好是**
`0.5 / 0.666 / 0.8 / 1 / 1.25 / 1.5 / 2`，**其他速率直接把聲音丟掉**。
那份清單就是使用者的回報：IOS-POC-16 新增的 `2.5` 與 `3` 正是不在清單上的兩個。

修法一行：`item.audioTimePitchAlgorithm = .timeDomain`（支援 1/32× 到 32×，保持音高，
比 `.spectral` 省 CPU，對手機上 3 倍速的人聲有差）。設在 item 上，因為屬性在那裡——
player 層級的設定不會跟著 `replaceCurrentItem` 走。

**「畫面會跳轉」只解決了一半。** 3 倍速要 3 倍的吞吐量；第一節的 playback-seconds cushion
會讓高倍速自動進 `risk`／`poor`，於是 forward buffer 升到 90／120 秒、
多 variant 來源還會降到 1080p／720p。**這是否足夠，只有真機能回答**，見第八節。

## 七、驗證（全部是程式證據，沒有真機）

### 單元測試

```bash
WANG_MOVIE_JSON=<config> swift test --package-path ios
```

**266 條，265 通過**（本階段之前是 228；新增 **38** 條）。
唯一失敗是既有的 `reportsLiveType4SitesFromProvidedConfig`：88看球 把一集解析成
`http://nba.toutiaozb.com/qq/qq-kbs.html?…`，也就是 HTML 頁，而測試斷言 `CMSClient` 直出媒體。
**這是 handoff 明文記載「不要去修」的 provider 天氣測試**，同一天在 `61f2d6fd` 也是同樣結果。
而且它**結構上不可能**被本次改動影響：`swift test --package-path ios` **完全不編譯 `WebHTVApp.swift`**，
而兩個新的 core 檔案在 `WebHTVCore` 內部沒有任何呼叫端。

新增的 38 條分兩個檔：

`PlaybackNetworkPolicyTests.swift`（22 條）— VOD 初始 60 秒；risk/poor 的 90／120；
live 四個狀態都不繼承大 buffer 也不被限畫質；**任何狀態都不設 peak bitrate 上限**；
0 與 1 個 variant 永不被限畫質；真 variant ladder 只在 risk/poor 被限且為 1080/720；
單一 sample 的分級（cushion／keepUp／throughput 三者並用、打平的 throughput 不算健康、
`waitingToPlay` 算 rebuffer）；**倍速讓同樣的 buffer 進入不同狀態**；
單一 sample 不能移動狀態、好 sample 會重設計數；起播不被誤判；
**stall 立刻降到 poor 並把 target 升到 120 秒**；buffer empty 要配合 `!likelyToKeepUp`；
**恢復一次只升一級、720p 先變 1080p 而不是直接解除**；降級兩個 sample 而恢復要三輪；
穩定串流不抖動；四類 diagnostics 各一條；暫停不被診斷成問題；
prefetch gate 的 stable／lead／使用者片尾／live／網路狀態／只有一集。

`NextPlaybackTargetTests.swift`（16 條）— 正常 consume；**headers round-trip**；
一次只握一個；take 會消耗；**六種 identity 變化（集／線路／畫質／站／片／設定檔）全部失效**；
不吻合也要消耗；新 identity 可搶走 slot；in-flight 期間使用者移動則丟棄；
`invalidate` 清兩者；**過期拒用**；窗口內可用；freshness 窗口大於 gate 的 lead；
時鐘倒退不算新鮮；**失敗不留殘留且可重試**；空 store 回 nil。

### 模擬器建置

```bash
xcodebuild -project ios/WebHTVApp/WebHTVApp.xcodeproj -scheme WebHTVApp \
  -destination 'platform=iOS Simulator,id=7B4E9557-4774-4EB9-B408-BB544DCC8657' \
  -configuration Debug build
```

→ **BUILD SUCCEEDED**。

**新程式沒有產生任何警告。** build log 裡 `WebHTVApp.swift` 的 7 條警告
（`deviceInfo()` 的三個 `UIDevice.current`，與 bridge 的 `evaluateJavaScript`）
**是既有的**：把本檔案還原成 base HEAD 再建一次，同樣 7 條出現在 2910–2912／3046 行，
正好是改動後的 3216–3218／3352 減掉本次新增的行數。**這是量出來的，不是推論的。**

### 沒有驗到的

- **真機一次都沒跑。** 啟播時間、buffer-ahead、stall/rebuffer 次數、throughput、
  下一集交棒耗時，**全部沒有真實數字**。
- **沒有人看著 policy 在真實弱網下生效**，也沒有人看著畫質降級或恢復。
- **`AVURLAsset.variants` 對本設定檔的來源實際回傳幾個，沒有量過**——
  所以「哪些來源真的是 adaptive」目前是未知數，而未知數走的是不限制那一邊。
- **`audioTimePitchAlgorithm` 的修正沒有人在真機上聽過 2.5 倍／3 倍。**
- **prefetch 命中率是 0 次實測。** 「A 播到最後 90 秒，B 已經解析好」這條路徑只有單元測試。

## 八、真機該怎麼驗收（欠著的那一半）

同一支手機、同一個來源、同一集，修改前後各做一次，至少比較：

1. **首畫面啟播時間** — 從點下該集到出現第一格畫面。CMS、`csp_*`、需要 headers 的（Bili）、
   需要 sniff 的各一條。看 `[playback] resolve … <n>ms` 分離「解析」與「緩衝」。
2. **30 秒／60 秒時的 buffer-ahead** — 看 `[playback]` 第一行的 `buffer=` 欄位；
   修改前應該遠小於 60 秒。
3. **5～10 分鐘內的 stall / rebuffer 次數** — `stalls=` 欄位。
4. **弱網恢復行為** — 刻意壓低頻寬再放開，看狀態序列是否
   `normal → risk → poor → (約 30 秒) risk → (約 30 秒) normal`，**且沒有來回抖動**。
5. **HLS 畫質降級與恢復** — 先確認該來源 `variants=` > 1，再看 `cap=` 是否只在 risk/poor 出現，
   且恢復時先 1080p 再解除。**畫面不應該在 1080/720 之間來回。**
6. **下一集從片尾到真正開始播放的耗時** — `[playback] resolve <集名> prefetched <n>ms`
   應該遠小於 `live` 的那一次。同時確認 **Bili 的 Referer + User-Agent 仍然有效**（沒有 403）。
7. **2.5 倍／3 倍有沒有聲音**，以及畫面是否還會跳轉。

## 九、Ponytail

**實作前（設計軸）。**
① 需要存在——使用者回報 ＋ roadmap 既有階段，不是臆測。
② **已有的東西先用**——`PlaybackSession.startSampling()` 的五秒迴圈已經在讀 position 與 duration，
policy 直接搭它，**沒有新增任何 timer**；`PictureInPictureForegroundRestoreState` 已經示範
「純狀態放 core、AVKit 接線放 app target」，本階段照抄這個切法；
`advance` / `onPlaylistFinished` 已經是「player 問、`VodView` 答」的接縫，prefetch 就是第三個同形狀的 closure；
`SourceClient.playbackURL` 已經是唯一的解析出口，prefetch **呼叫它**；
`PlaybackTarget` 已經帶 url＋headers＋qualities，預解析的值**就是它**，只多一個 identity 與時間戳；
`WatchHistory.key` / `ConfigSource.identity` / `Site.id` 已經表達「哪部片、哪個站、哪份設定」，identity 直接沿用。
③ **平台原生**——`AVURLAsset.variants`（不自己解析 playlist）、
`playbackStalledNotification`（不自己推論 stall）、`AVPlayerItemAccessLog`（不自己量吞吐）。
④⑤ **沒有新增任何相依**。
⑦ 最小：兩個新 core 檔（純值）、app target 內一處，**沒有新增 app target 檔案**
（`project.pbxproj` 逐檔列源碼，新增檔會是額外的 build 設定改動）。

刻意不做：第二個 player、persistent media cache、HLS segment 攔截、playlist rewrite、
ring-buffer 遙測、預解析深度 > 1、非預設畫質的 resolver、遙測伺服器。

**final diff 軸（抓到並修掉四條）。**

1. **`lastResolutionSeconds` 會殘留。** 只有 `VodView` 會設定它，卻沒有人清除，
   於是 `limit=` 可能在二十分鐘後還在說 `.sourceResolution`，並滲進 bridge 的裸網址播放。
   改成**用過即清**。殘留邊界寫在第四節。
2. **第一次套用 policy 不會被 log。** 狀態起始就是 `.normal`，永遠不會「轉換」到 `.normal`，
   所以最關鍵的那一行——60 秒 VOD policy 到底有沒有套上、這個 item 被讀成 VOD 還是 live——
   看不到。改成「第一次套用 ＋ 之後只記轉換」，並在該行印出 `kind`。
3. **`prefetchRequested` 被檢查了兩次**，於是 `shouldPrefetch` 的 `alreadyHolding` 參數在 production
   永遠是 `false`——一個有測試卻沒有真正在跑的參數。合併成一個閘門，跑的就是被測的那條規則。
4. **`loadedTimeRanges.first` 是既有缺陷**，而且 IOS-POC-16 的進度條也照第一段畫。
   兩處都改讀包含播放頭的那一段（見第一節）。

**明白保留的取捨。** `prefetchRequested` 失敗後不重試：每個 item 只問一次，
是有界的選擇，也是「只預解析下一集一個」的字面意思；要重試就會變成對一個正在失敗的 provider 反覆請求。

## 十、回滾

單一 commit，`git revert` 即可。
關閉開關不需要 revert：`PlaybackBufferPolicy.policy` 永遠回 `.systemManaged`，
buffer policy 就完全不存在；把 `VodView` 那一行 `PlaybackSession.shared.prefetchNext = …` 刪掉，
預解析就完全不存在，`playNext` 回到原本每次都解析。
兩者都是 optional／純函式，**沒有資料格式改變，沒有 migration**。

## 十一、驗收條件現況

| 計畫的 acceptance criteria | 狀態 |
|---|---|
| real-device pre-change baseline | **未完成** |
| buffering policy 對 VOD 明確、不誤傷 live | 已實作，單元測試涵蓋 |
| 沒有人為的低 peak-bitrate 上限 | 已實作，**結構上可測** |
| buffer/stall/throughput diagnostics 能解釋測試案例 | 已實作，單元測試涵蓋 |
| 下一集可預解析且不造第二套播放狀態 | 已實作 |
| stale prefetch 被 source/title/line/quality/config 改變失效 | 已實作，六種變化各一條測試 |
| prefetch 失敗乾淨回退 | 已實作 |
| headers 與 multi-quality 不退步 | 已實作（headers 有 round-trip 測試） |
| opening/ending、history/resume、auto-advance、播放速度、外部播放器不退步 | 既有測試全數維持（265 通過） |
| full Swift test suite | **266／265**（1 條為既有 provider 天氣） |
| simulator build | **BUILD SUCCEEDED** |
| real-device post-change 量測 | **未完成** |
| Ponytail pre-review 與 final-diff review | **完成**，見第九節 |
| durable docs 記錄實測增益 | **只記錄了程式證據**；增益數字欠真機 |

**結論：IOS-POC-15 是「code implemented / real-device performance verification pending」，
不是已完全驗收。** 在真機做完第八節的七項比較之前，不得把本階段標記為 closed。
