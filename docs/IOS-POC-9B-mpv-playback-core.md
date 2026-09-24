# IOS-POC-9B — MPV 第二播放核心：技術可行性

- 狀態（**2026-09-23 更新，IOS-POC-9G**）：**黑畫面根因已找到並修正——模擬器上 Metal 與 OpenGL
  都出 first frame；真機尚未重跑**。見文末 9G 一節。下面這一段是 2026-09-22 的舊狀態，保留作歷史：
- 舊狀態：**已開始、部分完成、算繪未解、暫停中**（2026-09-22 於 IOS-POC-11B 校正措辭）。
  「進行中」不足以描述現況，因為它同時被讀成「還沒動」與「快好了」，兩者都錯。
  - **已完成**：9A 授權審查；MPVKit 1.0.0（非 GPL）接進 App target；靜態連結以 symbol table 證實；
    **libmpv 在模擬器與 iPhone 18 Pro 都初始化成功**。
  - **未完成**：**算繪**。真機 Metal＋軟解到得了 `FILE_LOADED`，`VIDEO_RECONFIG` 從未觸發，畫面全黑。
  - **不存在第二個播放核心。** `PlaybackTarget → PlayerRouter → AVPlayerEngine / MPVEngine` 是設計，
    不是現況；沒有任何播放會被導離 `AVPlayer`。
  - 恢復條件：**使用者明確指示**。恢復後從 `FILE_LOADED → VIDEO_RECONFIG` 這一段接續，
    **不要**從 MPVKit 安裝重來，**不要**重做 9A（除非 MPVKit 或其相依真的改版）。
- 分支 `ios-poc`，基線 HEAD `4cc36ed9`（IOS-POC-9A）
- 前置：`docs/IOS-POC-9A-mpv-license-provenance.md`（授權審查，結論是沒有阻斷條件）
- Lane：`upstream`（動到相依與二進位歸屬）

## 9A 留下的 gate，本輪關閉情形

9A 說「MPVKit LGPL 變體的完整相依授權要在 9B 開始前補完」。做法不是逐一去查 20 個上游專案的
授權頁——那既慢又不決定任何事——而是**讀 MPVKit 自己的建置腳本，看非 GPL 變體實際包含什麼**。
決定散布資格的是「有沒有 GPL-only 或 nonfree 元件」，不是「lcms2 是不是 MIT」。

來源：`Sources/BuildScripts/XCFrameworkBuild/main.swift`（tag 1.0.0 / main），存取日 2026-09-21。

| 檢查項 | 結果 | 出處 |
|---|---|---|
| mpv 是否 LGPL 模式 | **是**，`-Dgpl=false`（`enableGPL` 為否時） | 第 400–404 行 |
| FFmpeg 是否 GPL | **否**，`--enable-gpl` 只在 `enableGPL` 時加 | 第 578–580 行 |
| FFmpeg 是否 nonfree | **否**，PR #78 已移除（1.0.0 起生效） | PR #78 diff |
| `libsmbclient`（GPLv3） | **只在 GPL 變體**，四處皆以 `enableGPL` 包住 | 第 377／475／485／506 行 |
| `rubberband`（GPLv2+） | **完全不存在**，`-Drubberband=disabled` | 第 398 行 |
| `libdvdread` / `libdvdnav`（GPLv2+） | **完全不存在**，不在 Library 列舉內 | 第 47 行 |
| `libaacs` / `libbdplus` | **完全不存在** | 全檔搜尋無命中 |
| `libbluray` | 有，LGPLv2.1，且未帶解密附加元件 | 第 47／405–409 行 |
| `--enable-version3` | **有** → 這份 LGPL 是 **v3** | 第 653 行 |

**結論：9A 的 gate 1 與 gate 3 關閉。** 非 GPL 變體裡沒有任何 GPL-only 或 nonfree 元件；
聚合授權是 **LGPLv3**（由 FFmpeg 的 `--enable-version3` 與 gmp／nettle 帶動），與本 repo 的
GPLv3 相容。

**未逐一向上游核對的**：`lcms2`、`libdovi`、`MoltenVK`、`libshaderc`、`libuchardet`、`libuavs3d`、
`libunibreak`、`libharfbuzz`、`libfribidi`、`libfreetype`、`gnutls`／`nettle`／`gmp` 各自的授權原文。
它們都不是 GPL-only，不改變散布結論，但**打包出貨前要逐一抄 notice**，列為 gate。

## 本輪查到的一件事，會影響誰都不該誤讀

**SPM 會為 manifest 裡宣告的「每一個」`binaryTarget` 下載產物，不是只下載你選的那個 product 需要的。**

證據：只依賴 `MPVKit`（LGPL）product 之後，
`DerivedData/…/SourcePackages/artifacts/mpvkit/` 底下出現 **40 個目錄**，其中包含
`Libmpv-GPL`、`Libavcodec-GPL`、`Libavcodec-GPL`…以及 `Libsmbclient`。

**這不改變散布結論**——決定授權的是連進 App 二進位的東西，不是躺在 DerivedData 裡的東西，
而開發機上的快取不是散布。但它推翻一句很容易脫口而出的話：「我們用 LGPL 變體，所以機器上沒有
GPL 程式碼」。那句話是錯的。真正要守住的是**連結的是 `MPVKit` 而不是 `MPVKit-GPL`**，
這件事寫在 `project.pbxproj` 的 `productName` 上，是驗收項 L2。

## Ponytail pre-review（實作前，AGENT_HANDOFF 強制）

