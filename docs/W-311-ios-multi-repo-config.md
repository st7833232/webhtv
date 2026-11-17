# W-311 iOS POC 多倉設定（urls depot）——第一階段設計研究

- 工單：herdr W-311（Manager #8661／#8662，brief `.herdr-synapse/webhtv-dev/artifacts/w311-brief.md`）。使用者需求（2026-11-17）：「android webhtv 有支援多倉設定，ios poc 也需要實作」。
- 階段：**第一階段只做設計研究，不改程式碼**（AGENTS.md §7）。經 Reviewer 審查、使用者核准「開始實施」後才進第二階段。
- 分支：`task/W-311`，底版 ios-poc `cb825e3fda82aecc601349043ef5f48e4734315d`（0.1.103）。下文 iOS 行號都以此為準；Android 行號以本倉 Android 程式（FongMi 分支）為準。
- 研究時間：2026-11-17 10:50–11:30（Asia/Taipei）。

## Recovery anchor

- 目標：設計 iOS 對「設定網址回傳 `{"urls":[{name,url}]}`」的多倉支援，對齊 Android 行為，單倉設定行為不變。
- 狀態：第二階段（實作＋Simulator 驗證）完成，送審。見 §11。
- 下一步：Reviewer 審查；通過後由 Manager 推 ios-poc。

## 1. 證據來源

| 類別 | 來源 | 版本／存取 | 用途 | 等級 |
|---|---|---|---|---|
| 參考實作（本倉 Android） | `app/src/main/java/com/fongmi/android/tv/`：`bean/Depot.java`、`api/config/VodConfig.java`、`LiveConfig.java`、`BaseConfig.java`、`bean/Config.java`、`api/Decoder.java`、`db/dao/ConfigDao.java`；`app/src/leanback/.../ui/adapter/ConfigAdapter.java`、`ui/dialog/HistoryDialog.java`、`ui/activity/SettingActivity.java` | 本倉 HEAD，2026-11-17 讀 | 使用者要對齊的行為 | A（實際程式） |
| 上游 | GitHub `FongMi/TV` `VodConfig.java`（`checkJson`／`parseDepot`）、`Config.java`（`find(Depot,int)`） | commit `097917c1c5eb6c94a14b2ede3f371a681dbb751f`（2026-11-13），2026-11-17 讀 | 確認本倉與上游一致：載入第一倉、刪除外層網址 | A |
| 成熟相關專案 | GitHub `takagen99/Box` `app/src/main/java/com/github/tvbox/osc/api/ApiConfig.java` | commit `258a5fef61578869ae905ca230bdde9e99fc19a8`（2026-02-27），2026-11-17 讀 | 其 `urls` 只用於單一直播頻道的多來源（`:714`），**沒有多倉**；多倉是 FongMi 系的事實格式 | B |
| 正式規格 | — | — | TVBox 設定格式沒有正式規格；以 FongMi 實作為事實標準。不適用 | — |
| 上游議題／文章 | — | — | 本題是本倉 Android 已有行為的移植，行為由程式碼決定；議題與部落格不會改變設計，不另查 | — |
| iOS 現況 | `ios/Sources/WebHTVCore/*`、`ios/WebHTVApp/Sources/WebHTVApp.swift`、`ios/Tests/WebHTVCoreTests/*` | `cb825e3f` | 插入點與風險 | A |

## 2. Android（FongMi）多倉行為

路徑縮寫：`M=app/src/main/java/com/fongmi/android/tv`，`LB=app/src/leanback/java/com/fongmi/android/tv`。

### 2.1 格式與判斷順序

- 格式：`{"urls":[{"url":"…","name":"…"}]}`；只讀 `url`、`name`（`M/bean/Depot.java:15-24`）。`url` 缺少當 `""`（`:26-28`）；`name` 空時顯示 url（`:30-32`）。
- **先解碼再判斷**：`Decoder.getJson()` 抓取後 `verify()`（`M/api/Decoder.java:25-40`）——JSON 原樣；含 `**` 取 `[A-Za-z0-9]{8}**` 後 base64（圖片內嵌設定同路，`:37,72-81`）；`2423` 開頭 AES-CBC（`:38,59-70`）。之後 `Json.parse` → `checkJson`（`M/api/config/VodConfig.java:117-120`）。
- 判斷順序 `msg`（拋例外）→ `urls` → 其他（`VodConfig.java:137-145`）。**`urls` 與 `sites` 並存時 `urls` 優先，`sites` 忽略。**
- 空陣列拋 `Depot urls is empty`（`VodConfig.java:151`），畫面顯示「配置取得失敗\nDepot urls is empty」（`M/api/config/BaseConfig.java:113`、`values-zh-rTW/strings.xml:1122`）。
- 不過濾空 url：若第一項 url 空，載入失敗。

