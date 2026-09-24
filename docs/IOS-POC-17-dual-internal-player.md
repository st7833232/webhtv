# IOS-POC-17 — 雙內部播放核心（AVPlayer + MPV）

- 狀態（2026-09-24）：**17A／9G／17B／17C／17D／17E 完成；17F（主動切換播放核心）完成到模擬器。MPV rendering 在模擬器已解；真機仍未驗證。**
  **使用者 2026-09-23 決定直接開放 MPV**（17E）：正式版現在可選 MPV；防黑畫面的只剩 `MPVEngine` 的
  first-frame watchdog（10 秒沒畫面 → 回 AVPlayer）。不可宣稱 MPVEngine 已完成真機驗收。
- 開始：2026-09-23 16:48 CST，起始 HEAD `2a46c3fb22e533588bee93cc0ac15d55c15736ca`
  （`git fetch` 後與 `origin/ios-poc` `0 0`，worktree clean）
- Lane：`standard`（功能開發）；MPV 算繪那一段屬 IOS-POC-9 家族，記為 **IOS-POC-9G**，
  細節同時寫在 `docs/IOS-POC-9B-mpv-playback-core.md`
- 授權：使用者 2026-09-23 明確指示「這次是正式的功能開發」，並逐條給出產品決策（下一節）。
  **不含**：release bump、tag、package、publish、GitHub Release、SideStore workflow、
  IOS-POC-12／13、VLC／KSPlayer／GStreamer 導入、自建 FFmpeg 播放器、Android `app/`。

## 一、使用者的產品決策（2026-09-23，原樣收斂）

1. **只維護 App 內部播放器。** Infuse／Fileball／SenPlayer／VidHub 從正式播放路徑移除——
   它們收不到 headers／Referer／User-Agent／Cookie，也不回傳 position、rate、line、quality、
   `PlaybackTarget` identity、WatchHistory、resume、auto-next。**不再是 fallback、正式選項、
   acceptance requirement 或 roadmap dependency。**
2. **正式播放核心只有兩個**：AVPlayer（Primary／Native）與 MPV（Compatibility Engine）。
   不同時加入第三套。
3. 技術優先序固定：`AVPlayer` → `MPV`（現在正式繼續）→ `VLCKit`（**只在 MPV 被實證不適用後**）
   → `KSPlayer`（secondary contingency，不導入）→ `GStreamer`／自建 FFmpeg+VideoToolbox（不做）。
4. 設定頁「預設播放器」（原生播放器／MPV，預設原生），全域、持久化；
   播放列顯示**目前實際工作的 engine**，點選只影響本次 session，關閉播放器後 override 清除。
5. 自動 fallback 是正式功能：只有 engine capability failure 才切另一個 engine，
   每次 attempt 最多一次，雙向都要支援。
6. MPV 在達到 load／first frame／play／pause／seek／currentTime／duration／headers／teardown
   之前，正式版中 **disabled**，不得讓使用者點進黑畫面。

## 二、研究（AGENTS.md §7；本輪實際讀過的來源）

