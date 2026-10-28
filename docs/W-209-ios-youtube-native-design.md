# W-209 iOS 自己處理 youtube.com 網址（設計，待使用者核准）

> 狀態：設計稿第 2 版（依 Reviewer #4537 F1／F2 修改），**只寫設計、不實作、不改 App**。Reviewer 核准後由 Manager 轉使用者決定是否開實作單。
> 範圍邊界（工單）：不補 PO Token、不偽造驗證、不繞簽章；若 FongMi 本身用了這類手段要明說並建議不採。

## 白話摘要

- Android 的「YouTube｜PY」站能播，不是腳本厲害，而是腳本出錯後丟回一個 `youtube.com/embed/…` 網址（`parse: 1`），FongMi 內建的 YouTube 功能再把它變成可直接播的串流。
- FongMi 這個內建功能靠的是 NewPipe 函式庫。NewPipe 會**假裝自己是 YouTube 官方 Android App／visionOS App 去要影片資料，並在手機上執行 YouTube 播放器的 JavaScript 算出簽章和 n 參數**，才拿到能播的 googlevideo 直連網址。FongMi 官方程式本身沒有再加別的冒充手段。
- 這些正是工單禁止的「偽造驗證、繞簽章」，也違反 YouTube 服務條款與開發者政策（禁止規避技術措施、禁止自動化存取、禁止偽裝 API 用戶端身分、禁止下載）。所以**不建議把 FongMi 的做法照搬到 iOS**。
- 建議改用 YouTube 明文允許的方式：遇到 YouTube 影片網址時，在 App 內開 **YouTube 官方嵌入式播放器**（IFrame Player），並照 YouTube 規定用我們自己 App 的 Bundle ID 表明身分。能起播、能拖進度，但畫面是 YouTube 自己的播放器，不走我們的 AVPlayer／MPV，可能有廣告，作者禁止嵌入的影片播不了。
- 使用者要決定：(1) 接受官方嵌入播放器（建議）；(2) 維持現狀不做；(3) 照搬 FongMi（不建議，違反工單邊界與條款）。

## 1. FongMi 內建 YouTube 處理的實際流程

### 1.0 依據的原始碼
- **官方 FongMi**：`https://github.com/FongMi/TV`，分支 `fongmi`，最新 commit `123cc086159b0f13bf54bdf64bacbc259ca47c88`（2026-10-27，「Fix Python loading errors and resource cleanup」），2026-10-28 取得。
  - 官方 repo **沒有 tag**；該 commit 的 `app/build.gradle:22-23` 是 `versionCode 583`、`versionName "5.8.3"`。
  - 使用者 Android（emulator-5560）裝的是 `versionCode=584`（5.8.4），**對應的原始碼 commit 未公開，查不到**。以下官方行為以 `123cc086`（5.8.3）為準，**5.8.4 是否有改動未驗證**。
- **本分支**（`origin/ios-poc` 3f499399）的 `app/src/main/java/com/fongmi/android/tv/player/…` 有本 repo 自己的修改，例如 commit `9385499699ca34ae7ea66aa9ac45d99f4136baf4`（fix: make jar youtube MPD playback usable）。這些**不是 FongMi 做法**，在下表另列。
- **NewPipe Extractor**：官方 FongMi 用 `v0.26.5`（官方 `gradle/libs.versions.toml:44`），commit `f9e6bb808f82bf3e4dc1f2a29a16fd376931c8ef`；本分支用 `v0.26.3`（`gradle/libs.versions.toml:47`）。下面引用的 NewPipe 行號在兩版相同。

### 1.1 什麼時候會進來（官方 123cc086）
- `app/src/main/java/com/fongmi/android/tv/player/extractor/Source.java:30-32`：抽取器清單 `Push, Video, WebView, Strm, Thunder, TVBus, YouTube`。
- `player/extractor/YouTube.java:62-70`：`match()` → `isYouTube()`，host 是 `youtube.com`／`*.youtube.com`／`youtu.be`／`*.youtu.be` 就接手。
- `Source.java:111-125` `fetch(Result)`：找到抽取器就 `setParse(0)`，`url = extractor.fetch(result)`，再 `BaseLoader.get().requireProxy(url)`，回傳。**YouTube 抽取失敗時例外直接往上丟，沒有退回 `parse: 1` 的機制。**
- 播放清單：`YouTube.java:259-304` `Parser`，網址帶 `list=` 時展開成集數（`Source.java:77-88`）。