### 2.2 流程與記憶

- `parseDepot`：每一倉存成 `Config` 表一列（`Config.find(Depot, VOD)`，`(url,type)` 唯一索引，新列 `time=0`；`M/bean/Config.java:22-43,128-131`），**固定載入第一項**（`VodConfig.java:152`），成功後**刪除外層多倉網址**（所有 type；`:153`、`M/db/dao/ConfigDao.java:36-37`）。上游 `FongMi/TV@097917c1` 同此（`VodConfig.java:163-167`）。
- 選倉介面**不是專用選擇器**，就是點播設定的歷史清單 `HistoryDialog.vod()`：設定頁「點播歷史」按鈕（`LB/ui/activity/SettingActivity.java:129,228-229`），列 `Config.getAll(0)` 依最近使用排序、排除目前這一項（`LB/ui/adapter/ConfigAdapter.java:42-46`），標籤 name 否則 url（`:72`、`Config.java:245-249`），可刪除。
- 重啟：取 `time` 最新的一筆（`Config.java:90-93`）。手動點選的倉會 `update()` 寫入時間，重啟會保留。
- **Android 疑似缺陷**（讀碼推論，未實機驗證）：自動載入的第一倉不會更新 `time`（`BaseConfig.java:104` 比對外層與第一倉 id 不同），所以若使用者以前用過其他設定，重啟可能跳回那個舊設定。iOS 不照抄。

### 2.3 巢狀、相對路徑、直播、切換

- **巢狀**：某一倉本身又回 `urls` 會遞迴，**沒有深度上限**；自我引用會無限遞迴到 StackOverflowError，只顯示「配置取得失敗」。
- **相對路徑**：對解碼後的整段原文做字串取代 `../`、`./`，基準是**當次實際抓取的 URL**（`Decoder.java:42-50`；重導向後 query 數相同就改用重導向後 URL，`:27-29`；`.js?` 特例 `:23,44,52-57`）。所以倉內 `./py/x.py`、`./jar/x.jar`、`lives` 以**該倉自己的 URL** 為基準；外層 `urls` 裡寫成相對的 `url` 以**外層網址**為基準。
- **直播**：`LiveConfig` 也處理 `urls`，邏輯相同、type=LIVE（`LiveConfig.java:160-177`）。點播倉內的 `lives` 只在直播原本跟隨點播或尚未設定時才同步（`BaseConfig.java:70-72`、`LiveConfig.java:88-92`）。
- **切換倉**：`VodConfig.load` 先 `clear()` 站台、首頁站、解析、規則、廣告、jar（`VodConfig.java:71-73,84-98`）再載入。首頁站、解析器存在各倉的 `Config` 列，歷史與收藏以 `Config.id` 區分（`M/bean/History.java:117-121`），所以都跟著倉走。
- **單一倉失敗**：不退回下一項，只顯示錯誤吐司。
- 重複 url：資料庫只留一列，已存在的列不會改名（`Config.java:130`）。http 與 https 視為不同。

## 3. iOS 現況（`cb825e3f`）

縮寫：`Core=ios/Sources/WebHTVCore/`，`App=ios/WebHTVApp/Sources/WebHTVApp.swift`。

### 3.1 載入流程

