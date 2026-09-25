# IOS-POC-9A — iOS MPV 第二播放核心：授權與來源（license / provenance）審查

> **Superseded by dual internal-player decision, 2026-09-23** — for every mention of third-party players here (Infuse / Fileball / SenPlayer / VidHub, URL-scheme handoff, "external player"): they were removed from the product; WebHTV plays only with its own AVPlayer and MPV engines. See `docs/IOS-POC-17-dual-internal-player.md`. The rest of this record stands as written.

- 狀態：**評估限定（assessment-only）**。**未改任何 production 程式碼、lock、build script 或二進位。**
- 分支 `ios-poc`，基線 HEAD `7aa5f980`
- 日期：2026-09-21
- 授權依據：使用者於 2026-09-21 指示「開始 MPV feasibility 的 license/provenance review」。**這份指示只授權審查，不授權整合。**
- 依 `AGENTS.md` §7／§8 與 `.codex/skills/upstream-integration-governor/SKILL.md` 的 mandatory
  best-practice gate 執行。已載入 `references/webhtv-player-gates.md` 與
  `references/evidence-and-research.md`；未載入 `references/integration-workflow.md`，理由是本輪沒有
  實作階段。
- **這不是法律意見。** 最終判斷屬於著作權人與法律顧問，與 `docs/analysis/ios-app-store-readiness-research.md`
  對 GPLv3 的處理一致。

## 決策形狀的問題

> **WebHTV 的 iOS 個人側載輪廓，能不能合法嵌入並散布一份 mpv／FFmpeg 建置？若能，是哪一份、
> 它帶來哪些義務、以及這些義務有沒有被目前的 repo 狀態滿足？**

- 假說：可以，但只有在 (a) FFmpeg 不含 GPL／nonfree 元件、(b) 我們能提供讓使用者重新連結的材料時成立。
- 反假說：iOS 只能靜態連結，靜態連結違反 LGPL，所以整條路不通。
- 能區分兩者的證據：LGPL 對靜態連結的實際條文、候選 SDK 的實際 configure 參數、本 repo 的散布形態。

## 任務編號：為什麼不進 `P*` 家族

`SKILL.md` 要求在 `docs/upstream-player-dependency-merge-assessment-2026-08-20.md` 配置 ID，MPV 用
`P*`。**本輪刻意不那樣做，理由要留下來：**

- 那份索引的 recovery anchor 寫明「當前分支：`feature-menu`」，`P0`–`P9` 全部是 **Android** 的
  mpv／FFmpeg／libplacebo native 建置鏈，且 ID 不可重編。
- iOS 是另一條產品線，六十多個 commit 都用 `IOS-POC-*`，本文件描述的東西**不共用任何二進位、
  toolchain、lock 或 rollback 單位**——正是 `webhtv-player-gates.md` §2 要求明確分離的邊界。
- 把一個 iOS 任務塞進 Android 台帳會污染那份 exhaustive commit ledger，而且會在分支之間製造衝突。

因此本任務用 iOS 線自己的編號 `IOS-POC-9A`，索引留在 `docs/current-task-state.md`。
**Android 的 `P*` 台帳一個字都沒動。**

## 本地既有事實（Grade A，直接讀檔）

### 這個專案已經在建 mpv，只是在 Android 上

`third_party/mpv-native-lock.json` 鎖定的是一整張建置圖，和 iOS 要的是同一批上游：