### 1.2 取哪個 client（NewPipe 本身做法）
- 官方 `YouTube.java:58-60`：`NewPipe.init(NewPipeImpl.get(), …)`；官方 `impl/NewPipeImpl.java:21`、`:33`、`:39`：所有請求用 OkHttp，UA 是桌面 Firefox 140；收到 429 丟 `ReCaptchaException`。
- 官方 `YouTube.java:78-83`：`StreamInfo.getInfo(url)` → NewPipe `extractors/YoutubeStreamExtractor.java:838-862`：
  1. `fetchAndroidClient`（:849）：以 InnerTube `ANDROID` client 要 player response（`ClientsConstants.java:100-111`，clientVersion `21.03.36`）。**冒充 YouTube 官方 Android App。**
  2. `fetchIosClient`（:853）：預設不做，要呼叫端 `setFetchIosClient(true)`；官方 FongMi 這幾個檔案都沒有呼叫（全 repo 是否另有呼叫：**未驗證**，因官方 repo 只部分下載）。
  3. `fetchVisionOsClient`（:859）：一律做，冒充 `VISIONOS` client（`ClientsConstants.java:116-120`）。
  4. `fetchWebClientMetadataAndSetThumbnails`：`WEB` client 取標題、縮圖。
- PO Token：NewPipe 有 `PoTokenProvider` 介面（:843-856）。官方 `YouTube.java`、`Source.java`、`NewPipeImpl.java` 都沒有設定；全 repo：**未驗證**（理由同上）。本分支全 repo 確認沒有（`git grep PoTokenProvider -- app` 無結果）。

### 1.3 簽章與 n 參數（NewPipe 本身做法；屬「繞簽章」）
- `YoutubeStreamExtractor.java:1311-1345` `buildAndAddItagInfoToList`：
  - 格式只有 `signatureCipher` 時呼叫 `YoutubeJavaScriptPlayerManager.deobfuscateSignature()`（:1325）。
  - **每個串流網址**都經過 `getUrlWithThrottlingParameterDeobfuscated()`（:1336）解 n 參數；註解寫明「n 解不出來，串流網址會回 HTTP 403」。
  - 兩者都是下載 YouTube 播放器 JS，用 Mozilla Rhino（`utils/JavaScript.java:3-4`）在手機上執行抽出的函式（`YoutubeJavaScriptPlayerManager.java:164`、`:264`）。
- 結論：FongMi 能播 YouTube，**依賴 NewPipe 的冒充官方 client＋執行 YouTube 播放器 JS 解簽章／n 參數**。這是工單說的「繞簽章」類手段；FongMi 官方程式自己沒有另外加。

### 1.4 怎麼選 itag、怎麼組 DASH（官方 123cc086）
- `YouTube.java:85-87`：直播 → `getLive()`（:102-104，有 HLS 用 HLS，否則 DASH MPD 網址）；隨選 → `getMpd()`。
- `YouTube.java:106-111` `getMpd()`：
  - 只留有 indexRange／initRange 的 video-only 與 audio 串流（:207-219）。兩邊都沒有時，退回單檔串流中「最高解析度、再比位元率」的那一個（:113-115）。
  - **不挑單一 itag**：每個符合的 video、audio 各做一個 AdaptationSet／Representation（:131-132、:136-166），帶 googlevideo 直連 `BaseURL`＋`SegmentBase` range（:168-173），由 ExoPlayer 自己挑畫質。使用者 10/27 看到的 itag 137（1080p H.264 mp4）就是 ExoPlayer 選中的那一路。
  - MPD 以 `data:application/dash+xml;base64,…` 交出（:110、:225-227）。
- 字幕：`YouTube.java:175-205`，只收 VTT；TTML 網址改 `fmt=vtt`。
- 影片資訊：`YouTube.java:81` `result.setList(List.of(convert(info).trans()))`，把標題、上傳者、縮圖帶回畫面。
- **官方沒有**替 YouTube 改播放 header；播放請求沿用一般設定。

### 1.5 網址有效期與刷新
- googlevideo 網址帶 `expire=` 時間戳（長度本次未實測）。
- 官方 FongMi **沒有刷新機制**：MPD 是起播時一次產生的 data URI，過期後要重新進入播放才會重抓。
- W-202 實測（`docs/W-201-ios-spider-local-proxy.md` 末節「實作結果（W-202）」，worktree `/Users/chengchenchih/GIT/webhtv-w202`）：腳本經 9978 拿到的網址有讀取配額，音訊讀到約 1 MB 後一律 403，iOS 經 9978 只能播約 75 秒；Android 能播是因為走了 1.1–1.4 的流程。