1. 輸入網址：`useRemote(_:named:)`（`App:482`）檢查 http(s)，**抓取前就** `saved.upsert`＋`persistSaved()`（`App:490`、`:539`），再 `load(remote:)`。
2. `load(remote:showHome:reportFailure:)`（`App:455`）：`ConfigLoader.fetch(from:)`（`Core/ConfigLoader.swift:101`，`URLSession.webHTV` 不用 HTTP 快取，非 2xx 丟錯）→ `validate(_:from:packs:)`（`:114`）→ `validate(_:resolvedBy:)`（`:83`）→ `decode`（JSON5，允許 `//` 註解）→ `unwrapped`（`:52`：JSON 原樣、`xxxxxxxx**base64`、`2423…` AES-CBC）→ `WebHTVConfig.init(from:)`（`Core/WebHTVConfig.swift:22-49`）。失敗時保留目前來源與快取，只顯示「遠端設定載入失敗：…」（`App:465-468`）。
3. 採用：`adopt(_:config:from:)`（`App:710`）寫快取檔、`configSourceURL`／`configUpdatedAt`（`App:713`），`show(_:from:)`（`App:673`）算 `sites`／`lives`，重設 `SpiderSessionStore`，`SiteSelection.choose` 選站（`App:723`）。
4. 啟動：`restore()`（`App:760`）讀磁碟快取，再 `refreshRemote(quiet:)`（`App:549`，2/5/15 s 重試，不跳 alert）。
5. 切換已存來源：`use(_ entry:)`（`App:497`）直接 `load(remote:)`。

**今天收到多倉 JSON 的結果**：`WebHTVConfig.CodingKeys` 沒有 `urls`（`Core/WebHTVConfig.swift:22`），`sites` 解成空陣列 → `validate` 丟 `.noSupportedSites`（`Core/ConfigLoader.swift:94`）→ 先去抓倉網址旁的 `./spiders/manifest.json`（`:117-119`）→ 仍失敗，跳出「遠端設定載入失敗：此設定沒有 iOS 可用的來源（CMS 或已支援的爬蟲）。」而且倉網址已被存進「已存來源」（`App:490`）。

### 3.2 相對路徑

唯一入口 `ConfigSource.resourceURL(for:)`（`Core/ConfigSource.swift:51`）：切掉 `;md5;…`，絕對網址原樣，`./`／`../` 用 `URL(string:relativeTo: baseURL)`；`baseURL` 就是該份設定自己的 URL。py、jar、drpy、type-4 `api`、`ext`、相容套件都走它。直播清單走 `LiveListLoader.address(_:base:)`（`Core/Live/LiveListLoader.swift:58-64`）。→ **子設定以 `ConfigSource.remote(子URL)` 載入時，相對路徑自然以子 URL 為基準，與 Android 一致，不需改。**

### 3.3 儲存

- UserDefaults：`configSourceURL`（`App:40`）、`configUpdatedAt`（全域一個）、`selectedSiteKey`（舊）、`selectedSiteBySource`（`App:39`，`[ConfigSource.identity: 站 token]`）。
- Application Support：`saved-sources.json`（`SavedSourceList`，`Core/SavedSource.swift:54`）、每來源一份快取 `<base64url(url)>.json`（`SavedSource.cacheFileName`）、`local-sites.json`（每來源本機站）。
- 以 `source.identity`（URL 字串）分開存的：記住的站、本機站、站點健康、直播狀態、收藏與觀看紀錄、drpy 快取。**全域一份**：相容套件 `SpiderPackStore`、`configUpdatedAt`。
- 儲存空間清理只保留「已存來源＋目前來源」的快取（`App:4592`）。

### 3.4 UI

- 空狀態「尚未載入設定」＋toolbar「使用網址」「匯入設定」（`App:166` 一帶）；「使用網址」開 alert「加入設定來源」（名稱、網址）→ `useRemote`（`App:396`）。
- 首頁 header「切換內容來源，目前為 …」開 sheet「內容來源」（`App:1122`、`:1149`）——**列的是目前設定裡的站，不是設定來源**。
- 設定頁：「內容來源」section（站）、「設定來源」section（`App:2428`：顯示原始 URL、上次更新、加入設定來源、重新整理、匯入本機檔案）、「已存來源」section（`App:2470`：已存的設定，目前使用打勾 `activeSourceID` `App:2504`，點一下切換，左滑刪除／改名）。
- 用詞：程式裡「內容來源」＝站，「設定來源」＝設定檔。

### 3.5 測試

`ios/Tests/WebHTVCoreTests/`：`ConfigLoaderTests`（含 base64／CBC 包裝、相對 type-4 api）、`ConfigSourceTests`（相對路徑、驗證）、`SavedSourceTests`、`SiteSelectionTests`、`LocalSitesTests`、`Live/*`。App 層流程（`adopt`、`restore`、`useRemote`）沒有單元測試。

