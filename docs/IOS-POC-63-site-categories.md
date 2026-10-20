# IOS-POC-63 — 站台 `categories` 白名單（W-188）

狀態：**設計，待 Reviewer 核准後實作**。來源：W-182 發現、Reviewer #3632 核對；Manager #3636 開單。

## 0. 範圍與時程

- 完成句：設定檔有 `categories` 的站，iOS 只顯示白名單內的分類（依白名單順序，平鋪），首頁片單也只留白名單分類的片；沒有 `categories` 的站完全不變。
- 允許路徑：本文件、`ios/Sources/WebHTVCore/WebHTVConfig.swift`、`CMSClient.swift`、`SourceClient.swift`、`ios/Tests/WebHTVCoreTests/CMSClientTests.swift`。不改 UI。
- 基準：`task/w184-cms-filters` `79ef062e`（W-184 已核准、待 Manager push），分支 `task/w188-site-categories`，task guard `IOS-POC-63`。
- 時程（2026-10-20 16:50 CST 起）：設計審查等候；實作＋測試約 25 分；Simulator 前後對照約 30 分。

## 1. 現況與問題

- `Site.CodingKeys`（`WebHTVConfig.swift:117`）沒有 `categories`，iOS 完全不讀白名單。
- 使用者 wang-movie.json（171 站）有 9 站設了 `categories`：vod_蜜雪（type 0）、vod_360、vod_天涯、vod_飘零、无忧采集资源、vod_艾旦、vod_优酷、如意、魔都（type 0）。沒有 spider 站設它。
- **修改前證據**：vod_360 首頁分類列露出「倫理片」（`.herdr-synapse/webhtv-dev/artifacts/site-categories/before/v01-launch.png`、`.txt`；W-184 驗證時的 build，分類行為與 `ios-poc` 相同）。vod_360 伺服器 51 個分類，白名單 26 個，`伦理片` 不在白名單。

## 2. 研究（存取日 2026-10-20）

| # | 證據類別 | 來源 | 內容 | 影響 |
|---|---|---|---|---|
| R1 | 上游原始碼（本 repo 的 Android） | FongMi `app/src/main/java/com/fongmi/android/tv/bean/Site.java:117-118`、`:322-323` | `categories` 為字串陣列，缺省為空 | 欄位形狀 |
| R2 | 同上 | `api/SiteApi.java` `setTypes`（:246-254） | 先把 `filters` 掛到各分類；`categories` 非空時，以**分類名稱精確比對**、依**白名單順序**組出新的分類清單；一個都對不上時保留原清單。spider 與 type 0/1/4 首頁都會呼叫 | 比對規則、順序、全失配回退 |
| R3 | 同上 | `api/SiteApi.java` `fetchPic`（:231-243） | type 0/1 首頁片單沒有圖時，只對 `type_name` 在白名單內的片再取詳情；一部都沒有就清空片單 | 首頁片單也要依白名單過濾，否則白名單外（伦理片）的片仍會出現在首頁 |
| R4 | 成熟相關專案 | TVBox `q215613905/TVBoxOS` @ `ab11d289`、`takagen99/Box` @ `258a5fef` 的 `SourceViewModel.java` | 不處理 `categories` | 只能以 FongMi 為準；這個欄位是 FongMi 生態的設定 |
| R5 | 實際資料 | 9 站白名單 × 各站首頁 `class`（`.herdr-synapse/webhtv-dev/artifacts/new-sites-filter/raw/t1-*-home.body`） | 精確比對對不上的：vod_360 7 個、vod_飘零 10 個、无忧 14 個、vod_艾旦 7 個、vod_优酷 1 個（`,记录片` 打錯）。主因是白名單寫繁體「劇」、伺服器是簡體「剧」（国产劇／国产剧、喜劇片／喜剧片…）；把劇→剧後只剩无忧 9 個（伺服器分類名本身不同）與优酷 1 個 | 見 D-2 |
| R6 | 本模組約束 | `TaiwanTraditional.swift:1-6` | 繁簡轉換「只供顯示」，模組內不得另作他用（`TaiwanTraditionalTests` 檢查） | 比對不能借用它做繁簡正規化 |
| — | 官方規格／issue／部落格 | CatVod 無正式規格，`categories` 只存在 FongMi 系用戶端 | 不適用，理由如左 | — |

## 3. 方案

| 方案 | 內容 | 結果 |
|---|---|---|
| A 不改 | — | 露出伦理片等白名單外分類 |
| **B 照 FongMi（建議）** | 讀 `categories`；首頁分類依名稱精確比對、依白名單順序平鋪；全失配保留原清單；type 0/1 首頁片單只留白名單分類的片 | 與 Android 一致；伦理片隱藏 |
| C B＋繁簡正規化比對 | 比對前把「劇」等字統一 | iOS 會比 Android 多顯示分類，兩平台不一致；而且不能用 `TaiwanTraditional`（R6），要另寫對照表 |

## 4. 設計（方案 B）

1. `Site` 加 `public let categories: [String]`，`CodingKeys` 加 `categories`，缺省或非陣列解成 `[]`。
2. `CMSResponse.restricted(to names: [String], listing: Bool) -> CMSResponse`（同檔，純函式，可測）：
   - `names` 空 → 原樣回傳。
   - 分類：依 `names` 順序，各取第一個同名分類，**平鋪**（`parentID` 0）；一個都對不上 → 保留原分類（R2）。平鋪的原因：白名單多半只列子分類（vod_360 的 动作片、国产劇…），現行 `categoryGroups` 只以頂層分類分組，父分類被濾掉後會整列消失。
   - `filters` 保留（以 `type_id` 為鍵，平鋪不改 id）。
   - `listing` 為真時，片單只留 `typeName` 在 `names` 內的片（R3；空片單就讓它空，與 Android 相同）。