| 元件 | 版本／commit | 授權（見下方證據表） |
|---|---|---|
| mpv | `cca559b41ceb0bb7731cf6ef2e1f33276cd30c42`（`v0.41.0-940`） | GPLv2+ 預設／LGPLv2.1+ 可選 |
| FFmpeg | FongMi fork `177f090e0503b7e013922ca903bde14b1c375f18`（`9.0.1-fongmi`） | LGPLv2.1+／GPL 視 configure |
| libplacebo | FongMi fork `b694a21bf2dc176c1e98b8a13c6421a0de5f3da5`（7.375.0） | LGPLv2.1+ |
| dav1d | `54706fc6bc0cdecab7e9593974a4039cc038fca7`（1.5.4） | BSD-2 |
| libass | `89cc0f4e450d64f74281a17d7f11ed05229665e8` | ISC |
| libdvdread / libdvdnav | 7.0.1 / 7.0.0 | **GPLv2+** |
| rubberband | 4.0.0 | **GPLv2+**（另有商業授權） |
| libbluray | 1.4.1 | LGPLv2.1 |

**觀察（不是推論）：Android 這份建置一定是 GPL 的**——`libdvdread`／`libdvdnav`／`rubberband`
任一個就足以讓整體變 GPL。iOS 不需要 DVD 導航與變速拉伸，**所以 iOS 不必繼承這個結論**。

### 目前的 provenance 缺口，本輪查出來的

- **`mpv-native-lock.json` 沒有任何 `license` 欄位**，`scripts/build_mpv_native.sh` 裡也找不到
  `--enable-gpl`／`--enable-lgpl`／`--enable-version3`（實際 configure 在 `FongMi/mpv-android`
  builder repo 內，本 repo 未記錄）。也就是說 **App 目前出貨的 `libmpv.so`（17.8 MB）等九個
  `.so` 的授權狀態，在這個 repo 裡無法重建。** 這違反 `webhtv-player-gates.md` §6
  「Native supply-chain gates」要求保留的 license notices。
- 專案**有**做對的先例：`third_party/exo-dv5-native/licenses/`（`LICENSE.libdovi`、
  `LICENSE.libplacebo`、`NOTICE.shaderc-toolchain`）與 `third_party/mpv-player-jni/LICENSE`（MIT）。
  **格式已經存在，只是 mpv native 那一組沒有比照辦理。**
- 這是 **Android 側的既有缺口，不是 iOS 帶來的**。列在這裡是因為 iOS 若採同樣做法會複製它。

### 本 repo 自身的授權

`LICENSE.md` 是完整的 **GPLv3**（674 行）。repo 公開在 `github.com/st7833232/webhtv`。
**這件事對下面的結論有決定性影響**：原始碼散布義務已經是持續在履行的狀態。

## 候選方案與授權證據

只考慮「授權允許嵌入的 SDK」。**依使用者 2026-09-21 的指示，不從 Infuse／Fileball／SenPlayer／
VidHub 拆任何 framework**，那條路本輪完全沒有評估，也不應被評估。

### Evidence: mpv 本身的授權與 LGPL 模式的代價

- Source type/grade：**A**（上游專案自己的 `Copyright` 檔）
- URL：<https://raw.githubusercontent.com/mpv-player/mpv/master/Copyright>，存取日 2026-09-21
- Supported claim：mpv 整體預設 **GPLv2+**；不含 GPL-only 檔案建置時為 **LGPLv2.1+**，由
  `-Dgpl=false` 排除。
- Relevant excerpt：LGPL 模式停用的功能是 `Linux X11 video output`、`BSD audio output via OSS`、
  `NVIDIA/Linux hardware decoding (vdpau)`、`jack, DVD, CDDA, DVB, CACA, legacy direct3d VO`。
  並明言 **“The intended use for LGPL mode is with libmpv”**。
- Applicability to WebHTV：**這是本輪最重要的一項。LGPL 模式停用的每一項都是 Linux／Windows 桌面
  功能，iOS 一項都用不到。** 我們要的正是 libmpv 而不是 mpv CLI，而上游說 LGPL 模式就是為 libmpv 設計的。
  **在 iOS 上選 LGPL 幾乎是零功能代價。**
- Caveats：上游同時警告 `-Dgpl=false` 本身「does not in itself create a LGPLv2.1+ license grant」，
  且 **“Linked libraries still can affect the final license (for example if FFmpeg was built as GPL)”**。
  所以 FFmpeg 的 configure 才是真正的關卡。
