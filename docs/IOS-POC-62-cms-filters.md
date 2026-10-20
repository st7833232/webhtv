# IOS-POC-62 — type 1 採集站的篩選（W-184）

狀態：**設計，待 Reviewer 核准後實作**。來源：W-183 根因（`.herdr-synapse/webhtv-dev/artifacts/new-sites-filter/根因.md`），使用者 2026-10-20 核准方案 A。

## 0. 範圍與時程

- 完成句：iOS 上會回 `filters` 的 type 1 採集站（目前是 创享影视）出現篩選列，切換後列表跟著變；不回 `filters` 的 type 1 站請求與畫面完全不變。
- 允許路徑：本文件、`ios/Sources/WebHTVCore/CMSClient.swift`、`ios/Sources/WebHTVCore/SourceClient.swift`、`ios/Tests/WebHTVCoreTests/CMSClientTests.swift`。不改 UI、不改 `XBPQ.js`（XBPQ 篩選是另一張單）、不改 spider 分支。
- 基準：`ios-poc` `25f3e662`，分支 `task/w184-cms-filters`，task guard `IOS-POC-62`。
- 時程（2026-10-20 16:10 CST 起）：設計審查等候；實作＋單元測試約 20 分；Simulator 驗證約 30 分；收尾約 10 分。

## 1. 現況（webhtv-dev1 `25f3e662`）

| 位置 | 現況 |
|---|---|
| `CMSClient.swift:425-431` `home()` type 0/1 | 分類用 `request([])`、片單用 `ac=detail` 並行請求，再 `CMSResponse(classes:list:)` 重組——**分類回應裡的 `filters` 被丟掉** |
| `CMSClient.swift:444` `category(id:page:)` | 沒有篩選參數 |
| `SourceClient.swift:58-62` `.cms` 分支 | 收到 `extend` 但不往下傳（註解寫「MacCMS 沒有篩選協定，所以忽略」） |
| `CMSClient.swift:6-8` | 註解「每個 MacCMS 來源 filters 都是空的」——创享已不符合 |
| `WebHTVApp.swift:1549`、`:1603`、`:1387` | UI 已就緒（IOS-POC-5J）：首頁有 `filters` 就顯示篩選列；分類請求已把 `chosenFilters` 當 `extend` 傳給 `SourceClient.category`；選「全部」（空值）會把那個鍵移除，所以 `extend` 不含空值 |
| `CMSResponse` | 已會解 `filters`（`CMSClient.swift:27`），CatVod 格式 |

## 2. 研究（存取日 2026-10-20）

| # | 證據類別 | 來源 | 內容 | 對決策的影響 |
|---|---|---|---|---|
| R1 | 上游原始碼（本 repo 的 Android） | FongMi `app/src/main/java/com/fongmi/android/tv/api/SiteApi.java`（repo HEAD 上的版本，最後修改 `e8a16685`）:80-86、:102 | type 1 首頁不帶參數 GET，`Result.fromType` 解出 `filters` 並掛到各分類（`setTypes`，:247）；分類只在 `extend` 非空時加 **`f=<JSON>`**；type 4 加 `ext=base64url(JSON)`（:103） | 首頁保留 `filters` 是對的；但只送 `f=` 對创享無效（R4） |
| R2 | 成熟相關專案原始碼 | TVBox 原版 `q215613905/TVBoxOS` @ `ab11d289e09963a9daf65ca7f6b7a9a8cbe184e1` `SourceViewModel.java:488-489` | type 0/1 分類：`.params(sortData.filterSelect)`（**每個篩選鍵直接當網址參數**）＋`.params("f", JSON)` | 兩種伺服器都照顧到 |
| R3 | 成熟相關專案原始碼 | `takagen99/Box` @ `258a5fef61578869ae905ca230bdde9e99fc19a8` `SourceViewModel.java:199-220`、`:326-330`、`:892-909` | 首頁不帶參數 GET、解析 `filters`；分類同 R2：每鍵一參數＋`f` | 同上，第二個獨立實作 |
| R4 | 實際伺服器行為 | 创享 `https://ys.cxkjg.cn/api/provide/vod`（`.herdr-synapse/webhtv-dev/artifacts/new-sites-filter/raw/cxkjg-*.body`、`requests.log`） | 首頁回 `filters`（9 類，鍵 `cid`／`area`／`language`／`sort`）。`ac=detail&t=9` 35683 筆；`&area=日本` 1934；`&cid=5`（t=1）1389；`&f={"area":…}` 與 `&ext=base64` **無效**；`area`＋`sort`＋`f` 同帶仍是 1934 且排序改變；`pg=2` 沿用篩選。站方自己的 TVBox 設定（`raw/cxkjg-tvbox.body`）寫 `type 1, filterable 1` | 選 R2 寫法；附帶 `f` 無害 |
| R5 | 實際伺服器行為 | 設定檔 17 個 type 0/1 站首頁（`research/type1-sites.tsv`、`raw/t1-*-home.body`） | 只有创享回 `filters`；vod_360、非凡、量子等 15 個 JSON 站都沒有；2 個 XML 站（type 0）沒有 | 其他站不會出現篩選列，也就不會帶篩選參數 → 請求不變。**vod_360 沒有篩選可顯示**（它的 `categories` 只是限制顯示哪些分類），只能當不退化對照 |
| R6 | 實際伺服器行為（範圍外） | 6 個 type 4 站加 `filter=true`（`research/type4-sites.tsv`、`raw/t4-*-home.body`） | 爱瓜TV、drpyS_枫林影视 回 `filters`；`CMSClient.swift:438` 同樣丟掉 | 同根因，但本單不做（見 §4 決策 D-2） |
| — | 官方規格 | 苹果CMS10 `provide/vod` 沒有篩選協定；CatVod 也沒有正式規格文件，事實標準就是 R1–R3 的用戶端實作 | 不適用，理由如左 | — |
| — | PR／issue／部落格 | 未搜尋：R1–R4 已能決定寫法（三個用戶端實作＋實測伺服器），再查不會改變決策 | — | — |

