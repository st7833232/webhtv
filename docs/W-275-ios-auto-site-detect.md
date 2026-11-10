# W-275 iOS App 內輸入網址自動偵測站型並加站（階段 1 設計）

工單 W-275（Manager #7281、#7283，使用者 11-10 選定做在 iOS App 裡）。分支 `task/W-275`，自 `origin/ios-poc` d198228a。
階段 1 只寫文件；階段 2 實作需 Manager 轉使用者核准後另行開始。

## Recovery anchor

- 目標：使用者在 App 輸入站台網址 → App 用公開請求判斷能用哪種通用格式 → 實際取首頁與一部詳情驗證 → 預覽 → 加入。不寫爬蟲、不改 GitLab 設定。加的站只在這支 iOS 裝置（使用者核准的雙平台規則例外）。
- 狀態：階段 1 設計已核准（Reviewer #7323，75e633f3）。使用者 11-10 答覆第七節：**1b 跟著目前來源**、2a 允許 http 並標「未加密」、3a 網頁版型退路另開 W-278。**階段 2a 實作中（W-277，分支 `task/W-277`）**，4.4 已改成 1b 寫法；實作紀錄見第八節。
- 下一步：見第八節最後一行。

## 一、現況（origin/ios-poc d198228a）

| 位置 | 內容 | 對本單的意義 |
|---|---|---|
| `ios/Sources/WebHTVCore/ConfigSource.swift:11` | 來源只有 `.remote(URL)` 與 `.imported(id:)`（匯入的本機設定） | 「把自動站做成另一個本機來源」是現成可行的方案，但使用者要切換來源才看得到 |
| `ios/Sources/WebHTVCore/SavedSource.swift` | 存的是**設定檔網址**清單，站點在設定檔裡 | 自動加的「站」不是一個「來源」，要另外存 |
| `ios/WebHTVApp/Sources/WebHTVApp.swift` `show(_:from:)`（:606） | 所有設定（啟動還原、重新整理、相容包重建）進畫面的唯一入口：`sites = config.drivableSites(resolvedBy:)` | 本機站在這裡併入，一處就涵蓋所有路徑 |
| `ios/Sources/WebHTVCore/WebHTVConfig.swift:94` `Site` | `Decodable`、欄位多為 `let`；type 0/1/4 且 api 為 http(s) 即 `isNativeCMS` | 本機站用同一個 JSON 形狀存，解碼成 `Site`，不另造型別 |
| `ios/Sources/WebHTVCore/CMSClient.swift:444-550` | 已支援 type 0（XML，`MacCMSXML.swift`）、1、4：`home()`、`category(t,pg)`、`detail(ids)`、`search(wd)`；type 0 的詳情用 `ac=videolist` | 偵測直接用 `CMSClient` 驗證候選，不寫第二套解析 |
| `CMSClient.swift:538` `isDirectMedia` | 副檔名 m3u8／mp4／flv／mkv／ts／mov／mpd 視為直連 | 預覽可標「直連可播」或「需嗅探」 |
| `ios/Spiders/XBPQ.js:14`、`:245-276`、`:432-439` | XBPQ 沒設規則時退回苹果CMS **stui／myui** 網頁版型（列表、線路、播放頁 `var now=`） | 網頁版型退路可以用現成引擎，不寫爬蟲 |
| `ios/Sources/WebHTVCore/Spider/DrpyEngine.swift:80`、`:99-103` | drpy 的 `模板.js` 等程式庫只從**設定檔自己的來源**載入，且只接受 https | drpy 自動模板依附使用者設定的信任模型，不適合放進「任意網址」功能 |
| `ios/WebHTVApp/Info.plist:5-9` | `NSAllowsArbitraryLoads=true`，沒有其他 ATS 鍵 | 使用者輸入的 http 站不用改 ATS；**不能**再加 `NSAllowsArbitraryLoadsForMedia` 等鍵（E10） |
| `ConfigLoader.swift` `URLSession.webHTV` | 每個請求逾時 10 秒、不快取 | 偵測沿用 |

## 二、研究證據

完整引文在 `.herdr-synapse/webhtv-dev/artifacts/w275/research-site-detect.md`（2026-11-10）。我已自己抽查 E2（maccms10 `Provide.php` L22-25：API 關閉時 `echo 'closed'; exit;`）。