| # | 來源 | 版本／存取 | 等級 | 支撐的事實 | 對決策的影響 |
|---|---|---|---|---|---|
| R1 | MPVKit iOS demo `Demo/Demo-iOS/Demo-iOS/Player/Metal/MPVMetalViewController.swift`、`MetalLayer.swift`、`Player/OpenGL/MPVViewController.swift` | tag `1.0.0` = `288527dffbc6d3e63cce147fc7b520c64a791603`（本機 SPM checkout，與 `Package.resolved` 同 revision），2026-09-23 | 上游原始碼 | demo 的 wakeup callback **只做** `queue.async { … mpv_wait_event … }`；Metal 路徑 `wid`=`CAMetalLayer`、`vo=gpu-next`、`gpu-api=vulkan`、`gpu-context=moltenvk`；OpenGL 路徑 `vo=libmpv` + `mpv_render_context_create`，在 `glkView(_:drawIn:)` 呼叫 `mpv_render_context_render` | 我們的探針在 callback **裡面**直接呼叫 `mpv_wait_event`，與 demo 不同（見 R2–R4） |
| R2 | `mpv/client.h`（MPVKit 1.0.0 `Libmpv.xcframework/ios-arm64`） | 同上 | 官方 API 契約 | `mpv_set_wakeup_callback`：「**You are not allowed to call any client API functions inside of the callback** … wake up another thread that does all the work」；錯誤碼 `MPV_ERROR_LOADING_FAILED -13`、`AO_INIT_FAILED -14`、`VO_INIT_FAILED -15`、`NOTHING_TO_PLAY -16`、`UNKNOWN_FORMAT -17`、`UNSUPPORTED -18`；`MPV_END_FILE_REASON_ERROR = 4` | 探針違反明文契約；MPV failure classification 用這些碼 |
| R3 | mpv `player/client.c` | tag `v0.41.0`（MPVKit 回報 `mpv v0.41.0-dirty`），raw GitHub，2026-09-23 | 上游原始碼 | `send_event` 持 `ctx->lock` → `append_event` → `wakeup_client` 持 `ctx->wakeup_lock` **期間**呼叫 wakeup callback；`mpv_wait_event` 取 `ctx->lock`、清空後走 `wait_wakeup` 取 `ctx->wakeup_lock`；`mpv_get_property*` 走 `run_locked` → `mp_dispatch_lock` | 在 callback 裡呼叫這些函式＝在 libmpv 自己持有的鎖內重入 |
| R4 | mpv `misc/dispatch.c`、`osdep/threads-posix.h` | tag `v0.41.0`，2026-09-23 | 上游原始碼 | `mp_dispatch_lock` 會**等到 core（playloop）執行緒進入 `mp_dispatch_queue_process`** 才返回，且明寫 non-recursive；mutex 在非 NDEBUG 為 `ERRORCHECK`，否則 `DEFAULT` | 若 callback 正跑在 playloop 執行緒（`FILE_LOADED` 由 playloop 廣播），探針在 `FILE_LOADED` 時呼叫的 8 個 `mpv_get_property_string` 會等待被自己擋住的執行緒 → 與「`FILE_LOADED` 之後永遠沒有 `VIDEO_RECONFIG`」完全吻合 |
| R5 | `render.h`（同 R2） | 同上 | 官方 API 契約 | render API 函式「never can be called from within the callbacks set with `mpv_set_wakeup_callback()` or `mpv_render_context_set_update_callback()`」 | OpenGL 路徑的 update callback 我們已經 `DispatchQueue.main.async`，符合；event 泵不符合 |
| R6 | `AVFoundation/AVError.h`（Xcode 27 iOS SDK） | 本機 SDK，2026-09-23 | 平台標頭 | `AVErrorDecodeFailed -11821`、`AVErrorFileFormatNotRecognized -11828`、`AVErrorFileFailedToParse -11829`、`AVErrorDecoderNotFound -11833`；另有 `ContentIsProtected -11831`、`FailedToLoadMediaData -11849`、`ServerIncorrectlyConfigured -11850`、`Unknown -11800` | fallback allowlist 只收前四個；其他（含 Unknown、DRM、載入失敗、伺服器設定）不 fallback |

**不適用而未查的類別（明記原因）**：VLCKit／KSPlayer／GStreamer 的 PR／benchmark／論文——使用者已固定它們的定位
（VLCKit 只在 MPV 觸發 stop condition 後做 spike；另兩者不導入），本輪沒有會被這些資料改變的決策。
MPV 的授權（9A）、MPVKit 安裝、boot、static link（9B）**不重做**，沒有任何相依改版。

## 三、方案比較

| | 做法 | 正確性／相容 | 風險 | 結論 |
|---|---|---|---|---|
| A 不改 | 保留外部播放器、MPV 探針照舊 | 違反使用者決策；MPV 永遠黑 | — | 否決 |
| B 上游原樣 | 照 MPVKit demo 直接做一個 `MPVMetalViewController` 取代播放器 | demo 沒有 headers、history、auto-next、opening/ending、PiP，且把 AVPlayer 換掉 | 大量回歸 | 否決；**只採用 demo 的 event-loop 與 layer 接法** |
| **C WebHTV 調整版（採用）** | `PlaybackSession` 留在 engine 上層不動；新增最小 `PlaybackEngine` 契約、`PlayerRouter`、`AVPlayerEngine`（包住現有 AVPlayer 程式，不搬 IOS-POC-15）、`MPVEngine`（demo 的 Metal 接法＋修正的 event 泵）；fallback 決策與 state 保存是 core 純邏輯 | AVPlayer 路徑呼叫的是同一段程式；MPV 缺的能力由 capability 關掉 | MPV 真機未驗證 → 正式版 disabled | **採用** |

## 四、Ponytail pre-review（實作前，2026-09-23）

1. **需要存在嗎**：外部播放器——使用者決策，而且是**刪除**，最便宜的一種改動。雙核心——使用者決策。
   `PlayerRouter`——以前被 Ponytail 擋下是因為只有一個 engine；現在有兩個真的實作，理由成立。