## 3. 方案比較

| 方案 | 內容 | 結果 |
|---|---|---|
| A 不改 | — | 创享沒有篩選（使用者回報的問題） |
| B 照 FongMi | 保留 `filters`；分類只送 `f=<JSON>` | 篩選列出現，但创享切換後列表不變——就是 Android 上「篩選不能用」 |
| **C 照 TVBox（建議）** | 保留 `filters`；type 1 分類把每個非空篩選值直接當網址參數，另附 `f=<JSON>` | 创享實測有效（R4）；只吃 `f` 的伺服器也有效；沒有 `filters` 的站不會有 `extend`，請求不變 |
| D 自己替一般苹果CMS 生篩選 | 依 `vod_year`／`vod_area` 等猜 | 拒絕：協定沒有，各站參數不一，不可驗證 |

## 4. 設計（方案 C）

1. `CMSClient.home()` type 0/1：重組時帶上分類回應的 `filters`（`CMSResponse(classes:list:filters:)` 已存在）。type 0 是 XML，解碼器本來就不產生 `filters`，行為不變。
2. `CMSClient.category(id:page:extend:)`：`extend` 預設 `[:]`。只有 **type 1** 且 `extend` 非空時，在 `listingQuery` 之後依鍵排序加上每個非空值，最後加 `f=<JSON>`（鍵排序，輸出固定）。
   - 與協定參數同名的篩選鍵（`ac`、`t`、`pg`、`f`、`ids`、`wd`、`h`、`at`）一律不帶：鍵是伺服器給的，撞名會蓋掉分類或頁碼。
   - type 0、type 4 不帶（D-2）。
3. `SourceClient.category` `.cms` 分支把 `extend` 傳下去；更新 `SourceClient.swift:56-57`、`CMSClient.swift:6-8` 的註解。
4. UI 不改：篩選列、清除、換分類時清空篩選都沿用 IOS-POC-5J。

### 決策點
- **D-1（建議照做）**：同時送「每鍵一參數」與 `f`，而不是只送前者。理由：兩個 TVBox 實作都這麼送，只吃 `f` 的伺服器（FongMi 生態）也能用；创享實測附帶 `f` 無害。
- **D-2（建議另開單）**：type 4 同根因（R6，2 站受影響），但不在本單核准範圍；改它會讓那 2 站出現篩選列，需要另外的實測。若 Reviewer／Manager 要併入，改動是同一處再加 `ext=base64url(JSON)`（R1:103）。

## 5. 驗收與驗證

- 單元測試（`CMSClientTests.swift`）：
  - type 1＋`extend` `{"area":"日本","cid":"5"}` → 查詢是 `ac, t, pg, area, cid, f`，`f` 為 `{"area":"日本","cid":"5"}`。
  - `extend` 空 → 查詢與現在相同（`ac, t, pg`）。
  - 空值與協定同名鍵被略過。
  - type 4 帶 `extend` → 查詢不變。
- 全量 `swift test` 一次。
- Simulator（熱點；创享主機未被 RPZ）：
  1. 创享：電影分類出現 类型／地区／语言／排序 列；選 地区=日本 → 列表換成日本片；再選 类型 → 列表再變；選回「全部」恢復。
  2. vod_360：沒有篩選列，分類列表照常。
  3. 非凡采集资源：沒有篩選列，分類列表照常。