## 4. 方案比較

| | A 不做 | B 照搬 Android | C iOS 調整版（建議） |
|---|---|---|---|
| 做法 | 維持現狀 | 新增「設定歷史」資料表語意：每倉一筆、載入第一倉、刪外層網址；遞迴不設限；選倉用歷史清單 | 多倉偵測放在 Core（解碼後、驗證前）；每倉存成既有的 `SavedSource`（加可選欄位 `depot`）；載入第一倉（或此倉群組上次用的那倉）；外層網址不當成設定來源；巢狀設深度與循環上限；選倉沿用「已存來源」並依倉分組 |
| 對齊 Android | ✗ 多倉網址報錯 | ✓ 最接近（含其缺陷：自動載入的第一倉不記時間、自我引用爆堆疊） | ✓ 格式、判斷順序、相對路徑、第一倉、各倉獨立的站／收藏／紀錄都一致；選倉 UI 用 iOS 既有清單 |
| 改動量 | 0 | 大：iOS 沒有 Config 歷史表，要新造一套與 `SavedSource` 重疊的資料 | 中小：Core 一個解析函式＋`SavedSource` 一個可選欄位＋`load(remote:)` 一個分支＋設定頁分組 |
| 單倉風險 | 無 | 中（新資料層取代既有來源清單） | 低：只在頂層 JSON 物件有 `urls` 陣列時才走新分支 |
| 維護 | — | 兩套來源資料要同步 | 沿用既有快取、記站、本機站、健康、收藏的 identity 分隔 |
| 回退 | — | 難（資料遷移） | 易：`depot` 是可選欄位，舊版讀檔忽略即可 |

結論：**建議 C**。B 的資料模型在 iOS 等於重做「已存來源」，還會複製 Android 的兩個缺陷；A 不滿足需求。

## 5. 建議方案（C）細節

### 5.1 Core（`ios/Sources/WebHTVCore/`）

- 新增 `Depot`（或放在 `ConfigLoader.swift`）：`static func entries(_ data: Data, from url: URL?) -> [SavedSource]?`（`url` 為 nil 表示匯入的本機檔案）
  - 用既有 `unwrapped`＋JSON5 解碼；**只有頂層是物件且 `urls` 是陣列**才回非 nil（`urls` 優先於 `sites`，對齊 Android）。
  - 每項 `{url,name}`：`url` 去空白，空的略過（比 Android 寬容）；相對 `./`、`../` 以**倉網址**解析（`URL(string:relativeTo:)`，同 `ConfigSource.resourceURL` 規則），沒有倉網址（匯入檔案）時相對項目略過並計數；只收 http(s)；依 `absoluteString` 去重、保留順序。
  - 陣列為空或全部無效 → 丟新錯誤 `ConfigLoaderError.emptyDepot`，訊息「多倉清單是空的（Depot urls is empty）」。
- `ConfigLoader.fetch(from:)` 改回傳列舉 `.config(data, WebHTVConfig)`／`.depot([SavedSource])`，**在 `validate(_:from:)` 之前判斷多倉**，避免對倉網址旁的 `./spiders/manifest.json` 發請求（`ConfigLoader.swift:117-119`）。
- `SavedSource` 加可選欄位 `depot: SavedSource.Depot?`，`Depot { id: String, url: URL?, name: String }`（`Codable` 用 `decodeIfPresent`，舊檔相容）：
  - `id`：分組鍵。遠端倉＝倉網址 `absoluteString`；匯入的多倉檔＝`imported:<檔名>`。
  - `url`：遠端倉網址（供「重新整理倉清單」重抓）；匯入檔為 nil。
  - `name`：分組標題。取「加入設定來源」對話框輸入的名稱；空白時用倉網址的主機名稱（匯入檔用檔名）。因為倉網址那一筆會從已存來源移除（§5.2），**倉名稱只存在各項的 `depot.name`**，同一倉各項一致；「改名」倉時一次改同組各項。

### 5.2 App（`WebHTVApp.swift`）