2. **已有的先用**：`PlaybackTarget`（url＋headers＋qualities）直接當載入內容，不新增 target 型別；
   `PlaybackSession` 的 record／resume／opening／ending／auto-next／prefetch／sampler 全部原地保留，
   只把「讀 position／duration／rate、play／pause／seek」改成問目前的 engine；
   IOS-POC-15 的 policy 與 variant 計數**不搬**，留在 AVPlayer 那一側並只在 native 時執行；
   偏好用既有的 `UserDefaults`（與 `selectedSiteKey` 同一機制）；MPV 的 layer 覆寫照 `MPVProbeView` 既有的。
3. **標準庫／平台**：錯誤分類用 `NSError` 的 domain／code 與 underlying chain，不做散落的字串比對；
   唯一的字串解析是從 `AVPlayerItemErrorLogEvent.errorComment` 讀 `HTTP nnn`，集中在一個 core 函式。
4. **不新增相依。**
5. **刻意不做**：engine factory protocol（router 收一個 closure）、capability OptionSet（四個 Bool）、
   MPV 字幕／音軌／track selection（第二階段）、MPV PiP／AirPlay、第二套 resolver／spider／sniffer、
   VLC／KSPlayer／GStreamer 任何程式碼。
6. **Blocking finding 與縮減**：第一版構想把 `PlaybackSession` 所有 AVPlayer 呼叫都改走 protocol——
   這會碰 IOS-POC-15 的整段 policy，AVPlayer 回歸風險最高而且沒有真機可驗。**縮成**：
   AVPlayerEngine 只轉呼叫既有方法；policy／variant／stall 維持原碼，加一行「只在 native 執行」；
   `PlayerView` 的 native periodic observer 不改，MPV 另走自己的 tick。
7. **MPV 可用性**：正式版（Release）`MPV` 一律 unavailable，直到真機 first-frame 門檻通過。

## 五、MPV stop condition（使用者要求，寫死在這裡）

以下 bounded investigation **全部做完**後，若仍無法在**真機**可靠取得 first frame：
Metal render path、OpenGL render path、render context lifecycle、event loop、`vo`、
hwdec／軟解對照、drawable／surface lifecycle、callback wiring、first-frame／`VIDEO_RECONFIG` path——

1. 整理最小重現；2. 記錄已排除的假設；3. 記錄 log／event sequence；4. 停止加入 workaround；
5. 不再無限制修改 MPV；6. **改開一個最小 VLCKit replacement spike**（只回答使用者列的 14 題，
不做三核心）。

## 六、驗收標準

- 外部播放器的 UI、URL scheme handoff、helper、測試全部移除；沒有 dead route。
- `swift test` 不低於 297／296 基線（唯一已知失敗 `reportsLiveType4SitesFromProvidedConfig`），
  新增測試涵蓋使用者列的 32 項中可在 macOS 上驗的部分。
- Simulator Debug build `BUILD SUCCEEDED`。
- AVPlayer 既有行為零回歸（同一段程式、同一組測試）。
- MPV：模擬器證據與真機證據分開寫；沒有真機 first frame 就寫 **MPV rendering still unresolved**。

## 七、回滾

- 每個單元一個 commit，`git revert` 即可。
- 旗標級：`PlaybackEngineAvailability` 只回 `[.native]`（現在 Release 就是如此）＝MPV 完全不出現。
- 外部播放器移除的 revert 會把 `ExternalPlayer.swift`、選單與測試整組還原。

## 八、17A — 外部播放器移除（完成）

盤點（`git grep`，2026-09-23）：外部播放器只存在於四處，**沒有設定頁項目，`Info.plist` 也沒有
`LSApplicationQueriesSchemes`**（`grep -c Queries` = 0）。

| 移除 | 位置 |
|---|---|
| `ExternalPlayer` 型別（`infuse://x-callback-url/play`、`filebox://play`、`senplayer://x-callback-url/play`、`open-vidhub://x-callback-url/play`） | `ios/Sources/WebHTVCore/ExternalPlayer.swift`（整檔刪除；除了 handoff 沒有其他用途） |
| 播放選單裡的四個按鈕 | `PlayerPickerView`（`WebHTVApp.swift`） |
| URL scheme handoff `open(_ player:)` 與只為它存在的 `error` state／「無法開啟播放器」alert | 同上 |
| `buildsExternalPlayerURLsWithoutChangingMediaURL` | `ios/Tests/WebHTVCoreTests/CMSClientTests.swift` |

選單標題「選擇影片播放器」→「播放」，按鈕「內建播放器」→「播放」——只剩一個播放器時，
「選擇播放器」是 dead UI。三處提到「external player」的註解改寫，不留過時說法。
新增 `noThirdPartyPlayerHandoffRemainsInTheApp`：掃 `WebHTVApp/Sources`、`Sources/WebHTVCore`
與 `Info.plist`，四個 scheme、`ExternalPlayer`、`LSApplicationQueriesSchemes` 任一回來就紅——
型別刪除由編譯器保證，這條補編譯器看不到的字串與 plist。