3. `SourceClient.home`：`.cms` 分支回傳前套 `restricted(to: site.categories, listing: site.type == 0 || site.type == 1)`；`.spider` 分支只套分類（`listing: false`，R2 對 spider 只換分類）。
4. 不動：分類內容、搜尋（Android 也不依白名單過濾）、沒有 `categories` 的站。

### 決策點
- **D-1（建議照做）**：平鋪而非保留父子分組——與 Android 一致，且白名單只列子分類時分組會消失。
- **D-2（建議）**：iOS 照 Android 精確比對；R5 的「劇／剧」不一致建議**改設定檔**（把白名單裡的「劇」改成伺服器用的「剧」，並修 `,记录片`），這樣 Android 與 iOS 一起恢復。設定檔由使用者決定，本單只附清單，不改 wang-movie.json。

## 5. 驗收與驗證

- 單元測試：`restricted` 的白名單順序與平鋪、全失配回退、`names` 空時不變、片單依 `typeName` 過濾、spider（`listing: false`）不過濾片單；`Site` 解出 `categories`、缺省為空。
- 全量 `swift test` 一次，log 存檔附上（Reviewer #3697）。
- Simulator：vod_360 首頁分類列只剩白名單內、依白名單順序（不再有倫理片），首頁片單都屬白名單分類；无忧（部分失配）只顯示對得上的；非凡（無 `categories`）不變。
- 回退：revert 本單 commit。

## 6. 實作紀錄

- 2026-10-20 Reviewer 核准設計（看板 #3709）：方案 B、D-1 平鋪、D-2 改設定檔不做繁簡比對。基準改為已推上的 `origin/ios-poc` `79ef062e`（Manager #3702）。
- `Site.categories`（`WebHTVConfig.swift`）：`CodingKeys` 加 `categories`，非字串陣列或缺省解成 `[]`。
- `CMSResponse.restricted(to:listing:)`（`CMSClient.swift`）：依白名單順序、精確比對、平鋪（`parentID` 0）；全失配保留原分類；`listing` 時片單只留 `typeName` 在白名單內的片；`filters`、`failure`、`listedCategoryID` 保留。
- `SourceClient.home`：`.cms` 套 `restricted(to: site.categories, listing: type != 4)`；`.spider` 解碼後立刻套 `listing: false`，**在「首頁沒片單就列第一個分類」的回退之前**，免得回退挑到白名單外的分類。
- 測試：`showsOnlyTheCategoriesASiteNamesInItsOrderAndFlat`、`decodesASitesCategories`。全量 `swift test` 1379 通過（1377＋2），log：`.herdr-synapse/webhtv-dev/artifacts/site-categories/swift-test.log`。
- Ponytail review（2026-10-20）：①白名單名稱重複時（使用者設定的 vod_飘零 列了兩次 `电影`）會產生兩個同 id 的分類，SwiftUI `ForEach` 遇到重複 id 行為未定義 → 已修：比對前去重複、保留首次順序，測試加入重複名稱（已採納）。結論：修 ① 後可交付；未測：spider「先過濾再回退」路徑只有 `restricted` 本身的單元測試。
- 設定檔修正清單（D-2）：`.herdr-synapse/webhtv-dev/artifacts/site-categories/categories-fix.md`（40 筆：33 筆「劇→剧」、`,记录片`→`记录片`、无忧 9 筆伺服器沒有的分類）。

### Simulator 驗證（2026-10-20，熱點，臨時模擬器，工作樹 build 含去重修正，diff 57 行，安裝前後 sha256 `5330bc27…`）
修改前：`.herdr-synapse/webhtv-dev/artifacts/site-categories/before/v01-launch.png`（vod_360 分類列有「倫理片」）。修改後：`…/site-categories/after/`（`RESULT.md`、截圖＋無障礙樹、`cms-log.txt`、`build-head.txt`）。

| 站 | 觀察 | 結果 |
|---|---|---|
| vod_360 | 分類列只剩白名單內的 19 個，順序同白名單；沒有倫理片、電影、連續劇。首頁片單「已載入 22 部」＝360zy `ac=detail` 第 1～3 頁 60 部中 `type_name` 在白名單內的 22 部（大陆综艺、国产动漫、恐怖片），名單一致；被濾掉的含 `台湾剧`、`喜剧片`（D-2 的「劇」寫法）。點「動作片」送 `ac=detail&t=6&pg=1`，列表 20 部 | PASS |
| 无忧采集资源 | 只顯示 12 個分類，＝白名單中伺服器有的、依白名單順序 | PASS |
| 非凡采集资源（無 `categories`） | 分類列（電影片、連續劇、綜藝片、動漫片）與 W-184 時相同；連續劇子分類面板正常 | PASS |

未在 Simulator 驗：白名單全失配時保留原清單（單元測試涵蓋）、spider 站白名單（設定中沒有）。另注意：Debug build 在 Simulator 上 `.private` 欄位也會顯示，屬開發環境行為。

### 限制（Reviewer #3709 要求寫明）
1. **白名單一個都對不上時保留原清單**（與 Android 相同）：那時倫理片等分類會露出。所以 D-2 的設定檔修正很重要；目前 9 站都至少對得上一部分，不會整站失配。
2. **搜尋結果、spider 首頁片單不依白名單過濾**（Android 也不過濾）；spider 只換分類列。
3. **type 4 首頁片單不受白名單限制**：type 4 首頁片單來自第一個分類（過濾前的），目前沒有 type 4 站設 `categories`。
