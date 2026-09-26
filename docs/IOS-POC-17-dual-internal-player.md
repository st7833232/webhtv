# IOS-POC-17 — 雙內部播放核心（AVPlayer + MPV）

- 狀態（2026-09-24）：**17A／9G／17B／17C／17D／17E 完成；17F（主動切換播放核心）完成到模擬器。MPV rendering 在模擬器已解；真機仍未驗證。**
  **使用者 2026-09-23 決定直接開放 MPV**（17E）：正式版現在可選 MPV；防黑畫面的只剩 `MPVEngine` 的
  first-frame watchdog（10 秒沒畫面 → 回 AVPlayer）。不可宣稱 MPVEngine 已完成真機驗收。
  （2026-09-25 更正：使用者 2026-09-24 在 `0.1.10 (11)` 真機回報 MPV 有畫面（`docs/IOS-POC-8L-core-real-device-acceptance.md` 7.2 表後的回報），
  MPV 正式播放路徑已在真機出畫面；first frame 事件序列、headers、硬解仍未逐項回報。之後的 17G（旋轉）已由 IOS-POC-17I
  自建含 resize 修正的 Libmpv 取代（`9186a272`，`0.1.19 (20)`）；17H（MPV 子母畫面）已於 `0.1.11 (12)` 發布；兩者真機驗收仍待回報。目前最新版為 `0.1.20 (21)`。）
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
   **（2026-09-24 被 17F 取代：network／unclassified 也切一次、20 秒沒開始播放也切；offline／source 不切。見第十二之二節。）**
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
  （2026-09-25 更正：程式裡的旗標是 `PlaybackEngines.offered`（`ios/WebHTVApp/Sources/WebHTVApp.swift:2949-2950`），17E 起所有 build 都是 `[.native, .mpv]`；改回 `[.native]` 後，MPV 在設定頁與控制列仍會列出，但顯示為「MPV（尚未開放）」且不能選（`:1244`、`:3689`）。）
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

## 十、17B — 雙核心本體（完成；當時 MPV 在正式版 disabled，17E 已開放）

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
| 已知差異 | 切回 AVPlayer 時位置落在關鍵影格（04:07 → 04:00）：`loadNative` 的續播 seek 本來就用預設容差，與既有 resume 同一行為，沒有為切換另外改成精確 seek。**2026-09-25 更正：真機回報切換位置不對，IOS-POC-26-1 改為交接時精確 seek，見 `docs/IOS-POC-26-engine-switch-position.md`** | — |

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
- **IOS-POC-27A（2026-09-26）修改**：`startupTimeout` 改為 `startupTimeout(for:)`，原生 5 秒、MPV 20 秒（使用者要求）；`engineStartedAt` 改為只計算想播時間的 `PlaybackStartupWatch`，暫停中不逾時；原生逾時時記錄等待原因與 error log，畫面顯示原因約 4 秒。見 `docs/IOS-POC-27-avplayer-2x-buffer-stall-controls.md`。

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

## 十二之三、17G — MPV 旋轉後跑版（使用者 2026-09-24 真機回報，修正到模擬器）

使用者在 SideStore 裝上 `0.1.10 (11)` 後回報：**MPV 直向播放轉成橫向會跑版，反過來也是**；另外 **MPV 還不支援 PiP**
（已知缺口＝第十四節 P6，需先做 feasibility spike，本節不處理）。

### 根因（讀上游原始碼，不是猜）

- MPVKit 為 iOS 加的 `moltenvk` context（`Sources/BuildScripts/patch/libmpv/0001-player-add-moltenvk-context.patch`，
  MPVKit `1.0.0`＝`288527dffbc6d3e63cce147fc7b520c64a791603`，本機 SPM checkout；2026-09-24 以 `gh api` 確認 MPVKit 主線同一份 patch 未改）：
  `moltenvk_reconfig` 只在 VO **設定時**讀一次 `layer.drawableSize`；`moltenvk_control` 一律回 `VO_NOTIMPL`，**從不回報 `VO_EVENT_RESIZE`**。
- mpv `v0.41.0` `video/out/vo_gpu_next.c`：`reconfig()` 才會呼叫 context 的 `reconfig`；另一條 `VOCTRL_EXTERNAL_RESIZE` 只由
  `android-surface-size`／`d3d11-composition-size` 觸發（`player/command.c`），**這兩個選項在 iOS 不會編進去**（`options/options.c` 的 `#if`）。
