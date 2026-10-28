# W-209 iOS 自己處理 youtube.com 網址（設計，待使用者核准）

> 狀態：設計稿，**只寫設計、不實作、不改 App**。Reviewer 核准後由 Manager 轉使用者決定是否開實作單。
> 範圍邊界（工單）：不補 PO Token、不偽造驗證、不繞簽章；若 FongMi 本身用了這類手段要明說並建議不採。

## 白話摘要

- Android 的「YouTube｜PY」站能播，不是腳本厲害，而是腳本出錯後丟回一個 `youtube.com/embed/…` 網址（`parse: 1`），FongMi 內建的 YouTube 功能再把它變成可直接播的串流。
- FongMi 這個內建功能是靠 NewPipe 函式庫：**假裝自己是 YouTube 官方 Android／visionOS App 去要影片資料，並在手機上執行 YouTube 播放器的 JavaScript 來算出簽章和 n 參數**，才拿到能播的 googlevideo 直連網址；播放時還把 User-Agent 冒充成 YouTube Android App。
- 這些正是工單禁止的「偽造驗證、繞簽章」，也違反 YouTube 服務條款（禁止規避技術措施、禁止自動化存取、禁止下載）。所以**不建議把 FongMi 的做法照搬到 iOS**。
- 建議改用 YouTube 條款明文允許的方式：遇到 YouTube 影片網址時，在 App 內開 **YouTube 官方嵌入式播放器**（IFrame Player）播放。能起播、能拖進度，但畫面是 YouTube 自己的播放器，不走我們的 AVPlayer／MPV，也可能有廣告、有些影片作者禁止嵌入就播不了。
- 使用者要決定：(1) 接受官方嵌入播放器（建議）；(2) 維持現狀不做；(3) 照搬 FongMi（不建議，違反工單邊界與條款）。

## 1. FongMi 內建 YouTube 處理的實際流程（本 repo Android 原始碼）

### 1.1 什麼時候會進來
- `app/src/main/java/com/fongmi/android/tv/player/Source.java:40-50`：播放前的抽取器清單，最後一個是 `new Youtube()`（:49）。
- `player/extractor/Youtube.java:65-68` `match()`：網址 host 含 `youtube.com` 或 `youtu.be` 就接手。
- `Source.java:91` `fetch(Result, playerType)`：
  - 找到抽取器就把 `parse` 改成 0，交給 `Youtube.fetch(result)`。
  - `:102`、`:106`：YouTube 抽取失敗或回空字串，且原本 `parse == 1`，就退回原網址、`parse = 1`（交給網頁嗅探）。
- 也會在別的地方被叫：`Source.java` 中 `MpdSanitizer.hasLimitedYoutubeAudio()` 判定 jar 給的 MPD 音訊受限、且 Referer 是 `youtube.com/watch` 時，改用 `new Youtube().fetch(referer)` 重抓（`Source.java:111-119`）。
- 播放清單：`Youtube.java:276-316` `Parser`，網址含 `list=` 時把整個 YouTube 播放清單展開成集數（`Source.java:65-66`）。

### 1.2 取哪個 client（NewPipe Extractor v0.26.3，`gradle/libs.versions.toml:47`）
- `Youtube.java:61`：`NewPipe.init(NewPipeImpl.get(), …)`；`impl/NewPipeImpl.java`：用 OkHttp 送出所有請求，預設 UA 是桌面 Firefox 140；收到 429 就丟 `ReCaptchaException`。
- `Youtube.java:72` / `:77`：`StreamInfo.getInfo(url)` → NewPipe `YoutubeStreamExtractor.onFetchPage`（v0.26.3 commit `caae86c943857cc6e1a762e3488d6a14e9cf7800`，`extractors/YoutubeStreamExtractor.java:838-862`）：
  1. `fetchAndroidClient`：以 InnerTube `ANDROID` client（`ClientsConstants.java:100-111`，clientVersion `21.03.36`）向 YouTube 要 player response。**這是冒充 YouTube 官方 Android App。**
  2. `fetchIosClient`：只有呼叫端打開 `setFetchIosClient(true)` 才做；本 repo 沒打開（`git grep fetchIosClient -- app` 無結果）。
  3. `fetchVisionOsClient`：一律做，冒充 `VISIONOS` client（`ClientsConstants.java:116-120`）。
  4. `fetchWebClientMetadataAndSetThumbnails`：`WEB` client 取標題、縮圖等資料。
