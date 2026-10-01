# Ponytail audit（2026-10-01）

- 指令：`/ponytail:ponytail-audit`，掃描基準 `ios-poc` `e9160234`。
- 範圍：iOS 移植的部分——`ios/Sources/WebHTVCore`、`ios/WebHTVApp/Sources`、`ios/WebHTVApp/Python`、iOS 用的 `scripts/` 與 `.github/workflows/`（約 2.8 萬行）。不含上游衍生的 Android 程式（`app/`、`catvod/`、`quickjs/`、`chaquo/`、`android-release.yml` 等），它們受上游合併規則管。
- 做法：三個子代理平行掃（Core、App、scripts／workflow），每項附 grep 證據；排名最前與最容易誤判的項目由主 session 再抽查（第 1、2、5、9、13、18、20、21 項屬實）。其餘只採信子代理的證據。
- 只看過度設計，不看正確性、安全、效能。版本／SHA-256 釘選、二進位比對、schema 驗證等供應鏈檢查刻意不列。

## 處理狀態

狀態：**已做**（commit）、**延後**（這裡驗證不了）、**待決定**（使用者先前的決定或使用者看得到的改變）、**待 ABI**（要升 runtime ABI 版本）、**未排入**（不需要決定，留給下一批）、**不做**（查證後不成立或不划算）。