驗證：`swift test --filter` 該條與相鄰的 `decodesPlaybackGroupsAndBracketedEpisodeNames` → 2／2 通過；
Simulator Debug build → **BUILD SUCCEEDED**。全套 `swift test` 留到 17B 一起跑一次。

## 九、9G — MPV 算繪復原（完成到模擬器；真機待跑）

根因是探針自己：event 泵在 wakeup callback 內呼叫 client API（`client.h` 明文禁止，`client.c`／
`dispatch.c` 顯示會在 libmpv 自己的鎖內等 playloop），以及 OpenGL update callback 繼承 main-actor
隔離後在 `vo` 執行緒 trap。兩者都照 MPVKit demo 修正。**模擬器上 Metal 與 OpenGL 都出 first frame**
（截圖與 event 序列見 `docs/IOS-POC-9B-mpv-playback-core.md` 9G 節）。**真機 first frame：尚未取得**——
本輪沒有可上機的 Debug build。**Stop condition 未觸發，VLCKit spike 不需要。**

## 十、17B — 雙核心本體（完成；MPV 在正式版仍 disabled）

### 契約（`ios/Sources/WebHTVCore/PlaybackEngine.swift`，純 core，macOS 可測）

| 型別 | 內容 |
|---|---|
| `PlaybackEngineKind` | `.native`（原生播放器／「原生」）、`.mpv`（MPV）；`capabilities`：native 有 AirPlay 與字幕／音軌選單，MPV 第一階段兩者皆無（PiP 只可能在 AVKit surface 上發生） |
| `PlaybackEnginePreference` | `globalDefaultEngine`，存在既有 `UserDefaults`（key `webhtv.playback.defaultEngine`），讀不懂或沒存 → `.native` |
| `PlaybackEngineSelection` | `globalDefaultEngine`／`sessionOverride`／`currentSessionEngine`／`fallbackSpent`。`startSession`（從關閉狀態開播：回到全域預設）、`beginAttempt`（同 session 下一集：保留 engine、重置 fallback 額度）、`choose`（手動：只改本 session）、`fallback(after:)`（只收 capability failure、每 attempt 一次、目標必須 available）、`endSession`（清 override） |
| `PlaybackFailure` | `engineCapability`／`network`／`source`／`unclassified`；只有第一種 `allowsEngineFallback`。分類順序：**HTTP 狀態先看**（403 回 HTML 也會讓 AVFoundation 說 format not recognized）→ NSURLError（DNS／timeout／TLS／憑證／離線）→ AVError allowlist `-11821/-11828/-11829/-11833` → mpv allowlist `-14/-15/-17/-18`＋自訂「沒有 first frame」→ 其他一律 `unclassified`（不 fallback）。`httpStatus(statusCode:comment:)` 是唯一的字串解析 |
| `PlaybackLoadRequest` | `PlaybackTarget`（url＋headers＋qualities 原封不動）＋`startSeconds`＋`rate`＋`autoplay`＋`title`＋`history`（WatchHistory：站、片、線路、集、畫質） |
| `PlaybackEngine`（`@MainActor` protocol） | `kind`、`load`、`play`、`pause`、`seek`、`currentTime`、`duration`、`rate`／`setRate`、`volume`、`isLoaded`、`isPlaying`、`state`、`bufferedUntil`、`onFailure(Error, httpStatus?)`、`onEnded`、`teardown` |
| `PlayerRouter` | `open`（新 session 或新 attempt）、`select`（手動切換：以當下 position、記住的 rate、播放／暫停狀態，把**同一個** request 交給另一個 engine）、engine 回報 → 分類 → 最多一次 fallback 或 `onUnrecoverable`、`endSession`（下一個 session 不會用的 engine 會被釋放）、`stop`。**不解析任何東西**；舊 engine 的遲到回報被丟棄 |
| `MPVRequestHeaders.fields` | 所有 header（含 UA／Referer）放進 mpv 的 `http-header-fields`；FFmpeg 看到自訂 UA／Referer 就不加自己的，HLS demuxer 會把同一組 header 帶到每個 playlist／segment；含 CR／LF 的 header 丟棄 |

### App 端

- `PlaybackSession`（不動它上層的一切）：新增 `router`；`load(url)` 變成組 request → `router.open`；
  原本建 `AVPlayerItem` 的那段改名 `loadNative(_:)`，只由 `AVPlayerEngine` 呼叫，內容不變
  （`.timeDomain`、`preferredPeakBitRate = 0`、IOS-POC-15 的重置、variant 計數、`defaultRate`、續播 seek、play）。
  `persist`／`reachedEnding`／`prefetchNextIfDue`／`status`／`control`／`setRate`／`seek` 改讀 engine；
  **IOS-POC-15 的 policy 只在 native 執行**。end-of-item observer 從 session 搬進 `AVPlayerEngine`。