| # | 結論 | 來源（等級） |
|---|---|---|
| E1 | 苹果CMS v10 API：`/api.php/provide/vod/`，參數 `ac`（list／videolist／detail）`t pg wd h ids`；預設 JSON `{code:1,msg,page,pagecount,limit,total,list,class}`；`at=xml` 或 `/at/xml/` 回 `<rss><list><video>…`。`pg` 從 1 起，`pagesize` 上限 100 | maccms10 v2026.1000.4057 `application/api/controller/Provide.php`、官方文件（A） |
| E2 | API 關閉回 200＋文字 `closed`；收費且未授權回 `域名未授权`；Content-Type 一律 `text/html` → 不能只看 HTTP 200，要看內容形狀 | 同上（A，已抽查） |
| E3 | `ac=list` 沒有 `vod_pic`、`vod_play_url`，只有 `videolist`／`detail` 有完整欄位 → 驗證要多打一個 `ac=detail&ids=` | 同上（A） |
| E4 | v8 舊版：XML 在 `/inc/api.php`、JSON 在 `/inc/apijson_vod.php`，詳情 `ac=videolist`（這就是 TVBox type 0 用 videolist 的原因） | 研究檔第 1 節（A） |
| E5 | FongMi：首頁是對 `api` 的 GET；分類 `ac,t,pg`；詳情 `ac,ids`；搜尋 `wd,quick,extend`；最小站點 `{key,name,type,api}`；解析失敗會**默默**變成空結果 | FongMi `SiteApi.java`、`Result.java` @4512b4c9（A） |
| E6 | drpy2 `模板:'自动'`：抓一次首頁，依序試 mx→mxpro→mxone5→首图→首图2→vfed→海螺3→海螺2→短视，第一個 `class_parse` 找得到分類的勝出；**不驗列表、詳情、播放**，會誤判 | drpy2 原始碼（A） |
| E7 | 海闊 drmatch：找不到預期標記就當驗證頁交給使用者手動處理 | 研究檔第 3 節（A） |
| E8 | 搜尋在伺服器跑 `LIKE '%..%'`，站長回報 CPU 100% → 探測不要用搜尋、不要並發 | maccms10 #677（B） |
| E9 | 同一 API 從某些網路可用、某些被封（#1208）→ 偵測結果與網路有關，要能重試 | maccms10 #1208（B） |
| E10 | ATS：任意使用者輸入的 http 網址只能靠 `NSAllowsArbitraryLoads`；同時存在 `…ForMedia`／`…InWebContent`／`NSAllowsLocalNetworking` 會讓它被忽略；iOS 17 起預設不允許直連 IP | Apple 文件（A） |
| — | 沒找到：type 4 的書面規格；現成「給一個裸網址就探測苹果CMS 路徑」的成熟工具；FongMi／MacCMS 關於 API 回 Cloudflare 挑戰頁的 issue | 研究檔第 12 點 |

## 三、方案比較（AGENTS §7）

| 方案 | 內容 | 能接的站 | 誤判風險 | 工時（我的實作時間） | 結論 |
|---|---|---|---|---|---|
| A 不做 | 照舊改設定檔 | — | — | 0 | 不採用：使用者明確要這功能 |
| B 只偵測苹果CMS API（type 0／1） | 依序試 v10 JSON、v10 XML、v8 JSON、v8 XML；每個候選用 `CMSClient` 實際取首頁＋一部詳情 | 開放採集 API 的苹果CMS 站（資源站、大部分影視站） | 低：API 有固定形狀（`code`、`class`／`list`），再加上詳情驗證 | 約 6～8 小時（偵測＋本機站存放＋合併＋UI＋測試）＋Simulator 1 小時 | **建議先做（階段 2a）** |
| C B＋XBPQ 網頁版型退路 | API 都不通時抓一次首頁，有 stui／myui 標記才建 XBPQ 站（只給 `主页url`／`分类url`），再用 XBPQ 引擎實跑列表＋詳情＋線路驗證 | 關了 API 但用標準 stui／myui 模板的站 | 中：網址規則（分類、分頁）各站不同，推不出來就驗證失敗、不加 | B 之外再 4～6 小時 | 建議做在 **2b**，2a 上線後再決定；W-274 盤點的 stui／myui 站可當測試集 |
| D C＋drpy 自動模板 | 照 drpy2 `模板:'自动'` 試多個模板 | 更多網頁版型 | 高：drpy2 本身不驗列表／詳情／播放（E6）；而且 drpy 程式庫只從設定檔來源載入（`DrpyEngine.swift:80`、`:99`），要讓任意網址的站用它，得改信任模型 | 1～2 天＋安全審查 | 不採用（本單範圍外；要做另開單） |
| E 不偵測、只給表單 | 使用者自己填 type／api | 會填的人 | 由使用者負責 | 約 3 小時 | 不採用：不符「自動」；但 B 的預覽頁可以讓使用者改名稱 |

**建議**：階段 2a 做 B；2b（C）等 2a 實測後由 Manager／使用者決定。

## 四、設計（方案 B，C 的差異另註）

### 4.1 輸入與正規化

- 只接受 `http`、`https`；沒寫 scheme 時先試 `https`，整輪都失敗再試 `http`（來源都不會自己升降級，這是我們的選擇，E 研究檔第 4 節）。其他 scheme（`file`、`javascript` 等）直接拒絕。
- 輸入如果已經是 API（路徑含 `provide/vod`、`api.php`、`inc/api`）→ 先原樣試，再試同源的其他候選。
- 其餘取 origin（scheme＋host＋port），子路徑若像站點根目錄（例如 `/m/`）就保留一份候選。

### 4.2 候選與順序（逐一、不並發，E8）

1. 使用者原樣網址（若像 API）
2. `{origin}/api.php/provide/vod/` → 期望 JSON → type 1
3. `{origin}/api.php/provide/vod/at/xml/` → 期望 XML → type 0
4. `{origin}/inc/apijson_vod.php` → JSON → type 1
5. `{origin}/inc/api.php` → XML → type 0
6. （方案 C）`{origin}/` 首頁 HTML：有 `stui-vodlist`／`myui-vodlist` 等標記 → XBPQ 候選