① **需要存在嗎** — 使用者指定，且有實際缺口：AVPlayer 放不了 MKV 與多數非 H.264/HEVC 編碼；
而外部播放器**拿不到 request headers**（IOS-POC-5P 記錄的既有限制，URL scheme 沒有那個介面）。
所以「丟給外部播放器」不是等價替代。

② **已有的先用** — `PlaybackSession`、`PlaybackTarget`、`WatchHistory`、畫質選單、`PlayerView`
全部沿用。**`PlayerRouter` 這一刀不做**：在只有一個真引擎、另一個還沒存在的時候做路由器，
就是「一個實作的介面」，正是 ponytail 第一條要擋的東西。等 MPVEngine 真的能播，路由器才有兩端
可路由。這是對使用者所述架構的**延後，不是否決**——順序改變，終點不變。

③ **原生平台優先** — AVPlayer 仍是預設核心，MPV 只補它做不到的。沒有取代關係。

⑤ **現成相依優先** — 用 SPM 的 `binaryTarget`，不自己刻下載與校驗。
**因此也不做 9A plan C 說的 `third_party/mpv-ios-lock.json` + fetch script**：
`Package.resolved` 已經釘住 version 與 revision，SPM 自己驗 SHA-256，再手寫一份 lock 只會漂移。
**9A 在這點上過度規劃了，這裡縮小。** lock 表達不了的只有「授權與 configure」，那個用 notice 檔補。

⑦ **最小可行** — 4 處 `project.pbxproj` 修改 + 一支 `MPVBoot.swift` + launch 一行 log。

刻意不做：`PlayerRouter`、`MPVEngine`、算繪、Metal/MoltenVK 調校、`third_party` lock 與 fetch
script、release 輪廓的 notice 打包。

## 這一刀做了什麼

| 檔案 | 改動 |
|---|---|
| `ios/WebHTVApp/WebHTVApp.xcodeproj/project.pbxproj` | 加 `XCRemoteSwiftPackageReference` → `https://github.com/mpvkit/MPVKit.git`，**`kind = exactVersion; version = 1.0.0`**；product dependency **`MPVKit`**（非 GPL 變體） |
| `…/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` | 新增，釘 `1.0.0` / revision `288527dffbc6d3e63cce147fc7b520c64a791603` |
| `ios/WebHTVApp/Sources/MPVBoot.swift` | 新增。`mpv_create → mpv_initialize → mpv-version`，含**負向對照** |
| `ios/WebHTVApp/Sources/WebHTVApp.swift` | DEBUG launch 加一行 `[mpv] boot …` |

**釘 `exactVersion` 而不是 `from:`**：9A 的硬性規則是「≥1.0.0」，但 1.0.0 之前每一版的「LGPL」
FFmpeg 都帶 `--enable-nonfree`（不可散布）。對一個二進位相依，精確釘版本才能讓 `Package.resolved`
與授權結論一一對應——這和 `python-ios-lock.json` 釘 `3.13-b15` 是同一個理由。

`MPVBoot` 的負向對照沿用 IOS-POC-7F 學到的教訓：沒有對照的話，一個什麼都沒做的 client library
看起來會跟成功一模一樣。所以除了讀出 `mpv-version`，還要求一個不存在的屬性**必須**回錯。

`ponytail:` Python 只進 App target，MPV 同理——MPVKit 的 xcframework 是 iOS-only，而
`WebHTVCore` 必須在 macOS 上跑那 151 條測試。core 一行都不連結 libmpv。

`ponytail:` boot 檢查掛在 DEBUG 啟動路徑，與 `PythonBoot` 同形。正確的家是 iOS Simulator test
target；等 MPVEngine 需要更完整的端到端驅動時一起搬。

## 環境：兩個實際踩到的坑（都不是猜的）

1. **`xcodebuild -resolvePackageDependencies` 在本 session 的沙箱裡會靜默卡住。** 下載毫無進度、
   零 ESTABLISHED 連線，但同一個沙箱裡 `curl` 抓同一個 release asset 有 1.4 MB/s。兩次嘗試皆然。
   在沙箱外執行才會印出真正的錯誤並開始下載。
2. **中途 kill 會留下半成品 zip，而 SPM 拒絕覆寫**，錯誤是
   `already exists in file system`。要清掉 `SourcePackages/artifacts/mpvkit/` 才能重跑。
   **而且若只清產物、不清 `Package.resolved`，`-resolvePackageDependencies` 會回報成功卻什麼都
   不下載**，下一步 build 才會以 `There is no XCFramework found at …` 失敗。兩個都要清。

## 結果

```
[mpv] boot running(version: "mpv v0.41.0-dirty", apiVersion: "2.5")
[python] boot running(version: "3.13.15")
```

iPhone 17 Pro 模擬器，App 自己的啟動路徑。**libmpv 在這個 App 內連結成功並初始化完成**，
`mpv-version` 讀得出來，不存在的屬性被正確回報為錯誤（負向對照成立）。Python 同時照常啟動，
**沒有退步**。

### 「-dirty」是個要記下來的 provenance 事實

版本字串是 `mpv v0.41.0-dirty`，不是 `v0.41.0`。**MPVKit 出貨的 libmpv 是打過 patch 的工作樹**
（README 提到 Metal 支援來自尚未合併的 #7857）。這不違反授權——MPVKit 的建置腳本與 patch 都公開——
但代表**不能宣稱「就是上游 v0.41.0」**。要對照的是 MPVKit 的 patch 集，不是 mpv 的 tag。
列為 gate：打包出貨前要把實際套用的 patch 列出來。

### 靜態連結：9A 的結論由實測確立，不只是讀 configure

