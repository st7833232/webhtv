# IOS-POC-60：資料夾導覽（`vod_tag` folder，W-40 FOLDER-IMPL）

> Recovery anchor（2026-10-15 11:55 CST）：已實作（W-40，guard `FOLDER-IMPL`，`--no-tag`）。Core 測試先紅後綠、ABI catvod.result 1.3、mutant 3/3 紅、全量 1187 通過、App Simulator build 成功、Ponytail 自審 Ship。不退化 GUI（R0–R7）全部 PASS；資料夾導覽本身的 GUI 依 Manager #2002 併到 W-41。下一步：Reviewer code review。

## 依據

- 設計：`.herdr-synapse/webhtv-dev/artifacts/qist-folder-design-2026-10-09.md`（W-28 PASS，sha256 `77e9ec60…ca74`，今天重算相同），輔助 `qist-folder-inputs-2026-10-09.md`（W-30 合成資料）、`qist-ikanbot-folder-2026-10-09.md`（W-26 方案 C）。
- 審查預備：`artifacts/review-prep-W-40-2026-10-13.md`（C01–C18、N01–N10、T1–T5、R0–R7）。行號基準 `8bee0b02`；之後的 commit 都沒動這 4 個檔，行號仍有效。
- 使用者 2026-10-12 核准實作。Manager #2002 選 a：本單交 Core 測試加上不退化的 GUI（R0–R7）；資料夾導覽 GUI（G1–G7、G11、G12）要有真的回 `vod_tag` folder 的來源，併到 W-41 Ikanbot 一起驗。

## 做了什麼

Android FongMi 的語義：列表項目 `vod_tag == "folder"` 時，點下去不是開詳情，而是以它的 `vod_id` 當分類 id 再呼叫 `categoryContent`，並帶入父列表的 extend。

| 檔案 | 改動 | 對應 |
|---|---|---|
| `CMSClient.swift` | `Vod.tag`；CodingKeys 只多 `case tag = "vod_tag"`；只收字串（`decodeIfPresent(String)` 失敗一律當空，不用 `decodeText`，數字不會變成字串）；memberwise init 加 `tag: String = ""`（呼叫端不用改）；`isFolder` 大小寫敏感 | C01–C04、C07 |
| `RuntimeABI.swift` | `.catvodResult` 1.2 → 1.3，加註解；js.host 仍是 1.5 | C05 |
| `RuntimeABITests.swift` | `frozen[.catvodResult]` 新增 1.3 列（`04cbf663…44fb`），1.0–1.2 與 js.host 各列不動 | C06 |
| `WebHTVApp.swift` | `FolderTarget { id, name, extend }`；`CMSView` 加 `folder` 參數與自訂 init（`State(initialValue:)` 設 `selectedCategory = folder.id`、`chosenFilters = folder.extend`，init 不做 I/O）；唯一呼叫點 :936 不變。`.task` 第 1 頁改成 `load(category: folder?.id)`：一般模式等於原本的 `load()`（S-06 不產生差異）。folder 模式隱藏 header、搜尋欄、分類與篩選列（用 `folder == nil` 判斷，不靠 `groups.isEmpty`）；W-107 頂端錨點仍是 VStack 第一個子 view，在隱藏區塊外。導覽列 `folder == nil ? .hidden : .visible`、標題是片單名（inline）。共用 `vodDestination(_:site:source:extend:)` 是 `isFolder` 唯一的分流點，featured、格子、聚合搜尋三個入口都用它；卡片上的 `.buttonStyle`／`.onAppear`／`.id(listingID)` 原樣保留。`linkExtend`：列分類且不在搜尋時用 `chosenFilters`，否則空；聚合搜尋用 `[:]` | C08–C14、C17、N01–N08 |
| `FolderVodTests.swift`（新） | T1 W-30 合成 7 筆（只有第 1 筆 `isFolder`；`123`／`null`／陣列／物件／`"Folder"` 都不是，也不會讓同筆其他欄位或整頁失敗）；T2 沒有 tag 的項目與 code 建的 `Vod` 不是 folder；T4 經 `SourceClient.spider`：tid 精確等於 `/article/233`、page `"1"`、extend 精確等於 `{"cateId":"kanlist/剧情"}`，回傳項目保留 tag；T5 `host.result.page` 會丟掉 tag（記錄現況：要 folder 的 adapter 必須自己組結果） | T1、T2、T4、T5 |