- `load(remote:)` 收到 `.depot(entries)`：
  1. 每項 `entries` 標上 `depot = Depot(id: 倉網址, url: 倉網址, name: 使用者輸入的名稱或主機名稱)`，`saved.upsert`（已存在的保留使用者改過的項目名稱，空名才補倉給的名稱）；把**倉網址本身**從 `saved` 移除，`persistSaved()`。
     - **刻意與 Android 不同**（Reviewer N-1）：Android 是第一倉**載入成功後**才刪外層網址；iOS 在載入前就移除。理由：各倉此時都已是可單獨使用的已存來源，第一倉失敗時使用者可直接點其他倉；倉網址仍保存在各項的 `depot.url`，可用「重新整理倉清單」重抓。所以第一倉失敗時 iOS 留下各倉、沒有外層；Android 則留著外層。
  2. 選要載入的倉：若目前來源已是此倉的一項 → 不切換；否則載入第一項。（Android 永遠第一項；iOS 只在「重新整理倉清單」時保留目前那倉，避免無故跳倉。）
  3. 遞迴呼叫 `load(remote: 子URL)`，帶入已走過的網址集合；**深度上限 3、遇到已走過的網址即停**，顯示「多倉設定巢狀過深或互相引用」。
     - （Reviewer N-2）中間層不切畫面、不跳錯誤：遞迴時內層以 `showHome: false, reportFailure: false` 呼叫，只有最外層在最後成功時切回首頁、失敗時只顯示一次錯誤。
  4. 顯示提示「已加入 N 個倉，目前使用：<名稱>」。
- **倉網址永遠不會成為 `source`／`configSourceURL`**，所以 `restore()` 與啟動時的安靜刷新只會刷新目前那一倉（風險見 §7）。
- 子設定以 `ConfigSource.remote(子URL)` 採用：快取、記住的站（`selectedSiteBySource`）、本機站、站點健康、直播、收藏與觀看紀錄全部**自動按倉分開**，與 Android「跟著倉走」一致，不需改。
- 單一倉失敗：沿用現有行為——保留目前來源與快取，只顯示錯誤（`App:465-468`），不自動換下一倉（對齊 Android）。
- **匯入本機檔案**（Reviewer F-1；`App:405` `.fileImporter` → `load(_ url:)` `App:430`，今天直接 `ConfigLoader.validate(data)`）：在 `validate` 之前先 `Depot.entries(data, from: nil)`：
  - 是多倉：**絕對 http(s) 網址**的項目照加入已存來源（`depot = Depot(id: "imported:<檔名>", url: nil, name: <檔名>)`），**相對網址的項目略過**（匯入檔沒有基準網址，對齊 iOS 現有「匯入檔不錨定相對路徑」的規則，`ios/Tests/WebHTVCoreTests/ConfigSourceTests.swift` 的 `anImportedFileAnchorsNothing`）；接著以 `load(remote:)` 載入第一個絕對項目。提示「已加入 N 個倉；M 個相對網址略過，請改用『使用網址』加入多倉網址」。
  - 全部都是相對網址或空：不改任何狀態，顯示「匯入的多倉檔案沒有完整網址，請改用『使用網址』加入」。
  - 匯入的多倉檔本身不寫入 `wang-movie.json` 快取、不成為目前來源；這一組沒有「重新整理倉清單」（`depot.url` 為 nil）。
  - 不是多倉：照現有流程，不變。
- 直播：iOS 沒有獨立直播來源，切倉時 `lives` 跟著子設定換，等同 Android「直播跟隨點播」的預設情形。Android `LiveConfig` 的 `urls`（獨立直播多倉）iOS 沒有對應入口，**不做**。

### 5.3 UI 草圖

設定頁「已存來源」依倉分組（沒有倉的維持原樣），右側打勾表示目前使用：

```
設定
├ 設定來源
│   來源        王的影視（倉：我的多倉）      ← 原本顯示原始 URL，改為名稱＋所屬倉
│   上次更新    11/17 11:20
│   加入設定來源
│   重新整理                                  ← 目前那一倉
│   重新整理倉清單                            ← 只有目前來源屬於某倉時才出現（重抓倉網址）
│   匯入本機檔案
├ 已存來源
│   ── 我的多倉（https://…/depot.json）──     ← 標題＝depot.name（＋網址）；匯入檔的組顯示檔名
│   王的影視                              ✓
│   成人
│   ── 其他 ──
│   單倉設定 A
```