bundle 裡 22 個 `Lib*.framework` 看起來像動態庫，`file` 也回報
`Mach-O 64-bit dynamically linked shared library`——**但那是誤導**。
`Libmpv.framework/Libmpv` 與 `Libavcodec.framework/Libavcodec` 都恰好 **33,184 bytes**，是 stub。
符號表才是證據：

| 查詢 | 結果 |
|---|---|
| `nm -gU WebHTVApp.debug.dylib \| grep _mpv_create` | **1（defined）** |
| `nm -gu WebHTVApp.debug.dylib \| grep _mpv_create` | 0（沒有 undefined） |
| `nm -gU Libmpv.framework/Libmpv \| grep _mpv_create` | **0** |
| `nm -gU WebHTVApp.debug.dylib \| grep _avcodec_open2` | **1（defined）** |

**mpv 與 FFmpeg 的程式碼是靜態連進 App 自己的二進位的。** 所以 9A 記的 LGPL 重新連結義務
**成立且不變**，而且證據等級從「讀 configure 參數」升級為「檢查出貨二進位」。
FFmpeg 官方合規清單裡「用動態連結」那條，**在這個組合下確定走不通**。

### 體積

Debug／模擬器組建，尚未瘦身，**不是出貨數字**：

| 項目 | 大小 |
|---|---|
| `WebHTVApp.app` 總計 | **80 MB** |
| `WebHTVApp.debug.dylib`（含靜態連入的 mpv/FFmpeg） | 39.9 MB |
| `Frameworks/`（96 個，絕大多數是 Python 的 `lib-dynload`） | 26.1 MB |
| `python/`（標準庫） | 10.8 MB |
| `python-packages/`（vendored wheels） | 1.6 MB |
| 22 個 MPV stub framework | 每個 33 KB |

**要留意的是 Debug dylib 那 39.9 MB**：MPV 進來之前它遠小於此。Release、strip、dead-strip 與
App Thinning 之後的真實增量**本輪沒有量**，列為 gate——`webhtv-player-gates.md` 明言不得把
建置成功當成體積或行為的結論。

### 驗證

| 檢查 | 結果 |
|---|---|
| `swift test --package-path ios` | **151 條全過**（core 完全不連結 libmpv，macOS 上照常） |
| `xcodebuild … -destination 'platform=iOS Simulator,id=7B4E9557-…' -configuration Debug build` | **BUILD SUCCEEDED** |
| 模擬器啟動 | `[mpv] boot running(version: "mpv v0.41.0-dirty", apiVersion: "2.5")` |
| 負向對照 | 通過（不存在的屬性回錯，沒有被回答） |
| 連結的是非 GPL 變體（驗收項 L2） | `project.pbxproj` 的 `productName = MPVKit`，不是 `MPVKit-GPL` |

## Ponytail（final diff）

功能性 diff 是：4 處 `project.pbxproj` 相依接線 + 2 處 `project.pbxproj` 檔案登錄 +
一支 68 行的 `MPVBoot.swift` + launch 一行。**沒有新抽象、沒有 `PlayerRouter`、沒有
`MPVEngine`、沒有第二份 lock、沒有 fetch script。** 9A 原本規劃的
`third_party/mpv-ios-lock.json` 與取回腳本**被刪掉了**，因為 `Package.resolved` 已經釘住
version 與 revision 且 SPM 自驗 SHA-256——那份手寫 lock 只會與它漂移。

唯一「多做」的是 `MPVBoot` 裡的負向對照，六行。它不是裝飾：沒有它，一個什麼都沒做的
client library 看起來與成功完全相同，這是 IOS-POC-7F 已經付過學費的教訓。

## 未解 gate

1. **Release 體積增量未量。** Debug dylib 39.9 MB 不是出貨數字。
2. **MPVKit 對 mpv 套的 patch 清單未列。** 版本字串是 `-dirty`，出貨前要列出來。
3. **`lcms2`、`libdovi`、`MoltenVK`、`libshaderc`、`libuchardet`、`libuavs3d`、`libunibreak`、
   `libharfbuzz`、`libfribidi`、`libfreetype`、`gnutls`／`nettle`／`gmp` 的授權原文未逐一抄錄**
   （已確認皆非 GPL-only，不影響散布結論，但 notice 要補）。
4. **真機完全沒跑過。** 與 Python 一樣，全部是模擬器證據。
5. **還沒播任何東西。** 本輪只證明直譯器層級的初始化，沒有算繪、沒有 Metal/MoltenVK 實測、
   沒有接 `PlaybackSession`。

## 下一步（唯一）

**等使用者決定是否繼續 9B 的第二個單元：讓 libmpv 真的把一支串流畫到畫面上**
（`MPVEngine` + Metal layer），成功後才談 `PlayerRouter` 與 `PlaybackSession` 整合。
在那之前不動 `PlaybackSession`、不動 `SourceClient`。

---

# IOS-POC-9C — 算繪：走到哪裡，以及為什麼停在這裡

日期 2026-09-21，基線 HEAD `401b3076`。**結論先講：畫面沒有出來，而且原因已經收斂到一個必須在
真機上回答的問題。** 這一節記錄每一步量到什麼，免得下一個人重跑一遍同樣的五輪。

## 做了什麼

`MPVProbeView`（Debug-only，設定頁「開發者」區第二列），照 **MPVKit 自己的 iOS demo** 接線，
不自行發明路徑：`CAMetalLayer` 當 `wid`、`vo=gpu-next`、`gpu-api=vulkan`、`gpu-context=moltenvk`。
**沒有碰 `PlaybackSession`、`SourceClient`、播放器選單，也還沒有 `PlayerRouter`。**

## 一個真的缺陷：wakeup callback 不能碰 MainActor 物件

