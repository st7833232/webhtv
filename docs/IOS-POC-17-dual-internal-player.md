# IOS-POC-17 — 雙內部播放核心（AVPlayer + MPV）

- 狀態：**實作中**（本節在每個單元完成時更新，見文末 Recovery anchor）
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

## Recovery anchor

- 已完成：17A 外部播放器移除；9G MPV 算繪根因修正（模擬器 first frame）。
- 下一步（唯一）：17B 雙核心（core model＋router＋fallback＋MPVEngine＋設定與控制列）。