- 「加入設定來源」對話框不變：貼多倉網址或單倉網址都可，App 自動判斷。
- 首頁 header（「內容來源」選站）不變；選倉入口只在設定頁，與 Android 的設定頁歷史清單同位置。
- 左滑「刪除」一倉只刪那一項；「刪除整個倉」（一次刪同組）列為可選，第二階段視時間再定。

## 6. 驗收條件（第二階段）

1. 用本機多倉設定網址（18xxx 提供 `{"urls":[…]}`，指向 GitHub recha 的 `wang-movie.json` 與 `wang-sex.json`）加入：已存來源出現該倉分組與各項，自動載入第一項，首頁站台為第一項的站。
2. 在已存來源點第二項：首頁站台換成第二項的站，直播清單也換成第二項的。
3. 重開 App：仍是上次選的那一項，記住的站正確。
4. **單倉設定行為完全不變**：既有 `ConfigLoaderTests`／`ConfigSourceTests`／`SavedSourceTests` 全過；單倉網址加入、切換、重開與現在相同。
5. 多倉 JSON 以 `**` base64、`2423` AES 包裝仍能辨識；`urls` 與 `sites` 並存時走多倉；相對 `url` 以倉網址解析；空 `urls` 顯示「多倉清單是空的」。
6. 巢狀：倉內一項本身又是多倉可展開；自我引用或超過 3 層會停下並提示，不當機。
7. 某一倉抓取失敗：保留目前來源，只提示錯誤。
8. 倉網址本身不出現在已存來源、不成為目前來源；啟動安靜刷新只刷新目前那一倉。
8a. **匯入本機多倉檔案**：絕對網址的項目加入已存來源並自動載入第一個，分組標題為檔名；相對網址項目略過並提示改用網址；全部是相對網址時不改狀態只提示。匯入一般單倉檔案行為不變。
8b. 倉名稱：加入時輸入的名稱出現在分組標題；未輸入時顯示主機名稱；重開 App 後仍在。
9. 舊版 `saved-sources.json`（沒有 `depot` 欄位）可正常讀入。
10. Core 新增單元測試：多倉解析（含包裝、相對 url、去重、空陣列、`urls` 優先、`from: nil` 時相對項目略過並計數）、只有 `sites` 的設定不被當成多倉、`SavedSource`（含 `depot`）新舊格式相容。

## 7. 風險

- **倉網址被當成設定來源**：今天 `useRemote` 抓取前就存網址（`App:490`）。第二階段要在判定為多倉後把倉網址移出 `saved`，並確保它不寫入 `configSourceURL`，否則啟動刷新會安靜地失敗。
- **儲存空間清理**：子設定若沒進 `saved`，快取會被當無效檔刪掉（`App:4592`）——各倉都 upsert 進 `saved` 即可避免。
- **全域狀態**：相容套件 `SpiderPackStore` 與 `configUpdatedAt` 是全域的，頻繁切倉時相容套件跟著換、「上次更新」只反映最後一次。這與今天切換已存來源相同，不是新問題；記錄、不在本單處理。
- **identity 依 URL 字串**：倉給的網址若和使用者原本存的只差尾端斜線或大小寫，會被當成不同來源（Android 也一樣）。不做正規化，記錄。

## 8. 回退

第二階段一次原子提交；回退＝`git revert`。資料面：`SavedSource.depot` 是可選欄位，舊版 App 讀 `saved-sources.json` 會忽略它，各倉項目仍以一般已存來源出現，可正常使用。

## 9. 第二階段範圍與時間

- 預計改動：`ios/Sources/WebHTVCore/ConfigLoader.swift`（或新檔 `Depot.swift`）、`SavedSource.swift`、`ios/WebHTVApp/Sources/WebHTVApp.swift`（`load(remote:)`、`useRemote`、設定頁已存來源分組與「重新整理倉清單」）、`ios/Tests/WebHTVCoreTests/` 新增或擴充測試、本文件。
- 驗證環境（Reviewer N-3）：本機 HTTPS 伺服器提供 `{"urls":[…]}`，各項指向 GitHub `st7833232/recha` main 的 `wang-movie.json`、`wang-sex.json`（用前 `git ls-remote https://github.com/st7833232/recha.git main`，報告寫 SHA）；另備一份含相對網址的多倉檔供匯入測試。
- 時間（本 agent 實際作業）：Core＋測試約 1 小時；App 流程（含匯入入口）與 UI 約 1.5 小時；Simulator 驗證（建置、本機多倉伺服器、驗收 1–9）約 1.5 小時；Ponytail 與文件約 0.5 小時。合計約 4.5 小時，不含審查往返。