第一次執行直接 **crash**，`EXC_BREAKPOINT`：

```
_dispatch_assert_queue_fail
dispatch_assert_queue
_swift_task_checkIsolatedSwift
swift_task_isCurrentExecutorWithFlagsImpl
closure #1 in MPVProbeController.start()   ← mpv 的 core_thread
```

`mpv_set_wakeup_callback` 在 mpv 自己的 core thread 上呼叫回來，而我把它接到 `UIViewController`
上——`UIViewController` 是 `@MainActor`，於是隔離檢查在非主佇列上觸發斷言。

**把方法標成 `nonisolated` 不夠，隔離檢查是針對實例而不是方法。** 正確的修法是讓 mpv 回呼的對象
根本不是 actor-isolated：把 mpv handle 與事件泵搬進 `MPVProbeCore`（`@unchecked Sendable`），
view controller 只留 layer。這個結構也正是未來 `MPVEngine` 該有的形狀。

## 模擬器上量到的三件事

| # | 量到什麼 | 判讀 |
|---|---|---|
| 1 | `Spent 1197.565 ms creating vulkan device (slow!)` | **MoltenVK/Vulkan 在 iOS 模擬器上建得起來**，只是很慢。這是開工前最大的未知，答案是肯定的 |
| 2 | `FILE_LOADED` | HLS demux 成功，網路與解析鏈通 |
| 3 | `videotoolbox_vld: hwaccel initialisation returned error` 與 `Device does not support the VK_KHR_video_decode_queue extension!` | **模擬器沒有任何硬體解碼**，而且 `hwdec=auto-safe` **不會自動回退**——它卡在 `h264: no frame!` |

把 `hwdec` 改成 `no`（軟解）之後，**h264 的錯誤全部消失**，`FILE_LOADED` 乾淨。所以解碼這一層沒問題。

因此探針把 `hwdec` 做成畫面上的開關，預設軟解：真機可以翻回 `auto-safe` 驗硬解，模擬器不必每次改碼。

## 沒有成立的事，明講

**`VIDEO_RECONFIG` 在任何一種組合下都沒有觸發，畫面始終是黑的。** 沒有任何一幀到過那個 layer。

試過而且都不是原因的：`hwdec=videotoolbox`／`auto-safe`／`no` 三種解碼設定；layer 幾何確認為
`402x874 scale 3.0`（不是零尺寸）。

**不要把「Vulkan device 建起來了」讀成「算繪成立」。** 建立 device 與送出一幀是兩件事。

## 為什麼停在這裡，而不是繼續試

`.codex/skills/upstream-integration-governor/references/webhtv-player-gates.md` §4 寫得很直接：
「Compilation or marker-string checks alone cannot validate Surface, fence, decoder, audio,
lifecycle, or vendor behavior.」而 `AGENTS.md` §3 要求同一個假設失敗兩次就換路徑。

模擬器的 MoltenVK 是軟體路徑，本來就是驗證算繪最差的環境。**剩下的問題只有真機能回答**，
而真機驗證是使用者在 2026-09-21 明確延後的事項。所以這是一個需要你決定的關卡，不是一個我該繼續
猜的技術問題。

iPhone 18 Pro（`00008160-00124C8200214036`）目前 `devicectl` 回報 `available (paired)`，
硬體是通的。

## 驗證

| 檢查 | 結果 |
|---|---|
| `swift test --package-path ios` | **151 條全過**（core 仍不連結 libmpv） |
| `xcodebuild … Debug build`（模擬器） | **BUILD SUCCEEDED** |
| 模擬器：mpv 初始化 | 成立 |
| 模擬器：Vulkan device | 成立（1197 ms） |
| 模擬器：HLS `FILE_LOADED` | 成立 |
| 模擬器：軟解無錯誤 | 成立 |
| **模擬器：畫面出現** | **未成立**，`VIDEO_RECONFIG` 從未觸發 |
| crash 回歸 | 已修，同一操作不再 crash |

## Ponytail（final diff）

新增一支 Debug-only 檔案與設定頁一列 `NavigationLink`，其餘都是 pbxproj 登錄。
**沒有動任何既有播放路徑**：AVPlayer、`PlaybackSession`、`SourceClient`、播放器選單一行未改。

拿掉了 MPVKit demo 裡的 `wantsExtendedDynamicRangeContent` override——它只為 `target-colorspace-hint`
存在，而這一刀沒開 HDR，留著就是死碼。保留了 `drawableSize` 的 override，因為那是 MoltenVK 的實際
bug（上游 PR 13651），不是偏好。

探針本身刻意報出 `w`/`h`/`codec`/`vo`/`hwdec`，理由與 `MPVBoot` 的負向對照相同：**黑畫面與壞掉的
算繪器在截圖上完全一樣**，只有數字能分辨。事後證明這個決定是對的——正是這些數字把問題從
「不知道為什麼黑」收斂到「VO 從未 reconfig」。

## 下一步（唯一，需要你決定）

**在 iPhone 18 Pro 上跑這個探針。** 那是唯一能回答「gpu-next + MoltenVK 在真機上會不會出畫面」
的方法，而真機驗證被你延後過，所以我不自行啟動。裝置簽章照既有做法走命令列
（`DEVELOPMENT_TEAM=764SVXY2B7 CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates`）。

若真機也不出畫面，退路是 `vo=gpu` + `gpu-api=opengl`（iOS 上 OpenGL ES 已棄用但仍在），
或 MPVKit demo 裡的另一條 OpenGL 路徑——**兩者都還沒試，不要當成已排除**。

---