找到第一個通過驗證的就停。type 4 不做自動偵測：沒有書面規格（E 研究檔），它的 api 通常是設定檔作者給的完整網址，不是使用者會輸入的站台首頁；使用者若貼的正好是 type 4 介面，第 1 步會被當 JSON API 試，失敗就列「不支援的格式」。

### 4.3 判定（每個候選）

- 形狀：JSON 要能解、`code` 是 1 或沒有、`class` 非空或 `list` 是陣列；XML 要有 `<rss>` 且有 `<list>` 或 `<class>`。
- 明確失敗原因，分開顯示（E2、E7）：`closed`（站方關了 API）、`域名未授权`（收費 API）、HTTP 4xx／5xx、HTML 挑戰頁（含 `cf-`、`challenge`、`验证` 等）→「需要人機驗證，不支援」、逾時、內容空白。
- 驗證（E3）：用暫時的 `Site`（`{key,name,type,api}`）建 `CMSClient`，跑 `home()`；取第一部的 id 跑 `detail(id:)`，要有至少一條線、一集。記下第一集是否直連（`isDirectMedia`），不是就標「需嗅探或解析，播放可能失敗」，仍可加入。
- 方案 C：建 XBPQ 站後經現有爬蟲 session 跑 `homeContent`→`categoryContent`→`detailContent`，同樣要有線路與集數。
- 預算：每請求 10 秒（`URLSession.webHTV`），整輪上限 45 秒，最多約 10 個請求；使用者可取消。只用 GET 公開頁面，不帶登入資訊。

### 4.4 存放與合併

- 新檔 `Application Support/local-sites.json`（裝置本機，不上傳、不回寫 GitLab），**依設定來源分開**（使用者 1b）：`{"bySource":{"<source.identity>":[{key,name,type,api,addedAt,detectedFrom}]}}`。每筆的 `key name type api` 就是設定檔站點的形狀，解碼成 `Site`。
- key＝`local_`＋正規化 api（4.4.1）的 SHA-256 前 10 碼：不會和遠端站撞名；同一個 api 永遠得到同一個 key，所以刪掉再加回來，收藏與歷史會接回去（4.4.2）。同一 api 再加一次就是改名（比照 `SavedSourceList.upsert`）。
- 合併：`show(_:from:)`（`WebHTVApp.swift:606`）裡 `sites = config.drivableSites(...) + 這個來源的本機站`，排在最後，站點選單上加「本機」標記。遠端設定已經有正規化後相同的 api 時，本機那筆不顯示，設定頁註明「遠端設定已有此站」。2a 只有 type 0／1，`isNativeCMS` 就能用；2b 的 `csp_XBPQ`（type 3）併入時要和遠端站一樣經過 `drivableSites`／resolver 過濾，不能直接附加（Reviewer N-1，2b 開工時寫進設計）。
- 跟著目前來源（1b）：換到 B 來源就看不到 A 的本機站，換回 A 又出現。在設定頁「忘記」某個來源時，連同它的本機站一起刪（`forget(_:)`，`WebHTVApp.swift:461`，和站點記憶、快取設定同一處）。
- 加入時若目前來源已經有正規化後相同的 api，直接告知「目前設定已有此站」、不加入。
- 刪除／改名：設定頁「本機加入的站」清單，註明「不會隨備份還原」（W-119 的備份不含此檔，Reviewer N-2）。刪掉只影響本機檔。
- 搜尋：沿用站點 `searchable` 的預設值（沒寫就是可搜尋，和遠端站相同）；聚合搜尋只在使用者主動搜尋時才打，偵測本身不用搜尋（E8，Reviewer N-3）。
- 不做：備份同步、匯出成設定檔（以後要可另開單）。

#### 4.4.1 「同一個 api」的正規化（F-3）

比對與產生 key 都用同一個函式 `LocalSites.normalizedAPI(_:)`（WebHTVCore，純函式）：

1. 用 `URLComponents` 解析；不是 http(s) 就不是有效 api。
2. 不分 scheme：`http` 與 `https` 視為同一站（同一主機常兩種都開；E 研究檔：用戶端不會自己升降級，但資料相同）。
3. 主機轉小寫；去掉預設埠（http 的 80、https 的 443），其他埠保留。`www.` **不**去掉（可能是不同主機）。
4. 路徑大小寫保留（伺服器可能區分）；連續斜線合成一個；去掉結尾斜線；去掉結尾的 `/at/xml`、`/at/json`（同一端點的 XML 與 JSON 寫法是同一站）。
5. query：去掉 `at` 和協定參數（`ac t pg wd h ids f quick extend`）；剩下的參數依名稱排序、保留值。
6. 去掉 fragment。

例：`https://Example.com:443/api.php/provide/vod/at/xml/`、`http://example.com/api.php/provide/vod?ac=list`、`https://example.com/api.php/provide/vod/` 三者相同；`https://www.example.com/api.php/provide/vod/` 不同；`/inc/api.php` 與 `/api.php/provide/vod/` 不同。

