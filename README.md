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
- **更新**：每次啟動先顯示快取，再在背景重新下載；下載或驗證失敗時保留上一份可用的設定。

設定檔必須是純 JSON，App 只讀 `sites`、`ads`、`rules` 三個鍵（`lives`、`parses` 等不讀），而且至少要有一個 `api` 為 http(s) 的 type 0／1／4 站。

### 支援的站台類型

| 類型 | 說明 |
|---|---|
| type 0／1 | MacCMS XML／JSON |
| type 4 | CatVod 遠端 API |
| type 3 `csp_*` | 只支援已用 JavaScript 重寫、在 JavaScriptCore 上執行的類別：AppGet、AppQi、App99、App3Q、Bili、JianPian（`JPianAmns` 是它的別名）、XBPQ、XYQHiker。其他類別不會出現在站台清單 |
| type 3 `.js` | drpy2 規則或 CatVod／TVBox JS Spider；drpy 引擎與函式庫從設定檔旁的 `./drpy_libs/` 下載，並以 SHA-256 釘死版本 |
| type 3 `.py` | 由 App 內嵌的 CPython 3.13 執行，附 requests、beautifulsoup4、lxml、pyquery、pycryptodome 等套件 |

- iOS **不執行** Android 的 JAR／DEX。`csp_*` 是參照反編譯結果重寫的等效實作；程式藏在加密 `.so` 裡的類別不會移植。
- drpy 與 Python 腳本只會從設定檔**自己的來源**載入，而且必須是 HTTPS（同主機、同 port）。所以用本機匯入的設定、或 `http://` 的設定網址時，這兩類站台無法使用。
- 設定檔旁的 `./spiders/manifest.json` 可以提供 Spider 相容性套件（取代或新增 `csp_*` 腳本），每支腳本驗過 SHA-256 才會採用。

### 瀏覽、搜尋、片庫

- 五個分頁：**首頁、搜尋、片庫、下載、設定**。
- 首頁：分類（有子分類的可收合）、篩選（只有 Spider 站台提供）、捲到底自動載入下一頁、下拉重新整理；首頁的「搜尋影片」只搜目前站台。
- 「全站台搜尋」：同時搜尋設定裡所有可搜尋的站台，可依站台篩選結果、停止或重試。關鍵字先轉成簡體送出，跟原輸入不同時再用原輸入搜一次，結果合併。
- 詳情頁：「立即播放」從上次看的線路與集數接著播；可切換線路，集數多時分段顯示。
- 「片庫」分頁分「收藏」與「記錄」，預設收藏。收藏是作品層級（設定來源＋站台＋作品），在詳情頁右上角加入或取消；收藏頁以海報顯示，可搜尋名稱、演員、導演、類型、年份，並列出觀看進度與已下載集數。來源可確認已完結的影集看完最終集後會自動移出收藏，可按「復原」。原站台不在目前設定時保留並標示「來源不可用」。收藏、觀看記錄、下載各自刪除，互不連帶（IOS-POC-48）。
- 「記錄」只顯示目前設定來源的記錄；記錄保留 60 天，所有來源合計最多 500 筆。同一集超過 10 秒才續播，接近結尾視為看完、從頭播。
- 來源的簡體中文一律以台灣繁體顯示（內建 OpenCC 字典，只影響畫面）。

### 播放器

- **兩個內建核心**：「原生播放器」（AVPlayer，預設）與「MPV」（libmpv）。設定頁「預設播放器」可改；播放中也能從控制列手動切換，只影響這次播放，會接在同一個位置。
- **自動換核心**：開播失敗、播放途中失敗或開播逾時時，每次開播最多自動換到另一個核心一次，不會來回切換；沒有網路或來源解析失敗時不換。
- **集數**：播完自動接下一集，並在快播完時預先解析下一集；有「上一集」「下一集」按鈕。可以標記片頭、片尾（整部片共用），播放時自動跳過。
- **速度**：0.5×～3×，設定頁「預設播放速度」用於開新的影片。原生播放器播不了的 2.5×、3× 會自動交給 MPV。
- **智慧去廣**（預設開）：HLS 點播偵測到插入的廣告片段時自動跳過，判斷不確定時照常播放。
- **子母畫面**：播放中離開 App 時自動進入，兩個核心都支援；沒有手動開子母畫面的按鈕。
- **AirPlay**：只有原生播放器提供。
- **音軌與字幕**：影片內嵌的軌道；字幕 panel 另有「線上字幕」，可編輯搜尋文字（自動帶入番號或片名）向 Subtitle Cat、射手網（網頁，不需設定）、OpenSubtitles 或射手網（API）搜尋（後兩者需在「設定 › 線上字幕來源」輸入自己的 API key／token，存在鑰匙圈），點選現成的 SRT 後下載並立即套用，兩個核心共用；同一面板可做時間軸校正。下載的字幕只保留到這次播放結束，不建立字幕庫（IOS-POC-45、45B、45C、45G）。
- **操作**：控制列 5 秒自動隱藏，點畫面叫回；±10 秒；左右拖曳調整進度，左半邊上下拖曳調亮度、右半邊調音量。
- 有背景音訊；需要網頁嗅探的播放網址會在畫面外用 WKWebView 找出影片網址。