# IOS-POC-9D — OpenGL 退路：走得更遠，但同樣沒有畫面

日期 2026-09-21，基線 HEAD `eab730fb`。使用者在 9C 的兩個選項中選了「先試 OpenGL 退路」。

**結論：兩條算繪路徑在模擬器上都不出畫面，而且它們卡在不同的地方。** 這個差異本身是有用的資訊。

## 做法

探針加一個 **Metal / OpenGL 分段選擇器**，而不是換掉 Metal。理由很簡單：
**「A 不行、B 可以」只有在同一個 build 裡驅動過兩者時才說得出口。**

OpenGL 走的是 mpv 的 **render API**，與 Metal 那條相反：

| | Metal（9C） | OpenGL（9D） |
|---|---|---|
| VO | `vo=gpu-next`、`gpu-api=vulkan`、`gpu-context=moltenvk` | **`vo=libmpv`** |
| 表面歸屬 | `wid` 把 `CAMetalLayer` 交給 mpv，**mpv 驅動它** | **宿主擁有 framebuffer**，mpv 畫進去 |
| 接法 | 設好 `wid` 再 `mpv_initialize` | `mpv_initialize` 後 `mpv_render_context_create` |
| 觸發繪製 | mpv 自己 | `set_update_callback` → `GLKView.display()` → `mpv_render_context_render` |

同樣照 MPVKit 的 iOS demo，不自行發明。**demo 自己就寫 `hwdec` 在模擬器要設 `no`**
（`isSimulator ? "no" : "videotoolbox"`），獨立佐證了 9C 量到的「模擬器沒有硬體解碼」。

## 兩條路徑卡在不同的地方

| 階段 | Metal | OpenGL |
|---|---|---|
| `mpv_initialize` | ✔ | ✔ |
| 算繪 context | ✔ Vulkan device（1197 ms, `slow!`） | ✔ `mpv_render_context_create` 成功 |
| mpv 對環境的判斷 | — | `Suspected software renderer or indirect context.`／`High bit depth FBOs unsupported. Enabling dumb mode.`／`Most extended features will be disabled.` |
| `FILE_LOADED` | ✔ | **✘ 從未觸發** |
| `VIDEO_RECONFIG` | ✘ | ✘ |
| 畫面 | 黑 | 黑 |
| 結束方式 | 停在原地 | **App 在約三分鐘後自行結束**（`DiagnosticReports` 沒有新的 `.ips`，所以**不是 crash**；也查不到 jetsam 記錄） |

**OpenGL 在算繪器建置上走得比 Metal 遠**——它成功建出 render context，而且 mpv 明確報出它偵測到
軟體算繪器並自動降級。但它連 demux 都沒走完。

## 判讀，以及不能過度延伸的地方

mpv 那句 `Suspected software renderer or indirect context` 是**模擬器自己承認它不是真 GPU**。
兩條路徑、兩種完全不同的表面模型、兩種不同的失敗點，指向同一件事：
**iOS 模擬器的圖形堆疊跑不動 mpv 的算繪器。**

**但這是判讀，不是證明。** 不能排除仍有第三個我沒找到的自身缺陷。能確定的只有：
在這台機器的 iOS 26.3 模擬器上，兩條官方路徑都沒有把任何一幀送上螢幕。

## 驗證

| 檢查 | 結果 |
|---|---|
| `swift test --package-path ios` | **151 條全過** |
| `xcodebuild … Debug build` | **BUILD SUCCEEDED** |
| Metal 路徑 | 可初始化、Vulkan device 成立、`FILE_LOADED`、**無畫面** |
| OpenGL 路徑 | 可初始化、render context 成立、**未到 `FILE_LOADED`**、**無畫面**、App 自行結束 |
| 既有播放路徑 | **一行未改**，AVPlayer／`PlaybackSession`／`SourceClient`／播放器選單完全不受影響 |

## Ponytail（final diff）

新增的全部在 `MPVProbeView.swift` 一個檔案裡：一個分段選擇器、一個 `MPVGLSurface`／`MPVGLController`，
以及 `MPVProbeCore` 多出的兩個進入點（`startRenderAPI`、`adopt(renderContext:)`）。
**沒有新檔案、沒有新抽象、沒有動 pbxproj 以外的既有程式碼。**

`adopt(renderContext:)` 值得說明為何存在：render context 必須在 `mpv_terminate_destroy` **之前**
釋放，而兩個各自有 `deinit` 的物件無法保證順序。所以 context 交給 `MPVProbeCore` 持有，
一個 `deinit` 內按正確順序釋放兩者。這不是抽象，是 use-after-free 的修法。

GL 的 update callback 同樣套用 9C 學到的教訓：**在 C 回呼裡不轉型、不碰 UIKit**，
先 `DispatchQueue.main.async` 再把 `Unmanaged` 還原成 `GLKView`。

## 下一步（唯一）

**真機。** 兩條路徑都試過了，模擬器這條線已經用盡。iPhone 18 Pro
（`00008160-00124C8200214036`）目前 `available (paired)`，探針有 Metal／OpenGL 與軟／硬解四種組合
可以一次問完。真機驗證是使用者延後過的項目，所以仍需要你的指令。

---

# IOS-POC-9E — 複測，以及它推翻的一件事

日期 2026-09-21，基線 HEAD `f67887f3`。使用者要求重新測試一次。**做對了**——複測推翻了 9D 寫下的
一個結論，並且量出兩件關於 MPVKit 的能力事實。

## 被推翻的：「Metal 會到 `FILE_LOADED`」不是穩定性質