- Decision impact：把問題從「mpv 能不能用」收斂成「FFmpeg 怎麼建的」。

### Evidence: FFmpeg 的授權與官方合規清單

- Source type/grade：**A**（FFmpeg 官方 Legal 頁）
- URL：<https://ffmpeg.org/legal.html>，存取日 2026-09-21
- Supported claim：FFmpeg 為 **LGPLv2.1+**；一旦用到 GPL 元件，**整個 FFmpeg 變 GPL**。
  官方 LGPL 合規清單要求：不帶 `--enable-gpl`／`--enable-nonfree`；**動態連結**；散布與二進位
  完全對應的原始碼；把 configure 命令寫進原始碼根目錄；在下載頁與 about box 標示；
  不得禁止逆向工程；不得混淆函式庫檔名。
- Applicability to WebHTV：清單裡**只有「動態連結」這一條在 iOS 上是問題**（見下）。其餘每一條，
  一個公開的 GPLv3 repo 本來就在做或極易做到。
- Decision impact：確立 iOS 的唯一真正障礙是連結方式，不是授權本身。

### Evidence: MPVKit — 最貼近需求的 iOS mpv 發行

- Source type/grade：**A**（專案 README、`Package.swift`、releases、PR diff）
- URL：<https://github.com/mpvkit/MPVKit>、`/main/Package.swift`、`/releases`、`/pull/78/files`，
  存取日 2026-09-21
- Supported claim：
  - 以 **SPM `binaryTarget`** 發行**預編譯 xcframework**，每個 zip 附 **SHA-256**（`Package.swift`
    內即 pin，另有 `.checksum.txt` asset）。平台涵蓋 iOS 15+／macOS 12+／tvOS 15+／visionOS。
  - 提供兩個產品：`MPVKit`（**LGPL**）與 `MPVKit-GPL`（**GPL**，多一個 `Libsmbclient`）。
  - 最新 **1.0.0 = mpv v0.41.0 + FFmpeg n8.1.2 + libplacebo 7.360.1 + MoltenVK 1.4.2**。
- **關鍵發現，三項，全部來自 PR #78 的實際 diff（`Sources/BuildScripts/XCFrameworkBuild/main.swift`
  第 649 行附近的 FFmpeg configure）：**
  1. **`--enable-nonfree` 直到 1.0.0 才從「非 GPL」建置移除。** `--enable-nonfree` 產生的二進位
     **完全不可再散布**。因此 **1.0.0 以前的任何 MPVKit release 都不得使用**，它們被標為 LGPL 但
     實際上不可散布。這是本輪最具體的硬性規則。
  2. **`--disable-shared --enable-static`** → **MPVKit 的 FFmpeg 是靜態的**。FFmpeg 官方清單
     推薦的「動態連結」這條最省事的合規路**走不通**。
  3. **`--enable-version3`** → 這份 LGPL 建置是 **LGPL v3**，不是 v2.1。這解釋了 README 為何寫
     LGPL-3.0，而 **LGPLv3 與本 repo 的 GPLv3 相容**。
  - 同一份 configure 沒有 `--enable-gpl`，佐證非 GPL 變體確實排除了 GPL-only 元件。
- Caveats：
  - README 第一句是維護者自己寫的：**“MPVKit is only suitable for learning libmpv and will not be
    maintained too frequently.”** 這是**維護風險的一手陳述**，不是外界揣測。
  - LGPL 變體仍相依 `gmp`／`nettle`／`hogweed`／`gnutls`（LGPLv3 一系）與 `Libdovi`、`MoltenVK`、
    `Libshaderc`、`lcms2`、`Libbluray`、`Libuchardet`——**逐一授權未在本輪全部核對**，列為未解 gate。
  - `Libluajit` 只在 macOS 條件連結，**iOS 沒有 Lua** → Android 的 `docs/MPV-SCRIPT-TRIGGERS.md`
    那套腳本觸發**不會**跟著過來。