| # | 標籤 | 項目 | 約省行數 | 狀態 |
|---|---|---|---|---|
| 1 | delete | `RuntimePackManifest.swift` 整個檔（IOS-POC-13 已撤銷，沒有呼叫者） | 763＋測試 467 | 待決定（IOS-POC-12 是使用者要求完成的） |
| 2 | delete | `MPVProbeView`（9C 算繪原型，只有 Debug 入口卻編進 Release） | 535 | **已做** `8bfe875a` |
| 3 | shrink | 兩個 MPVKit workflow 抽成可重用 workflow | 100 | 延後：要實際跑 MPVKit 建置 workflow 才能驗證，而它會發布 prerelease |
| 4 | delete | `spider.py` 的 urllib `requests` 備援 | 80 | 待 ABI（`python.host`） |
| 5 | delete | `MPVBoot` 與 Debug 啟動 print | 73 | **已做** `8bfe875a` |
| 6 | yagni | `SpiderRuntime` 5 個沒人呼叫的方法 | 48 | 待 ABI（`catvod.result`） |
| 7 | yagni | `RuntimeABI.capabilities` 等只給第 1 項用的表 | 37 | 跟第 1 項一起決定 |
| 8 | shrink | `Playback` struct 拆成 9 欄又組回去 | 30 | **已做** `f26ccae6`；行為差別見下 |
| 9 | delete | `SpiderPortability`、`Entry.portability`／`origin`、`portedClasses` | 28 | **已做** `1ea1c732`；稽核分類與原 JAR 改成 `ported` 旁的註解 |
| 10 | shrink | `MacCMSXMLDecoder` 10 個欄位變數 → 一個字典 | 25 | **已做** `f26ccae6` |
| 11 | shrink | 首頁來源選單改用 `SiteChoiceList` | 25 | 待決定：`SiteChoiceList` 帶桌布與半透明列底，首頁選單的樣式會變 |
| 12 | delete | `PythonLiveCheck.run()` | 25 | **已做** `8bfe875a` |
| 13 | yagni | 引擎可用性判斷（兩個引擎一直都開放） | 22 | **已做** `8bfe875a` |
| 14 | delete | 只有測試在用的 public 符號（`skipTargetMs` 等） | 21 | **部分已做** `1ea1c732`：刪 `CookieJar.all`／`clear`；`sessionOverride` 同 commit 刪除（寫入但從不讀）。保留 `skipTargetMs`、`plan(mediaPlaylist:)`、`PlayURL.isEmpty`（Android `Url.isEmpty` 語意）、`bundled(bundle:)`：都是測試切面，刪掉只是把同一行搬進測試 |
| 15 | shrink | `WebHTVConfig` 的站台篩選 | 20 | **已做**（commit 2，部分）：刪掉和 `nativeCMSSites` 完全相同的 `supportedSites`、`isSupported` 與沒人呼叫的 `cspSpiderSites`；只有測試用的 `drpySpiderSites`、`spiderSites(resolvedBy:)` 保留 |
| 16 | native | `CryptoHost` 的 CommonCrypto 雜湊與 HMAC → CryptoKit | 16 | **已做** `3fd68923`；AES／DES 仍走 `CCCrypt`，HMAC 補了已知向量測試 |
| 17 | delete | `DrpyEngine.rule(at:)`、`notADrpyRule` | 16 | **已做** `8bfe875a` |
| 18 | yagni | `HLSAdTimeline.resolve` 的 `direct:` 等參數與 `Variant.Kind` | 14 | 待決定：`resolve` 是 Android `MpvHlsProxy.resolveAdTimeline` 的移植，測試對應 `MpvHlsAdblockTest`；刪掉這兩個分支等於刻意跟 Android 分岔 |
| 19 | yagni | release workflow 的 tag 推送觸發 | 13 | 待決定（使用者在 `5a488f7a` 刻意加回） |
| 20 | delete | Prepare Python build phase 重複的 module map 迴圈 | 12 | **已做** `8bfe875a` |
| 21 | shrink | 設定頁重複的「加入設定來源」對話框 → `ConfigView` 那份 | 11 | **已做** `f26ccae6`；多了網址鍵盤 |
| 22 | shrink | release workflow 第二次 `update_sidestore_source.py` 與 `ajv` | 11 | 延後：要跑一次發布才能驗證 |
| 23 | shrink | `MediaSniffer` 一路傳的 `keywords:`／`exclusions:` | 10 | **已做** `f26ccae6`；`isCandidate` 的兩個參數在 ponytail review 後另一個 commit 拿掉（兩個測試傳的也都是預設清單） |
| 24 | shrink | 兩個引擎各一份的 `[audio]` 診斷 | 10 | 不做：每個引擎仍要自己的去重狀態，抽出來只省兩三行 |
| 25 | shrink | `VodView.playNext` → `step(forward: true)` | 9 | **已做** `f26ccae6`；已查證 `take` 與 `miss == nil` 同一個判斷，兩者等價 |
| 26 | delete | `webhtv_runtime.diagnostics()` | 8 | 待 ABI（與第 4 項同一次） |
| 27 | shrink | 播放畫面兩個相同的訊息泡泡 → `bubble(_:)` | 8 | **已做** `f26ccae6` |
| 28 | stdlib | 觀看記錄手寫的時:分:秒 → `Duration.formatted` | 8 | 待決定：分鐘會補零（5:03 → 05:03） |
| 29 | shrink | workflow 對 patch 原始碼的 grep | 8 | 延後：CI workflow |
| 30 | shrink | Python 抓取／建置腳本重複的下載與驗證 | 8 | 延後：要重新下載整包 payload 才能驗證 |
| 31 | delete | `WatchHistoryStore.remove(key:)`、`clear()` 不分來源的版本 | 8 | **已做** `1ea1c732`（連同只測它們的那條測試） |
| 32 | delete | `AdBlockList.blocked`／`.inert` | 7 | **已做** `1ea1c732`；測試改為數 JSON 規則數 |
| 33 | yagni | `capabilities.trackSelection`（兩個引擎都是 true） | 5 | **已做** `1ea1c732`；ponytail review 後 `PlaybackEngineCapabilities` 改成 `supportsAirPlay` |
| 34 | shrink | `WatchHistory.reidentified` 重列 17 個欄位 | 5 | **已做** `f26ccae6`；`key` 改成 `public internal(set) var` |
| 35 | stdlib | 手寫的 Duration 轉數字 | 5 | **已做** `3fd68923`；`/ .milliseconds(1)`、`/ .seconds(1)`，`HLSAdSkipper.seconds(_:)` 刪除 |
| 36 | shrink | CI 的「Prepare CPython payload」步驟 | 4 | **不做**：這一步是必要的。沒有 module map 時，Xcode 在跑 Prepare Python phase 之前就先做模組相依掃描而失敗；2026-10-01 在原本的 HEAD 上重現過 |
| 37 | yagni | `audit_spider_jars.py` 沒用到的常數與參數 | 4 | **已做** `53de9b61`：刪 `CATVOD_HELPERS`、`classify` 的 `jar_types`；review 後 `NATIVE_SUFFIXES` 內嵌 |
| 38 | yagni | `SpiderPackManifest.Script` 沒人讀的欄位 | 4 | **已做** `1ea1c732` |
| 39 | yagni | `spider_pack.py` 沒人傳的參數 | 3 | **已做** `53de9b61`：刪 `--origins`、`--min-host-api`；review 後拿掉每支 script 的 `minHostApi` 鍵（已沒有來源） |
| 40 | shrink | SHA-256 hex 同一行寫三次 → `DrpyEngine.digest` | 3 | **已做** `f26ccae6`；`SpiderPackStore.sha256` 刪除 |
| — | yagni | `PlaybackEngineSelection.available`／`isAvailable` 與 router 的 `available:`（第 13 項之後 App 一律傳全部引擎） | 12＋測試 | **已做** `1ea1c732`；三條只測「只有原生」的測試一起刪除 |