9D 把「Metal 到得了 `FILE_LOADED`、OpenGL 到不了」記成兩條路徑的差異。**複測時 Metal 也到不了**，
同一個 build、同一個串流、連跑兩次各等 25 秒與 70 秒，都停在
`log: mime type is not rfc8216 compliant` 就不動了。

**所以那是跨次不穩定，不是路徑差異。** 9D 那張對照表的 `FILE_LOADED` 列要這樣讀：
Metal 曾經到過一次，OpenGL 從未到過，而 Metal 並非每次都到。這正是本文件早就寫過的紀律——
「provider state moves by the hour，單次結果是樣本不是判決」——只是這次輪到我自己被它抓到。

## 量出來的兩件 MPVKit 能力事實

想把算繪器和網路分開，就要一個不碰網路的來源。試了兩個，兩個都被 build 的功能集擋掉：

| 來源 | 結果 | 意義 |
|---|---|---|
| `av://lavfi:testsrc=size=640x360:rate=30` | `Unknown lavf format lavfi`、`Failed to recognize file format`、`END_FILE reason=4` | **MPVKit 的 FFmpeg 沒有編入 `lavfi` 輸入** |
| bundle 內的 `wallpaper_1.png` | `Failed to initialize a decoder for codec 'png'` | **沒有 PNG 解碼器**；但檔案被找到並正確辨識為 png，所以**本機讀檔與 demux 這一層是好的** |

兩者都不是缺陷，是這個 build 刻意精簡的結果。記下來是因為它們會影響之後怎麼設計測試，
也會影響「MPV 能放什麼」的期待——**它是個影片播放器的 build，不是萬用 FFmpeg**。

順帶修掉一個自己的設計失誤：探針原本把位址包成 `URL`，而 `URL(string:)` 直接拒絕 `av://lavfi:…`。
mpv 要的本來就是字串，`URL` 在這條路上只會擋事，已改成全程 `String`——**少一個型別、少一次轉換、
少一類拒絕**。

## 現在的狀態

三種來源、兩種算繪器、兩種解碼設定，**沒有任何一次把一幀送上螢幕**。
新的可疑點是**網路**而不是算繪：`mime type` 警告立刻出現代表 master playlist 抓到了，
但之後的 media playlist 與 segment 有沒有到，目前沒有證據，而 `FILE_LOADED` 正是要等第一段媒體。

## 驗證

| 檢查 | 結果 |
|---|---|
| `swift test --package-path ios` | **151 條全過** |
| `xcodebuild … Debug build` | **BUILD SUCCEEDED** |
| Metal + HLS，複測兩次 | **未到 `FILE_LOADED`**，無畫面 |
| Metal + `lavfi` | 輸入格式不存在 |
| Metal + 本機 PNG | 解碼器不存在（但檔案讀得到） |
| 既有播放路徑 | 一行未改 |

## 下一步（兩條，都需要你決定）

1. **真機。** 仍然是決定性的一步，而且現在多了一個理由：模擬器的網路堆疊也進了嫌疑名單。
2. **若要繼續留在模擬器**，唯一還沒試的便宜隔離是**放一個本機 H.264 MP4 進 App 容器**——
   那會一次排除網路、HLS 與這個 build 缺失的解碼器。**這台 Mac 上沒有 `ffmpeg`**，所以要先產生
   樣本（用 AVFoundation 寫一支小工具，或你手邊直接給一個檔案）。

---

# IOS-POC-9F — 真機安裝，與兩個「第一次」

日期 2026-09-21。使用者指示「先安裝在我的手機」。

裝置：iPhone 18 Pro `00008160-00124C8200214036`，`connected`。
簽章照既有做法走命令列，**專案檔仍然不含任何 `CODE_SIGN` 或 `DEVELOPMENT_TEAM`**：

```
xcodebuild -destination 'platform=iOS,id=00008160-00124C8200214036' -configuration Debug \
  DEVELOPMENT_TEAM=764SVXY2B7 CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates build
xcrun devicectl device install app --device 00008160-00124C8200214036 …/WebHTVApp.app
```

`** BUILD SUCCEEDED **`，22 個 MPV framework 一併簽入，安裝成功。
**裝置版 `.app` 為 78 MB**（Debug，未瘦身；模擬器版是 80 MB）。
描述檔是免費個人帳號，**七天後到期**，屆時要重裝。

## 啟動時取得的兩件事，都是這個專案的第一次

```
[mpv] boot running(version: "mpv v0.41.0-dirty", apiVersion: "2.5")
[python] boot running(version: "3.13.15")
[python] selfcheck 13/13 methods OK, errors propagate
[python] live OK [🏆｜銅牌｜高清] init → home(5 classes) → category(21 items)
                               → detail → search(1 hits) → player → probe(media)
```

1. **libmpv 第一次在真機上初始化。** 靜態連結的 mpv/FFmpeg 在 arm64 裝置上載入並回報版本。
2. **CPython 第一次在真機上執行——而且是走完整條鏈。** 本文件與
   `docs/IOS-POC-7A-python-runtime.md` 從 IOS-POC-7E 起一直寫著「Nothing Python has ever run on a
   device」「全部是模擬器證據」。**那句話從今天起不成立**：`皮皮虾.py` 在 iPhone 18 Pro 上
   從同源下載腳本、在內建直譯器執行、經 `base` shim 與 dict→JSON 橋、走 `SpiderSession` 契約、
   最後由 `MediaProbe` 取得**真實媒體位元組**。13 個 ABI 方法的 selfcheck 也通過，
   含刻意的負向對照（`ValueError: boom` 如預期傳回）。

**這不是本輪要找的東西**——要找的是 MPV 算繪——但它是 Python 那條線最大的未驗證缺口，順手就關掉了。