### 1.6 官方與本分支差異（逐項）

| 項目 | 官方 123cc086 | 本分支 origin/ios-poc |
|---|---|---|
| 抽取器清單與 YouTube 判斷 | 有（`Source.java:30-32`、`YouTube.java:62-70`） | 有，類名 `Youtube`，判斷改為 host「包含」字串（`player/extractor/Youtube.java:65-68`），清單另有 `Force`、`JianPian` |
| 以 NewPipe 取 player response、組 DASH data URI、字幕 | 有（1.2–1.4） | 有（`Youtube.java:115-120` 等），邏輯相同 |
| YouTube 抽取失敗或回空時退回 `parse: 1` 原網址 | **沒有**，例外往上丟 | 只有本分支（`player/Source.java:100-109`） |
| jar 給的 MPD 音訊受限時，以 Referer 的 `youtube.com/watch` 重抓（`MpdSanitizer.hasLimitedYoutubeAudio`） | **沒有**（官方無 `MpdSanitizer`） | 只有本分支（`player/Source.java:110-121`，commit 9385499699ca…） |
| 播放 UA 改成 `com.google.android.youtube/21.02.35 …`（冒充 YouTube Android App） | **沒有** | 只有本分支（`player/Source.java:122-126`） |
| MPV 用 `MpdEdlResolver` 把 MPD 轉 EDL | **沒有**（官方無 MPV 這條路） | 只有本分支（`player/Source.java:127-134`） |
| NewPipe 版本 | v0.26.5 | v0.26.3 |

- 對本設計的影響：本分支多出的 UA 冒充是本 repo 自己加的，同樣屬工單禁止範疇；iOS 不移植。其他差異不影響「不採方案 B」的結論。

## 2. iOS 現況（`parse: 1` 的 youtube.com 網址目前怎麼走）

依程式碼推論，**未實測**：
- `ios/Sources/WebHTVCore/SourceClient.swift:152-191` `target(from:…)`：
  - `GlobalParse.plan()`（`GlobalParse.swift:98-136`）：設定沒有全域解析接口且沒有 `jx`、`parse: 1` 而 `playUrl` 為空 → `.none`。
  - 接著 `parse != 0` → `MediaSniffer.shared.sniffWithSubtitles(page:)`：用隱藏 WKWebView 開 `youtube.com/embed/…`，12 秒內等符合關鍵字的媒體請求。
- `MediaSniffer.swift:108` 的關鍵字含 `/videoplayback`，`blob:`／`data:` 會被忽略（`:508`）。YouTube 嵌入播放器用 MSE 播放，實際抓的是 googlevideo `videoplayback` 的「純影像或純音訊、帶 range」片段。
- 結果只有兩種，兩種都不能正常看：
  1. 12 秒內嗅不到（例如嵌入頁要使用者點擊才載入）→ 播放失敗。
  2. 嗅到第一個 `videoplayback` 請求 → 交 AVPlayer／MPV 播一個只有畫面或只有聲音、有讀取配額的片段，播一下就 403。
- iOS 沒有任何 YouTube 專用處理；直播清單遇到 YouTube 網址直接標「不支援」（`Live/LivePlaylistParser.swift:360-373`）。

## 3. 方案比較