#### 4.4.2 收藏、歷史、站點記憶（F-2，1b 寫法）

現況：收藏的身分含 `configSourceID`，換來源時判成 `.otherConfiguration`（`FavoriteBrowsing.swift:48`）；歷史帶 `sourceID`，只在擁有它的來源列出（`WatchHistory.swift:319-330`）；站點記憶是 `siteMemory()[source.identity]`。

1b 之後本機站就是「目前來源站點清單的一部分」，所以**完全沿用現有規則，不加任何特例**：

- 寫入：收藏、歷史照常填目前來源的 ID（和遠端站相同）。原先為全域設計的專用來源 ID `LocalSites.sourceID` 與 `isListed` 的 `hiddenFrom` 分支（Reviewer #7323 實作注意）都不需要了，不實作。
- 換來源：A 的本機站在 B 看不到，它的收藏在 B 判成 `.otherConfiguration`、歷史只在 A 列出——和 A 的遠端站一模一樣。換回 A 一切恢復。
- 站點記憶：不改。選到本機站會記在目前來源下；換回來源時本機站已經在 `sites` 裡，照常選回。
- 刪掉本機站：收藏、歷史都保留，顯示成「站已不在」（和遠端站被移除時相同）；再加回同一 api 會得到同一個 key，紀錄自動接回。
- 已知行為（Reviewer N-4）：加入時已擋掉「目前來源已有同 api」；只有在**加入之後**遠端設定才新增同一個 api 時，本機那筆會被隱藏，它的收藏與歷史顯示「站已不在」。把這些紀錄改對到遠端站，需要改收藏／歷史的站點身分遷移規則（目前依 key＋ext 對站），超出 2a 範圍，保留為已知行為，設定頁的本機站清單把這筆標成「遠端設定已有此站，未顯示」，使用者可自行刪除。

#### 4.4.3 沒有設定檔時（F-1，1b 寫法）

本機站必須掛在某個來源下。沒有可用設定時（全新安裝、快取不存在或驗證失敗，`restore()` `WebHTVApp.swift:717`、`rebuildSites()` `:596`），「新增站台」按鈕停用，下方說明「請先加入設定來源，本機加入的站會跟著目前的設定來源」。原先全域設計的 `showLocalSitesOnly()` 不需要，不實作。

### 4.5 UI 流程

設定 →「新增站台（自動偵測）」→ 輸入網址（可選名稱）→ 偵測中：逐步列出試過的候選與結果，可取消 → 結果預覽：格式（苹果CMS JSON／XML、XBPQ 網頁）、api、分類數、第一部片名、線路數／集數、是否直連 → 「試播第一集」（用既有播放器）→「加入」。失敗時顯示原因，不加入。

### 4.6 安全

- 只有 http(s)；不新增任何執行遠端程式碼的能力：API 型是純資料；方案 C 用 App 內建、已審查的 `XBPQ.js`，規則只是字串；不載 drpy。
- 不繞過驗證碼、登入、收費授權：遇到就顯示原因、不加入。
- 不改 ATS（E10）；不碰 `DrpyEngine.checked` 的 https 限制（那是 drpy 的信任邊界，偵測有自己的 scheme 規則）。
- log 只記候選類別（v10 JSON、v8 XML…）與結果、失敗原因，不記完整網址與片名。

### 4.7 與 W-274 的關係

W-274（claude-dev）盤點現有專用爬蟲能否改走通用格式。兩者用的是同一套通用格式：W-274 找出的「其實是苹果CMS API」的站，可以拿本功能驗證；「stui／myui 網頁」那一組可當方案 C 的測試集與標記清單。2a 不依賴 W-274 的結果；2b 建議等 W-274 完成再定標記清單。

## 五、驗收條件（階段 2a）

1. 單元測試（假回應，不連外）：`normalizedAPI` 照 4.4.1 的每條規則與三個例子；本機站依來源分開存、忘記來源連同刪除；v10 JSON、v10 XML、v8 JSON、v8 XML 各一例判對 type；`closed`、`域名未授权`、HTML 挑戰頁、空白、逾時各判成對應原因；詳情沒有集數判失敗；候選順序與「第一個成功就停」；`local_` key 不撞名、同 api 改名不重複；與遠端同 api 時本機那筆不顯示。
2. Simulator：用本機測試伺服器模擬一個苹果CMS v10 JSON 站、一個只開 XML 的站、一個回 `closed` 的站，走完 輸入→預覽→加入→首頁出現→播放第一集；重開 App 仍在。
   - **沒有任何設定來源**（全新安裝）時：「新增站台」停用並顯示提示（F-1，1b）。
   - **換設定來源**：A 的本機站在 B 看不到，換回 A 又出現，收藏與歷史照常（F-2，1b）。
   - http 站：預覽標示「未加密」。
   - **刪掉本機站**：收藏與歷史保留並顯示「站已不在」；加回同一 api 後恢復可開（F-2）。
