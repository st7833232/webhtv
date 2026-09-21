# IOS-POC-9B — MPV 第二播放核心：技術可行性

- 狀態：**進行中**。使用者於 2026-09-21 指示「開始 IOS-POC-9B」。
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
