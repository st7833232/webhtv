# IOS-POC-41 — Source Health / Diagnostics（assessment）

## Recovery anchor

- 目標：使用者 2026-10-02「開始 Source Health / Diagnostics 的 assessment」。起因是 IOS-POC-39 第七節：113 個 XBPQ 項目中 90 個是網站本身不通，App 卻只顯示「沒有內容」，使用者分不出是網站死了還是程式問題。
- 範圍：只做 assessment（`AGENTS.md` §7 的 design-research gate），**不改程式**。task guard `IOS-POC-41`（`assessment`），路徑：本文件、`docs/current-task-state.md`、`docs/IOS-POC-39-xbpq-rule-coverage.md`（第 7.9 節加連結）。
- 狀態與唯一下一步：見第 10 節。

## 1. 要解決的問題

- 兩份設定（2026-09-30 量測，`docs/SITE-AVAILABILITY-2026-09-30.md`）提供給 App 的來源共 368 站（`wang-movie.json` 111、`wang-sex.json` 257），**只有 98 站（約 27%）讀得到影片位元組**。來源清單裡大多數站點開了是空的或播不了。
- IOS-POC-39 第七節把 113 個 XBPQ 項目逐站歸因：C（網站不通）90、B（網站通但瀏覽鏈斷在分類／片單／詳情／播放）13、D（沒有搜尋設定）6、E（搜尋正常）4。原因都查得出來，但要靠 Mac 上的測試、curl、`dig` 與人工判讀，使用者在 App 裡看不到。
- 使用者真正要的判斷是三種：**網站本身不通**（等網站或換設定，App 改不了）、**網站通但 App 取不到**（可能是 App 或規則的問題，值得回報）、**可以用**。

## 2. 現況：錯誤在哪裡被丟掉（程式位置）

| 位置 | 現在的行為 | 對診斷的影響 |
|---|---|---|
| `ios/Sources/WebHTVCore/Spider/Host/HTTPHost.swift` `HTTPHost.perform` | spider 的每個 HTTP 請求都經過這裡；失敗時回 `status: 0`、`body: ""`、`error: error.localizedDescription`（逾時是 `"timeout"`），HTTP 狀態碼與標頭有回傳 | `URLError` 的錯誤碼在這裡被轉成本地化字串，之後只剩文字 |
| `ios/Sources/WebHTVCore/Resources/Spiders/host.js` `host.req` | 把 `__http.request` 的結果原樣回給 spider | spider 自己決定要不要看 `error`／`status` |
| `XBPQ.js` `fetch`（第 182 行）等 spider | `host.get(...).body \|\| ''`：失敗就是空字串 | **DNS 失敗、TLS 錯誤、403、JS 跳轉頁全部變成「0 部」**；Swift 端只收到空列表，沒有錯誤 |
| `ios/Sources/WebHTVCore/SourceClient.swift` | CMS 站（type 0／1）的錯誤會丟出（`CMSClientError`、`URLError`）；spider 站回傳的空列表不是錯誤 | 只有 CMS 站有錯誤可顯示 |
| `ios/WebHTVApp/Sources/WebHTVApp.swift` `emptyState`（第 684～692 行） | 有錯誤時「載入失敗」＋`localizedDescription`；沒有錯誤又沒有片時「沒有內容／這個來源或分類沒有回傳任何項目。」 | spider 站一律落在「沒有內容」 |
| `ios/Sources/WebHTVCore/AggregateSearch.swift` `Outcome` | 全站台搜尋每站 `found`／`failed(String)`／`timedOut`／`busy` | 搜尋有逾時與失敗兩類，但沒有原因分類，也不保存 |
| `WebHTVApp.swift` `SiteChoiceList`（第 1481 行）與首頁來源選單 | 只列站名與目前選取的勾 | 沒有任何狀態資訊 |
| `ios/Sources/WebHTVCore/MediaSniffer.swift` `MediaProbe.classify` | 以 `Range: bytes=0-1023` 讀前 64 bytes，分成 `media`／`page`／`unknown` | 已經能判斷「播放網址不是影片」，可直接重用 |
| `ios/Tests/WebHTVCoreTests/SourceClientTests.swift` `sweepsEveryDrivableSourceThroughTheAppPath` | 只在 `swift test`（macOS）跑；首頁或第一個分類 → 第一部詳情 → 播放網址 → `MediaProbe`；8 站並行、每站 90 秒；結果分 `PLAYABLE`／`DEAD-MEDIA`／`NO-PLAY`／`NO-EPISODE`／`EMPTY`／`ERROR` | 檢查流程已經存在，但不在 App 裡，也不含 Python 站 |
| `ios/WebHTVApp/Sources/PythonLiveCheck.swift` `survey()` | 只在 DEBUG build 啟動 6 秒後自動跑；分階段（load → init → home → category → search → detail → player → media），以文字比對把錯誤分成 `site/network`、`dependency`、`policy`、`script` 等 | 只印到 console，Release 沒有 |