3. 熱點下用一個真實開放 API 的站做一次冒煙（站名不寫進文件與版本說明）。
4. 遠端設定、既有站點、W-262／W-268 等既有行為不變：全量 `swift test` 通過。
5. 方案 C 另訂（2b 開工時）。

## 六、Rollback

- 程式：revert 階段 2 的提交即可；`show()` 回到只用遠端站點。
- 資料：`local-sites.json` 只是多出來的檔案，舊版不讀它，不影響任何遠端設定或快取；不需要遷移。

## 七、未決事項（使用者 11-10 已答覆，Manager W-277 工單）

1. 本機加的站要**全域**還是**跟著目前來源**？→ **1b 跟著目前來源**（4.4 已改）。
2. 是否允許 `http://`（不加密）站？→ **允許**，預覽頁標示「未加密」。
3. 方案 C（網頁版型退路）是否要排在 2a 之後做？→ **另開 W-278**。

## 八、階段 2a 實作紀錄（W-277）

- 11-10 13:40 CST 自 `origin/ios-poc` 3967892b 開 `task/W-277`；task guard standard。4.4／4.4.2／4.4.3、第五節、第七節改成 1b。
- 程式（全在 `ios/`）：
  - `Sources/WebHTVCore/LocalSites.swift`：`LocalSite`（設定檔站點形狀＋`addedAt`、`detectedFrom`，`site` 解碼成 `Site`）、`LocalSites.normalizedAPI`／`key(forAPI:)`（4.4.1）、`merged`（遠端同 api 時本機那筆不列）、`LocalSiteStore`（`bySource`，upsert 同 api 即改名、rename、remove、forget、load／save）。
  - `Sources/WebHTVCore/SiteDetector.swift`：`candidates(for:)`（4.1／4.2；沒寫 scheme 先整輪 https 再整輪 http）、`judge`（4.3 形狀與 closed／域名未授权／挑戰頁／空白／HTTP 狀態）、`detect`（逐一、第一個成功就停、45 秒預算、同一 origin 逾時或連不上就跳過其餘路徑、可取消）、`verify`（`CMSClient` 取首頁＋一部詳情，要有線路與集數，記直連與否）。子路徑（`/m/`）只試 origin，已用 `shortcut:` 註明。
  - `Sources/WebHTVCore/CMSClient.swift`：`init(site:session:)`，預設仍是 `URLSession.webHTV`，只讓測試注入假伺服器。
  - `WebHTVApp/Sources/WebHTVApp.swift`：`localSites` 狀態；`restore()` 先讀 `local-sites.json`；`show()` 併入目前來源的本機站；`forget()` 連同刪除；`changeLocalSites` 存檔後走 `rebuildSites()`；設定頁「新增站台（自動偵測）」（沒有站點時停用並在說明加提示）與「本機加入的站」（改名、左滑刪除、遠端已有時標示）；`AddSiteView`（輸入→逐步列出試過的格式→預覽→試播第一集→加入，按偵測會收起鍵盤）；兩個站點選單加「本機」標記。log 只印格式與結果（4.6）。
- 實作和設計的差異：
  - 刪除後收藏顯示的是 App 既有字樣「來源不可用」（不是文件原寫的「站已不在」），行為相同。
  - `CMSClient.home()` 對 type 1 本來就同時打兩個請求（分類＋列表）；「逐一」指的是候選之間，沒改 `home()`。
  - 試播後沒加入的站，觀看紀錄會留一筆「來源不可用」；之後加回同一 api 就接回。
- 驗證：
  - 單元測試 13 個（`LocalSitesTests` 4、`SiteDetectorTests` 9）全過：正規化每條規則與三個例子、key 穩定、依來源存放／改名／忘記、遠端同 api 隱藏本機；候選順序、各失敗原因、v10 JSON／v10 XML（http，未加密）／v8 JSON、沒集數判失敗、逾時跳過同 origin 與預算、非 http 拒絕、從不搜尋。
  - 全量 `swift test`：1522 個測試，2 個失敗（`offlineSubtitleRedirectsKeepTheSourceCredentialsOnItsOrigin`、`theRulesScriptRunsOnTheSnifferWebViewAndItsStreamIsCaught`），單獨重跑都通過，是高負載下的既有不穩測試，與本單無關。
  - Simulator（iPhone 18 Pro，iOS 27，本機測試伺服器 `artifacts/w277/work/srv.py`；截圖在 `artifacts/w277/sim/`）：
    - 全新安裝沒有設定時只有「尚未載入設定」，沒有設定頁可進，所以不能加站（v01）。
    - 加入來源 A 後輸入 `127.0.0.1:18278`（只開 XML）：https 連不上（其餘 https 路徑跳過）→ http v10 JSON 404 → v10 XML 可用；預覽有格式、介面、「未加密」、分類、第一部、線路、直連（v08～v10）；試播第一集起播（v12）；加入（v14）。
    - 重開 App 本機站仍在，站點選單有「本機」標記（v18、v19）。
    - 回 `closed` 的站：四個格式都顯示「站方關閉了採集介面」，不加入（v21）。
    - 輸入來源 A 自己的 api：「目前的設定已有這個站，不用再加」（v24）。
    - v10 JSON 站偵測、加入（v25、v26）；收藏它的一部片（v29）。
    - 換到來源 B：站點選單只有 B 的站（v31）；收藏顯示「來源不可用」（v34）。換回 A：本機站回來、上次選的站記得、收藏可開（v35、v36）。
    - 改名、左滑刪除（v39）；刪除後收藏保留並顯示「來源不可用」（v40）；用另一種寫法（`…/at/json/`）加回同一 api，收藏接回（v41、v42）。
    - 熱點下對一個真實開放 API 的站冒煙：https v10 JSON 可用、分類 39 個、2 條線路（v43，站名不寫）。
  - Ponytail 審查：1 項「應修」——加入時的「已有此站」檢查原本也包含本機站，擋掉「同 api 再加一次即改名」；已改成只比對遠端站，App 重新編譯通過。改名路徑由 `LocalSiteStore.upsert` 單元測試涵蓋，修正後沒有再跑 Simulator。