## MPV 算繪在真機上的結果：**尚未取得**

啟動只證明 libmpv 初始化。**算繪要人在螢幕上操作**，而實體裝置無法由本工作階段自動驅動
（模擬器工具只能驅動模擬器）。所以這一項仍然是空的，要使用者自己點。

操作路徑：**設定 → 開發者 → MPV 算繪驗證**，然後四種組合各試一次：

| # | 算繪 | 硬體解碼 | 這一格要回答什麼 |
|---|---|---|---|
| 1 | Metal (gpu-next) | 關 | 真機的 MoltenVK 會不會出畫面 |
| 2 | Metal (gpu-next) | 開 | VideoToolbox 在真機存在，`auto-safe` 是否正常 |
| 3 | OpenGL (libmpv) | 關 | render API 那條路 |
| 4 | OpenGL (libmpv) | 開 | 同上加硬解 |

畫面下方的文字區會列出 `FILE_LOADED`／`VIDEO_RECONFIG` 與 `w`／`h`／`codec`／`vo`／`hwdec`。
**`VIDEO_RECONFIG` 出現且有畫面才算成立**；只有 `FILE_LOADED` 不算。
「本機圖片」在這個 build 上必定失敗（沒有 PNG 解碼器），不必試。

---

# 真機算繪結果（2026-09-21，使用者回報）

**Metal (gpu-next) + 軟體解碼，在 iPhone 18 Pro 上：`FILE_LOADED` 到了，`VIDEO_RECONFIG` 沒有，畫面仍然是黑的。**

## 這推翻了 9C／9D 的判讀

9C 與 9D 都把「模擬器的 MoltenVK 是軟體路徑」當成最可能的原因，9E 又把嫌疑轉向網路。
**真機這一格把兩個都排除掉了**：真機有真 GPU，也有正常網路，而且 `FILE_LOADED` 證明媒體確實到手了
——demux 成功，資料有進來。**卡住的就是 `FILE_LOADED` 之後、`VIDEO_RECONFIG` 之前那一段**，
也就是解碼輸出接上 video output 的地方。

先前三輪寫的「模擬器環境不可靠，要真機才能判斷」是對的方向，但**結論不是「真機就會動」**。
現在證據更集中，不是更分散：

| 假設 | 狀態 |
|---|---|
| 模擬器的軟體 MoltenVK 擋住 | **排除**，真機一樣黑 |
| 網路／HLS 拿不到媒體 | **排除**，真機 `FILE_LOADED` 成立 |
| 硬體解碼不存在 | 不適用，這一格是軟解 |
| **`wid` + `CAMetalLayer` 的接線本身** | **最可疑，尚未驗證** |

## 還沒問的三格

使用者目前只回報了 Metal＋軟解。剩下三格仍有價值，尤其 **OpenGL**：它走的是完全不同的表面模型
（宿主擁有 framebuffer），如果 OpenGL 在真機出得了畫面，就直接指向 `wid` 那條路的接線問題。

## 下一步

本輪暫停 MPV，優先處理使用者提出的五項 UI／資料問題（`docs/IOS-POC-10-plan-ux-and-sources.md`）。
恢復時的第一個動作是**真機跑 OpenGL 那一格**，那是目前最能分辨病因的一次點擊。

## 狀態複核（2026-09-22，IOS-POC-11B，純文件校正）

自 2026-09-21 以來 MPV **沒有任何程式碼變動**，本輪也沒有跑算繪。這一節只是把狀態釘住，
因為 `docs/AGENT_HANDOFF.md` 當時仍把 MPV 列在「Not implemented」裡，
與本文件記錄的「libmpv 已在真機初始化」互相矛盾——那個矛盾已經修掉。

未關閉的技術關卡，依可鑑別性排序：

| # | 關卡 | 狀態 |
|---|---|---|
| 1 | 真機 **OpenGL**（軟解） | **未試**，最能分辨病因：宿主擁有 framebuffer，與 `wid` 那條路完全不同 |
| 2 | `wid` + `CAMetalLayer` 的接線 | **最可疑，未驗證** |
| 3 | 真機 Metal＋硬解（VideoToolbox） | 未試 |
| 4 | 真機 OpenGL＋硬解 | 未試 |

已排除：模擬器的軟體 MoltenVK（真機一樣黑）、網路取不到媒體（真機 `FILE_LOADED` 成立）。

---

# IOS-POC-9G — 黑畫面的根因：探針自己違反了 libmpv 的 callback 契約（2026-09-23）

屬於 IOS-POC-17（雙內部播放核心）的第一個 MPV 單元。基線 HEAD `ecb0c4d0`。
**先講結論：`FILE_LOADED → VIDEO_RECONFIG` 的卡點是我們的程式，不是 MoltenVK、不是網路、不是模擬器。
修掉之後，模擬器上 Metal 與 OpenGL 兩條路徑都出了第一格畫面。真機仍未驗證。**

## 對照 MPVKit 1.0.0 demo，找到的兩個差異

來源：MPVKit tag `1.0.0` = `288527dffbc6d3e63cce147fc7b520c64a791603` 的
`Demo/Demo-iOS/Demo-iOS/Player/{Metal/MPVMetalViewController.swift, OpenGL/MPVViewController.swift}`；
`Libmpv.xcframework` 內的 `client.h`／`render.h`；mpv `v0.41.0` 的 `player/client.c`、
`misc/dispatch.c`、`osdep/threads-posix.h`（raw GitHub，2026-09-23 讀原文）。