- PO Token：NewPipe 有 `PoTokenProvider` 介面（`YoutubeStreamExtractor.java:843-856`），**本 repo 沒設定**（`git grep PoTokenProvider -- app` 無結果），所以沒帶 PO Token。

### 1.3 簽章與 n 參數（重點：屬於「繞簽章」）
- `YoutubeStreamExtractor.java:1311-1345` `buildAndAddItagInfoToList`：
  - 格式資料沒有直接 `url`、只有 `signatureCipher` 時，呼叫 `YoutubeJavaScriptPlayerManager.deobfuscateSignature()` 算出簽章。
  - **每個串流網址**都會經過 `getUrlWithThrottlingParameterDeobfuscated()` 解 n 參數；程式註解寫明「n 解不出來，串流網址會回 HTTP 403」。
  - 兩者都是下載 YouTube 播放器 JS，再用 Mozilla Rhino（`utils/JavaScript.java:3-4`）在手機上執行其中被抽出的函式（`YoutubeJavaScriptPlayerManager.java:164`、`:264`）。
- 結論：FongMi 能播 YouTube，**依賴冒充官方 client＋執行 YouTube 播放器 JS 解簽章／n 參數**。這就是工單說的「繞簽章」類手段。

### 1.4 怎麼選 itag、怎麼組 DASH
- `Youtube.java:87-89`：直播 → `getLive()`（`:111-113`，有 HLS 用 HLS，否則用 DASH MPD 網址）；隨選 → `getMpd()`。
- `Youtube.java:115-120` `getMpd()`：
  - 只留「有 indexRange 與 initRange」的 video-only 與 audio 串流（`:216-228`）。
  - 兩邊都沒有時退回單檔（muxed）串流中「最高解析度、再比位元率」那一個（`:122-124`）。
  - **不挑單一 itag**：把所有符合的 video、audio 各自做成一個 AdaptationSet／Representation（`:140-141`、`:145-175`），每個 Representation 帶 `BaseURL`（googlevideo 直連）＋ `SegmentBase indexRange/Initialization range`（`:177-182`），交給播放器（ExoPlayer）自己挑畫質；使用者 10/27 看到的 itag 137（1080p H.264 mp4）就是 ExoPlayer 選中的那一路。
  - 整份 MPD 用 `data:application/dash+xml;base64,…` 的 data URI 交出（`:119`、`:234-236`）。
- 字幕：`Youtube.java:184-214`，只收 VTT；TTML 網址改 `fmt=vtt`。
- 播放 header：`Source.java:122-126`，MPD 是 YouTube 的話，User-Agent 改成 `com.google.android.youtube/21.02.35 (Linux; U; Android 14) gzip`（**冒充 YouTube Android App**）。
- MPV：`Source.java:127-131`，用 `MpdEdlResolver` 把 MPD 轉成 MPV 的 EDL。

### 1.5 網址有效期與刷新
- googlevideo 網址帶 `expire=` 時間戳（一般約數小時；本次未實測確認長度）。
- FongMi **沒有刷新機制**：MPD 是起播時一次產生的 data URI；網址過期後要重新進入播放（重新呼叫 `Source.fetch`）才會重抓。
- W-202 實測（`docs/W-201-ios-spider-local-proxy.md` 末節「實作結果（W-202）」，worktree `/Users/chengchenchih/GIT/webhtv-w202`）：腳本經 9978 拿到的網址有每個網址的讀取配額，音訊讀到約 1 MB 後一律 403，所以 iOS 走 9978 只能播開頭約 75 秒；Android 能播是因為走了上面 FongMi 自己的抽取流程。