沒改（C15、C16、C18）：觀看紀錄、收藏、`pendingVod` 仍直接進 `VodView`；`listing(page:)`、`loadMore`、下拉刷新、清除搜尋、`load` 主體都沒動，`listingID` 的寫入點仍只有 `load` 一處；host.js、SourceClient、SpiderSession、JavaScriptSpiderRuntime、播放器、相容包都沒動。

和設計的差異：設計把共用函式叫 `vodLink`，實作是只回傳目的地 view 的 `vodDestination`，讓三個入口的 `NavigationLink` 與它們的修飾都原樣保留（N03）。功能相同。

## 驗證

| 項目 | 結果 | 證據（`.herdr-synapse/webhtv-dev/artifacts/w40-logs/`） |
|---|---|---|
| 先紅 | 新測試在 `Vod` 還沒有 `tag`／`isFolder` 時編譯失敗；加了 `case tag` 還沒升版時，ABI 測試以「catvod.result 1.2 no longer matches its frozen fingerprint」失敗 | `w40-red-folder.log`、`w40-red-abi.log` |
| 後綠 | FolderVodTests 4 個＋RuntimeABITests（4 個 surface）全過 | `w40-green-core.log` |
| Mutant | M1 tag 改用 `decodeText` → T1 紅；M2 `isFolder` 不分大小寫 → T1 紅；M3 拿掉 frozen 1.3 列 → ABI 紅。都已還原，sha256 一致 | `mutants.txt`、`mut-*.log` |
| 全測試 | `swift test` 1187 tests／41 suites 全部通過（W-105 後 1183＋4） | `w40-full.log` |
| App build | Simulator Debug `** BUILD SUCCEEDED **`；警告都在既有程式（:8762 起），不在本次改動 | `w40-app-build.log` |
| Ponytail | 自審 Ship，沒有 finding | — |
| 不退化 GUI（R0–R7，Simulator BC4948DD，0825 荐片；R7 加看球） | **PASS**。R6：根層沒有導覽列，header、選站、搜尋欄、分類 chip 都在；featured、格子、站內搜尋、聚合搜尋都進詳情，返回鈕正常。R1：列表 90 部時進詳情再返回，可見的 8 張卡名稱與 frame 都相同、數量仍 90；返回時只有一個海報請求，沒有列表請求；續捲自動載到 105。R2：同一 chip 點兩次、頂端下拉刷新，都回到 15 部，頂端沒有回到頂部按鈕，之後自動載到 45。R3：有結果的搜尋頂端沒有按鈕，捲動後出現、點了回頂；空搜尋顯示「沒有內容」，t+1／3／5／9 秒都沒有按鈕。R4：15 → 195 部，按鈕可回頂（荐片每頁 15 部，停不在剛好 48／96／144）。R7：換到看球 6 部，換回荐片 15 部。R0：「中國香港」篩選「已選 1 項」，進出詳情後仍在。容器還原 BYTE-IDENTICAL | `.herdr-synapse/webhtv-dev/artifacts/w40-gui-evidence/RESULT.md`（sha256 `c62ca4e4…6f68`） |
| folder 導覽 GUI（G1–G7、G11、G12） | **未驗，待 W-41**（Manager #2002） | — |

App 的路由與返回行為（N01、N03、N05、C12）沒有單元測試可以抓，只能靠讀 diff 和 GUI。

## 風險與未驗

- 巢狀 folder 只有 Core 合成資料證明會解碼成 `isFolder`，導覽沒驗。搜尋結果裡的 folder 沒有來源可驗。
- extend 帶入在 Ikanbot／Djuu 兩站都沒有可見效果，只靠 T4。
- folder 模式導覽列可見時，W-107 錨點的實際門檻（N04）要到 W-41 的 G11 才驗得到。
- catvod.result 1.3 一旦隨 IPA 發出，指紋表就只能 append。
- 依賴 folder 的腳本（Ikanbot、Djuu）不能進相容包（FOLDER-04）。
- R1 的「返回時格子沒有閃一下重建」是間接證明（frame 相同、沒有列表請求），沒有錄影。R5 需要 folder 來源，沒做。
- 沒有實機測試。

## 回滾

一個 commit；`git revert` 會回到 folder 項目點下去進詳情的現況（Core、ABI、App、測試一起）。catvod.result 1.3 若已隨 IPA 發出，revert 要另立工單處理指紋表。