- `AVPlayerEngine`：同一個 `AVPlayer` 的薄轉接；新增 item `.failed`／`failedToPlayToEndTime` 的回報，
  附帶 error log 裡的 HTTP 狀態——**以前失敗是無聲黑畫面，現在會顯示真正原因**。
- `MPVEngine`（新檔 `ios/WebHTVApp/Sources/MPVEngine.swift`）：view 的 layer 就是 mpv 的 `wid`（demo 的 Metal 路徑）；
  wakeup callback 只排程（9G 的規則）；所有 mpv 呼叫在自己的 queue，主執行緒只讀 snapshot；
  `FILE_LOADED` 後 10 秒沒有 `VIDEO_RECONFIG` → `mpv` 自訂碼「沒有 first frame」→ capability failure → 回 AVPlayer；
  模擬器 `hwdec=no`、真機 `auto-safe`（真機未量）；背景時 `vid=no`、前景 `vid=auto`（demo 的黑畫面修法）。
- `PlaybackEngines.offered`：**Release 只有 `[.native]`**，Debug 有 `[.native, .mpv]`（SideStore 只發 Release）。
- 設定頁「預設播放器」：原生播放器／MPV，不可用者顯示「（尚未開放）」且不能點。
- 控制列：速度右邊新增 engine 選單，**標籤是目前實際在跑的 engine**；AirPlay、字幕／音軌依 capability 隱藏。
- 播放畫面：`engineKind` 決定畫 `PlayerSurface`（AVKit）或 `MPVVideoSurface`；MPV 用 0.25 秒 tick 讀 snapshot；
  失敗時顯示分類後的訊息；關閉時先 `persist` 再 `closePlayer()`（override 清除，MPV 釋放）。

### 驗證

| 檢查 | 結果 | 證據等級 |
|---|---|---|
| `swift test --package-path ios`（`WANG_MOVIE_JSON` 為使用者設定） | **322 tests，全部通過**（297 − 1 移除 + 1 移除檢查 + 25 新增）；`reportsLiveType4SitesFromProvidedConfig` 本輪也通過（天氣） | macOS |
| 25 條雙核心測試 | 對應使用者 32 項中的 1–28 與 32（29–31 由 17A 的移除測試涵蓋） | macOS，真 `PlayerRouter`＋假 engine |
| 測試抓到的真缺陷 | `MPVRequestHeaders` 的 CR／LF 防注入原本用 `Character` 比對，Swift 把 `"\r\n"` 當成一個 grapheme，**擋不住**；改成比 unicode scalar | macOS |
| Simulator Debug build | **BUILD SUCCEEDED**；`WebHTVApp.swift` 的 7 條 warning 與 IOS-POC-15 記錄的既有 warning 相同，`MPVEngine.swift` 無 warning | 模擬器 |
| 模擬器實操（荐片《欢迎来龙餐馆》TC国语，iOS 26.3） | 設定頁出現「預設播放器」；播放選單只剩「播放」；AVPlayer 播放，控制列顯示「原生」；1.5×、暫停於 03:59 → 切 MPV：標籤變「MPV」、1.5× 與 03:59 與暫停保留、AirPlay 隱藏、畫面由 MPV 畫出；按播放從 03:59 前進到 04:07 → 切回原生：「原生」、1.5×、暫停保留、AirPlay 回來，位置 04:00 | **模擬器，不是真機** |
| 已知差異 | 切回 AVPlayer 時位置落在關鍵影格（04:07 → 04:00）：`loadNative` 的續播 seek 本來就用預設容差，與既有 resume 同一行為，沒有為切換另外改成精確 seek | — |

### Ponytail

- **pre-review**：見第四節；blocking finding（把整個 `PlaybackSession` 改走 protocol 會動到 IOS-POC-15）已先縮減。
- **final-diff review（`ponytail-review`，2026-09-23）**：一條——`PlaybackEngineCapabilities.pictureInPicture` 沒有任何讀者，
  **已刪**（`net: -3 lines`）。`PlaybackLoadRequest.title` 目前兩個 engine 都沒讀，但屬使用者契約要求的 media metadata，保留。其餘皆有呼叫端或明確需求。

### 沒有驗到的

- **真機一次都沒跑**：MPV first frame、MPV headers 真的送出、`auto-safe` 硬解、fallback 在真實失敗上觸發、背景／前景。
- 自動 fallback 在模擬器上**沒有被真實失敗觸發過**（只有單元測試）；因為 Release 沒有 MPV，正式版的 native 失敗只會顯示訊息。