## 2. iOS 現況（`parse: 1` 的 youtube.com 網址目前怎麼走）

依程式碼推論，**未實測**：
- `ios/Sources/WebHTVCore/SourceClient.swift:152-191` `target(from:…)`：
  - `GlobalParse.plan()`（`GlobalParse.swift:98-136`）：若設定沒有全域解析接口且沒有 `jx`，`parse: 1` 而 `playUrl` 為空 → `.none`。
  - 接著 `parse != 0` → `MediaSniffer.shared.sniffWithSubtitles(page:)`：用隱藏 WKWebView 開 `youtube.com/embed/…`，12 秒內等符合關鍵字的媒體請求。
- `MediaSniffer.swift:108` 的關鍵字含 `/videoplayback`，`blob:`／`data:` 會被忽略（`:508`）。YouTube 嵌入播放器用 MSE 播放，實際抓的是 googlevideo `videoplayback` 的「純影像或純音訊、帶 range」片段。
- 所以結果只有兩種，兩種都不能正常看：
  1. 12 秒內嗅不到（例如嵌入頁要使用者點擊才開始載入）→ 播放失敗。
  2. 嗅到第一個 `videoplayback` 請求 → 交給 AVPlayer／MPV 播一個只有畫面或只有聲音、而且有讀取配額的片段，播一下就 403。
- iOS 沒有任何 YouTube 專用處理；直播清單遇到 YouTube 網址直接標「不支援」（`Live/LivePlaylistParser.swift:360-373`）。

## 3. 方案比較

| | A 不做 | B 照 FongMi 移植 | C 官方嵌入播放器（建議） |
|---|---|---|---|
| 做法 | 維持 2. 的行為 | 在 iOS 以 InnerTube 冒充 ANDROID／VISIONOS client 取 player response，用 JavaScriptCore 執行 YouTube 播放器 JS 解簽章／n 參數，組 DASH 或 HLS 交 MPV／AVPlayer；UA 冒充 YouTube App | 偵測到 YouTube 影片網址時，不嗅探，改在 App 內以全螢幕 WKWebView 開官方 IFrame Player（`https://www.youtube.com/embed/<id>?playsinline=1&enablejsapi=1&origin=…`） |
| 能不能起播＋拖到中段 | 不能 | 能（直到 YouTube 改版或擋下） | 能（`seekTo`、播放器自帶進度條） |
| 條款／工單邊界 | 無問題 | **違反**：冒充 client＝偽造驗證；執行播放器 JS 解簽章／n＝規避技術措施；YouTube 條款禁止規避、禁止自動化存取、禁止下載 | 符合：YouTube 條款明文允許「透過嵌入式 YouTube 播放器播放影片」 |
| 維護 | 無 | 很高：YouTube 每幾週改播放器 JS 與 client 版本，NewPipe 要一直追；iOS 沒有現成 Swift 版，要自己追或嵌 JS 版 | 低：官方 API 穩定 |
| 畫質／體驗 | — | 我們的播放器、可選畫質、無廣告 | YouTube 自己的播放器 UI；可能有廣告；畫質由 YouTube 自動 |
| 失敗情況 | 一律失敗 | YouTube 擋 client 或改 JS 時全站失效；可能觸發 429／帳號風險 | 作者禁止嵌入（錯誤 101／150）、私人或已刪除（100）時播不了，要明確提示 |
| 與我們播放器的功能 | — | 續播紀錄、PiP、AirPlay、MPV 都可用 | 續播紀錄需用 `getCurrentTime()` 自己存；PiP／AirPlay 取決於 WKWebView 的 HTML5 video 支援（未驗證）；MPV 不適用 |
| 工作量 | 0 | 大（數天以上，且長期追版） | 中小（一個網址判斷＋一個嵌入播放畫面＋錯誤提示＋續播紀錄） |