結論：**檢查流程（sweep）、媒體判斷（`MediaProbe`）、分階段與原因的概念（`PythonLiveCheck`）都已經有了，缺的是 (1) spider 失敗原因在 `HTTPHost` 之後被丟掉，(2) 沒有使用者能觸發、能看的入口，(3) 結果不保存。**

## 3. 本機實證（2026-10-02，個人熱點 `172.20.10.1`）

- **`URLSession` 對各類失敗丟出的錯誤碼**（macOS `swift` script，ephemeral session、逾時 12 秒，對 IOS-POC-39 C 類的真實網域）：

| 情況（站） | 結果 |
|---|---|
| NXDOMAIN（香蕉系列 `su-qq.vip`） | `URLError` −1003 `cannotFindHost` |
| SERVFAIL（精工厂） | −1003 `cannotFindHost`（與 NXDOMAIN 分不出來） |
| 自簽憑證（TaiAv2） | −1202 `serverCertificateUntrusted` |
| TLS 交握失敗（AV帝国） | −1200 `secureConnectionFailed` |
| 連線逾時（歐吉） | −1001 `timedOut` |
| 拒絕連線（癢癢） | −1004 `cannotConnectToHost` |
| Cloudflare 520（妻妹） | 早上 curl 是 520，這次 HTTP 200：**網站狀態幾小時內就會變** |

- **Cloudflare 挑戰**：Airav、sexBJcam、看AV 對 curl（iPhone UA）回 `HTTP/2 403`、`cf-mitigated: challenge`、`server: cloudflare`。但 IOS-POC-39 的 App 路徑探測裡，Airav 與 sexBJcam 用 spider 自己的請求拿得到片單、讀得到影片。**同一個站對不同請求的回應不同，所以檢查必須走 App 本身的請求路徑（spider 的標頭、cookie），不能另做一套通用的 HTTP 探測。**
- **網路環境決定結果**：公司網路（閘道 `10.1.207.254`）封鎖 gitlab.com 與大量網域（IOS-POC-37 第 15.4 節、IOS-POC-39 第 4.6 節：約 40 站 DNS 失敗），同一批站在個人熱點上一部分是好的。**在一個網路上判為「連不上」的站，換網路可能可以用。**

## 4. 外部證據（2026-10-02 存取）

### 4.1 相關專案的做法

- **本 repo 的 Android 端已經有被動的站點健康記錄**：`app/src/main/java/com/fongmi/android/tv/setting/SiteHealthStore.java`（commit `474cc04f3d16ecb6dab8ac260baec131660c2d88`，2026-06-06「feat: add site health ranking」；上游 FongMi HEAD `c616c0aa3613e87529791587a9f71b78c278c991` 沒有）。本機逐行讀過：
  - 只記錄使用者實際的操作，**不另外發請求**：`recordSearch`（成功與否、筆數、耗時、錯誤文字）、`recordDetail`、`recordPlay`；呼叫端是 `SiteViewModel.java:139-140、160-167`（搜尋）與兩個 `VideoActivity`（詳情、播放）。錯誤文字只截 120 字，**沒有分類原因**；被取消的搜尋不算失敗（`SiteViewModel.java:166`）。
  - key 是「設定 id（`VodConfig.getCid()`）＋`siteKey`」，存在 `Prefers` 的 `site_health`，保留 90 天。
  - 分數：播放 ×5、詳情 ×2、搜尋 ×1 的成功率，加上搜尋筆數、扣耗時，最後一次播放成功／失敗 ±18；轉成綠（GOOD）、黃（WARN）、紅（BAD）、灰（未知）點，顯示在 leanback 與 mobile 的 `SiteAdapter`。
  - `site_health_sort` 預設**開**（`Setting.java:478`）：來源清單、`CollectActivity` 的站序與搜尋結果依分數排序；站點彈窗排序另一個開關，預設關（`Setting.java:486`）。設定頁可清除。不會自動隱藏或刪除站。
  - **兩個缺口**：(1) 沒有記錄首頁／分類，所以首頁就失敗的站（IOS-POC-39 的 C 類大多如此）只能靠全站台搜尋留下記錄；(2) 搜尋只要沒有丟例外就記成「成功、N 筆」（`SiteViewModel.java:139、160`），回 0 筆也算成功；spider 若把網路失敗轉成空列表（iOS 的 `XBPQ.js` 就是如此；Android 原版 jar 的抓頁失敗處理沒有逐條確認），死站就不會被記成失敗，**多半只會是黃點**（只有搜尋記錄時分數約 12，低於綠點門檻 20、高於紅點門檻 −20）。逾時則算失敗（`withTimeout` 30 秒，`Constant.java:16`）。