## 十一、17C — 拿掉「播放」選單頁（使用者 2026-09-23 追加要求，完成）

使用者：「把播放選單那頁拿掉 點選集數後應該就直接到播放畫面」。

- `PlayerPickerView` 整個刪除。詳情頁點集數、以及 WebHome `player.playUrl`，都直接 `fullScreenCover` 出
  `PlayerView`；原本選單頁 onDismiss 的清理（`advance`、`prefetchNext`、`prefetch.invalidate()`、
  記錄重讀）移到 player 的 onDismiss，`onPlaylistFinished` 由呼叫端設定。
- 選單頁唯一做的決定搬到 `Playback.start()`：畫質＝這部片記住的畫質，否則來源預設，用的是同一個
  `PlaybackQuality.defaultIndex`。**代價（已知、刻意）**：多網址來源不再能在開播前手動挑畫質。
  使用者設定檔裡**沒有任何來源回傳多個網址**（IOS-POC-5Q 記錄；Bili 的畫質是分線路，仍在詳情頁線路列選）。
  `ponytail:` 註記寫明：真有這種來源時，把畫質選單放進控制列。
- 驗證：Simulator Debug build **BUILD SUCCEEDED**；`noThirdPartyPlayerHandoffRemainsInTheApp` 1／1；
  模擬器實操——點「TC国语」直接進播放畫面、從上次位置續播、engine 回到全域預設「原生」（上一個
  session 的 MPV override 已清除）、按 X 直接回詳情頁。`swift test` 不編譯 App target，本單元沒有 core 變更。
- Ponytail pre-review：刪除優先，無新抽象。final-diff：`+50 / −118`（淨 −68 行）；兩個呼叫端各三行
  「設定 `onPlaylistFinished`＋`start()`＋指派」沒有再抽 helper（抽了要多傳 binding，反而更長）。Lean already.

## 十二、17D — 文件整理（完成）

更新：`docs/current-task-state.md`、`docs/AGENT_HANDOFF.md`、`docs/IOS-POC-8L-core-real-device-acceptance.md`
（⑪ superseded、新增 ⑮–⑲、RC 內容與 release notes 草稿）、`docs/IOS-POC-12-13-runtime-update-roadmap.md`
（新的進入順序）、`docs/IOS-POC-11-sidestore-release.md`（RC 內容）、`docs/IOS-POC-9B-mpv-playback-core.md`（9G）。
歷史文件加上 `Superseded by dual internal-player decision, 2026-09-23` 標記、內容不刪：IOS-POC-2E、5P、
5Q、5Q-5R 計畫、5R、9A、14、15、`IOS-PORTING-HANDOFF-2026-09-13.md`、`analysis/ios-app-store-readiness-research.md`。

## 十二之一、17E — MPV 直接開放＋畫質選單進控制列（使用者 2026-09-23 決定，完成）

使用者：「直接將MPV開放然後畫質選單放進控制列，修改完成直接PUSH 發佈」。

- `PlaybackEngines.offered` 在所有 build 都是 `[.native, .mpv]`（原本 Release 只有 `.native`）。
  **風險明記**：MPV 在真機上尚未看過 first frame。保護只剩 `MPVEngine` 的 watchdog——
  `FILE_LOADED` 後 10 秒沒有 `VIDEO_RECONFIG` 就是 capability failure，router 把同一個 target 交回 AVPlayer；
  沒走到 `FILE_LOADED` 的失敗（網路、格式）則照分類顯示或 fallback。
- 畫質選單：新增 core `PlaybackQualityChoice`（`PlayURL.swift`）——起始＝記住的畫質否則來源預設；
  預設項目播放它經 probe/sniff 解析過的位址，其他項目照來源原樣開（原選單頁的不對稱，`ponytail:` 註記搬過來）。
  `PlaybackSession.open(_ target:preferredQuality:…)` 建立它並寫進 record；`selectQuality(_:)` 以當下位置、
  播放／暫停狀態重開同一集的另一個項目，並寫回 record，所以歷史會記住。控制列在速度左邊顯示畫質選單，
  **只有來源給兩個以上項目時才出現**。自動下一集改用 store 裡剛持久化的畫質（`finished()` 先 persist）。
- 驗證：`theQualityChoiceStartsRememberedAndOpensTheResolvedDefault`（新）通過；Simulator Debug build
  **BUILD SUCCEEDED**（7 條既有 warning）；全套 `WANG_MOVIE_JSON=<config> swift test` → **323 tests，全部通過**。
  **畫質選單的 UI 沒有在模擬器上被真實資料觸發**：使用者設定檔裡沒有任何來源回傳多個網址（Bili 是一線路一畫質，
  在詳情頁的線路列選）。