決定：**C**。B 的核心手段正是工單明列不得採用的範疇，即使 FongMi 這樣做，也不跟進；A 對使用者沒有價值。

## 4. 建議設計（方案 C）

### 4.1 判斷條件（只影響 YouTube）
- 在 `SourceClient.target(from:…)` 決定要嗅探之前加一個判斷：選中的播放網址 host 是 `youtube.com`／`*.youtube.com`／`youtu.be`／`youtube-nocookie.com`，且能取出 11 字元影片 ID（`/embed/<id>`、`/watch?v=<id>`、`/shorts/<id>`、`youtu.be/<id>`、`/live/<id>`）。
- 符合 → 回傳新的播放目標種類「YouTube 嵌入」（帶影片 ID 與起始秒數），不進 `MediaSniffer`、不進 AVPlayer／MPV。
- 不符合（含 googlevideo 直連、其他站的網址）→ 完全照現在的流程，不變。
- 判斷用和 `LivePlaylistParser.isYouTube`（`:369-373`）一致的 host 規則，抽成一個共用函式，兩邊一起用。

### 4.2 播放畫面
- 新增一個全螢幕 YouTube 嵌入播放畫面（SwiftUI 包 WKWebView）：載入官方 IFrame Player API，`playerVars`: `playsinline=1`、`start=<續播秒數>`；`origin` 設為 App 用的固定 https 來源，並設 Referer，避免錯誤 153。
- 播放器視窗至少 200×200（官方要求）。
- 不注入任何改變 YouTube 行為的腳本，不擋廣告、不改 UA、不讀取 googlevideo 網址。只用官方 API：`seekTo`、`getCurrentTime`、`getDuration`、`onStateChange`、`onError`。
- 續播：每 5 秒及離開時用 `getCurrentTime()` 寫入現有播放紀錄；下次以 `start=` 從該秒起播。
- 錯誤：`onError` 101／150 → 提示「這部影片的作者不允許在其他 App 播放」；100 → 「影片不存在或已設為私人」；2／5／153 → 「YouTube 播放器無法載入」；並提供「用 YouTube App／Safari 開啟」按鈕（`UIApplication.open`）。
- 播放清單（`list=`）：第一版只播該網址指定的影片；整個清單展開成集數不做（FongMi 的 `Parser` 也是靠 NewPipe 抓 YouTube 頁面，屬自動化存取）。

### 4.3 不做的事（明列）
- 不補 PO Token、不冒充任何 YouTube client、不改 UA 成 YouTube App。
- 不執行或解析 YouTube 播放器 JS、不解簽章／n 參數、不取 googlevideo 直連。
- 不下載、不快取影片內容；不擋廣告。
- 不經 9978 本機代理播 YouTube（W-202 已證實只能播約 75 秒）。

## 5. 對其他站的影響
- 只有播放網址本身是 YouTube 影片頁／嵌入網址時才會改走新畫面；其他所有站、所有直連媒體、解析接口流程都不經過新判斷之後的分支。
- 若有站點腳本自己回 googlevideo 直連（例如 W-202 的 YouTube｜PY 正常路徑經 9978），**不受影響**，照舊交 MPV（仍只有約 75 秒，這是 W-202 已記錄的限制）。
- 直播清單裡的 YouTube 頻道目前標「不支援」；第一版不改（可另開單評估用同一嵌入畫面）。
- Android 不變。

## 6. 驗收（實作單用）
- Simulator＋實機各一（實機以 SideStore IPA，不直接安裝）：
  1. YouTube｜PY 站任一影片：點播後 10 秒內起播、有畫面有聲音。
  2. 拖到影片中段（例如 50%）後 10 秒內繼續播放，至少再播 60 秒不中斷（對照 W-202 的 75 秒限制）。
  3. 離開再進入，從上次位置續播（誤差 ≤ 10 秒）。
  4. 一部作者禁止嵌入的影片：顯示 4.2 的提示與「用 YouTube 開啟」按鈕，App 不卡住。
  5. 回歸：任選一個一般 m3u8 站、一個 `parse: 1` 非 YouTube 站、一個經 9978 的 PY 站，行為與實作前相同。