- 所以旋轉後 layer 的 bounds 變了，mpv 仍用舊方向的尺寸畫，Core Animation 再把它拉到新 bounds 上＝跑版。
  **2026-09-25 更正**：播放中的實際機制是 MoltenVK 回報 `VK_SUBOPTIMAL_KHR`、libplacebo 依新尺寸重建 swapchain，mpv 卻仍用舊方向的目標矩形畫進新畫布；Core Animation 拉伸只發生在暫停中與第一幀。詳見 `docs/IOS-POC-17I-mpv-resize-libmpv.md`（根治方案：自建含 resize 修正的 Libmpv）。
  上游 **MPVKit issue #3「Player won't resize on iOS when using Metal」**（2024-04 開、2026-09 仍 open）就是同一個問題；
  社群修法 edde746/MPVKit@`e6b129fdd31347b25d5d862f73f52c23f9e55624` 是改 libmpv 的 `moltenvk` context，需要自己重編 libmpv。

### 方案比較

| 方案 | 內容 | 結論 |
|---|---|---|
| no change | 維持現狀 | 不採用：真機可重現的跑版 |
| 上游修法 | 套 edde746 的 context patch、自己重編 libmpv | **這次不做**：要改二進位來源與打包（AGENTS §8），不是單一 bug 修正的範圍；列為根治路徑 |
| 改走 OpenGL render path | `vo=libmpv`＋render API，每幀以 view 尺寸繪製 | 不採用：renderer 選擇屬 material change，需另行研究與授權 |
| **採用：App 端重建 VO** | `MPVVideoView.layoutSubviews` 偵測尺寸變化 → 0.3 秒穩定後把 `drawableSize` 設成新 bounds × scale → `MPVPlayerCore.rebuildVideoOutput()` 把 `vo` 換成同一個 driver 的另一種寫法（`gpu-next` ↔ `gpu-next,`） | mpv 的 `UPDATE_VO`（`player/command.c`）會**同步** `uninit_video_out` → 重建 VO → 對目前位置 exact seek；新 VO 在 reconfig 時讀到新尺寸。mpv 會略過與現值相同的設定（`options/m_config_core.c` 的 `m_option_equal`），所以要交替兩種寫法。背景中（`vid=no`，沒有 VO）只改選項，回前景建 VO 時自然讀到新尺寸 |

**沒採用 `vid` 開關**：`vid=no` 之後要等 playloop 下一輪 `handle_force_window` 才銷毀 VO，緊接著 `vid=auto` 可能沿用舊 VO、參數相同就不 reconfig，時序不保證。

### 驗證

| 檢查 | 結果 | 證據等級 |
|---|---|---|
| 修正前重現 | 荐片《欢迎来龙餐馆》TC国语，MPV 直向播放 → App 內 `requestGeometryUpdate` 轉橫向：**影片只剩左上角一小條、其餘全黑**；轉回直向恢復（VO 是用直向尺寸建的） | 模擬器 |
| 修正後 直→橫 | 影片鋪滿橫向畫面、字幕正常，播放從 29:09 持續前進 | 模擬器 |
| 修正後 橫→直 | 直向畫面正確，播放 29:26 持續前進；`vo` 兩種寫法各用過一次 | 模擬器 |
| 修正後 暫停中旋轉 | 轉橫向後仍是暫停、畫面停在 29:40 的影格並正確鋪滿，沒有變黑也沒有自己開始播 | 模擬器 |
| Simulator Debug build（移除臨時觸發器後） | **BUILD SUCCEEDED**；`MPVEngine.swift` 無 warning | 模擬器 |

模擬器無法手動旋轉，測試時暫時在 `MPVEngine` 放了一段「App tmp 目錄出現旗標檔就 `requestGeometryUpdate`」的程式，
**已移除、沒有 commit**；測後模擬器偏好設定已確認沒有殘留（設定來源仍是使用者的 `wang-movie.json`）。
`swift test` 不涵蓋 App target，本次未重跑（core 未變更）。

### 限制／未驗證