- **上游與其他 TVBox 客戶端**：FongMi/TV（`c616c0aa…`）、takagen99/Box（`258a5fef61578869ae905ca230bdde9e99fc19a8`）、q215613905/TVBoxOS（`ab11d289e09963a9daf65ca7f6b7a9a8cbe184e1`）都沒有「源檢測／線路檢測」功能；後兩者的 `SearchCheckboxDialog` 只是選哪些站參加搜尋（檔名與字串層級的搜尋，沒有讀完整程式碼）。CatVodTVOfficial（GitHub 404）、OK影視、影視仓（閉源）：**UNVERIFIED**。
- **伺服器端工具** Liu-Bot24/tvbox-manager（README，C 級）：對 CMS 站手動逐站實際搜尋、讀詳情、讀一段 HLS；對 spider／JS／Python 站只報「資源可達」或「需電視端驗證」，並明說可達不等於能搜能播。印證：**spider 站只有實際跑它自己的請求才算數**。

### 4.2 平台與協定

- **Apple `URLError.Code`**（developer.apple.com/documentation/foundation/urlerror/code；iOS 27.0 SDK `NSURLError.h` 確認數值，A 級）：裝置離線 `notConnectedToInternet` −1009（以及 `dataNotAllowed`、`internationalRoamingOff`、`callIsActive`；`networkUnavailableReason` 說明是否因受限網路）；DNS `cannotFindHost` −1003、`dnsLookupFailed` −1006；逾時 `timedOut` −1001；連不上 `cannotConnectToHost` −1004；中途斷線 `networkConnectionLost` −1005；TLS `secureConnectionFailed` −1200、憑證 −1201～−1204；ATS 擋下 `appTransportSecurityRequiresSecureConnection` −1022（是 App 設定，不是網站死）；`cancelled` −999 不算失敗。`waitsForConnectivity` 預設 false 時離線立即失敗，檢查器要維持 false。第 3 節的實測與此一致。UNVERIFIED：DNS 卡住時會不會變成 −1001；−1004 分不出「拒絕」與「無法到達」。
- **Cloudflare 挑戰**（developers.cloudflare.com/cloudflare-challenges/challenge-types/challenge-pages/detect-response/，2026-05-05 更新，A 級）：`cf-mitigated: challenge` 是官方文件記載的可靠標記，所有挑戰頁都有，內容一律 `text/html`；挑戰需要 JavaScript，原生 HTTP 用戶端過不了，應歸為「瀏覽器驗證」而不是「網站死了」。`cf-ray`、`server: cloudflare` 只表示經過 Cloudflare，不是挑戰訊號；`<title>Just a moment...</title>` 只是沒有文件依據的備用判斷。挑戰的 HTTP 狀態碼文件沒寫（第 3 節實測是 403）。
- **Cloudflare 5xx**（官方各錯誤碼頁，A 級）：520 來源回應異常、521 來源拒絕 Cloudflare 連線、522 連來源逾時、523 連不到來源、524 來源 125 秒內沒回應、525／526 Cloudflare 與來源間 TLS 失敗、530 Cloudflare 解析不到來源主機。
- **健康檢查設計**（Azure Architecture Center「Health Endpoint Monitoring」ms.date 2026-09-24、「Circuit Breaker」；Google SRE book「Monitoring Distributed Systems」）：檢查要驗內容而不只看狀態碼；只做唯讀檢查；結果會因檢查地點而異（**裝置上的結果＝「這個網路、這個時間」**）；區分暫時性與持續性失敗，不要對不會成功的請求一直重試；結果帶時間戳快取，不要每次看畫面就重查；提供手動重查、不自動刪除；**先確認檢查器本身正常**（裝置在線）再判斷別人；只呈現可行動的結論。並行上限沒有文件給出具體數字，採用既有 sweep 的 8。
- **iOS 背景執行**（`BGTaskScheduler.submit`、`BGTaskRequest.earliestBeginDate`、`BGProcessingTask`／`BGAppRefreshTask` 文件；WWDC19 session 707）：refresh 任務同時只能排 1 個、每次約 30 秒、何時執行由系統決定甚至可能不執行；processing 任務只在裝置閒置時跑、使用者一用就終止。**背景定期檢查幾百個站不可行**。側載是否保有對應 entitlement：UNVERIFIED（不影響結論）。