| | A 不做 | B 照 FongMi 移植 | C 官方嵌入播放器（建議） |
|---|---|---|---|
| 做法 | 維持 2. 的行為 | iOS 以 InnerTube 冒充 ANDROID／VISIONOS client 取 player response，用 JavaScriptCore 執行 YouTube 播放器 JS 解簽章／n 參數，組 DASH 或 HLS 交 MPV／AVPlayer | 偵測到 YouTube 影片網址時，不嗅探，改在 App 內以全螢幕 WKWebView 開官方 IFrame Player，Referer 用本 App 的 Bundle ID |
| 能不能起播＋拖到中段 | 不能 | 能（直到 YouTube 改版或擋下） | 能（`seekTo`、播放器自帶進度條） |
| 條款／工單邊界 | 無問題 | **違反**：冒充 client＝偽造驗證、偽裝 API 用戶端身分；執行播放器 JS 解簽章／n＝規避技術措施；YouTube 條款禁止規避、自動化存取、下載 | 符合：YouTube 條款明文允許「透過嵌入式 YouTube 播放器播放影片」；身分用本 App 自己的 ID |
| 維護 | 無 | 很高：YouTube 經常改播放器 JS 與 client 版本，iOS 沒有現成 Swift 版 | 低：官方 API 穩定 |
| 畫質／體驗 | — | 我們的播放器、可選畫質、無廣告 | YouTube 自己的播放器 UI；可能有廣告；畫質由 YouTube 自動 |
| 失敗情況 | 一律失敗 | YouTube 擋 client 或改 JS 時全站失效；可能觸發 429 | 作者禁止嵌入（101／150）、私人或已刪除（100）、缺身分（153）時播不了，要明確提示 |
| 與我們播放器的功能 | — | 續播紀錄、PiP、AirPlay、MPV 都可用 | 續播紀錄用 `getCurrentTime()` 自己存；PiP／AirPlay 取決於 WKWebView 的 HTML5 video 支援（未驗證）；MPV 不適用 |
| 工作量 | 0 | 大（數天以上，且長期追版） | 中小（網址判斷＋嵌入播放畫面＋錯誤提示＋續播＋接下一集） |

決定：**C**。B 的核心手段正是工單明列不得採用的範疇，即使 FongMi（經 NewPipe）這樣做，也不跟進；A 對使用者沒有價值。

## 4. 建議設計（方案 C）

### 4.1 判斷條件（只影響 YouTube）
- 在 `SourceClient.target(from:…)` 決定要嗅探之前加一個判斷：選中的播放網址 host 是 `youtube.com`／`*.youtube.com`／`youtu.be`／`youtube-nocookie.com`，且能取出 11 字元影片 ID（`/embed/<id>`、`/watch?v=<id>`、`/shorts/<id>`、`youtu.be/<id>`、`/live/<id>`）。
- 符合 → 回傳新的播放目標種類「YouTube 嵌入」（帶影片 ID 與起始秒數），不進 `MediaSniffer`、不進 AVPlayer／MPV。
- 不符合（含 googlevideo 直連、其他站的網址）→ 完全照現在的流程，不變。
- host 規則和 `LivePlaylistParser.isYouTube`（`:369-373`）一致，抽成一個共用函式，兩邊一起用。

### 4.2 播放畫面
- 新增全螢幕 YouTube 嵌入播放畫面（SwiftUI 包 WKWebView），以 `loadHTMLString(html, baseURL:)` 載入一段本地 HTML，HTML 用官方 IFrame Player API（`https://www.youtube.com/iframe_api`）建立播放器。
- **身分（Referer／origin）具體值**：
  - `baseURL` = `https://com.webhtv.ios.poc`（本 App 的 Bundle ID，`ios/WebHTVApp/WebHTVApp.xcodeproj/project.pbxproj:323`、`:407` 的 `PRODUCT_BUNDLE_IDENTIFIER`）。
  - 依據：YouTube「Required Minimum Functionality」的 API Client Identity 一節：嵌入播放器「must provide identification through the HTTP Referer request header」；WebView 整合預設 Referer 為空，「setting the baseUrl parameter will set the Referer」；Referer 的網域「must be your application identifier ("app ID")」，Apple 平台用 Bundle ID，且「should be stable across app version changes」。開發者政策 III.D.1 另規定「must not mask or misrepresent your identity or your API Client's identity」。
  - 因此 IFrame 的 `origin` 參數也用同一值 `https://com.webhtv.ios.poc`（IFrame API 建議帶 `origin`）。
  - **不得**借用 `youtube.com`、`google.com` 或任何他站網域，也不得用 `com.google.android.youtube` 等別的 App ID。
  - 寫死專案的 Bundle ID，不用執行期 `Bundle.main.bundleIdentifier`：SideStore 重簽後執行期 ID 可能加上後綴，規範要求這個值跨版本穩定。
  - 風險：RMF 寫的是「registered with the store」，本 App 經 SideStore 發佈、未上架 App Store；YouTube 是否因此拒絕（錯誤 153 或其他）**未驗證**，實作單第一步用原型確認。若被拒，就停在方案 C 失敗、改提示「用 YouTube App 開啟」，**不改用他人 ID**。