- **真機未驗證**：需要下一次經使用者授權的發布才會到手機上。（2026-09-25 更正：17G 已隨 `0.1.11 (12)` 發布；使用者在 `0.1.18 (19)` 真機回報旋轉時「畫面會短暫的跑版，然後恢復正常」，
  之後由 IOS-POC-17I 以自建含 resize 修正的 Libmpv 根治，並移除本節的 VO 重建（`9186a272`，`0.1.19 (20)` 發布，真機待驗），見 `docs/IOS-POC-17I-mpv-resize-libmpv.md`。）
- 每次旋轉會重建一次 VO 並對目前位置 exact seek：模擬器上看不出卡頓，弱網路下若 demuxer cache 沒有涵蓋目前位置，可能短暫緩衝。
- 根治是 libmpv 的 `moltenvk` context 自己回報 resize（上游 issue #3／edde746 修法），要自己編 libmpv；程式裡以 `ponytail:` 註記。

### 回滾

`git revert` 本 commit：回到旋轉會跑版的行為，其他不受影響。

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
→ MPV rotation resize (rebuild the VO on a settled size change)     ✓ 17G（模擬器；真機待跑）
→ MPV Picture in Picture (SW output into a sample buffer layer)    ✓ 17H（模擬器能驗的部分；PiP 畫面與自動 PiP 真機待跑）＝第十四節 P6
→ core real-device acceptance      ← 下一步（8L；含 ⑱⑲ MPV 真機，`0.1.8 (9)` 起可在正式版測；
                                      = 第十四節 MPV parity 的 P1）