- 沒驗證：實機（依規定只建 IPA 不裝機，本單未建 IPA）；忘記來源連同刪除只有單元測試（`forget(source:)`）和程式閱讀，沒在 Simulator 刪來源。
- 下一步：Reviewer 審查本單（W-277）；通過後 W-278（網頁版型退路）。

## 九、階段 2b 設計：網頁版型退路（W-278，方案 C）

使用者 11-10 選 3a（2a 之後做）。基底是 W-277（task/W-277 e6d9f559，送審中），W-278 分支自它開。本節是開工前的設計，送審後才改程式。

### 9.1 現況（程式位置）

| 位置 | 內容 | 對本單的意義 |
|---|---|---|
| `ios/Spiders/XBPQ.js:14` | 沒有規則時，列表、線路、播放都退回苹果CMS stui／myui 版型 | 只要給 `主页url`、`分类url`、`分类` 三個字串，其餘都走現成退路 |
| `XBPQ.js:245-276` | 線路：`ul.stui-content__playlist`／`ul.myui-content__list`，線路名取 `.stui-pannel__head h3`／`.myui-panel__head h3` | 詳情驗證直接用它 |
| `XBPQ.js:432-439` | 列表：`.stui-vodlist li`、`ul.stui-vodlist__media li`、`.myui-vodlist li` | 偵測的版型標記就用這幾個 class |
| `XBPQ.js:366-394` `categories()` | 分類只認明寫的 `分类`（或 `分类数组` 切片）；原版用 XPath 猜導覽列的那段沒移植 | 偵測端要自己從首頁導覽列抽出 `名$id`，寫成 `分类` |
| `XBPQ.js:404-430` `categoryUrl()` | `{cateId}`／`{catePg}` 代換，相對網址補上主頁 | 分頁網址由偵測端給模板 |
| `XBPQ.js:683-697` `playerContent` | 依序試 `player_aaaa`（macPlayerUrl）、`"url":`、`var now=`、頁內唯一串流，都沒有才交給嗅探 | 播放不必另寫 |
| `docs/W-185-ios-xbpq-filter.md:16`、`docs/IOS-POC-5I-…:46` | 苹果CMS v10 的 `/vodshow/{id}-{area}-{by}-{class}-{lang}-{letter}---{pg}---{year}.html`；導覽列有 `/vodtype/1/`、`/vodtype/1.html` 兩種寫法 | 分頁模板與導覽列樣式的依據 |
| `artifacts/w275/research-site-detect.md:66` | drpy 的 mxpro 模板：分類取導覽列 `a&&href` 的 `/(\d+)`，分頁 `/vodshow/fyclass--------fypage---.html` | 同一個推法，成熟專案在用 |
| `Spider/SpiderRegistry.swift:72`、`CSPSourceResolver` | `csp_XBPQ` 是已移植、已審查的引擎；能不能跑由 resolver 判斷（爬蟲工具包有沒有到） | Reviewer N-1：本機的 type 3 站要和遠端站一樣經過 resolver 過濾 |

### 9.2 流程（API 四個候選全部失敗之後才做）

1. 抓一次 `{origin}/`（沿用 2a 的 http／https 輪次與 origin 逾時跳過）。沒有 `stui-`／`myui-` 版型 class → 失敗「不是苹果CMS 網頁版型」；挑戰頁、HTTP 錯誤沿用 2a 的 `judge` 原因。
2. 分類：從首頁所有 `<a href>` 抽 `/vodtype/(\d+)`、`/index.php/vod/type/id/(\d+)`、`/vod/type/id/(\d+)`，名稱用連結文字（去標籤、去空白），依出現順序去重，最多 20 個。抽不到 → 失敗「找不到分類」。
3. 分頁模板，依導覽列的寫法選一個，只用第一個分類試第 1 頁：
   - `index.php` 形式 → `{origin}/index.php/vod/show/id/{cateId}/page/{catePg}.html`
   - 其他 → `{origin}/vodshow/{cateId}--------{catePg}---.html`
   - 第 1 頁沒有影片時，改試導覽列本身的分頁形式 `{origin}/vodtype/{cateId}-{catePg}.html` 一次；再沒有 → 失敗「分類頁沒有影片」。