## 已做的兩個 commit

- **commit 1 `8bfe875a`（刪死碼）**：第 2、5、12、13、17、20 項，約 -700 行。`swift test` 621/621（少的一條是刪掉的 `notADrpyRule` 訊息測試）；模擬器 Debug、generic iOS Release build 通過，`MPVProbeView` 帶來的 13 條 OpenGL ES／Sendable warning 消失。刪掉 module map 迴圈後，map 由 `fetch_python_ios.sh` 重新產生。
- **commit 2 `f26ccae6`（縮減）**：第 8、10、15、21、23、25、27、34、40 項。
  - 第 8 項唯一的行為差別：播放器已經開著時，WebHome 頁面的 JS 又呼叫播放——以前 `fullScreenCover(item:)` 會因為 id 改變而關掉再重開播放器，現在在原地換片。App 自己的換集（自動下一集、上一集／下一集）本來就不經過這裡。
  - 第 21 項：對話框改由 `ConfigView` 呈現（設定頁在它的 TabView 裡），開之前清空欄位，和原本設定頁的行為相同，另外多了網址鍵盤。
  - 驗證：`swift test` 621/621；模擬器 Debug、generic iOS Release build 通過（`WebHTVConfig.swift:23` 的 warning 是既有的，這次重新編譯才出現）。模擬器（iPhone 17 Pro Max、iOS 26.3，本機測試 server 的 port 8766 副本）實測：設定頁的「加入設定來源」對話框由 `ConfigView` 正常跳出、欄位為空；「播放器」選單只有「原生播放器」「MPV」，沒有「（尚未開放）」（commit 1）；詳情頁點集數開啟播放器（第 8 項）；拖到結尾後自動下一集走 `step(forward: true)`：`D… finished (end)` → `resolve E… prefetched 0ms` → `started … E… on MPV`（第 25 項）；最後一集播完由 `onPlaylistFinished` 關閉播放器、回到詳情頁（第 8 項）。第 27 項的泡泡只在失敗或換核心提示時出現，這次沒有觸發。真機未驗證。

- **commit 3（`isCandidate` 參數）**：commit 2 的 ponytail review 發現 `isCandidate` 的 `keywords:`／`exclusions:` 也沒有人傳預設值以外的清單（兩個測試傳的就是預設值），拿掉並改兩個測試。測試檔不在 commit 2 的 guard 範圍內，所以分開提交。

- **第二批 commit `1ea1c732`（2026-10-01）**：第 9、14（部分）、31、32、33、38 項與 `PlaybackEngineSelection.available`。`swift test` 616/616（刪掉 5 條只測被刪分支／API 的測試）；模擬器 Debug、generic iOS Release build 通過；真機未驗證。第一次 `finish` 被 guard 的 whitespace 檢查擋下（`SpiderRuntime.swift` 檔尾多一個空行），修正後才提交。

- **第二批 commit B `3fd68923`（2026-10-01）**：第 16、35 項。先在舊的 CommonCrypto 程式上補 HMAC 已知向量（sha256／md5／sha1／空 key，原本的測試算了 HMAC 卻沒比對），確認是綠的才換成 CryptoKit。`swift test` 616/616；`xcodebuild -scheme WebHTVCore -destination generic/platform=iOS` 通過。整個 App 的模擬器 Debug、generic iOS Release build 之後在 `53de9b61` 補跑通過，改到的三個檔沒有 warning。ponytail-review：沒有可刪的。真機未驗證。
- **第二批 commit C `53de9b61`（2026-10-01，第二批收尾）**：第 37、39 項與本文件。`py_compile` 通過；`spider_pack.py build` 新舊版產出的 pack（manifest 與 8 支 script）逐位元相同；`audit_spider_jars.classify` 與 `jar_inventory`（`.so`、改名的 ELF）用合成輸入實跑。ponytail-review 找到兩項並套用（內嵌 `NATIVE_SUFFIXES`、拿掉 `minHostApi` 鍵）。腳本沒有接上 CI，也沒有用真的 JAR 壓縮檔重跑 audit。

## 建議的下一批

- 第二批已全部做完（第 16、35、37、39 項見上一節）。剩下的都需要決定、升 ABI 或跑 CI。
- 一次升 ABI 版本一起做：第 4、26 項（`python.host`）、第 6 項（`catvod.result`）。
- 等使用者決定：第 1（連帶第 7）、11、18、19、28 項。
- 要能跑 CI 才做：第 3、22、29、30 項。
