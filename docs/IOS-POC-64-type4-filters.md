# IOS-POC-64 — type 4 站的篩選（W-187）

狀態：**設計已核准（Reviewer #3721、Manager #3722），實作中**。分兩個 commit（Reviewer 要求，`ac` 出問題可單獨 revert）：A「type 4 補 `ac=detail`」、B「type 4 篩選 `ext`」。基準：W-188 `422648a3`（parent `79ef062e`=origin/ios-poc），分支 `task/w187-type4-filters`。

## 0. 範圍
- 完成句：會回 `filters` 的 type 4 站（爱瓜TV、drpyS_枫林影视）出現篩選列，切換後列表跟著變；其他 type 4 站分類列表內容不變。
- 允許路徑：`docs/IOS-POC-64-type4-filters.md`、`ios/Sources/WebHTVCore/CMSClient.swift`、`ios/Tests/WebHTVCoreTests/CMSClientTests.swift`。`SourceClient` 已在 W-184 傳 `extend`，不用再改。

## 1. 現況（W-184 之後）
| 位置 | 現況 |
|---|---|
| `CMSClient.home()` type 4 | 以 `filter=true` 取分類（回應帶 `filters`），再 `CMSResponse(classes:list:)` 重組——**`filters` 被丟掉** |
| `CMSClient.listingQuery` type 4 | 只送 `t`、`pg`，**沒有 `ac`**（測試 `asksForTheDetailFormOnlyWhereItSuppliesThePoster` 斷言如此） |
| `CMSClient.filterQuery` | 只對 type 1 |

## 2. 研究（存取日 2026-10-20；證據 `.herdr-synapse/webhtv-dev/artifacts/new-sites-filter/raw/`、`requests.log`）
| # | 類別 | 來源 | 內容 |
|---|---|---|---|
| R1 | 上游原始碼 | FongMi `SiteApi.java:72-79`（首頁 `filter=true`）、`:103`（`ext=Util.base64(JSON, URL_SAFE)`）、`:53-55`（`ac(4)` = `detail`）；`catvod/.../Util.java:29`（`URL_SAFE = DEFAULT|URL_SAFE|NO_WRAP`，保留 `=`） | type 4 分類送 `ac=detail&t&pg&ext=<URL-safe base64 JSON>` |
| R2 | 成熟相關專案 | TVBox `q215613905/TVBoxOS` @ `ab11d289` `SourceViewModel.java:522-` ；`takagen99/Box` @ `258a5fef` `:361-376` | `ac=detail&filter=true&t&pg&ext=<標準 base64 JSON>` |
| R3 | 實測：爱瓜TV（`aigua1.php`） | 电视剧 `t=2`：不帶篩選首部《莲花楼》；`ext={"area":"19"}`（欧美），URL-safe 與標準兩種編碼都換成《权力的游戏第1季》… | 兩種編碼都吃；有沒有 `ac` 結果相同 |
| R4 | 實測：drpyS_枫林影视（`:5757/api/枫林影视`） | **沒有 `ac` 時回首頁**：`t=movie` 與 `t=tv` 都是《拜託了冰箱2》…且帶 `class`；`ac=detail&t=movie` 才是電影（《廢土戰警》…），`t=tv` 才是劇集（《她的局》…）；`ext={"cateId":"action"}` 只在有 `ac` 時生效 | **iOS 目前在這站點任何分類都看到同一份首頁片單（既有 bug）**；要讓篩選生效必須補 `ac=detail` |
| R5 | 實測：其他 type 4 | 采集集合 `t=1`、88看球 `t=4`、爱瓜TV `t=2`：有無 `ac=detail` 結果相同；drpyS／爱瓜 加 `ac` 後海報仍齊（48/48、24/24），采集集合本來就沒有海報（0/56 兩者相同）；php_无水印资源首頁無分類，無法測 | 補 `ac=detail` 對現有站無退化 |
| — | 規格／issue | CatVod type 4 無正式規格；R1–R2 兩個用戶端實作即事實標準 | — |

## 3. 方案
| 方案 | 內容 | 結果 |
|---|---|---|
| A 不改 | — | 無篩選；drpyS 分類錯誤 |
| B 只保留 `filters`＋`ext` | 不補 `ac` | 爱瓜有效；drpyS 篩選與分類仍錯（R4） |
| **C 照 FongMi（建議）** | 保留 `filters`；type 4 分類補 `ac=detail`；有篩選時加 `ext=<URL-safe base64 JSON>`（保留 `=`） | 兩站篩選有效，drpyS 分類順帶修正；其他站不變（R5） |

## 4. 設計（方案 C）
1. `home()` type 4：`CMSResponse(classes:list:filters: categories.filters)`。
2. `listingQuery`：type 4 也加 `ac=detail`（與 Android `ac(4)` 一致）。更新該函式與測試 `asksForTheDetailFormOnlyWhereItSuppliesThePoster` 的說明：原本「type 4 已有海報所以不加」的理由不變，但 drpyS 需要 `ac` 才會回分類（R4）。
3. `filterQuery`：type 4 且有非空篩選值時回 `[ext=<base64url(JSON)>]`（`Data.base64EncodedString()` 再把 `+/` 換成 `-_`，保留 `=`；JSON 鍵排序）。type 1 行為不變。
4. 單元測試：type 4 查詢為 `ac, t, pg, ext`，`ext` 解回原 JSON；沒有篩選時 `ac, t, pg`；type 1 不受影響。
5. Simulator：爱瓜TV 电视剧 選 地区=欧美 列表改變；drpyS_枫林影视 选「动作」列表改變、电影／电视剧兩分類內容不同；88看球（無 filters）分類照常。附 `[cms] category` log 與 total。

### 決策點
- **D-1（建議納入）**：補 `ac=detail` 會改變全部 type 4 站的分類請求。R5 測過 3 站無差異，且是 Android 的行為；它同時修正 drpyS 分類錯誤。若 Reviewer 認為修分類超出本單，可拆成先修 `ac` 的獨立 commit。

## 5. 實作紀錄

### Commit A — type 4 分類補 `ac=detail`（task guard `IOS-POC-64-A`）
- `CMSClient.listingQuery`：`ac` 不再只給 type 0/1，type 4 也帶 `ac=detail`（`detailAction`；type 0 仍是 `videolist`）。type 4 的 `listingQuery(categoryID: nil)` 沒有呼叫端（type 4 首頁走第一個分類）。
- 測試 `asksForTheDetailFormOnlyWhereItSuppliesThePoster`：type 4 期望改成 `ac, t, pg`，`ac` 為 `detail`。
- 前後對照（curl，2026-10-20，`.herdr-synapse/webhtv-dev/artifacts/new-sites-filter/raw/`）：drpyS_枫林影视 改前 `t=movie`、`t=tv` 都回同一份首頁片單（《拜託了冰箱2》…，`fl-movie.body`、`fl-tv-noac.body`）；改後 `ac=detail&t=movie` 《廢土戰警》…、`ac=detail&t=tv` 《她的局》…（`fl-movie-ac.body`、`fl-tv-ac.body`）。不退化：采集集合（`cj-t1-*`）、88看球（`kq-t4-*`）、爱瓜TV（`ag-t2`、`ag-t2-ac`）有無 `ac` 結果相同。php_无水印资源首頁無分類，**未驗證**。
- Simulator 前後截圖與 log 與 commit B 一起做（Manager #3722 的驗收）。