- Decision impact：技術上最合身（同一個 mpv v0.41.0 版本線），但**必須釘 1.0.0 或更新**，
  且要處理靜態連結義務與維護風險。

### Evidence: VLCKit — 授權最乾淨的替代路線

- Source type/grade：**A**（VideoLAN 官方 mirror README）
- URL：<https://github.com/videolan/vlckit>，存取日 2026-09-21
  （`code.videolan.org` 有 Anubis bot 驗證，**未嘗試繞過**，改用官方 GitHub mirror）
- Supported claim：VLCKit／MobileVLCKit／TVVLCKit 為 **LGPLv2.1 或更新**，VideoLAN 官方維護，
  以 CocoaPods／Carthage 發行。README 的 FAQ **明文允許嵌入專有 App**，並列出三項義務：
  發布你對它所做的修改、讓終端使用者知道 VLCKit 被內嵌、讓終端使用者知道其權利並能取得程式碼。
- Applicability to WebHTV：這是使用者「只能整合授權允許嵌入的 SDK」這條限制的**教科書答案**——
  上游自己書面允許。**LGPLv2.1+ 可升版至 LGPLv3，與本 repo 的 GPLv3 相容。**
- Caveats：**它是 libvlc，不是 mpv。** 與 Android 側共用上游知識、patch、診斷的好處全部消失；
  `webhtv-player-gates.md` §2 的「兩個播放器是獨立建置」在這裡會變成「兩個播放器是不同專案」。
  MobileVLCKit 的靜態／動態形態本輪**未查證**，列為 gate。
- Decision impact：若 MPVKit 的維護風險或靜態連結義務被判定不可接受，這是唯一的現成退路。

## 靜態連結：為什麼在 WebHTV 這裡不是阻斷條件（推論，標記清楚）

**這一節是推論，不是引用。** FFmpeg 官方清單把動態連結列為「最簡單」的合規方式，但 LGPL 本身
並未禁止靜態連結；它要求的是**讓使用者能以修改過的函式庫重新連結**——LGPLv2.1 §6(a) 允許提供
「as object code and/or source code」的 *work that uses the Library*，LGPLv3 §4(d)(1) 同構。

**WebHTV 的處境剛好滿足它：整個 App 的原始碼已經以 GPLv3 公開在 GitHub 上。** 提供「使用該函式庫
的作品」的完整原始碼，正是 §6(a) 接受的兩種形式之一。加上 MPVKit 的 xcframework 本身可由公開的
build script 從釘住的上游重建，重新連結的材料是齊的。

**因此：靜態連結在這個專案不是阻斷條件，但它是一項必須明寫並持續履行的義務**，不能像現在
`mpv-native-lock.json` 那樣沒有任何 license 記錄就出貨。

## 真正的限制條件不是 MPV，而是既有的 GPLv3

`docs/analysis/ios-app-store-readiness-research.md` 已經記錄：本 repo 為 GPLv3，
「App Store 條款與 GPLv3 是否能同時履行屬法律判斷；目前證據不足以宣稱已解決」。

**本輪的結論是：加入 mpv 不會讓那個問題變得更糟。**

- 上架輪廓本來就不含遠端執行的 Python／drpy／compatibility pack，也已被同一份研究判定不適合原封送審；
  **MPV 只會掛在個人側載輪廓上**，那正是使用者 2026-09-21 定案的 build profile 分法。
- 側載／Ad Hoc 不經 Apple 通路，**Apple ToS 與 GPL 的衝突在那條路上不成立**；需要履行的是 GPL／LGPL
  自己的散布義務，而公開的 GPLv3 repo 已經在履行主要部分。
- 若日後真的用 GitHub Release 發 IPA，那**是**二進位散布，義務會真正觸發（對應原始碼、configure
  記錄、notice）。**這一點與 MPV 無關，Python payload 已經讓它成立了。**