## 10. 第一階段狀態

第一階段完成；2026-11-17 依 Reviewer #8681 補匯入本機檔案入口（F-1）、倉名稱欄位（F-2）與 N-1～N-3 註記，重送 Reviewer（webhtv-dev-codex-reviewer-2）審查；核准「開始實施」前不改程式碼。

## 11. 第二階段：實作與驗證（2026-11-17，使用者核准方案 C，Manager #8694）

使用者確認的行為：原有來源保留在「其他」組；新多倉各項自動加入並載入第一倉；網址相同不重複；同一網址出現在兩個多倉時歸到最後加入的那組。Reviewer 提醒：同名匯入檔改用內容雜湊分組。

### 11.1 改動

| 檔案 | 內容 |
|---|---|
| `ios/Sources/WebHTVCore/DepotConfig.swift`（新） | `DepotConfig.entries(_:from:)`：解包後（`unwrapped`，JSON5）只有頂層物件且 `urls` 是陣列才算多倉；相對 `./`、`../` 以倉網址解析，無網址（匯入檔）時略過並計數；略過空白／非 http(s)／重複；全空丟 `emptyDepot`。`importedID(_:)`：`imported:`＋SHA-256 前 8 位元組。 |
| `ios/Sources/WebHTVCore/ConfigLoader.swift` | `ConfigLoaderError` 加 `emptyDepot`／`depotLoop`／`importedDepotNeedsAddress`；`fetch(from:)` 回傳 `Fetched`（`.config`／`.depot`），**驗證前**先判斷多倉，倉網址不會被探測相容套件。 |
| `ios/Sources/WebHTVCore/SavedSource.swift` | `SavedSource.depot: Depot?`（`{id, url?, name}`，舊檔相容）；`SavedSourceList.adopt(_:into:replacing:)`（移除倉網址本身、同網址只留一筆並移到最後加入的倉、保留使用者改過的名稱）、`renameDepot(id:to:)`、`groups`（各倉依出現順序，無倉的最後）。 |
| `ios/WebHTVApp/Sources/WebHTVApp.swift` | `load(remote:)` → 新 `open(remote:visited:)`：多倉時加入各項、目前來源已屬此倉則只更新清單（「重新整理倉清單」），否則開第一項；深度 3＋循環偵測。匯入入口 `load(_:)` 先判斷多倉（§5.2 F-1）。`depotNotice` 提示在載入結束且未失敗時才顯示，失敗時併進錯誤訊息。設定頁：有多倉時「已存來源」依倉分組（標題「多倉：名稱」＋改名、倉網址在 footer，無倉者在「其他」），沒有多倉時維持原本單一區塊；「設定來源」的「來源」對多倉項目顯示「名稱（多倉：倉名）」，並出現「重新整理倉清單」。 |
| `ios/Tests/WebHTVCoreTests/DepotConfigTests.swift`（新） | 10 個測試：相對解析、`urls` 優先／一般設定不是多倉／直播 `urls` 不誤判、空白重複非 http 略過與空清單錯誤、base64 包裝與註解、匯入檔相對略過計數、內容雜湊分組、加入與移除倉網址、最後加入的倉擁有、整組改名、舊檔相容與往返。 |
| `ios/Tests/WebHTVCoreTests/ConfigSourceTests.swift` | 連網測試配合 `fetch` 新回傳型別。 |

### 11.2 驗證

