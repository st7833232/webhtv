# W-311 iOS POC 多倉設定（urls depot）——第一階段設計研究

- 工單：herdr W-311（Manager #8661／#8662，brief `.herdr-synapse/webhtv-dev/artifacts/w311-brief.md`）。使用者需求（2026-11-17）：「android webhtv 有支援多倉設定，ios poc 也需要實作」。
- 階段：**第一階段只做設計研究，不改程式碼**（AGENTS.md §7）。經 Reviewer 審查、使用者核准「開始實施」後才進第二階段。
- 分支：`task/W-311`，底版 ios-poc `cb825e3fda82aecc601349043ef5f48e4734315d`（0.1.103）。下文 iOS 行號都以此為準；Android 行號以本倉 Android 程式（FongMi 分支）為準。
- 研究時間：2026-11-17 10:50–11:30（Asia/Taipei）。

## Recovery anchor

- 目標：設計 iOS 對「設定網址回傳 `{"urls":[{name,url}]}`」的多倉支援，對齊 Android 行為，單倉設定行為不變。
- 狀態：設計研究完成，待審查與使用者核准。未改任何程式碼。
- 下一步：使用者核准方案 C 後，開新的 guard（scope 見「第二階段範圍」）實作並在 Simulator 驗證。

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

- 新增 `Depot`（或放在 `ConfigLoader.swift`）：`static func entries(_ data: Data, from url: URL) -> [SavedSource]?`
  - 用既有 `unwrapped`＋JSON5 解碼；**只有頂層是物件且 `urls` 是陣列**才回非 nil（`urls` 優先於 `sites`，對齊 Android）。
  - 每項 `{url,name}`：`url` 去空白，空的略過（比 Android 寬容）；相對 `./`、`../` 以**倉網址**解析（`URL(string:relativeTo:)`，同 `ConfigSource.resourceURL` 規則）；只收 http(s)；依 `absoluteString` 去重、保留順序。
  - 陣列為空或全部無效 → 丟新錯誤 `ConfigLoaderError.emptyDepot`，訊息「多倉清單是空的（Depot urls is empty）」。
- `ConfigLoader.fetch(from:)` 改回傳列舉 `.config(data, WebHTVConfig)`／`.depot([SavedSource])`，**在 `validate(_:from:)` 之前判斷多倉**，避免對倉網址旁的 `./spiders/manifest.json` 發請求（`ConfigLoader.swift:117-119`）。
- `SavedSource` 加可選欄位 `depot: URL?`（`Codable` 用 `decodeIfPresent`，舊檔相容）。

### 5.2 App（`WebHTVApp.swift`）

- `load(remote:)` 收到 `.depot(entries)`：
  1. 每項 `entries` 標上 `depot = 倉網址`，`saved.upsert`（已存在的保留使用者改過的名稱，空名才補倉給的名稱）；把**倉網址本身**從 `saved` 移除（對齊 Android 刪外層），`persistSaved()`。
  2. 選要載入的倉：若目前來源已是此倉的一項 → 不切換；否則載入第一項。（Android 永遠第一項；iOS 只在「重新整理倉清單」時保留目前那倉，避免無故跳倉。）
  3. 遞迴呼叫 `load(remote: 子URL)`，帶入已走過的網址集合；**深度上限 3、遇到已走過的網址即停**，顯示「多倉設定巢狀過深或互相引用」。
  4. 顯示提示「已加入 N 個倉，目前使用：<名稱>」。
- **倉網址永遠不會成為 `source`／`configSourceURL`**，所以 `restore()` 與啟動時的安靜刷新只會刷新目前那一倉（風險見 §7）。
- 子設定以 `ConfigSource.remote(子URL)` 採用：快取、記住的站（`selectedSiteBySource`）、本機站、站點健康、直播、收藏與觀看紀錄全部**自動按倉分開**，與 Android「跟著倉走」一致，不需改。
- 單一倉失敗：沿用現有行為——保留目前來源與快取，只顯示錯誤（`App:465-468`），不自動換下一倉（對齊 Android）。
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
│   ── 我的多倉（https://…/depot.json）──
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
9. 舊版 `saved-sources.json`（沒有 `depot` 欄位）可正常讀入。
10. Core 新增單元測試：多倉解析（含包裝、相對 url、去重、空陣列、`urls` 優先）、只有 `sites` 的設定不被當成多倉、`SavedSource` 新舊格式相容。

## 7. 風險

- **倉網址被當成設定來源**：今天 `useRemote` 抓取前就存網址（`App:490`）。第二階段要在判定為多倉後把倉網址移出 `saved`，並確保它不寫入 `configSourceURL`，否則啟動刷新會安靜地失敗。
- **儲存空間清理**：子設定若沒進 `saved`，快取會被當無效檔刪掉（`App:4592`）——各倉都 upsert 進 `saved` 即可避免。
- **全域狀態**：相容套件 `SpiderPackStore` 與 `configUpdatedAt` 是全域的，頻繁切倉時相容套件跟著換、「上次更新」只反映最後一次。這與今天切換已存來源相同，不是新問題；記錄、不在本單處理。
- **identity 依 URL 字串**：倉給的網址若和使用者原本存的只差尾端斜線或大小寫，會被當成不同來源（Android 也一樣）。不做正規化，記錄。

## 8. 回退

第二階段一次原子提交；回退＝`git revert`。資料面：`SavedSource.depot` 是可選欄位，舊版 App 讀 `saved-sources.json` 會忽略它，各倉項目仍以一般已存來源出現，可正常使用。

## 9. 第二階段範圍與時間

- 預計改動：`ios/Sources/WebHTVCore/ConfigLoader.swift`（或新檔 `Depot.swift`）、`SavedSource.swift`、`ios/WebHTVApp/Sources/WebHTVApp.swift`（`load(remote:)`、`useRemote`、設定頁已存來源分組與「重新整理倉清單」）、`ios/Tests/WebHTVCoreTests/` 新增或擴充測試、本文件。
- 時間（本 agent 實際作業）：Core＋測試約 1 小時；App 流程與 UI 約 1.5 小時；Simulator 驗證（建置、本機多倉伺服器、驗收 1–9）約 1.5 小時；Ponytail 與文件約 0.5 小時。合計約 4.5 小時，不含審查往返。

## 10. 狀態

第一階段完成，送 Reviewer（webhtv-dev-codex-reviewer-2）審查；核准「開始實施」前不改程式碼。