4. 用 `{"主页url":origin,"分类url":模板,"分类":"名$id#…"}` 建暫時的 `csp_XBPQ` 站，經現有爬蟲 session 跑 `categoryContent`（第 1 頁）→ `detailContent`（第一部），要有至少一條線、一集；記第一集是否直連（大多不是，標「需解析或嗅探」）。播放不在偵測裡驗，由預覽頁的「試播第一集」驗（和 2a 相同）。
5. 預算：網頁輪最多 4 個請求（首頁、分類 1～2 次、詳情），算在 2a 的 45 秒總預算內；一次一個，不搜尋。

### 9.3 存放與合併

- `LocalSite` 加選填的 `ext`（JSON 字串）；type 3、api `csp_XBPQ`。key 用 `local_`＋正規化 `主页url` 的雜湊（同一站加兩次即改名）。舊的 `local-sites.json` 沒有 `ext` 照樣讀。
- 合併（N-1）：`show()` 裡本機站也要過 `drivableSites` 的同一條規則——`isNativeCMS`，或 `isSpiderShape && resolver.canResolve`；爬蟲工具包還沒到時本機 XBPQ 站和遠端 XBPQ 站一樣先不列，設定頁的本機站清單標「等爬蟲工具」。
- 「目前設定已有此站」：type 3 站沒有可比的 api，只比本機站彼此（同 key 即改名），不和遠端 XBPQ 站比對（遠端的 `主页url` 在 ext 規則檔裡，可能是遠端 URL，不下載比對）。

### 9.4 方案比較

| 方案 | 內容 | 結論 |
|---|---|---|
| 不做 | 只有 2a | 不採用：使用者選 3a |
| 照原版 XBPQ 猜導覽列（XPath） | 移植原版 `m()` 的 XPath 導覽列推測 | 不採用：XBPQ.js 沒有 XPath（`categories()` 的 ponytail 註記），要補一整套 XPath，風險大於收益 |
| drpy 自動模板 | 第三節 D | 不採用（第三節已說明信任模型） |
| **偵測端抽 `名$id`＋給分頁模板（建議）** | 9.2 | 引擎不改；規則只是三個字串；每一步都有實際取資料的驗證 |

### 9.5 安全

- 不改 `XBPQ.js`；不新增任何遠端程式碼；ext 是三個字串，由 App 自己產生，不從網路取規則檔。
- 遇到驗證頁、登入、收費就顯示原因、不加入；不帶 Cookie。log 只記「網頁版型」與結果。

### 9.6 驗收（2b）

1. 單元測試（假回應）：stui 首頁（`/vodtype/1.html` 導覽）與 myui 首頁（`/index.php/vod/type/id/1.html` 導覽）各一例抽出分類與模板、經 `XBPQ.js` 跑出列表與線路並判成功；沒有版型 class、找不到分類、分類頁沒影片、詳情沒集數各判對原因；vodshow 第 1 頁空時改試 vodtype 一次；舊 `local-sites.json`（沒有 ext）照樣讀；resolver 不能跑 XBPQ 時本機 XBPQ 站不列。
2. Simulator：本機假站（stui 版型 HTML＋HLS）走完 輸入→API 四個都失敗→網頁版型成功→預覽→試播→加入→首頁出現→播放；重開仍在。
3. 熱點下用一個真實、關了採集 API 的苹果CMS 網頁站做一次冒煙（站名不寫進文件）；找不到合適的站就明寫沒驗。
4. 全量 `swift test` 通過（既有不穩測試另記）。

### 9.7 Rollback

revert W-278 的提交即可。已存的網頁版型站留在 `local-sites.json`，回到 W-277 的程式時不會出現：`LocalSites.merged` 遇到 api 不是 http(s)（`csp_XBPQ`）時 `normalizedAPI` 為 nil，`isShadowed` 判成隱藏；設定頁清單仍看得到，可以手動刪。

### 9.8 工時

設計審查後：偵測與合併 1.5 小時、測試 1 小時、UI 小改 0.5 小時、Simulator 1 小時。

### 9.9 實作紀錄（W-278）

- 設計 8a271c8a，Reviewer #7453 核准，附條件 C-1～C-3。W-277 審查的 N-1、N-2、N-3、N-4 也一起處理（Manager #7458）。
- 程式：
  - `SiteDetector`：新增 `.webTemplate` 候選，排在每一輪四個 API 候選之後；`verifyWebTemplate` 照 9.2 的流程：首頁要有 `stui-`／`myui-`，導覽列抽分類，`navigationCategories` 抓 `/vodtype/N` 與 `/vod/type/id/N`，先試 vodshow（或 index.php show），沒影片再試 vodtype 一次，最後用 XBPQ 讀分類頁和詳情。新增失敗原因「不是苹果CMS 網頁版型」「網頁上找不到分類」「需要先下載爬蟲工具」。`Found.localSite(named:)` 產生要存的站。
  - `LocalSite` 新增 `ext`、`home`：key 用 `home`，舊檔沒有這兩個鍵也照樣讀。`LocalSites.merged(_:with:runnable:)` 用遠端站同一條規則過濾；網頁版型站不和遠端比對 api。
  - App：`show()` 傳入 `isNativeCMS || (isSpiderShape && resolver.canResolve)`；偵測時建 `SiteDetector(makeSpiderClient:)`；本機站清單在爬蟲工具還沒到時標「等爬蟲工具，暫不顯示」；網頁版型站不做「已有此站」檢查，同一個網址再加一次就是改名。