- 單元測試：`swift test`（`ios/`）**1563 tests in 67 suites 全過**（`.herdr-synapse/webhtv-dev/artifacts/w311/core-tests-full.txt`）。
- Simulator：webhtv-w311（iOS 27，iPhone 17 Pro），本分支 Debug 現場建置；熱點 172.20.10.7。測試伺服器 HTTPS 18451 提供多倉檔與 GitHub `st7833232/recha` main **`e6adf93a55996b876029f5c994fde330b439a30f`**（`git ls-remote` 確認）的鏡像；多倉的絕對項目指向 `raw.githubusercontent.com/st7833232/recha/e6adf93a…/wang-movie.json`。證據 `.herdr-synapse/webhtv-dev/artifacts/w311/`（`sim/*.labels`、`*-end.txt`、`srv.log`、`w311.sh`）。

| 驗收 | 結果 |
|---|---|
| 1 加入多倉網址 | 「加入 2 個倉，第一個是『影視（GitHub）』」；已存來源只剩兩項、倉網址本身已移除；相對 `./mirror/wang-sex.json` 解析為 `https://127.0.0.1:18451/mirror/wang-sex.json`；首頁為第一項的站（YouTube｜PY，22 部）（`v1`） |
| 2 選第二項 | 首頁換成 wang-sex 的站（黃豆短劇，18 部），`configSourceURL` 為第二項（`v5`）。兩份設定的直播清單名稱相同，畫面上無法以名稱區分；程式上直播一律取自目前那份設定 |
| 3 重開 App | 仍是第二項；在第二項改選 Pornhub(嗷嗚) 後重開仍是它（`v6`、`v9`） |
| 4 單倉不變 | 單倉網址加入照舊載入、歸「其他」組、無多倉提示（`t4`）；既有單元測試全過 |
| 5 包裝／優先／空 | base64 包裝的多倉被辨識（`t6`）；`urls`＋`sites` 走多倉（`t8`）；空清單「多倉清單是空的（Depot urls is empty）」（`t7`） |
| 6 巢狀／循環 | 多倉→內層多倉→載入 wang-sex（`t9`）；自我引用「多倉設定巢狀過深或互相引用」（`t10b`） |
| 7 一項失敗 | 第一項 404：「設定來源回應 HTTP 404」，目前來源不變（`t11d`） |
| 8 倉網址不當來源 | 倉網址不在已存來源、不寫入 `configSourceURL`；重開時伺服器沒有再收到倉網址請求（`srv.log`） |
| 8a 匯入多倉檔 | 只有相對網址：提示改用網址、已存來源與目前來源不變（`i5`）；混合：加入絕對項並開啟、略過 1 個相對項並提示、分組鍵 `imported:f99996bd…`、名稱為檔名（`i6`） |
| 8b 倉名稱 | 分組標題「多倉：<輸入的名稱>」；未輸入時為主機名稱；整組改名只改該組（`v4`、`n1`） |
| 同網址兩倉 | 第二個多倉列相同網址：兩項移到後加入的倉、保留原名稱（`t5`） |
| 重新整理倉清單 | 重抓倉網址、「倉清單已更新：1 個倉」、目前來源不變（`r1`） |
| 9 舊檔相容 | 單元測試 `aListSavedBeforeDepotsDecodesUnchanged` |
| 10 單元測試 | 見上 |

驗證中修正的問題（已含在本次提交）：
1. 多倉提示與錯誤同時出現時兩個對話框都不顯示（自我引用、第一項失敗）→ 提示等載入結束才顯示，失敗時併進錯誤。
2. 提示裡的第一項名稱改用已存名稱（使用者改過的名稱優先）。

Simulator 操作備註：此模擬器 App 為繁中、鍵盤為注音，XCUITest 打英文網址會被注音吃掉，改用 `simctl pbcopy`＋貼上；匯入檔放在 `group.com.apple.FileProvider.LocalStorage` 的 File Provider Storage。

### 11.3 Ponytail

`ponytail:ponytail-review`：Ship。唯一一項（啟動安靜刷新失敗時仍可能留下多倉提示）已套用：失敗時一律清掉 `depotNotice`。

### 11.4 限制

- 抓取失敗的網址（例如空的多倉清單）照既有行為留在已存來源，方便重試（與現有單倉一致）。
- 自我引用的倉會留下一筆指向自己的項目（點它會再顯示循環錯誤）。
- 真機沒測；Android 不改。
- 相容套件與「上次更新」仍是全域一份（§7 既有限制）。

### 11.5 回退

`git revert` 本提交；`saved-sources.json` 的 `depot` 是可選欄位，舊版 App 會忽略它。