## 三個對照方案

| 方案 | 內容 | 授權／provenance 評價 | 成本 |
|---|---|---|---|
| **A. 不做**（no change） | 只保留 AVPlayer + 四個外部播放器 | 零新義務。外部播放器由使用者自行安裝，授權責任不在我們 | 0。但 MKV／進階字幕／冷門編碼仍只能丟給外部播放器，且外部播放器拿不到 request headers（`SourceClient` 的 header 支援對它們無效） |
| **B. 原封採用上游** | 直接 SPM 依賴 `MPVKit` 1.0.0 LGPL 變體 | **可接受**，條件是釘 ≥1.0.0、記錄 configure 與授權、履行重新連結義務 | 最低。但把維護風險（維護者自陳「不常維護」）與一整串未逐一核對的相依授權一起吃下 |
| **C. WebHTV 適配** | 以 MPVKit 1.0.0 為上游，但比照 `third_party/python-ios-lock.json` 建立 `third_party/mpv-ios-lock.json`：釘版本／URL／sha256／授權／configure，並把 license notices 落到 `third_party/mpv-ios/licenses/` | **最佳**。同時補上 Android 側目前缺的那塊 | 略高於 B，但那份 lock 正是 IOS-POC-7E 已經驗證過的模式，腳本可照抄 |

**不在對照內**：自行從源碼交叉編譯 mpv/FFmpeg 到 iOS。技術上可行，但那是 Android 那條 native 建置鏈
的規模，而 B／C 已經能回答可行性問題。若日後 MPVKit 停止維護，這是升級路徑。

## 建議

**採 C，但分兩段，而且第二段要另外授權。**

1. **IOS-POC-9A（本輪，已完成）**：授權與 provenance 審查。結論是**沒有授權層面的阻斷條件**，
   前提是釘 MPVKit **1.0.0 或更新**的 **LGPL（非 GPL）** 變體。
2. **IOS-POC-9B（尚未授權）**：技術可行性 spike——`PlaybackTarget → PlayerRouter →
   AVPlayerEngine / MPVEngine`，共用既有 `PlaybackSession`、headers、history、resume、quality，
   不重造 `SourceClient`。**未經使用者明確指示不得開始。**
   （2026-09-25 更正：IOS-POC-9B 已於 2026-09-21 開始並實作（`401b3076`），MPV 之後由 IOS-POC-17 成為第二內部播放核心，
   見 `docs/IOS-POC-9B-mpv-playback-core.md` 與 `docs/IOS-POC-17-dual-internal-player.md`。）

理由：授權問題已經收斂到可判定，而技術問題（App 體積再 +80 MB 以上、Metal/MoltenVK 在真機的表現、
與 `PlaybackSession` 的生命週期整合）需要的是量測而不是閱讀，屬於另一個決策。

## 驗收條件（給 IOS-POC-9B，不是本輪）

| # | 條件 | 怎麼驗 |
|---|---|---|
| L1 | 釘的是 MPVKit **≥1.0.0** 的**非 GPL** 變體 | `Package.resolved` 的 URL 與 sha256 對上 release asset 的 `.checksum.txt` |
| L2 | 打包進 App 的二進位裡沒有 GPL-only 元件 | 檢查 `Libsmbclient` 不在相依圖；比對 configure 不含 `--enable-gpl`／`--enable-nonfree` |
| L3 | `third_party/mpv-ios-lock.json` 記錄版本、URL、bytes、sha256、授權、configure | 比照 `python-ios-lock.json` 的欄位 |
| L4 | license notices 隨 App 出貨，且 App 內有可看到的歸屬 | 比照 `third_party/exo-dv5-native/licenses/` 的先例 |
| L5 | 既有 151 條測試與模擬器 build 無退步 | `swift test` + `xcodebuild` |

## 回滾