→ IOS-POC-12
→ IOS-POC-13
```

（2026-09-25 更正：9G 的 MPV 畫面已在 `0.1.10 (11)` 真機看到（見文首狀態）；17G 已由 IOS-POC-17I（自建含 resize 修正的 Libmpv，`9186a272`，
`0.1.19 (20)` 發布，真機待驗）取代並移除；17H 的 PiP 視窗在真機有畫面（`docs/IOS-POC-17H-mpv-picture-in-picture.md` 第六節之六），其餘 PiP 項目真機待驗；
MPV 內嵌字幕／音軌切換已由 P10 實作（見第十四節 P3 列）。「core real-device acceptance」仍是下一步。）

MPV parity 的後續階段（P2 前置緩衝 → P3 字幕／音軌 → P4 外掛字幕 ASS/SSA → P5 背景音訊／鎖屏／remote command →
P6 PiP bridge → P7 AirPlay Audio；AirPlay Video 只做 feasibility）見第十四節；它們與 IOS-POC-12／13 的先後由使用者決定。

只有當 MPV 在真機觸發第五節 stop condition 並被實證不適用：`MPV stop → minimal VLCKit spike →
decision AVPlayer + VLC`（絕不三核心）。IOS-POC-15 真機效能測試依使用者決定延後，不是 blocker。

## 十四、MPV parity roadmap（2026-09-24 起，使用者指示寫入；P6 已由 IOS-POC-17H 實作，其餘仍只是計畫；2026-09-25 更正：P3 的內嵌字幕／音軌切換已由 P10 實作，見 P3 列）

> **編號說明**：P1–P7 是本節內的先後順序，**不是** AGENTS.md §8 上游合併計畫的 `P*` 任務 ID；
> 每一階段開始實作時另取 IOS-POC 家族的 stage ID（例如 `IOS-POC-17G`），並登記在第十三節與 `docs/current-task-state.md` 的 stage index。
> P1 就是第十三節「core real-device acceptance」裡的 8L ⑱⑲；P2–P7 與 IOS-POC-12／13 的先後，**由使用者決定**，本節不預設。

IOS-POC-16B（控制列 panel）完成後，MPV 的後續工作依下列順序進行。**每一階段都是獨立的 functional unit**：
各自走 AGENTS §7 的設計研究、task guard 與 targeted verification；Ponytail 若可用可做 pre-review／final-diff review，若不可用直接略過且不得成為 blocker，
**不得合併成一次大改**，也不得動 `PlaybackSession`／`PlayerRouter` 既有的雙核心責任分層
（engine 只執行媒體；解析、線路、畫質、WatchHistory、resume、片頭片尾、auto-next、prefetch 都在 session 上層）。

| 順序 | 階段 | 產品目標 | 已知技術依據（2026-09-24 研究，來源見下表） | 驗收重點 |
|---|---|---|---|---|
| P1 | **MPV 真機 baseline** | 先量，不先調 | first frame（`VIDEO_RECONFIG`＋`PLAYBACK_RESTART`）、`hwdec-current` 實際是 `videotoolbox` 還是 `videotoolbox-copy`、HLS／MP4、headers（Bili Referer＋UA）、2.5×／3×／4× 聲音與畫面、`demuxer-cache-state` 的 forward 秒數與 `cache-speed`、AVPlayer↔MPV 切換、**真實**失敗觸發的 fallback | 8L ⑱⑲ 全部有真機結果；每項記錄事件序列與數字，不寫「應該可以」 |
| P2 | **MPV 前置緩衝 parity（IOS-POC-15 的 MPV 版）** | 與 AVPlayer 相同的產品目標：足夠的前置 buffer、可量測的 cache、弱網不抖動 | 用 libmpv 自己的機制，**不**照抄 `preferredForwardBufferDuration`：`cache=yes`（不靠 `auto` 啟發式）、`cache-secs`（以秒表達目標）、明確且較低的 `demuxer-max-bytes`／`demuxer-max-back-bytes`（預設 150／50 MiB，iOS 記憶體需另定）、`cache-pause-wait`（預設 1 秒，弱網易抖）、觀察 `demuxer-cache-state`（`cache-end`、`fw-bytes`、`raw-input-rate`）與 `cache-buffering-state`；live／未知長度不套 VOD 目標 | 真機比較 P1 baseline：startup、buffer-ahead、stall 次數；記憶體峰值 |
| P3 | **subtitle／audio track parity**（2026-09-25 更正：內嵌字幕／音軌切換已由 P10 實作，`637d3597`＋編譯修正 `7acb5db1`，於 `0.1.16 (17)` 發布；MPV 的 `trackSelection` 已是 true（`ios/Sources/WebHTVCore/PlaybackEngine.swift:31-34`），以 `track-list`＋`aid`／`sid` 實作，`secondary-sid` 未做；真機未驗證。見 `docs/P10-IOS-EMBEDDED-TRACK-SELECTION.md`） | 控制列的字幕／音軌 panel 在 MPV 也出現 | `track-list`（NODE）→ `aid`／`sid`／`secondary-sid`；IOS-POC-16B 的 panel 直接沿用，只補 MPV 的資料來源與 `PlaybackEngineCapabilities.trackSelection = true` | 多音軌／多字幕來源實測；切換不重開影片 |
| P4 | **外掛字幕、ASS/SSA** | 來源提供的字幕網址可載入，ASS 樣式正確 | `sub-add <url> cached <title> <lang>`；libass 已在 MPVKit 1.0.0 LGPL 產品內（ISC 授權、CoreText 字型、無 fontconfig），中文字型走系統字型；需在授權聲明補 fribidi（LGPL）／freetype | CJK 字幕、ASS 特效、字幕與影片同步 |
| P5 | **背景音訊、鎖屏、控制中心、耳機／AirPods／Bluetooth／車機控制** | 離開 App 或鎖屏時 MPV 繼續出聲，鎖屏／控制中心顯示並可操作 | App 已設 `.playback`／`.moviePlayback` 與 `UIBackgroundModes`；**但 mpv 的 `ao_audiounit` 預設把 session 設成 `mixWithOthers`**，可混音的 session 不具 Now Playing 資格 → 需 `audio-exclusive=yes`；非 AVPlayer engine 必須自己發 `MPNowPlayingInfoCenter.default().nowPlayingInfo`（只在 play/pause/seek/rate 變化時更新，不要每 tick）並註冊 `MPRemoteCommandCenter.shared()`（play/pause/toggle/skip±/changePlaybackPosition）；`MPNowPlayingSession` 只收 AVPlayer | 鎖屏、控制中心、AirPods 雙擊、車機上一首／下一首實測；uninit 的 `setActive:NO` 不得打斷 AVPlayer 路徑 |
| P6 | **MPV PiP bridge** — **已實作：IOS-POC-17H（2026-09-24，`8824c8ee`，已於 `0.1.11 (12)` 發布；模擬器能驗的部分通過，PiP 畫面與自動 PiP 真機未驗證）**（2026-09-25 更正：使用者在 `0.1.11 (12)` 回報 PiP 解析度降低，表示真機 PiP 視窗有畫面，解析度已由 `5613517a` 修正；其餘 PiP 項目真機未驗證，見 17H 文件第六節之六與其後的真機回報） | MPV 也能子母畫面 | 唯一公開路徑：`AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)`（iOS 15+）。原本的 feasibility 問題（拿不到 `CVPixelBuffer`）的答案：**inline 維持 Metal，只在 PiP 期間把 `vo` 切到 libmpv SW render**，以 PiP 視窗寬度（上限 960 px）畫進 IOSurface BGRA buffer 送進 MPV view 裡的 `AVSampleBufferDisplayLayer`；背景不能用 GPU（Apple），所以 PiP 畫面必須在 CPU 上產生。代價：PiP 開始／結束各一次 VO 重建＋exact seek。模擬器的 sample-buffer PiP 視窗一律全黑（SwiftVLC `0ec31e4e` 記載的限制；最小對照組也黑、AVPlayerLayer PiP 有畫面）。詳見 `docs/IOS-POC-17H-mpv-picture-in-picture.md` | play/pause/seek、背景播放、返回 App 自動恢復 inline player；**不建立第二個 MPV instance、不重開影片**，保留 position／rate／audio／subtitle；與 AVPlayer 相同，由使用者離開 App 自動進入（`canStartPictureInPictureAutomaticallyFromInline`），沒有手動 PiP 按鈕 |
| P7 | **AirPlay Audio** | MPV 播放時可選 AirPlay 音訊輸出 | `AVRoutePickerView`（控制列已有）＋`AVAudioSession` route；需 P5 的 Now Playing／remote command 才完整 | 真機接 AirPlay 喇叭 |
| — | **AirPlay Video：feasibility only** | **不承諾**與 AVPlayer 等價 | Apple 只把外部影片播放寫成 AVPlayer 的屬性（`allowsExternalPlayback`、`usesExternalPlaybackWhileExternalScreenIsActive`）；沒有文件說 AirPlay 影片必須 AVPlayer，但也沒有任何非 AVPlayer 的公開路徑——MPV 在實務上大概只剩螢幕鏡像或外接顯示視窗（A/V 同步風險）。AirPlay 影片維持由 AVPlayer 負責 | 只做可行性評估，不列入 parity 驗收 |

**IOS-POC-15 的 MPV 對應（P2 之外已具備的部分）**：下一集 `PlaybackTarget` 預解析在 session 層、與 engine 無關，
MPV 播放時同樣會預解析與交棒（IOS-POC-15D 起 MPV 不再沿用上一個 AVPlayer item 的網路狀態）；
啟播時間、prefetch 命中／未命中原因、解析耗時的量測也與 engine 無關。AVPlayer 專屬的是 buffer policy 與
access-log 類診斷，MPV 對應項在 P2 補上。

### 研究來源（2026-09-24 存取；讀原文，非摘要）

| 主題 | 來源 | 等級 |
|---|---|---|
| `cache`／`cache-secs`／`demuxer-max-bytes`／`demuxer-max-back-bytes`／`demuxer-readahead-secs`／`cache-pause*` 語意與預設值 | mpv `DOCS/man/options.rst` 與 `demux/demux.c`，tag `v0.41.0`（commit `41f6a645068483470267271e1d09966ca3b9f413`） | 上游原始碼 |
| `demuxer-cache-state`／`demuxer-cache-time`／`cache-speed`／`paused-for-cache`／`cache-buffering-state` | mpv `DOCS/man/input.rst`，同 tag | 上游原始碼 |
| `hwdec`：`auto-safe`＝`auto`，白名單先試 `videotoolbox` 再 `videotoolbox-copy`；gpu-next／Vulkan 的 VT zero-copy 依賴 libplacebo Metal texture import | `options.rst`、`video/decode/vd_lavc.c`、`video/out/hwdec/hwdec_vt_pl.m`，同 tag | 上游原始碼 |
| render API 只有 OpenGL 與 SW | `include/mpv/render.h`，同 tag | 上游原始碼 |
| `ao_audiounit` 預設 `mixWithOthers`、`audio-exclusive` | `audio/out/ao_audiounit.m`，同 tag | 上游原始碼 |
| libass 在 MPVKit LGPL 產品內、CoreText、無 fontconfig | MPVKit `1.0.0`（`288527dffbc6d3e63cce147fc7b520c64a791603`）`Package.swift`、README、build script；`mpvkit/libass-build` `0.17.5` | 上游原始碼 |
| PiP custom player、`ContentSource(sampleBufferDisplayLayer:playbackDelegate:)`、playback delegate 必要方法、`AVSampleBufferDisplayLayer` | Apple Developer Documentation（AVKit／AVFoundation 現行頁面） | 官方文件 |
| Now Playing 資格（非混音 session、至少一個 remote command）、`MPNowPlayingSession` 只收 AVPlayer | WWDC22 session 110338；Apple Developer Documentation（MediaPlayer） | 官方文件 |
| AirPlay：`AVRoutePickerView`、外部影片播放只見於 AVPlayer 屬性 | Apple「Supporting AirPlay in your app」與 AVPlayer 屬性頁 | 官方文件（「AirPlay 影片需 AVPlayer」為推論，已標明） |

## Recovery anchor

- 已完成：17A `ecb0c4d0`、9G `cf076e79`、17B `7d679d68`、17C `a1750b8c`、17D `bbc73051`、17E `a1bc5bb6`、
  版號 `0a57d545`；**已 push，並已發布 `0.1.8 (9)`**（run `35846736589`，tag `ios-v0.1.8-b9`，
  `source.json` `30af13f5`，IPA 下載回驗通過）。之後的 `0.1.9 (10)`（IOS-POC-18）也含上述全部。
- 17F `b37751d2`（2026-09-24）：已 push，並於 2026-09-24 以 `0.1.10 (11)` 發布（run `35953397506`，tag `ios-v0.1.10-b11`）。
- 17G `257553f2`（旋轉，第十二之三節）與 17H `8824c8ee`（MPV PiP，第十四節 P6、`docs/IOS-POC-17H-mpv-picture-in-picture.md`）：2026-09-24 已 push，並以 `0.1.11 (12)` 發布（run `35968750165`，tag `ios-v0.1.11-b12`）；
  17H 的 PiP 畫面、自動 PiP、PiP 控制都是**真機未驗證**。（2026-09-25 更正：使用者在 `0.1.11 (12)` 回報 PiP 解析度降低，表示真機 PiP 視窗有畫面，見 17H 文件第六節之六；自動 PiP 與 PiP 控制仍未在真機驗證。）
- 已驗證：macOS `swift test` 17E 後 323／323、17F 後 **344／344**；Simulator Debug build；模擬器上 MPV Metal／OpenGL
  first frame、AVPlayer↔MPV 手動切換保留位置／速度／暫停／target、點集數直接播放；iphoneos Release 預建置；
  17F 的 20 秒主動切換在模擬器上兩個方向都觸發過、且不會切第二次（第十二之二節）。
- 未驗證：**任何真機行為**（MPV first frame、headers、硬解、切換、watchdog fallback、17F 的切換、背景／前景）；
  畫質選單沒有被真實多網址來源觸發過；自動 fallback 沒有被**真實來源**的失敗觸發過（17F 用的是本機假串流）。
  （2026-09-25 更正：MPV 在真機出畫面已由 `0.1.10 (11)` 的使用者回報確認（見文首狀態）；IOS-POC-23 的 T1～T3 在 `0.1.20 (21)`
  兩個核心都通過。其餘項目仍未在真機驗證。）
- 17I（2026-09-25）：以自建含 resize 修正的 Libmpv 取代 17G 的 VO 重建（`9186a272`），以 `0.1.19 (20)` 發布，真機待驗；見 `docs/IOS-POC-17I-mpv-resize-libmpv.md`。
- 下一步（唯一）：使用者用 SideStore 裝最新的 `0.1.11 (12)`，依 8L 7.2 回報，
  **優先 ⑱⑲（MPV 真機）**＝第十四節 P1，並回報 17F 的自動切換是否在真實來源上出現。
  （2026-09-25 更正：目前最新為 `0.1.20 (21)`，使用者已安裝；在這一版上依 8L 7.2 回報，其餘不變。）