- 單元測試：網址判斷函式（各種 YouTube 網址形式取出 ID、非 YouTube 網址回 nil、`googlevideo.com` 回 nil）。

## 7. 回退
- 變更集中在「YouTube 網址判斷＋嵌入播放畫面」兩處；回退＝ revert 該 commit，或移除 `target(from:)` 中的新判斷，YouTube 網址就回到現在的嗅探流程。
- 不改資料格式；續播紀錄沿用現有欄位，回退後舊紀錄仍可讀。

## 8. 研究紀錄

| 來源 | 版本／存取 | 證據等級 | 支持的結論 | 對決策的影響 |
|---|---|---|---|---|
| 本 repo `app/src/main/java/com/fongmi/android/tv/player/extractor/Youtube.java`、`player/Source.java`、`impl/NewPipeImpl.java` | `origin/ios-poc` 3f499399，2026-10-28 | 一手程式碼 | 1.1–1.5 的流程、DASH 組法、UA 冒充 | 確認 FongMi 能播的機制 |
| TeamNewPipe/NewPipeExtractor `v0.26.3` | commit `caae86c943857cc6e1a762e3488d6a14e9cf7800`，2026-10-28 shallow clone | 一手程式碼 | ANDROID／VISIONOS client 冒充、Rhino 執行播放器 JS 解簽章與 n 參數、PO Token 介面未設定 | 證明方案 B 屬「偽造驗證／繞簽章」，不採 |
| YouTube 服務條款 https://www.youtube.com/static?template=terms | 2026-10-28 | 一手（官方條款） | 禁止下載、規避技術措施、以自動化工具存取；允許「透過嵌入式 YouTube 播放器播放影片」 | 方案 B 違反條款；方案 C 是條款明文允許的路 |
| YouTube IFrame Player API https://developers.google.com/youtube/iframe_api_reference | 2026-10-28 | 一手（官方文件） | `enablejsapi`、`origin`、`playsinline`、`seekTo`／`getCurrentTime`、錯誤碼 2/5/100/101/150/153、最小 200×200 | 4.2 的播放與錯誤處理設計 |
| W-202 實測（`docs/W-201-ios-spider-local-proxy.md`「實作結果（W-202）」） | worktree webhtv-w202，task/W-202 | 本專案實測 | 經 9978 只能播約 75 秒；Android 走 FongMi 抽取器 | 排除「繼續走 9978／直連」作為解法 |

- 成熟專案對照：NewPipe 本身即為 B 路線的代表，並明確提供 PO Token 介面，表示不帶 token 時部分格式會失效（`YoutubeStreamExtractor.java:1632-1651` 註解）——B 路線長期穩定性差，也佐證不採。
- 論文／部落格：此題的決策由條款與工單邊界決定，額外技術文章不會改變結論，未再蒐集。

## 9. 未驗證／風險
- 2. 的 iOS 現況是依程式碼推論，未在 Simulator 實測。
- 方案 C 在 WKWebView 中的 PiP、AirPlay、背景播放支援度未驗證；實作單第一步先做最小原型確認。
- 嵌入播放器是否出廣告、畫質上限由 YouTube 決定，App 無法控制。
- googlevideo 網址有效期長度未實測（對方案 C 無影響，C 不使用直連）。

## Recovery anchor
- 目標：W-209 設計稿，Reviewer 核准後 Manager 轉使用者決定。
- 狀態：設計稿完成（2026-10-28），待 Reviewer 審。
- 下一步：Reviewer 審查本檔；核准後 work done W-209 通知 Manager。