- `playerVars`：`playsinline=1`、`enablejsapi=1`、`start=<續播秒數>`、`origin` 如上。
- 播放器可視區至少 200×200（官方要求）；播放器上方、前方不疊任何遮罩或控制項（RMF「Overlays and frames」）；我們的返回鍵放在播放器區域之外。
- 不注入任何改變 YouTube 行為的腳本，不擋廣告、不改 UA、不讀取 googlevideo 網址。只用官方 API：`seekTo`、`getCurrentTime`、`getDuration`、`loadVideoById`、`onStateChange`、`onError`。
- 續播：每 5 秒及離開時以 `getCurrentTime()` 寫入現有播放紀錄；下次以 `start=` 起播。
- **播完接下一集**：`onStateChange` 收到 `ended`（0）時，交給現有「下一集」流程取得下一集網址：
  - 下一集仍是 YouTube 影片 → 同一個嵌入播放器 `loadVideoById(<下一集 ID>)`，不重建畫面。
  - 下一集不是 YouTube → 關閉嵌入畫面，回到一般播放器流程。
  - 沒有下一集 → 停在 YouTube 播放器的結束畫面。
  - 依據：RMF 規定自動播放只能在播放器可見且超過一半可見時開始；本畫面是全螢幕且前景，符合。App 在背景時不自動接下一集。
- 錯誤：`onError` 101／150 →「這部影片的作者不允許在其他 App 播放」；100 →「影片不存在或已設為私人」；153 →「YouTube 不接受本 App 的播放器身分」；2／5 →「YouTube 播放器無法載入」；並提供「用 YouTube App／Safari 開啟」按鈕（`UIApplication.open`）。
- 播放清單（`list=`）：第一版只播網址指定的影片；整個清單展開成集數不做（FongMi 的 `Parser` 也是靠 NewPipe 抓 YouTube 頁面，屬自動化存取）。

### 4.3 不做的事（明列）
- 不補 PO Token、不冒充任何 YouTube client、不改 UA 成 YouTube App、不借用他人 App ID 或網域當 Referer。
- 不執行或解析 YouTube 播放器 JS、不解簽章／n 參數、不取 googlevideo 直連。
- 不下載、不快取影片內容；不擋廣告；不在播放器上疊東西。
- 不經 9978 本機代理播 YouTube（W-202 已證實只能播約 75 秒）。

## 5. 對其他站的影響
- 只有播放網址本身是 YouTube 影片頁／嵌入網址時才改走新畫面；其他站、直連媒體、解析接口流程都不受影響。
- 站點腳本自己回 googlevideo 直連（例如 W-202 的 YouTube｜PY 正常路徑經 9978）**不受影響**，照舊交 MPV（仍只有約 75 秒，這是 W-202 已記錄的限制）。
- 直播清單裡的 YouTube 頻道目前標「不支援」；第一版不改（可另開單評估用同一嵌入畫面）。
- Android 不變。

## 6. 驗收（實作單用）
- Simulator＋實機各一（實機以 SideStore IPA，不直接安裝）：
  1. YouTube｜PY 站任一影片：點播後 10 秒內起播、有畫面有聲音。
  2. 拖到影片中段（例如 50%）後 10 秒內繼續播放，至少再播 60 秒不中斷（對照 W-202 的 75 秒限制）。
  3. 離開再進入，從上次位置續播（誤差 ≤ 10 秒）。
  4. 一部作者禁止嵌入的影片：顯示 4.2 的提示與「用 YouTube 開啟」按鈕，App 不卡住。
  5. 有兩集以上的 YouTube 節目：第 1 集播完自動接第 2 集。
  6. 用網頁代理或 WKWebView 檢查確認請求的 Referer 是 `https://com.webhtv.ios.poc/`。
  7. 回歸：一般 m3u8 站、一個 `parse: 1` 非 YouTube 站、一個經 9978 的 PY 站，行為與實作前相同。
- 單元測試：網址判斷函式（各種 YouTube 網址形式取出 ID、非 YouTube 網址回 nil、`googlevideo.com` 回 nil）。

## 7. 回退
- 變更集中在「YouTube 網址判斷＋嵌入播放畫面」；回退＝ revert 該 commit，或移除 `target(from:)` 中的新判斷，YouTube 網址就回到現在的嗅探流程。
- 不改資料格式；續播紀錄沿用現有欄位，回退後舊紀錄仍可讀。

## 8. 研究紀錄（存取日 2026-10-28）

