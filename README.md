# WebHTV（iOS）

WebHTV 是 iPhone 上的影音用戶端：讀取使用者自己提供的 TVBox／CatVod 格式設定檔，瀏覽、搜尋各站台的影片，並用 App 內建的兩個播放核心——原生播放器（AVPlayer）與 MPV——播放。

這個版本移植自本 repo `main` 分支的 Android 版 WebHomeTV（基於 [FongMi](https://github.com/FongMi/TV)／CatVod 生態二次開發），只存在於 **`ios-poc` 分支**。Android 版的說明請看 `main` 分支。

> **狀態**：個人側載使用的開發中版本，透過 SideStore 安裝，沒有上架 App Store 或 TestFlight。多數播放修正只有自動測試、模擬器或編譯的證據，**還沒有在真機上驗收**（見[驗證狀態](#驗證狀態)）。

## 目錄

- [功能](#功能)
- [安裝](#安裝)
- [開發](#開發)
- [文件](#文件)
- [授權與第三方元件](#授權與第三方元件)
- [免責聲明](#免責聲明)

## 功能

App 不內建任何設定檔或影片來源。第一次開啟會顯示「尚未載入設定」，用左上角「使用網址」或右上角「匯入設定」加入第一個設定來源；載入成功後才會出現分頁，之後可以在設定頁加入其他來源。

### 設定來源

- **遠端網址**：設定頁「加入設定來源」，填名稱與 `http://` 或 `https://` 開頭的網址。
- **本機檔案**：「匯入本機檔案」，從「檔案」App 選一個 `.json`。
- **多個來源**：「已存來源」可切換、改名、刪除；每個來源各自記住上次選的站台。
- **多倉設定**：加入多倉設定網址後，各倉列在「已存來源」並依倉分組，可直接切換；重開 App 會記得上次使用的倉。
- **更新**：每次啟動先顯示快取，再在背景重新下載；下載或驗證失敗時保留上一份可用的設定。
- **新增站台**：設定頁「新增站台（自動偵測）」貼上網址，App 先判斷常見的影視採集介面，判斷不到再試常見的網頁版型，驗證過首頁與詳情才加入（最多約 45 秒，可取消）。手機上加的站跟著目前的設定來源保存，可改名或刪除，站點選單標示為本機站，使用 http 的標示未加密。

設定檔是 JSON，可以帶註解（JSONC）；不是明碼時，App 會自動嘗試 TVBox 常見的加密格式（base64 與 AES 包裝）。App 讀 `sites`、`lives`、`parses`、`flags`、`ads`、`rules`、`spider` 這幾個鍵。只有爬蟲站的設定也能用：第一次加入時會先取得該設定需要的爬蟲包再檢查。

### 支援的站台類型

| 類型 | 說明 |
|---|---|
| type 0／1 | MacCMS XML／JSON |
| type 4 | CatVod 遠端 API；`api` 也可以寫成相對設定檔的路徑 |
| type 3 `csp_*` | 只支援已用 JavaScript 重寫、在 JavaScriptCore 上執行的類別，由「官方爬蟲包」提供（見下方）。包裡沒有的類別不會出現在站台清單 |
| type 3 `.js` | drpy2 規則或 CatVod／TVBox JS Spider；drpy 引擎與函式庫從設定檔旁的 `./drpy_libs/` 下載，並以 SHA-256 釘死版本 |
| type 3 `.py` | 由 App 內嵌的 CPython 3.13 執行，附 requests、beautifulsoup4、lxml、pyquery、pycryptodome 等套件 |

- iOS **不執行** Android 的 JAR／DEX。`csp_*` 是參照反編譯結果重寫的等效實作；程式藏在加密 `.so` 裡的類別不會移植。
- **官方爬蟲包**：`csp_*` 腳本不在 App 本體裡，而是由 repo 的 `spider-pack/official/` 發布，App 驗過每個檔案的 SHA-256 才採用，更新不必等 App 改版。全新安裝或按「重設」後，要在首頁提示或「設定 › 爬蟲工具」下載；同一處可手動檢查更新、查看版本說明、重設。只有按下時才連網，播放中下載的版本等關閉播放器後才套用。各包的說明在 [`spider-pack/CHANGELOG.md`](spider-pack/CHANGELOG.md)。
- drpy 與 Python 腳本只會從設定檔**自己的來源**載入，而且必須是 HTTPS（同主機、同 port），單一腳本最大 1 MiB。所以用本機匯入的設定、或 `http://` 的設定網址時，這兩類站台無法使用。
- 設定檔旁的 `./spiders/manifest.json` 可以提供 Spider 相容性套件（設定頁顯示為「設定檔相容包」，取代或新增 `csp_*` 腳本），每支腳本驗過 SHA-256 才會採用。

### 瀏覽、搜尋、片庫

- 五個分頁：**首頁、搜尋、片庫、下載、設定**。
- 首頁：分類、子分類與篩選（子分類與篩選預設收合，切換分類會重新收合，收合時已選條件仍有效）、捲到底自動載入下一頁（某一頁載入失敗或回空時再往下捲會重試，連續 3 次才停）、下拉重新整理；首頁的「搜尋此來源的影片」只搜目前站台（IOS-UI-A4）。
- 篩選：Spider 站、提供篩選的採集站（type 0／1）與 type 4 站，以及設定了篩選規則的網頁站，分類頁都會顯示篩選列，翻頁時保留條件。設定檔為站台指定的分類清單會生效，只顯示清單上的分類並照清單順序（IOS-POC-62～64）。
- 片單裡的資料夾項目（例如片單、歌單）可以點進去看清單，再打開影片（IOS-POC-60）。片單項目沒有影片編號時改用片名搜尋找到詳情。
- 排行榜類來源：點任一部片會自動到其他來源搜尋它來播放。
- **直播**：首頁的「直播」入口讀設定檔的 `lives`，依群組列出頻道。播放中在畫面中間上下滑動換台；一條線路卡住約 30 秒會自動試下一條，全部失敗時停下提示、不自動跳台；可從線路選單手動切換。會記住上次的頻道，常看的可加入收藏。
- 外觀：Cinematic Minimal 版面，底部固定薄型分頁列（iOS 16 使用系統原生分頁列）；設定可選深色或淺色（預設深色），播放器維持黑底（IOS-UI-A／A3）。
- 「全站台搜尋」：同時搜尋設定裡所有可搜尋的站台，可依站台篩選結果、停止或重試。關鍵字先轉成簡體送出，跟原輸入不同時再用原輸入搜一次，結果合併。
  - 結果依片名與關鍵字的接近程度排序，同一系列的各季排在一起；開始捲動或點選後順序固定，新結果改用提示列，點了才重排（W-312）。
  - 同一部片在多個站台都有時合併成一張卡並標示來源數，點進去選來源；輸入框下方列出最近 12 筆搜尋，可單筆刪除或全部清除（W-315）。
  - 「站點健康排序」開啟時，狀況較好的站先問；「略過一直失敗的站」（預設開）會暫時略過最近連續搜尋失敗 3 次以上的站，一週後或在進度列手動重試時再問；「站點順序與搜尋」可關閉個別站台不參與（W-316）。
- **站點順序**：設定 ›「站點順序與搜尋」按「排序」拖曳，拖過的站固定排在最前（左滑可取消），其餘依站點健康或設定檔順序；首頁換站清單與全站台搜尋都照這個順序，可一鍵「恢復設定檔順序」。每個設定來源分開存（W-317）。
- **站點健康**：站點清單的圓點依平常瀏覽、搜尋、詳情與播放的結果標示（綠色正常、黃色不確定、紅色常失敗），記錄只存在這支手機；設定頁「檢查來源」可主動檢查各站（IOS-POC-41）。
- 詳情頁：「立即播放」從上次看的線路與集數接著播；可切換線路，集數多時分段顯示。
- **追更新**：詳情頁可按「追更」，有新集數時片庫「記錄」頁的追更區顯示「+N 集」、片庫分頁出現徽章，播到最新一集後提示自動清除；影集出新一季時會提示並可直接搜尋。開著 App 時最多每 30 分鐘檢查一次，播放中不檢查（W-313）。
- 「片庫」分頁分「記錄」與「收藏」，預設記錄（IOS-UI-A3 起；IOS-POC-48 原本預設收藏）。收藏是作品層級（設定來源＋站台＋作品），在詳情頁右上角加入或取消；收藏頁以海報顯示，可搜尋名稱、演員、導演、類型、年份，並列出觀看進度與已下載集數。來源可確認已完結的影集看完最終集後會自動移出收藏，可按「復原」。原站台不在目前設定時保留並標示「來源不可用」。收藏、觀看記錄、下載各自刪除，互不連帶（IOS-POC-48）。
- 「記錄」只顯示目前設定來源的記錄；記錄保留 60 天，所有來源合計最多 500 筆。同一集超過 10 秒才續播，接近結尾視為看完、從頭播。
- 來源的簡體中文一律以台灣繁體顯示（內建 OpenCC 字典，只影響畫面）。

### 播放器

- **兩個內建核心**：「原生播放器」（AVPlayer，預設）與「MPV」（libmpv）。設定頁「預設播放器」可改；播放中也能從控制列手動切換，只影響這次播放，會接在同一個位置。
- **自動換核心**：開播失敗、播放途中失敗或開播逾時時，每次開播最多自動換到另一個核心一次，不會來回切換；沒有網路或來源解析失敗時不換。偵測到 H.266（VVC）影片時直接改用 MPV。
- **自動換線**：點播時某條線路試過所有恢復方式仍無法播放，會換到下一條線路的同一集並接著原本的位置；換線一輪最多約 2 分鐘，可按「停止換線」。
- **集數**：播完自動接下一集，並在快播完時預先解析下一集；有「上一集」「下一集」按鈕。快看完時會在背景先準備下一集開頭（每集最多 20 MB，開啟系統「低數據模式」時不做），換集幾乎立即開播。控制列上方顯示片名與集數。可以標記片頭、片尾（整部片共用），播放時自動跳過。
- **速度**：0.5×～3×，設定頁「預設播放速度」用於開新的影片。原生播放器播不了的 2.5×、3× 會自動交給 MPV。
- **智慧去廣**（預設開）：HLS 點播偵測到插入的廣告片段時自動跳過，判斷不確定時照常播放。
- **子母畫面**：播放中離開 App 時自動進入，兩個核心都支援；沒有手動開子母畫面的按鈕。
- **AirPlay**：原生播放器可投放畫面與聲音；MPV 的控制列也能選 AirPlay，但只送聲音（畫面留在手機上），AirPlay 斷線時暫停。
- **影片網站網址**：可直接用 App 播放器播放（設定裡可關閉）；需要驗證或年齡確認的影片會停下並提供改用官方 App 開啟，這類影片不提供下載。
- **音軌與字幕**：影片內嵌的軌道；字幕 panel 另有「線上字幕」，可編輯搜尋文字（自動帶入番號或片名）向 Subtitle Cat、射手網（網頁，不需設定）、OpenSubtitles 或射手網（API）搜尋（後兩者需在「設定 › 線上字幕來源」輸入自己的 API key／token，存在鑰匙圈），點選現成的 SRT 後下載並立即套用，兩個核心共用；同一面板可做時間軸校正。下載的字幕只保留到這次播放結束，不建立字幕庫（IOS-POC-45、45B、45C、45G）。來源播放回應附的字幕（`subs`）與網頁播放頁裡的 `<track>`／VTT／SRT／ASS 字幕也會列成可選的外掛字幕（IOS-POC-45H、45I）。時間軸會扣除智慧去廣留在播放器裡的廣告，可「對齊上一句／下一句」（IOS-POC-45E）。內嵌字幕標示 CC、SDH、強制字幕；沒有內嵌字幕時會說明原因並提供「改用 MPV」（IOS-POC-45F）。MPV 字幕使用內建中文字型（IOS-POC-45D）。
- **操作**：控制列 5 秒自動隱藏，點畫面叫回；±10 秒；左右拖曳調整進度，左半邊上下拖曳調亮度、右半邊調音量。
- 有背景音訊；需要網頁嗅探的播放網址會在畫面外用 WKWebView 找出影片網址。
- **全域解析接口**（設定檔的 `parses`，IOS-POC-56）：來源回 `jx:1`、站台或播放結果帶 `playUrl`（`json:`、`parse:名稱`、網頁解析網址），或線路屬於設定的 `flags` 時，交給設定的解析接口。支援 type 0 網頁解析與 type 1 JSON 解析；沒有指定時照 Android 的預設「超級解析」：符合線路的 JSON 接口同時送出，網頁接口放在同一頁一起嗅探，最多 15 秒，誰先解出用誰。其他類型（type 2、3）與 Android JAR 在本機提供的接口會明確顯示「尚未支援」。直接的媒體網址不經過解析。沒有解析選單，也不會在播放失敗時自動換下一個解析。

### 離線下載

- 詳情頁可下載單集，或用「全部下載」下載本線路從觀看進度那一集（含）起尚未下載的集數，畫質用設定的預設值，每集輪到時才解析（IOS-POC-47、49）。
- 一集只存一份，最高 1080p：「智慧 1080p」（預設，優先 HEVC、SDR、合理的低位元率）、「最省空間」（最高 720p；來源沒有 720p 以下版本時會說明，改以「智慧 1080p」下載，IOS-POC-52 F21）、「1080p 高畫質」；60fps 版本要另外開啟。原生播放器與 MPV 共用同一份，離線播放不連網；有 DRM 的影片不能下載（IOS-POC-47）。
- 可在背景繼續，App 重開後接回；最多同時 3 集，其餘排隊（IOS-POC-50）。需要 App 內建轉址服務的來源例外：要開著 App 才會下載，離開 App 會暫停、回來後自動繼續。
- 預設只用 Wi-Fi。「允許使用行動網路下載」切換後立即套用到所有未完成的下載；只有行動網路且未允許時顯示「等待 Wi-Fi」（IOS-POC-49）。
- 預估容量用實際片段大小推算，下載一成後再依已下載的片段修正；讀不到片段大小時退回來源宣告的位元率並註明。開始前的空間檢查與多工預留用同一個數字（IOS-POC-51）。
- 「下載」分頁依影集分組，點標題展開各集；每組可全部暫停、全部繼續（暫停與失敗的集數）、刪除全部（IOS-POC-57）。每一集也能單獨暫停、繼續、刪除；「看完後自動刪除」（預設開）只在真正播到結尾或片尾自動跳下一集後才刪，手動拖到片尾不算；關閉後所有下載都不會自動刪除（IOS-POC-52 F1、F13）。
- 設定 › 儲存空間（IOS-POC-53）：「掃描無效檔案」列出舊版本或中斷留下的殘留檔（檔名、原因、大小），確認後才刪，不動離線下載、來源、記錄與收藏；「初始化」經兩次確認後刪除所有資料、下載、網站資料與線上字幕金鑰，回到剛安裝的狀態並關閉 App。

### iOS 版沒有的功能

彈幕、本機字幕檔匯入，以及 Android 版的管理頁、遠端託管、一鍵同步、雲端硬碟連結檢測、本機 HTTP API、DLNA 都沒有。WebHome 只有「設定 → 開發者 → WebHome 橋接驗證」的內建展示頁，不會載入設定檔站台的 `homePage`。Infuse 等外部播放器已經移除。

### 已知限制

- App 一啟動就啟用不混音的音訊工作階段（子母畫面需要），會中斷其他 App 正在播的音樂；來電等中斷結束後不會自動續播。
- MPV 的 AirPlay 只送聲音，也沒有鎖定畫面的 Now Playing 與遠端控制；換到 MPV 播 2.5×／3× 之後，這次播放都會留在 MPV。
- App 全域允許明文 HTTP（ATS `NSAllowsArbitraryLoads`）；drpy 與 Python 腳本另外強制同源 HTTPS，相容性套件的 manifest 與腳本則必須是 HTTPS。
- 完整清單見 [`docs/IOS-POC-36-playback-acceptance-stability.md`](docs/IOS-POC-36-playback-acceptance-stability.md) 第九節。

### 驗證狀態

播放功能的驗收矩陣在 [`docs/IOS-POC-36-playback-acceptance-stability.md`](docs/IOS-POC-36-playback-acceptance-stability.md) 第四節（各狀態的項目數見該節的統計表），絕大多數項目只有模擬器、自動測試或編譯的證據。真機證據只有第五節列出的幾次使用者回報，較早的真機結果也大多因為之後改過程式而降級，所以近期的播放修正都不能算已經過真機驗收。需要真機確認的項目也列在同一份文件裡。

## 安裝

需求：**iPhone、iOS 16.0 以上**（不支援 iPad 與 Apple TV）。

1. 在 iPhone 上安裝並設定好 [SideStore](https://sidestore.io)。
2. 在 SideStore 加入這個來源：

   ```text
   https://raw.githubusercontent.com/st7833232/webhtv/ios-poc/source.json
   ```

3. 從來源安裝 WebHTV。

GitHub Release 上的 IPA 沒有簽章，由 SideStore 在裝置上重新簽署。最新版本與各版說明看 [`source.json`](source.json) 或 [Releases](https://github.com/st7833232/webhtv/releases)（`ios-v*` 開頭的才是 App；`mpvkit-*`、`ffmpeg-*` 是建置用的二進位）。`source.json` 有約 5 分鐘的快取，新版發布後可能要稍等才會出現在 SideStore。

## 開發

### 需求

- Apple silicon 的 Mac（模擬器用的 Python 原生套件只編了 arm64）。
- Xcode：本機以 Xcode 27.0 驗證，CI 用 GitHub `macos-26` runner；`ios/Package.swift` 是 swift-tools 6.2，所以至少要 Swift 6.2（最低 Xcode 版本沒有實測）。
- 主機端 `python3.13`（例如 `brew install python@3.13`，或用 `PYTHON_HOST` 指定），用來交叉編譯 pycryptodome、lxml。
- 第一次建置要有網路：MPVKit 的 xcframework（SwiftPM binary target）與 CPython payload 都是下載的，repo 裡沒有這些二進位檔。

### 專案結構

```text
ios/
├── Package.swift            SwiftPM 套件 WebHTVCore（iOS 16／macOS 14）
├── Sources/WebHTVCore/      與 UI 無關的核心：設定載入、CMS、搜尋、觀看記錄、HLS 去廣、
│   │                        嗅探、播放核心選擇與切換、台灣繁體顯示、WebHome 橋接、
│   │                        站點健康與順序、追更新（Follows/）、直播（Live/）
│   ├── Spider/              CatVod Spider runtime（JavaScriptCore、drpy、Python 來源、相容性套件、官方爬蟲包更新）
│   └── Resources/           runtime 自己的 JS（Spiders/：host.js 與兩個 bridge）、OpenCC 字典、字幕字型；
│                            SpiderBaseline/ 只留在 repo 給爬蟲包發布檢查用，不進 App
├── Spiders/                 官方爬蟲包的 csp_* JavaScript 原始檔
├── Tests/
│   ├── WebHTVCoreTests/     Swift Testing 單元測試
│   └── Python/              Python runtime 的主機端測試
├── Vendor/MPVKit/           MPVKit 1.0.0 的 Package.swift（只有 manifest，二進位由 SwiftPM 下載）
└── WebHTVApp/               Xcode App：SwiftUI 畫面、AVPlayer 與 MPV 播放核心、內嵌 Python 的啟動
    └── WebHTVApp.xcodeproj  scheme：WebHTVApp
```

其他與 iOS 有關的位置：

- `third_party/python-ios-lock.json`、`third_party/mpv-ios-lock.json`：CPython 與 libmpv／FFmpeg 的版本、網址、SHA-256。
- `third_party/mpv-ios/`：WebHTV 對 libmpv、FFmpeg 的修補、授權原文與重建說明。
- `scripts/fetch_python_ios.sh`、`scripts/build_python_ios_native.sh`：下載 CPython payload、交叉編譯原生 Python 套件。
- `scripts/spider_pack.py`：產生與檢查 Spider 相容性套件（設定檔旁的 `spiders/`）。
- `scripts/runtime_pack.py`、`spider-pack/official/`、`spider-pack/CHANGELOG.md`：官方爬蟲包的建包工具、發布位置與版本說明。
- `scripts/ios_adskip_sim/`：模擬器量測用的本機 CMS＋HLS server。
- `.github/workflows/ios-*.yml`：IPA 發布（`ios-sidestore-release.yml`）、官方爬蟲包發布（`ios-spider-pack.yml`）、iOS 16 相容建置檢查（`ios16-compat-check.yml`）、libmpv 與 FFmpeg 重建。

### 建置

第一次建置不需要手動步驟：scheme `WebHTVApp` 的 build pre-action 會在 Xcode 規劃建置之前執行 `scripts/fetch_python_ios.sh`，下載 CPython payload、產生 module map，並交叉編譯這次建置的 SDK 需要的原生套件（剛 clone 或 lock 改變後的第一次建置會多花幾分鐘）。pre-action 只在透過 scheme 建置時執行，它的輸出也不會出現在 build log；如果建置時找不到 `Python.xcframework`，手動執行一次看原因：

```bash
scripts/fetch_python_ios.sh
```

模擬器 Debug build（destination 要用模擬器的 UDID；同名的模擬器有好幾個 runtime 時，用 `name=` 會被 xcodebuild 拒絕）：

```bash
xcrun simctl list devices available
```

```bash
xcodebuild -project ios/WebHTVApp/WebHTVApp.xcodeproj -scheme WebHTVApp -configuration Debug -destination 'platform=iOS Simulator,id=<UDID>' build
```

不簽章的裝置 Release build（和 CI 相同；`EXPANDED_CODE_SIGN_IDENTITY=-` 不能省，內嵌的 CPython framework 需要一個簽署身分）：

```bash
xcodebuild -project ios/WebHTVApp/WebHTVApp.xcodeproj -scheme WebHTVApp -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO EXPANDED_CODE_SIGN_IDENTITY=- build
```

注意：

- 專案沒有設定 `DEVELOPMENT_TEAM`。要直接裝到自己的裝置，需在本機自行指定，不要 commit。
- Xcode 27 建置時可能把 `project.pbxproj` 升級成較新的 `objectVersion` 並重排內容，這個改動要還原、不要 commit。
- 用 `scripts/fetch_python_ios.sh --force` 重抓 payload 後，若 `import Python` 解析失敗，刪掉 DerivedData 裡舊的 `Python.framework` 再建置。

### 測試

核心邏輯的單元測試（在 Mac 上執行，Swift Testing）：

```bash
swift test --package-path ios
```

Python runtime 的主機端測試（`swift test` 無法執行內嵌的 CPython，因為它沒有 macOS slice）：

```bash
python3.13 -m unittest discover -s ios/Tests/Python
```

需要連網的測試預設跳過，要設環境變數才會執行，例如 `WANG_MOVIE_URL`、`SWEEP_CONFIG` 加 `SWEEP_BASE`（詳見各測試檔）。Python 站、子母畫面等行為要在模擬器上驗；iPhone 模擬器沒有子母畫面，要用 iPad 模擬器。

### 發布

發布由 GitHub Actions 的 `iOS SideStore Release`（[`.github/workflows/ios-sidestore-release.yml`](.github/workflows/ios-sidestore-release.yml)）完成：

1. 把要發布的 commit push 到 `ios-poc`。
2. 手動觸發 workflow，填版本號（`version`）、build（`build_number`）與版本說明（`release_notes`）；版本號與 build 留空時用 `project.pbxproj` 的 `MARKETING_VERSION`、`CURRENT_PROJECT_VERSION`。也可以推送 `ios-v<版本>-b<build>` 格式的 tag。
3. Workflow 在 `macos-26` 建置不簽章的 IPA，建立 tag 與 GitHub Release，確認公開下載的檔案與建置結果一致，再把 `source.json` 推回 `ios-poc`（release commit 只改 `source.json`）。

`source.json` 以版本號辨識新版，同一個版本號重新發布不會被 SideStore 當成更新，所以每次都要用新的版本號。發布紀錄見 [`docs/IOS-POC-11-sidestore-release.md`](docs/IOS-POC-11-sidestore-release.md)。

官方爬蟲包另由 `iOS spider pack`（[`.github/workflows/ios-spider-pack.yml`](.github/workflows/ios-spider-pack.yml)）發布：手動觸發時填比已發布更大的序號（`sequence`）、版本（`version`）與必填的版本說明（`release_notes`），workflow 建包、驗證、把說明寫進 [`spider-pack/CHANGELOG.md`](spider-pack/CHANGELOG.md)，再推回 `ios-poc` 的 `spider-pack/official/`。版本說明只寫功能與修正，不寫站名、設定檔名、站數或成人內容。

### 協作規則

工作規則以 [`AGENTS.md`](AGENTS.md) 為主，iOS 專屬的補充寫在 [`docs/current-task-state.md`](docs/current-task-state.md)，要點：

- 改程式前先 `bash .codex/scripts/task_guard.sh start --id <task-id> --mode <lane> --scope <path>...`，完成後用 `task_guard.sh finish --verified <證據> --commit-message <訊息> --no-tag` 做一個原子 commit。
- 範圍預設封閉：只改宣告的路徑，不碰開始前就有的未提交改動；iOS 工作不修改 Android 的 `app/`。
- 有 Ponytail 時，每個程式修改都要先對最終 diff 跑 `ponytail:ponytail-review`。
- 調整版號、建立 tag、發布、push 都要先取得 repo 擁有者授權。

## 文件

- [`docs/current-task-state.md`](docs/current-task-state.md)：目前狀態與交接（先讀最上方的 Current handoff）。
- [`docs/IOS_SPIDER_RUNTIME_SPEC.md`](docs/IOS_SPIDER_RUNTIME_SPEC.md)：Spider runtime 的 ABI 與宿主能力。
- [`docs/IOS-POC-17-dual-internal-player.md`](docs/IOS-POC-17-dual-internal-player.md)：AVPlayer＋MPV 雙核心的決策。
- [`docs/IOS-POC-36-playback-acceptance-stability.md`](docs/IOS-POC-36-playback-acceptance-stability.md)：播放驗收矩陣、已知限制與真機待驗清單。
- [`docs/IOS-POC-11-sidestore-release.md`](docs/IOS-POC-11-sidestore-release.md)：SideStore 發布流程與每次發布的紀錄。
- [`docs/IOS-POC-7A-python-runtime.md`](docs/IOS-POC-7A-python-runtime.md)、[`docs/IOS-POC-37-python-runtime-dependency-expansion.md`](docs/IOS-POC-37-python-runtime-dependency-expansion.md)：內嵌 CPython 與第三方套件。
- [`docs/IOS-POC-9A-mpv-license-provenance.md`](docs/IOS-POC-9A-mpv-license-provenance.md)、[`third_party/mpv-ios/README.md`](third_party/mpv-ios/README.md)：MPV／FFmpeg 的授權與重建。
- [`docs/IOS-POC-61-spider-decouple.md`](docs/IOS-POC-61-spider-decouple.md)：官方爬蟲包與 App 本體分離（爬蟲工具、更新、重設）。
- [`docs/IOS-POC-41-source-health-diagnostics.md`](docs/IOS-POC-41-source-health-diagnostics.md)：站點健康圓點與「檢查來源」。
- [`docs/W-311-ios-multi-repo-config.md`](docs/W-311-ios-multi-repo-config.md)：多倉設定。
- [`docs/W-312-ios-search-improvements.md`](docs/W-312-ios-search-improvements.md)、[`docs/W-315-ios-search-merge-history.md`](docs/W-315-ios-search-merge-history.md)、[`docs/W-316-ios-search-site-participation.md`](docs/W-316-ios-search-site-participation.md)：全站台搜尋的排序、同片合併與紀錄、略過與參與開關。
- [`docs/W-317-ios-site-order.md`](docs/W-317-ios-site-order.md)：自訂站點順序。
- [`docs/W-313-ios-update-notifications.md`](docs/W-313-ios-update-notifications.md)：追更新與新季提示。

各任務的文件都在 `docs/IOS-POC-*.md` 與 `docs/W-*.md`；較舊的交接文件以 `docs/current-task-state.md` 為準。

## 授權與第三方元件

- 本 repo 以 [GNU GPL v3](LICENSE.md) 授權。
- MPV 使用 MPVKit 1.0.0 的 LGPL 產品（libmpv 以 `-Dgpl=false` 建置，mpv v0.41.0、FFmpeg n8.1.2）。其中 Libmpv 與 Libavformat 兩個 xcframework 由本 repo 加上修補後重建，發布在本 repo 的 prerelease；其餘是上游 MPVKit 的二進位。各元件的授權原文在 [`third_party/mpv-ios/licenses/`](third_party/mpv-ios/licenses/)。
- 內嵌的 CPython 3.13 來自 BeeWare Python-Apple-support；CPython 與各 Python 套件的授權記在 [`third_party/python-ios-lock.json`](third_party/python-ios-lock.json)。
- 台灣繁體顯示用的 OpenCC 字典為 Apache License 2.0。
- MPV 字幕使用的中文字型是 Noto Sans CJK TC 的子集，改名為 WebHTV Subtitle CJK，授權為 SIL Open Font License 1.1；來源、製作方式與授權原文在 [`ios/Sources/WebHTVCore/Resources/SubtitleFont/`](ios/Sources/WebHTVCore/Resources/SubtitleFont/)。
- App 內目前沒有開源授權畫面。上述授權資訊不是正式的授權稽核，也不是法律意見。

## 免責聲明

WebHTV 是基於開源生態二次開發的技術學習與研究專案，軟體本身完全免費，不提供任何付費服務、影視內容、直播源、介面源、資源儲存或內容分發。

本軟體僅供技術學習、研究與個人測試使用，請在下載、安裝或試用後 24 小時內自行移除。繼續使用本軟體所產生的一切行為與後果，由使用者自行承擔。

本軟體不內建、不販售、不散布任何影視資源，也不對使用者自行加入的介面、站源、外掛、腳本、連結、雲端硬碟資源或第三方服務內容負責。使用者應遵守所在地的法律法規，尊重版權方與內容提供者的合法權益，不得將本軟體用於侵權、盜版、散布非法內容或其他違法用途。

嚴禁任何個人或組織以本軟體名義進行販售、引流、收費維護、會員服務、廣告變現、預裝或綑綁銷售，或其他任何形式的獲利行為。對於將本軟體內建於電視盒、機上盒、付費套餐或商業服務中販售、推廣的行為，本專案明確反對並予以譴責。