- Ponytail：pre-review——沿用 `PlaybackQuality.defaultIndex` 與原選單頁的規則，不新增 resolver；final-diff——
  `+147／−31`，唯一保留的不可達分支是「（尚未開放）」兩行，理由是日後若重新限制 MPV，不會變成無聲的死按鈕。

## 十二之二、17F — 無法播放時主動切換播放核心（使用者 2026-09-24 追加要求，完成到模擬器）

使用者 2026-09-24 要求：播不出來時要主動換另一個播放器，不要停在錯誤或黑畫面。

### 決策：取代 17B「只有 capability failure 才 fallback」

17B 的理由是「網路類失敗在兩個核心上一樣會失敗，切換只會把問題藏起來」。這個判斷常常成立，
但**不夠可靠到可以直接放棄**。本機程式碼的證據如下：

- AVPlayer 的來源 header 是走未公開的 asset option `AVURLAssetHTTPHeaderFieldsKey`
  （`ios/WebHTVApp/Sources/WebHTVApp.swift` `PlaybackSession.asset(for:headers:)`），**真機從未確認過它真的送出**；
  MPV 則是 mpv 文件記載的 `http-header-fields`（`MPVEngine.swift`，`change-list … append`）。
  同一個 403，換到另一邊可能就能播。
- 兩邊的 HLS／TLS／HTTP 是不同的程式：CFNetwork＋AVFoundation 對上 FFmpeg。
- 讓嘗試變得便宜的是**有上限**：每個 attempt 最多切一次，而且不會切回來（`fallback(after:)` 的
  `fallbackSpent`，17B 已有）。

| 方案 | 內容 | 結果 |
|---|---|---|
| no change | 維持 17B：只有 capability failure 切換 | 不採用。header 路徑差異造成的 403、只有一邊卡住的串流都會直接報錯或一直轉圈 |
| 全部都切 | 任何失敗、包括離線與解析失敗都切 | 不採用。離線時兩個核心都不可能播；`source` 是 resolver 在任何核心介入**之前**就失敗，換核心只是多等一次 |
| **採用版** | engineCapability／network／unclassified 都可以切一次；`offline`、`source` 不切；另加「20 秒沒開始播放」的主動切換 | **採用** |

### 契約（`ios/Sources/WebHTVCore/PlaybackEngine.swift`）

- `PlaybackFailure` 新增 `.offline`（`NSURLErrorNotConnectedToInternet`／`DataNotAllowed`／`InternationalRoamingOff`），
  訊息是「沒有網路連線」；`NetworkConnectionLost` 仍然是 `.network("網路中斷")`。
- `allowsEngineFallback`：`.engineCapability`、`.network`、`.unclassified` → true；`.offline`、`.source` → false。
  分類本身不變，因此訊息不變（例如 403 藏在 format error 後面時仍然顯示 `網路錯誤：HTTP 403`）。
- `PlayerRouter.startupTimeout = 20`（秒）與 `startupTimedOut() -> Bool`：本 attempt 還沒切過、另一個核心可用時，
  用當下位置、`autoplay: true` 把同一個 request 交給另一個核心。**永遠不會顯示成錯誤**：切不了就什麼都不做，
  讓它自己慢慢開始播。

### App 端（`PlaybackSession.watchStartup()`）

- 15D 的 startup watch（0.1 秒 poll）同時負責判斷「一直沒開始播放」。條件：engine 不在播放中、`state` 是
  `preparing` 或 `buffering`，而且距離**目前這個核心接手**已超過 `startupTimeout` → `router.startupTimedOut()`。
  `ready`（已載入但暫停）不算卡住。
- 「目前這個核心接手的時間」`engineStartedAt`：`load` 時設定，`router.onEngineChange` 時重設。因此
  使用者剛手動選的核心、或 fallback 過去的核心，都有自己完整的 20 秒；檢查一次後就清掉，不會每 0.1 秒重打。
- 切換時寫一行 `[playback] <片名> not started on <核心> after 20s — trying <另一個>`（`os.Logger`）。

### 驗證