本輪沒有可回滾的東西——**沒有動任何程式碼**。IOS-POC-9B 若開始，回滾單位是一個 SPM 依賴加一份
lock，`git revert` 即可；`WebHTVCore` 不會連結它（沿用 `PythonSpiderSupport` 那個 seam 的做法，
讓 macOS 上的測試不受影響）。

## 未解 gate（刻意不臆測）

（2026-09-25 更正：gate 1 與 gate 3 已由 IOS-POC-9B 讀 MPVKit 建置腳本關閉，見 `docs/IOS-POC-9B-mpv-playback-core.md`「9A 留下的 gate，本輪關閉情形」。
方案 C 的 lock 與 notice 之後由 IOS-POC-17I-1 建立：`third_party/mpv-ios-lock.json`（`1fdce318`）與 `third_party/mpv-ios/licenses/`
（`85642ec5`、`9f2af62c`）；驗收項 L4 的 App 內歸屬畫面仍是另一個任務（`third_party/mpv-ios/README.md` 末段）。）

1. **MPVKit LGPL 變體的完整相依授權未逐一核對**：`Libdovi`、`MoltenVK`、`Libshaderc_combined`、
   `lcms2`、`Libuchardet`、`gnutls`／`nettle`／`hogweed`／`gmp`、`Libuavs3d`。要在 9B 開始前補完。
2. **MobileVLCKit 是靜態還是動態 framework，未查證。** 只在方案 C 被否決時才需要。
3. **`Libbluray` 出現在 LGPL 變體的相依裡**。libbluray 本身是 LGPLv2.1，但需確認 MPVKit 沒有一併
   帶入 GPL 的 `libaacs`／`libbdplus`。
4. **App 體積**：MPVKit 的 `Libavcodec.xcframework.zip` 單一檔案就 53.1 MB（壓縮後）。實際進 App
   的大小本輪**沒有量**，屬於 9B 的技術題。
5. **GPLv3 與 iOS 簽章的既有法律問題**，見 `docs/analysis/ios-app-store-readiness-research.md`。
   **不屬於本任務，也不因本任務而改變。**

## 順帶查出、但不在本任務範圍的缺陷

`third_party/mpv-native-lock.json`（Android）沒有任何 license 欄位，本 repo 也沒有記錄其 FFmpeg
configure，因此 **App 目前出貨的九個 mpv `.so` 的授權狀態無法從這個 repo 重建**。
依 `AGENTS.md` §2，這不在本任務範圍，**只回報不修**。修它屬於 Android 線。

## Ponytail（評估階段）

① 需要存在——使用者指定的階段，且 `AGENTS.md` §8 強制要求整合前先做這件事。
② 已有的東西先用——`python-ios-lock.json` + `fetch_python_ios.sh` 的模式直接照抄，
`exo-dv5-native/licenses/` 的 notice 格式直接照抄，`PythonSpiderSupport` 的 seam 直接照抄。
⑤ 用現成套件——MPVKit／VLCKit 都是現成發行，不自行交叉編譯。
⑦ 最小可行：本輪的產出是一份文件與一個「釘 ≥1.0.0 非 GPL 變體」的硬性規則，沒有別的。

刻意不做：自行 cross-compile mpv 到 iOS、拆任何商業 App 的 framework、上架輪廓的授權分析
（已有 `docs/analysis/ios-app-store-readiness-research.md`）、Android 那份 lock 的 license 補登。

## 下一步（唯一）

**無。** 本審查已完成，IOS-POC-9B 之後已開始（`401b3076`）；MPV 的後續狀態見
`docs/IOS-POC-9B-mpv-playback-core.md` 與 `docs/IOS-POC-17-dual-internal-player.md`。
（2026-09-25 更正：原寫「等使用者決定要不要開 IOS-POC-9B（技術可行性 spike）。在那之前不得新增依賴、不得改
`Package.swift`、不得下載任何 xcframework。」）