### iOS 版沒有的功能

直播、解析介面（`parses`）、下載、彈幕、本機字幕檔匯入，以及 Android 版的管理頁、遠端託管、一鍵同步、雲端硬碟連結檢測、本機 HTTP API、DLNA 都沒有。WebHome 只有「設定 → 開發者 → WebHome 橋接驗證」的內建展示頁，不會載入設定檔站台的 `homePage`。Infuse 等外部播放器已經移除。

### 已知限制

- App 一啟動就啟用不混音的音訊工作階段（子母畫面需要），會中斷其他 App 正在播的音樂；來電等中斷結束後不會自動續播。
- MPV 沒有 AirPlay，也沒有鎖定畫面的 Now Playing 與遠端控制；換到 MPV 播 2.5×／3× 之後，這次播放都會留在 MPV。
- App 全域允許明文 HTTP（ATS `NSAllowsArbitraryLoads`）；drpy 與 Python 腳本另外強制同源 HTTPS，相容性套件的 manifest 與腳本則必須是 HTTPS。
- 完整清單見 [`docs/IOS-POC-36-playback-acceptance-stability.md`](docs/IOS-POC-36-playback-acceptance-stability.md) 第九節。

### 驗證狀態

播放功能的驗收矩陣在 [`docs/IOS-POC-36-playback-acceptance-stability.md`](docs/IOS-POC-36-playback-acceptance-stability.md) 第四節（各狀態的項目數見該節的統計表），絕大多數項目只有模擬器、自動測試或編譯的證據。真機證據只有第五節列出的幾次使用者回報，較早的真機結果也大多因為之後改過程式而降級，所以近期的播放修正都不能算已經過真機驗收。需要真機確認的項目也列在同一份文件裡。

## 安裝

需求：**iPhone、iOS 17.0 以上**（不支援 iPad 與 Apple TV）。

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
├── Package.swift            SwiftPM 套件 WebHTVCore（iOS 17／macOS 14）
├── Sources/WebHTVCore/      與 UI 無關的核心：設定載入、CMS、搜尋、觀看記錄、HLS 去廣、
│   │                        嗅探、播放核心選擇與切換、台灣繁體顯示、WebHome 橋接
│   ├── Spider/              CatVod Spider runtime（JavaScriptCore、drpy、Python 來源、相容性套件）
│   └── Resources/           內建 JS Spider（Spiders/）與 OpenCC 字典（OpenCC/）
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
- `scripts/spider_pack.py`：產生與檢查 Spider 相容性套件。
- `scripts/ios_adskip_sim/`：模擬器量測用的本機 CMS＋HLS server。
- `.github/workflows/ios-*.yml`：IPA 發布、libmpv 與 FFmpeg 重建。

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

1. 在 `project.pbxproj` 調高 `MARKETING_VERSION`、`CURRENT_PROJECT_VERSION`，commit 並 push 到 `ios-poc`。
2. 手動觸發 workflow（或推送 `ios-v<版本>-b<build>` 格式的 tag）。
3. Workflow 在 `macos-26` 建置不簽章的 IPA，建立 tag 與 GitHub Release，確認公開下載的檔案與建置結果一致，再把 `source.json` 推回 `ios-poc`。

`source.json` 以版本號辨識新版，同一個版本號重新發布不會被 SideStore 當成更新，所以每次都要調高版本號。發布紀錄見 [`docs/IOS-POC-11-sidestore-release.md`](docs/IOS-POC-11-sidestore-release.md)。

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

各任務的文件都在 `docs/IOS-POC-*.md`；較舊的交接文件以 `docs/current-task-state.md` 為準。

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