| 來源 | 版本 | 證據等級 | 支持的結論 | 對決策的影響 |
|---|---|---|---|---|
| 官方 FongMi/TV `player/extractor/Source.java`、`YouTube.java`、`impl/NewPipeImpl.java`、`app/build.gradle`、`gradle/libs.versions.toml` | `fongmi` 分支 `123cc086159b0f13bf54bdf64bacbc259ca47c88`（versionName 5.8.3） | 一手程式碼 | 1.1–1.5 官方流程；官方沒有 parse 退路、MpdSanitizer、UA 冒充、MPV 路徑 | 第 1 節以此為準 |
| 本 repo 同名檔（`player/Source.java`、`player/extractor/Youtube.java`、`MpdSanitizer.java`） | `origin/ios-poc` 3f499399；commit 9385499699ca34ae7ea66aa9ac45d99f4136baf4 | 一手程式碼 | 1.6 本分支差異 | 標明非 FongMi 做法 |
| TeamNewPipe/NewPipeExtractor | `v0.26.5` `f9e6bb808f82bf3e4dc1f2a29a16fd376931c8ef`；對照 `v0.26.3` `caae86c943857cc6e1a762e3488d6a14e9cf7800` | 一手程式碼 | ANDROID／VISIONOS client 冒充、Rhino 執行播放器 JS 解簽章與 n 參數、PO Token 介面 | 證明方案 B 屬「偽造驗證／繞簽章」，不採 |
| YouTube 服務條款 https://www.youtube.com/static?template=terms | 當日版本 | 一手（官方條款） | 禁止下載、規避技術措施、自動化存取；允許「透過嵌入式 YouTube 播放器播放影片」 | B 違反；C 是條款允許的路 |
| YouTube API Services Developer Policies https://developers.google.com/youtube/terms/developer-policies | 當日版本 | 一手（官方政策） | III.D.1 不得偽裝 API 用戶端身分；III.D.7 不得逆向未公開 API；III.E.1 不得下載／快取；III.I.5–7 不得改動廣告、播放器或拆分影音 | B 違反；4.2／4.3 的限制 |
| YouTube Required Minimum Functionality https://developers.google.com/youtube/terms/required-minimum-functionality | 當日版本 | 一手（官方規範） | 嵌入播放器以 Referer 表明身分；WebView 用 `baseUrl` 設 Referer；值為 App ID（Apple 用 Bundle ID）；不疊遮罩；最小 200×200；可見才自動播放 | 4.2 的 Referer／origin、遮罩、接下一集設計 |
| YouTube IFrame Player API https://developers.google.com/youtube/iframe_api_reference | 當日版本 | 一手（官方文件） | `enablejsapi`、`origin`、`playsinline`、`seekTo`／`getCurrentTime`、錯誤碼 2/5/100/101/150/153 | 4.2 播放與錯誤處理 |
| W-202 實測（`docs/W-201-ios-spider-local-proxy.md`「實作結果（W-202）」） | worktree webhtv-w202，task/W-202 | 本專案實測 | 經 9978 只能播約 75 秒；Android 走 FongMi 抽取器 | 排除繼續走 9978／直連 |

- 成熟專案對照：NewPipe 本身即方案 B 的代表，並提供 PO Token 介面、註明不帶 token 時部分格式會失效（`YoutubeStreamExtractor.java:1632-1651` 註解），B 路線長期不穩，也佐證不採。
- 論文／部落格：此題由條款與工單邊界決定，額外技術文章不會改變結論，未再蒐集。

## 9. 未驗證／風險
- FongMi 5.8.4（versionCode 584）的確切原始碼未公開；第 1 節以官方最新公開 commit 123cc086（5.8.3）為準。
- 官方 repo 只部分下載，「官方全 repo 沒有設定 PoTokenProvider／setFetchIosClient」未全域確認（已確認的是 `Source.java`、`YouTube.java`、`NewPipeImpl.java`）。
- 2. 的 iOS 現況依程式碼推論，未在 Simulator 實測。
- 未上架 App Store 的 Bundle ID 當 Referer 是否被 YouTube 接受，未驗證（4.2）。
- WKWebView 嵌入播放器的 PiP、AirPlay、背景播放支援度未驗證。
- 嵌入播放器是否出廣告、畫質上限由 YouTube 決定。
- googlevideo 網址有效期長度未實測（方案 C 不用直連，無影響）。

## Recovery anchor
- 目標：W-209 設計稿，Reviewer 核准後 Manager 轉使用者決定。
- 狀態：第 2 版（回應 #4537 F1、F2 與兩個小問題），待 Reviewer 複審。
- 下一步：Reviewer 複審；核准後通知 Manager。