### 4.3 證據對設計的影響

| 證據 | 決定 |
|---|---|
| Android `SiteHealthStore` | iOS 以它為基礎（被動記錄、彩色點、清除、排序開關），而不是另起一套模型 |
| 它沒有首頁／分類記錄、空列表算成功 | iOS 補記首頁／分類，並把 spider 的網路失敗原因帶上來（41A） |
| tvbox-manager、第 3 節 Cloudflare 實測 | 檢查只走 App 本身的請求路徑 |
| `URLError`、`cf-mitigated`、Cloudflare 5xx 文件 | 原因分類只用這些確定訊號；頁面特徵只標「疑似」 |
| Azure／SRE | 先確認裝置在線（遇到 −1009 整批中止）；暫時性失敗標示出來、由使用者重跑而不自動重試；結果帶時間、不自動刪除 |
| `BGTaskScheduler` | 不做背景檢查，主動檢查只在前景由使用者觸發 |

## 5. 選項比較

| 選項 | 內容 | 評估 |
|---|---|---|
| A. 不改 | 維持「載入失敗／沒有內容」 | 七成來源開了是空的，使用者無從判斷要等網站、換設定還是回報 bug；每次都要靠 Mac 端 sweep／curl 人工歸因。不建議 |
| B. 照搬 Android `SiteHealthStore` | 被動記錄搜尋、詳情、播放，彩色點、排序、清除 | 與 Android 一致、改動中等；但死站多半只會是黃點（第 4.1 節的兩個缺口），「沒有內容」仍然說不出原因。可行但不夠 |
| **C. Android 模型＋失敗原因＋手動檢查（建議）** | B 的模型與呈現，加上：首頁／分類也記錄、spider 網路失敗原因（41A）、使用者觸發的全站檢查與報告（41C） | 解決「分不出網站死了還是程式問題」；重用 sweep、`MediaProbe` 與 `HTTPHost` 單一入口；不改 spider 腳本、不改 `js.host` ABI、不改設定檔；平常瀏覽不增加請求 |
| D1. 背景定期檢查 | `BGTaskScheduler` 定時跑 | 第 4.2 節：時間與次數都不夠。不建議 |
| D2. 伺服器端檢查 | 另架服務定期檢查 | 沒有伺服器；伺服器的網路不代表使用者的網路。不建議 |
| D3. 自動刪除或改寫來源 | 把不通的站從清單拿掉 | 設定檔是使用者的、Android 也在用；網站狀態會變（妻妹 520→200）。不建議 |
| D4. 開 App 就自動檢查全部 | 每次啟動跑一遍 | 368 站 × 每站 4～6 個請求 ≈ 2,000 個請求，耗流量、對第三方網站不友善。不建議 |

C 對照 B 多出來的代價與取捨：

- **正確性**：原因只依確定訊號分類（`URLError` 錯誤碼、HTTP 狀態、`cf-mitigated`）；頁面特徵（JS 跳轉頁）標「疑似」；沒有網路錯誤卻 0 部的站寫「網站有回應但取不到片單」，不硬猜。
- **與 Android 的差異（刻意）**：key 用 iOS 的 `Site.id`（設定裡有同 key 不同站，`wang-sex.json` 重複 11 次），不是 Android 的 `siteKey`；多記首頁／分類；記錄原因分類。分數公式與顏色門檻照 Android。
- **ABI 與相容性**：`HTTPHost` 回給 JavaScript 的物件不變，`js.host` 維持 1.1；Python spider 走自己的網路庫，`HTTPHost` 看不到，只能用例外文字分類（第 8 節）。
- **效能**：被動記錄只是每次呼叫後寫一筆、延遲批次存檔（Android 是 2 秒）；主動檢查只在使用者按下時跑。
- **生命週期**：spider 的 JavaScript 呼叫無法中途取消（sweep 註解已記錄）；以並行上限控制堆積；取消不算失敗。
- **安全與隱私**：結果只存在本機（Application Support），報告只在使用者按分享時送出。
- **維護**：sweep 測試改成呼叫同一個 Core 檢查器，Mac 端 `swift test` 與 App 內檢查的定義一致。
- **驗證與回滾**：原因對照表可單元測試；主動檢查可在熱點下對照 IOS-POC-39 第 7.3 節；三段各一個 commit。