| 檢查 | 結果 | 證據等級 |
|---|---|---|
| `swift test --filter PlaybackEngineTests` | **29／29 通過**：network／unclassified 會切；offline／source 不切；403 切一次後第二次失敗才顯示；offline 不切直接顯示；startup timeout 切一次、第二次不切也不顯示錯誤、下一集有新額度；只有一個核心時不動作 | macOS |
| 全套 `swift test` | **344／344 全部通過**（15D 基線 340／339；+4 條 17F 測試；天氣測試 `reportsLiveType4SitesFromProvidedConfig` 本輪也通過） | macOS |
| Simulator Debug build | **BUILD SUCCEEDED**；`WebHTVApp.swift` 只有既有 warning（`deviceInfo()` 的 `UIDevice.current`、bridge 的 `evaluateJavaScript`），新程式沒有新增 | 模擬器 |
| 模擬器實播：本機假 type-1 CMS 站，唯一一集的 `.m3u8` 回 200 後每秒只送 1 byte（永遠不逾時、永遠不完整） | 預設原生：`11:41:38 resolve` → `11:41:58 … not started on 原生 after 20s — trying MPV`，畫面標籤變 MPV。預設 MPV：`11:42:29 resolve` → `11:42:49 … not started on MPV after 20s — trying 原生`，伺服器同一秒收到新請求、MPV 的連線隨即關閉；**11:43:25 仍停在原生、沒有第二次切換、沒有錯誤訊息** | **模擬器，不是真機** |
| 模擬器實播：同一站，但 `.m3u8` 完全不回應 | AVPlayer 自己報網路錯誤 → 依新的分類 fallback 到 MPV → MPV 也失敗（`mpv error -13`）才顯示錯誤。這是「network 會切一次」在 App 端的實證，不是 timeout 路徑 | **模擬器，不是真機** |

測試後模擬器的 App 偏好設定與 Application Support 都已從備份還原（設定來源回到使用者的 `wang-movie.json`）。

### Ponytail

- pre-review（前一 session）：不新增 watchdog task，沿用 15D 的 startup watch；不新增設定項，20 秒是常數。
- final-diff：App 端 `+23／−1`，core `+43／−10`，測試 `+60／−7`。`watchStartup` 裡的 `engineStartedAt = .now` 不能刪——同一個核心播下一集不會觸發
  `onEngineChange`。沒有可再刪的部分。

### 沒有驗到的／已知限制

- **真機一次都沒跑**：真實來源上的 403／逾時切換、20 秒門檻在弱網路下是否太短或太長。
- 使用者在開播前按暫停：AVPlayer 仍回報 `preparing`，20 秒後會切到另一個核心並自動播放。罕見，沒有另外處理。
- 20 秒是常數；要調整就改 `PlayerRouter.startupTimeout`。

### 回滾

`git revert` 17F 的 commit 即可：core 回到 17B 規則，App 端的 startup watch 回到只量測啟播時間。

## 十三、正式 roadmap（2026-09-23 起）

```
remove external players            ✓ 17A
→ MPV rendering recovery           ✓ 9G（模擬器；真機待跑）
→ minimal MPVEngine                ✓ 17B
→ AVPlayer + MPV dual-engine       ✓ 17B
→ global/default engine setting    ✓ 17B
→ session engine selector          ✓ 17B
→ manual engine switching          ✓ 17B（模擬器實測）
→ classified automatic fallback    ✓ 17B（單元測試；真實失敗未觸發過）
→ MPV opened in release + quality menu in the bar  ✓ 17E（使用者決定）
→ proactive engine fallback (network/unclassified + 20 s no-start)  ✓ 17F（模擬器；真機待跑）
→ core real-device acceptance      ← 下一步（8L；含 ⑱⑲ MPV 真機，`0.1.8 (9)` 起可在正式版測）
→ IOS-POC-12
→ IOS-POC-13
```

只有當 MPV 在真機觸發第五節 stop condition 並被實證不適用：`MPV stop → minimal VLCKit spike →
decision AVPlayer + VLC`（絕不三核心）。IOS-POC-15 真機效能測試依使用者決定延後，不是 blocker。

## Recovery anchor

- 已完成：17A `ecb0c4d0`、9G `cf076e79`、17B `7d679d68`、17C `a1750b8c`、17D `bbc73051`、17E `a1bc5bb6`、
  版號 `0a57d545`；**已 push，並已發布 `0.1.8 (9)`**（run `35846736589`，tag `ios-v0.1.8-b9`，
  `source.json` `30af13f5`，IPA 下載回驗通過）。
- 已驗證：macOS `swift test` **323／323**；Simulator Debug build；模擬器上 MPV Metal／OpenGL first frame、
  AVPlayer↔MPV 手動切換保留位置／速度／暫停／target、點集數直接播放；iphoneos Release 預建置。
- 未驗證：**任何真機行為**（MPV first frame、headers、硬解、切換、watchdog fallback、背景／前景）；
  畫質選單沒有被真實多網址來源觸發過；自動 fallback 沒有被真實失敗觸發過。
- 下一步（唯一）：使用者用 SideStore 裝 `0.1.8 (9)`，依 8L 7.2 回報，**優先 ⑱⑲（MPV 真機）**。