- 回退：revert 本單 commit；不涉及資料或設定格式。

## 6. 實作紀錄

- 2026-10-20 16:15 Reviewer 核准設計（看板 #3622，紀錄 `.herdr-synapse/webhtv-dev/artifacts/w184-design-review-2026-10-20.md`）；D-2 type 4 另開 W-187。
- `CMSClient.home()` type 0/1：保留分類回應的 `filters`。
- `CMSClient.category(id:page:extend:)`＋`filterQuery(_:)`：只對 type 1；略過空值與 `protocolNames`（`ac t pg f ids wd h at`）；鍵排序，`f` 以 `JSONSerialization` `.sortedKeys .withoutEscapingSlashes` 產生。
- `CMSClient.log`（subsystem `com.webhtv.ios.poc`，category `cms`）：每次分類請求以 info 等級印出 `[cms] category <本 client 加的參數> <完整網址>`，供 Simulator 驗證與日後排查（Reviewer 要求 ②）。
- 2026-10-20 Reviewer 退回 F1（`.herdr-synapse/webhtv-dev/artifacts/w184-review-2026-10-20.md`）：初版以 `.public` 記完整網址，設定檔 `api` 可能自帶 key／token。修正：公開部分只有本 client 加的參數（`ac`、`t`、`pg`、篩選鍵值、`f`），完整網址 `.private`（Simulator 上 `log stream` 預設顯示 `<private>`）。Simulator 驗證用的是初版，表中網址即當時的公開輸出。
- `SourceClient.category` `.cms` 分支傳 `extend`；更新兩處註解。
- 測試：`sendsAType1SitesChosenFiltersAsParametersAndAsF`（含第 2 頁仍帶篩選、空值／協定同名鍵略過、type 0／4 不送）。全量 `swift test` 1378 通過（原 1376＋當時 2 個新測試）。
- Ponytail review（2026-10-20）：①刪除 `keepsTheFilterRowsAType1HomePublishes`——只測既有的 `filters` 解碼（`SourceClientTests.swift:498` 已涵蓋），碰不到 `home()` 那一行；`home()` 走固定的 `URLSession.webHTV`，不能注入，改由 Simulator 驗證（已採納）。②分類網址為了 log 多組一次，成本可忽略，不改。結論：修 ① 後可交付。

### Simulator 驗證（2026-10-20，熱點，臨時模擬器，工作樹 build）
證據：`.herdr-synapse/webhtv-dev/artifacts/new-sites-filter/gui-w184/`（`RESULT.md`、截圖、無障礙樹、`cms-log.txt` 為 App 的 `[cms] category` 網址；total 以同一網址另外請求取得）。

| 站 | 動作 | App 送出（`[cms] category`） | total | 結果 |
|---|---|---|---|---|
| 创享影视 | 電影 | `?ac=detail&t=9&pg=1` | 35683 | 出現 类型／地区／语言／排序 四列 |
| 创享影视 | 地区＝美国 | `…&area=%E7%BE%8E%E5%9B%BD&f={"area":"美国"}` | 8169 | 列表改變 PASS |
| 创享影视 | ＋类型＝动作片 | `…&area=…&cid=11&f=…` | 1232 | 列表再變（乐高蝙蝠侠大电影、开拓者、机械师）PASS |
| 创享影视 | 捲到第 2、3 頁 | `pg=2`／`pg=3` 仍帶 `area`、`cid`、`f` | — | PASS |
| 创享影视 | 兩列選回「全部」 | `?ac=detail&t=9&pg=1` | 35683 | 恢復 PASS |
| vod_360 | 連續劇、香港劇 | `?ac=detail&t=13&pg=1`、`t=14` | 4517、98 | 沒有篩選列，網址與改動前相同 PASS |
| 非凡采集资源 | 連續劇 | `?ac=detail&t=13&pg=1` | 8354 | 沒有篩選列 PASS |

未測：语言、排序兩列；电影以外的分類（日本不在地区列第一屏，改選美国）。

### 已知但不在本單處理
- **App 目前不讀站台的 `filterable` 欄位**（Reviewer 要求 ③）：篩選列只看伺服器有沒有回 `filters`。`filterable: 0` 的站若伺服器回了 `filters`，iOS 仍會顯示；FongMi 也是以 `filters` 為準。
- type 4 篩選：W-187。站台 `categories` 白名單：W-188。XBPQ 篩選：W-185／W-186。