## 6. 建議方案（C，分三段，各自可獨立回滾）

### 41A 失敗原因：首頁「沒有內容」說出原因（建議先做）

- `HTTPHost.perform` 為每個 spider session 記下**這次呼叫中第一個失敗的回應**：`URLError` 錯誤碼、HTTP 狀態（≥ 400）、`cf-mitigated` 標頭，以及頁面標題是否是已知的挑戰／跳轉頁（`Just a moment`、`Redirecting`、`Security Check`、`检测中`、`跳转中`）。
- 原因分類（Core 的純函式）：裝置離線、找不到網域、連線逾時、連不上主機、安全連線失敗、Cloudflare 驗證、網站伺服器錯誤（HTTP 4xx／5xx，顯示狀態碼；Cloudflare 520～530 也在這裡）、疑似要執行 JavaScript；`cancelled` 不是失敗。ATS（−1022）不列：`Info.plist` 已設 `NSAllowsArbitraryLoads`。CMS 站的 `URLError` 用同一套分類。
- spider 回傳 0 部且這次呼叫有記錄時，首頁顯示原因（例：「網站連不上：找不到網域」「網站要求瀏覽器驗證（Cloudflare）」），取代「沒有內容」；沒有記錄時仍顯示「沒有內容」。
- 不保存、不增加請求。程式位置：`HTTPHost.swift`、`SpiderSession`／`SourceClient`（把記錄帶出來）、`WebHTVApp.swift` `emptyState`；新增分類對照的單元測試。

### 41B 被動健康記錄（對齊 Android `SiteHealthStore`）

- 照 Android 記錄搜尋、詳情、播放的成功／失敗、筆數、耗時，**另外記首頁與分類**，失敗時帶 41A 的原因；spider 回 0 部且有網路失敗記錄時算失敗（補 Android 的缺口）。
- 分數公式、綠／黃／紅／灰門檻、90 天保留照 Android；key 是「設定來源＋`Site.id`」。
- 首頁來源選單與設定頁 `SiteChoiceList` 顯示彩色點；設定頁可清除；依分數排序的開關（預設值待決定，第 9 節第 4 點）。目前選取的站不受影響。

### 41C 手動檢查與報告（WebHTV 新增）

- 設定頁「檢查來源」：對目前設定提供的所有來源跑和 sweep 相同的 App 路徑（首頁或第一個分類 → 第一部詳情 → 播放網址 → `MediaProbe` 讀到影片位元組），並行 8 站、每站上限約 90 秒，可取消。
- 遇到第一個 −1009（裝置離線）就整批停止，不寫入任何結果。不自動重試：逾時（−1001）與中途斷線（−1005）標成「可能是暫時的」，使用者可以重跑檢查。
- 結果寫進 41B 的記錄（每站附原因與失敗階段、時間），依結論分組顯示，可用分享表單匯出文字報告；報告開頭寫明檢查時間與「結果取決於當下的網路」。
- 結論分類：可以播放／網站連不上（41A 的各原因）／網站有回應但取不到片單／有片單但沒有集數／取不到播放網址／播放網址不是影片／檢查逾時。對應 IOS-POC-39：「網站連不上」≈ C，其餘失敗 ≈ B。
- sweep 測試改成呼叫同一個 Core 檢查器。

## 7. 驗收標準（各段實作時）