1. **Event 泵在 wakeup callback 裡面跑。** 探針的 callback 直接呼叫 `drainEvents()`——也就是
   `mpv_wait_event`，並在 `FILE_LOADED` 時呼叫 8 次 `mpv_get_property_string`。
   `client.h` 明文：「You are not allowed to call any client API functions inside of the callback」。
   `client.c` 顯示 callback 是在 libmpv 持有 `ctx->wakeup_lock`（經 `send_event` 也持有 `ctx->lock`）
   時被呼叫；`mpv_get_property*` 走 `run_locked → mp_dispatch_lock`，而 `mp_dispatch_lock` 會等
   playloop 執行緒停進 `mp_dispatch_queue_process`。`FILE_LOADED` 由 playloop 廣播——等於 playloop 在等自己。
   **demo 的 callback 只做 `queue.async { … mpv_wait_event … }`。**
2. **OpenGL 的 render update callback 寫成 `viewDidLoad` 裡的 closure。** 它繼承了 view controller 的
   main-actor 隔離，mpv 在 `vo` 執行緒呼叫它時 Swift 6 的 executor 檢查直接 trap
   （`WebHTVApp-2026-09-23-170820.ips`：thread `vo`，`_dispatch_assert_queue_fail` ←
   `closure #4 in MPVGLController.viewDidLoad()` ← `draw_frame` ← `vo_thread`）。
   **以前沒爆，只是因為差異 1 讓播放永遠走不到畫第一格。** demo 用的是 file-scope 的 `mpvGLUpdate`。

## 修正（`ios/WebHTVApp/Sources/MPVProbeView.swift`，Debug-only）

- `installWakeup`：callback 只 `queue.async { [weak core] in core?.drainEvents() }`；兩條路徑共用。
- `deinit` 先 `mpv_set_wakeup_callback(mpv, nil, nil)`（它取同一把 `wakeup_lock`，返回後不會有 callback 在跑）。
- GL update callback 與 `get_proc_address` 改成 file-scope 函式 `requestGLDisplay`／`openGLProcAddress`。
- 回報多一個 `PLAYBACK_RESTART` 事件與 `END_FILE` 的 `error` 碼；「範例」選單三個 Apple 測試串流
  （fMP4 master 多軌／TS 單一 playlist／TS 單一片段），讓真機測試不用在手機上打網址。

## 模擬器結果（iPhone 17 Pro，iOS 26.3，`7B4E9557-…`；**模擬器證據，不是真機**）

安裝前比對過：`simctl get_app_container` 的 `WebHTVApp.debug.dylib` 與 DerivedData 產物 SHA-256 相同。
`hwdec=no`（模擬器沒有 VideoToolbox）。stdout 由 `simctl launch --console-pty` 擷取。

| 路徑 | 串流 | 事件序列 | 畫面 |
|---|---|---|---|
| Metal（`gpu-next`/Vulkan/MoltenVK） | TS 單一片段 | `FILE_LOADED → VIDEO_RECONFIG → PLAYBACK_RESTART`，log `first video frame after restart shown`、`playback restart complete … video=playing`，10 秒播完 `END_FILE reason=0 error=0` | —（太短未截圖） |
| Metal | TS 單一 playlist | 同上 | **有畫面**：bipbop 4x3 測試圖，時間碼 00:00:08.14（截圖） |
| Metal | fMP4 master（1080p、多軌） | 約 20 秒後 `FILE_LOADED`（慢在開約 30 個 rendition），接著 `VIDEO_RECONFIG → PLAYBACK_RESTART`；`warn` 與 `v` 兩種 log 等級各一次都成立 | **有畫面**：1920×1080，含 WebVTT 字幕「Subtitles: Bop!」（截圖） |
| OpenGL（`vo=libmpv` render API） | TS 單一 playlist | 修正差異 2 **之前**：`FILE_LOADED` 後 App crash（上面那份 ips）。**之後**：`FILE_LOADED → VIDEO_RECONFIG → PLAYBACK_RESTART`，`first video frame after restart shown`；mpv 自報 `Suspected software renderer`、`dumb mode` | **有畫面**：時間碼 00:00:14.12（截圖），無新 crash report |

**被推翻的舊判讀**：9C/9D 的「模擬器的軟體 MoltenVK 擋住」、9E 的「網路嫌疑」、真機那一格的
「`wid` + `CAMetalLayer` 接線最可疑」——全部不是原因。`wid` 的傳法與 demo 等價（都是 layer 物件位址）。
9E 那次「停在 `mime type is not rfc8216 compliant`」可能就是 fMP4 master 開 rendition 要約 20 秒，
加上差異 1 的死鎖時機不定。

## 仍未解（真機）

- **真機一次都還沒跑修正後的版本。** 真機那一格（Metal＋軟解，`FILE_LOADED` 後無 `VIDEO_RECONFIG`）
  的症狀與差異 1 完全吻合，但**吻合不是證明**——要真機重跑才算數。
- 真機要跑需要一個含 Debug 探針的 build：SideStore 發的是 Release，探針是 `#if DEBUG`。
  （17E 起 `0.1.8 (9)` 以後的正式版可直接選 MPV 看 first frame；只有四格探針仍需 Debug build。）
  本輪使用者未授權 package／publish，也依既有決定不直接裝到手機，所以**本輪沒有真機證據**。
- 真機要問的四格：Metal／OpenGL × 軟解／硬解（`auto-safe` → VideoToolbox），各用「範例」的三個串流。

## MPV stop condition（IOS-POC-17 §五）是否觸發

**沒有觸發。** 模擬器上兩條算繪路徑都拿到了 first frame，阻斷點已從「黑畫面原因不明」縮小成
「真機尚未重跑」。VLCKit spike **不需要開**。