- 審查條件怎麼做到：
  - C-1：resolver 跑不了 XBPQ 時，網頁那一輪回「需要先下載爬蟲工具」。有單元測試，也在 Simulator 看到（官方包下載前，w278-02-needs-tool）。
  - C-2：`verify` 的每個請求前都會檢查取消與 45 秒預算，API 輪和網頁輪都一樣。按「取消」時，正在跑的那個請求會由 URLSession 中止，之後不再試下一個候選，畫面顯示「已取消」。有兩個測試證明預算檢查（API 輪、網頁輪）。
  - C-3：偵測用 `resolver.session(for:)`，每次都建新的 session，不進 `SpiderSessionStore`，偵測完沒人持有就由 ARC 釋放。站點健康圓點只在 App 的瀏覽、播放畫面記錄，偵測不會寫。HTTP cookie 和其他請求一樣用共用的 `URLSession.webHTV`。
  - W-277 N-1：`IOS-POC-31` 的註解移回 `SiteChoiceList` 上方。
  - W-277 N-2：同 C-2。
  - W-277 N-3（匯入檔換檔後，舊檔的本機站留在檔案裡）**不修**。匯入檔的身分是依內容算的，換回同一份檔，那些站就會回來；這時刪掉等於丟掉使用者還可能用到的資料。量也很小（每站一筆）。記為已知行為。
  - W-277 N-4：在 Simulator 「忘記」來源 B 之後，`local-sites.json` 裡 B 的本機站已刪除，A 的兩個站還在。
- 已知限制：只認 stui／myui 版型和 `/vodtype/`、`/vod/type/id/` 兩種導覽寫法。mxpro、mxone 這類新版 module 版型（`module-` class）不支援，會顯示「不是苹果CMS 網頁版型」；要支援另開單。分類只取導覽列連結，最多 20 個。
- 驗證：
  - 單元測試 21 個（SiteDetectorTests 16、LocalSitesTests 5）全過。全量 `swift test` 1541 個全過。
  - Simulator（iPhone 18 Pro、iOS 27；本機 stui 假站 18280，見 `artifacts/w277/work/srv.py`；截圖在 `artifacts/w278/sim/`）：
    - 下載爬蟲工具前：網頁輪顯示「需要先下載爬蟲工具」（w278-02）。
    - 下載官方包序號 16 之後：四個 API 都是 HTTP 404，網頁版型可用。預覽顯示 2 個分類、第一部片、1 條線路、「需嗅探或解析」、「未加密」（w278-04、05）。
    - 試播第一集起播：XBPQ 從播放頁的 `player_aaaa` 取出 m3u8（w278-07）。加入後站點選單有「本機」標記（w278-09），首頁有分類與影片，可以播放（w278-10、11）。重開 App 站還在（w278-12）。
    - 忘記來源 B 會連同刪除 B 的本機站（w278-13、14）。
  - 熱點冒煙：一個真實的苹果CMS stui 網頁站（站名不寫）。它的 API 會轉到驗證頁，四個 API 都判成「需要人機驗證」。網頁版型可用：16 個分類、9 條線路，試播起播（w278-15～17）。這一站沒有加入。
  - Ponytail：沒有必修項。非阻擋：網頁站分類頁沒影片時，失敗原因沿用「介面有回應，但沒有任何影片」，字面上稍有出入。
- 下一步：Reviewer 審 W-278。

### 9.10 審查修正（Reviewer #7478 REVISE）

- F-1（必修）：`navigationCategories` 先把連結文字裡的 HTML 實體還原（`&nbsp;`、`&lt;`、`&gt;`、`&quot;`、`&#39;`、`&apos;`、十進位與十六進位的數字實體，最後處理 `&amp;`），再 trim；還原後還剩下的 `&` 換成全形「＆」。這樣 `分类` 裡就不會出現 `&`，XBPQ 也不會依 `&` 把整串切開。測試 `navigationLinksGiveTheCategoriesAndTheirStyle` 增加 `&nbsp;电影&nbsp;`、`日韩&amp;欧美`、數字實體三種情況。
- 非阻擋也一起修了：
  - N-1：`makeSpiderClient` 丟出不是 `Failure` 的錯誤（例如腳本載入失敗）時，改報「網頁版型引擎載入失敗」，不再當成「連不上」，也不會把這個 origin 標成連不上。
  - N-2：網頁站分類頁沒有影片時，改報「分類頁沒有影片」（`noCategoryTitles`）。
  - N-3：分類頁和詳情的 `try?` 之後各檢查一次取消與預算。取消或逾時不會再被記成「沒影片」或「沒集數」。
- 驗證：SiteDetectorTests 與 LocalSitesTests 共 21 個全過。只動到 Core 和測試，App 端沒有用 `switch` 列舉 `Failure` 的地方，所以不需要重新編譯 App。