- **41A**：(1) 網域不存在的 XBPQ 站顯示「找不到網域」；回 `cf-mitigated: challenge` 的站顯示 Cloudflare 驗證；網站正常回應但 0 部的站仍顯示「沒有內容」（不能誤報網路問題）。(2) 能用的站畫面與行為不變。(3) `swift test` 全過，新增以 `URLProtocol` 模擬各類失敗的測試。(4) spider 腳本與 `js.host` ABI 不變。
- **41B**：(1) 搜尋、詳情、播放、首頁、分類的結果都有記錄，取消不算失敗；(2) 分數與顏色與 Android 同一組輸入的結果相同（以單元測試對照 Android 的公式）；(3) 清除後全部回到灰點；(4) 排序開關照第 9 節的決定；目前選取的站不會被移走或藏起來；(5) 沒有記錄時清單和現在完全相同。
- **41C**：(1) 並行不超過 8、每站有上限、可取消；遇到 −1009 中止且不寫入結果。(2) 熱點下對 `wang-sex.json` 的 XBPQ 項目，結果與 IOS-POC-39 第 7.3 節一致（容許網站在兩次之間變化，差異逐站說明）。(3) 報告列出各分類的站名與檢查時間。(4) 模擬器上 Python 站也會被檢查。
- 每段都要 `ponytail:ponytail-review`、模擬器 Debug 與 generic iOS Release build；真機沒測到的寫「未驗證」。

## 8. 風險與未決

- **網路環境**：公司網路上的檢查會把很多站判成連不上（第 3 節）。對策：顯示檢查時間、報告寫明「結果取決於當下的網路」、不自動隱藏或刪除。
- **結果會過期**：網站狀態幾小時內就會變（妻妹）。對策：只顯示「x 小時前」，不自動重跑；被動記錄會隨使用自然更新。
- **頁面內容判斷不可靠**：JS 跳轉頁、停放網域、導流頁只能靠頁面特徵猜，只標「疑似」；停放／導流頁不做判斷，落在「網站有回應但取不到片單」。
- **Python 站**：網路錯誤不經過 `HTTPHost`，原因只能用例外文字分類（`PythonLiveCheck.cause` 的做法），精度較低；41A 對 Python 站只在例外文字明確時顯示原因。
- **排序改變清單順序**：Android 預設開；iOS 使用者習慣的來源順序會變（第 9 節第 4 點）。
- **第三方網站負載**：只在使用者按下時主動檢查，每站一條鏈約 4～6 個請求，並行上限 8。
- **JavaScript 呼叫無法取消**：取消後已送出的呼叫仍會跑完。
- **同名站**：設定裡有同名或同 key 不同站，一律以 `Site.id` 為 key。

## 9. 待使用者決定

1. **範圍**：全部來源（CMS、spider、Python；建議）／只有 XBPQ／只有 spider。
2. **要做哪幾段**：41A＋41B＋41C 都做（建議）／只做 41A＋41B（不要主動檢查）／只做 41A。
3. **順序**：41A → 41B → 41C（建議：41A 改動最小、立刻讓「沒有內容」有原因；41B 對齊 Android；41C 是 WebHTV 新增）。
4. **依健康分數排序來源清單**：照 Android 預設開（建議，與 Android 一致，死站會排到後面）／提供開關但預設關／不做排序只顯示點。
5. **主動檢查的深度**：到讀到影片位元組，與 sweep 相同（建議）／只到片單（較快，但「播放網址不是影片」分不出來）。
6. **是否另外提供「只顯示可以播放的來源」**：先不做（建議；排序與彩色點已足夠，Android 也沒有）／要做（預設關）。

## 10. 狀態

- 2026-10-02 assessment 完成：第 2 節（iOS 現況與程式位置）、第 3 節（本機實證）、第 4 節（外部證據：Android `SiteHealthStore`、上游與相關專案、Apple、Cloudflare、Azure／SRE、BGTaskScheduler）、第 5 節（選項比較）、第 6 節（建議分段）、第 7 節（驗收）、第 8 節（風險）。**沒有改程式。**
- 研究過程：外部資料由一個背景研究 agent 讀取原始頁面並回報（約 27 次工具呼叫），其中 Android `SiteHealthStore` 與呼叫端已由本文作者逐行確認；`URLError` 與 Cloudflare 標頭另以本機實測對照（第 3 節）。
- 未驗證：OK影視／影視仓、CatVodTVOfficial；DNS 卡住時的錯誤碼；側載 App 的背景任務 entitlement（不影響結論）。
- Ponytail：`ponytail:ponytail-review` 對提案設計提出 4 項簡化（刪 ATS 類別、Cloudflare 5xx 併入 HTTP 錯誤、只用 −1009 判斷離線、不自動重試），已套用到第 4.3、6、7 節。
- 回滾：本任務只有文件，`git revert` 即可。
- **唯一下一步**：等使用者回覆第 9 節 6 個決定並核准第一段（建議 41A）；核准前不改程式。
