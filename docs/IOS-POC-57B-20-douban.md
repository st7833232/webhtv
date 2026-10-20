# IOS-POC-57B-20：豆瓣「熱播排行榜」（`csp_Douban`）＋App「點片單自動搜尋」

> Recovery anchor（2026-10-20 CST）：W-175，分支 `task/W-175`（從 `origin/ios-poc` `ac490ee3`），兩個 guard session：`W-175-A`（爬蟲＋本文件）、`W-175-B`（App 路由），`--no-tag`。閘門 W-173 **條件 GO**：`.herdr-synapse/webhtv-dev/artifacts/spider-gate-batch5-2026-10-20.md` §Douban，審查 `w173-review-2026-10-20.md`。使用者 10/20 核准（Manager #3353）。**狀態：** 設計第 1 輪審查（#3364）方案 C 同意，D-1～D-3 已補（§6.1、§6.2、§7、§8），待 Reviewer 確認；設計第 2 輪（#3369）同意。commit A 已實作並驗證（§10）。唯一下一步：實作 commit B（guard `W-175-B`）。

## 1. 要做什麼

- 使用者的 recha `wang-movie.json` 前兩筆是豆瓣「🇹🇼｜熱播排行榜｜自動切換」（key `豆瓣`）與「｜可選站」（key `豆瓣-搜索`），類別 `csp_Douban`（`./jar/river-fman.jar`）。它只產生片單（熱門電影、熱播劇集、榜單、篩選…），每部片的 `vod_id` 是 `msearch:<豆瓣 id>`，**本身沒有播放線路**。
- ① 爬蟲：把 `Douban` 移植成官方包的 JS spider，片單、篩選、分頁、海報能看。
- ② App：點到 `vod_id` 以 `msearch:` 開頭的片單項目時，不開詳情，改用片名在使用者其他可搜尋的站做聚合搜尋，讓使用者從結果選一個播放。

## 2. Android（FongMi）怎麼做

依據 `app/src/mobile/java/com/fongmi/android/tv/ui/activity/VideoActivity.java`（leanback 版 :1069 相同）：

- `checkId()`（:1218–1222）：id 是空的或以 `msearch:` 開頭時**不呼叫 detailContent**，直接 `setEmpty(false)`。
- `setEmpty(false)`（:1265–1275）：畫面顯示片名，10 秒後若還沒有結果就顯示「沒有內容」（`mR4`），並呼叫 `checkSearch(false)`。
- `checkSearch(false)`（:6111–6115）：**只有開啟「自動換源」設定（`PlayerSetting.isAutoChange()`）才繼續**，否則什麼都不做（使用者自己按快速搜尋）。
- `initSearch(name, auto=true)`→`startSearch`（:6117–6137）：搜尋 `searchable` 且（自動模式下）`changeable` 的站，依站台健康排序。
- `setSearch`／`mismatch`（:6139–6160）：自動模式只留**片名完全相同**的結果；有結果且自動換源開著就 `nextSite()`（:6173–6183）**自動打開最佳結果的詳情**並播放。
- 兩筆設定的差別只在 App 端：`changeable:1` 的「自動切換」那筆會被自動換源挑中；「可選站」那筆 `changeable:0`、`indexs:1`。

## 3. WebHTV 現況

- `ios/` 全部原始碼沒有任何 `msearch:` 處理。片單項目統一走 `vodDestination`（`ios/WebHTVApp/Sources/WebHTVApp.swift`:1091–1098）：folder → 子清單、其他 → `VodView` 詳情。呼叫端：`CMSView` 兩處（:1285、:1318）、`AggregateSearchView` 結果（:1701）。
- 聚合搜尋已有：`AggregateSearch`（`ios/Sources/WebHTVCore/AggregateSearch.swift`，`sites(from:)` 只取 `isSearchable` 的站、`Site.id` 去重）＋`AggregateSearchView(sites:source:initialQuery:isSheet:)`（:1641；搜尋分頁 :215、網頁首頁的搜尋 sheet :9075）。結果點下去走 `vodDestination` → `VodView`，可直接播放。
- `vodDestination` 拿不到完整站台清單（`CMSView` 只持有目前的站）；清單在根畫面（:200 起的 `TabView`，`sites`）。
- 沒有新路由時：`VodView.loadDetail`（:2648）呼叫 spider 的 `detailContent`，豆瓣沒有實作 → 空清單 → `SourceClient.detail` 回 nil（`ios/Sources/WebHTVCore/SourceClient.swift`:89–95）→ 畫面**一直停在「載入詳情」轉圈**，不會報錯也不能播。

## 4. 最佳實務研究（§7）

| 證據類別 | 來源 | 結論 |
|---|---|---|
| 上游原碼 | FongMi `VideoActivity.java`（上節行號，本 repo `/Users/chengchenchih/GIT/webhtv` 2026-10-20 讀）；`Douban.java`（river-fman.jar，jadx，閘門 W-173） | 行為見 §2；spider 只出片單，`detailContent`／`playerContent`／`searchContent` 都沒有覆寫 |
| 官方平台文件 | SwiftUI `NavigationStack` 的既有慣例（本次**沒有重讀** Apple 文件，屬已知做法，不是新查證） | 在既有導覽堆疊裡推入一個畫面（有返回鍵）；不在 `NavigationStack` 裡再巢狀一個 `NavigationStack`。repo 內同樣做法：`vodDestination` 推入 `CMSView` 子清單（:1094） |
| 上游議題／討論 | — | 不適用：這是 App 自己的路由選擇，沒有可對照的上游 PR／issue |
| 相近專案 | TVBox／FongMi 系列（同一行為，見 §2） | 「片單站＋點片搜其他站」是 TVBox 生態的既有慣例，使用者預期點了會去找可播的站 |
| 論文／技術文章 | — | 不適用 |

## 5. 方案比較

| 方案 | 做法 | 優點 | 缺點 |
|---|---|---|---|
| A 不改 App（只出爬蟲） | 只移植 spider | 不用出 IPA | 點片單永遠轉圈（§3），等於壞掉的功能；不採用 |
| B 照 Android | `VodView` 遇 `msearch:` 改成自動搜尋 `changeable` 站、片名完全相同、自動開最佳結果並播放 | 與 Android「自動切換」一致 | WebHTV 沒有「自動換源」設定與站台健康排序可用；完全相同的片名常誤配（同名不同片、年份不同）；自動跳轉使用者不知道播的是哪一站；改動 `VodView`（播放主畫面）風險較高 |
| **C WebHTV 改良（建議）** | `vodDestination` 遇 `msearch:` 改推入**既有的聚合搜尋畫面**、預填片名並立即搜尋；使用者從各站結果挑一個 → 既有詳情 → 播放 | 重用已驗證的搜尋與詳情流程；使用者看得到是哪一站；只動一個路由點，其他項目行為完全不變；與「可選站」那筆的語意一致 | 少了「自動切換」一鍵播放（多一次點擊）；兩筆豆瓣設定在 WebHTV 行為相同 |

**決定：C。** 對上游的取捨：**補充**（加上 Android 有、WebHTV 缺的 `msearch:` 路由），**改良**（不做自動挑選，改由使用者選）。「自動切換」若日後需要，可在 C 的搜尋畫面上加「自動播放第一個完全同名結果」，屬另一張單。

## 6. 設計

### 6.1 commit A：爬蟲（`W-175-A`）

| 檔案 | 內容 |
|---|---|
| `ios/Spiders/Douban.js`（新） | 照 river 版：寫死 8 類（熱門電影 `hot_gaia`、熱播劇集 `tv_hot`、熱門動漫 `anime_hot`、熱播綜藝 `show_hot`、電影篩選 `movie`、電視篩選 `tv`、電影榜單 `rank_list_movie`、電視劇榜單 `rank_list_tv`）＋上游整包 filters；直接打 `https://frodo.douban.com/api/v2/…`（不經 `api.douban.com` 的 301），header 照上游（Referer `servicewechat.com/…`、微信小程式 UA），apikey 寫死（上游明文常數）；每頁 20、`start=(pg-1)*20`；**丟掉沒有海報的項目**（上游 `filterItemsWithoutPic`）；片單項目 `vod_id="msearch:<id>"`、`vod_pic=<pic>@Referer=https://api.douban.com/@User-Agent=<UA>`（App 的 `ImageRequest` 已支援）、`vod_remarks="评分：x"`。首頁推薦用 `subject_real_time_hotest`。`searchContent`／`playerContent` 回空（同上游）。**`detailContent` 不回空（審查 D-1）**：回這部片的 id、空片名（`VodView` 標題與海報本來就先用片單項目的），加一條線路「豆瓣片單（需更新 App）」，集名「請更新 WebHTV 到 0.1.82 以上」、網址 `msearch:update`；舊版 App 按播放時 `playerContent` 回空網址，App 跳出「這一集沒有可播放的網址」，不再一直轉圈（作法同 Libvio 的 `DISK_ONLY`，W-171）。0.1.82 起的 App 不會對 `msearch:` 呼叫詳情。上游讀 App 檔案 `config.json` 的 `homePage` 來隱藏部分分類，WebHTV 沒有這個檔：**一律顯示全部分類**。 |
| `ios/Sources/WebHTVCore/Spider/SpiderRegistry.swift` | `ported` 加 `Douban`（一行註解） |
| `ios/Tests/WebHTVCoreTests/SpiderGoldenTests.swift` | 預期清單加 `Douban` |
| `ios/Tests/WebHTVCoreTests/DoubanSpiderTests.swift`（新） | 假站（URLProtocol）回閘門抓到的真回應（遮罩 apikey 後嵌入）：分類 8 個與 filters、首頁推薦、各分類網址與分頁、沒海報的被丟掉、`msearch:` id、海報 `@Referer` 後綴、篩選值組 tags、空回應不當掉；mutant 檢查 |
| `scripts/spider_pack.py` | `DEFAULT_ORIGINS` 加 `Douban`（river-fman.jar 名與 sha256 `3133519d148c35d03b947dc4b571ae7d59214422a181772ae5e4fe29ec680392`） |

### 6.2 commit B：App 路由（`W-175-B`）

- `Vod`（`WebHTVCore`）加計算屬性 `isMultiSearch`：`id.hasPrefix("msearch:")`（大小寫照上游，區分大小寫）。單元測試。
- `vodDestination`：`vod.isMultiSearch` → `MultiSearchDestination(keyword: vod.name, source:)`；其他分支一字不改。
- `MultiSearchDestination`：從 environment 讀完整站台清單，顯示 `AggregateSearchView(sites:source:initialQuery: keyword, isSheet: false, embedded: true)`。
- `AggregateSearchView` 加 `embedded`（預設 `false`）：`true` 時**不包自己的 `NavigationStack`**，被推入既有堆疊。`embedded == false` 時 body 結構與現在相同，搜尋分頁與 sheet 行為不變。
  - **停止時機（審查 D-2）**：sheet 照舊在 `onDisappear` 停止。embedded **只在被 pop 時停止**：推入詳情時 `onDisappear` 也會觸發，但這時 `@Environment(\.isPresented)` 仍是 `true`，不停止，其他站的結果繼續進來；被 pop 時 `isPresented` 變 `false` 才停止（`onDisappear` 與 `onChange(of: isPresented)` 都檢查，誰先到都一樣）。
  - **導覽列與標題（審查 D-3）**：embedded 不套 `.toolbar(.hidden, for: .navigationBar)`，改用既有的 `.appNavigationBar()`（`VodView` 也用），顯示返回鍵；導覽列標題 inline 為片名。頁首大標題由「搜尋」改為片名，副標題「從其他來源找可播放的版本」；搜尋框預填片名，使用者可改字重搜。
- 根畫面把 `sites` 放進 environment（新 `EnvironmentValues` 鍵 `configSites`，預設空陣列）。站台清單為空時搜尋畫面顯示既有的空狀態，不會當掉。
- 被搜尋的站：沿用 `AggregateSearch.sites(from:)`（`searchable` 的站）。`豆瓣`（`searchable:0`）不會被搜；`豆瓣-搜索`沒寫 `searchable`（預設 1）會被搜，但它的 `searchContent` 回空，只多一個「0 筆」的站，不影響結果。
- 不做：自動挑選並播放、改 `VodView`、改收藏與觀看紀錄（`msearch:` 項目不會進到 `VodView`，所以不會留下紀錄）。

### 6.3 不變的行為（驗收時逐項確認）

- 非 `msearch:` 項目：點了照舊開詳情或子清單。
- 搜尋分頁、網頁首頁的搜尋 sheet：畫面、搜尋、載入更多、關閉時停止，都與現在相同。
- 播放流程完全不動。

## 7. 驗收條件

1. 爬蟲：`DoubanSpiderTests` 先紅後綠、mutant 全殺；全量 `swift test` 通過；官方包試建（`spider_pack.py build` → `verify` 0 problem）、pack exclusions 通過。
2. App：`Vod.isMultiSearch` 測試；全量 `swift test` 通過；建置通過。
3. Simulator（真網址、手機熱點）：載入含豆瓣的設定 → 下載爬蟲工具 → 選「熱播排行榜」→ 片單有海報 → 點一部 → 進入預填片名的搜尋畫面（導覽列有返回鍵、標題是片名）並開始搜尋 → **在搜尋還沒全部回應時**點一個結果進詳情 → 返回：結果仍在、回應站數繼續增加（D-2）→ 再點一個結果 → 播放開始 → 返回鍵能一路回到片單。另驗：搜尋分頁照舊（沒有返回鍵、大標題「搜尋」），非豆瓣站的片單項目點了照舊開詳情（回歸）。
4. 舊版 App 行為（D-1）：以 0.1.81 程式（`origin/ios-poc` 現況，不含 commit B）＋試建包，點豆瓣片單 → 詳情顯示「豆瓣片單（需更新 App）」線路 → 按播放跳出「這一集沒有可播放的網址」。
5. Reviewer 核准 commit A、commit B。

## 8. 發布順序與舊版 App

- 先發官方包（含 Douban），再發 App 0.1.82（含 commit B）。
- **舊版 App（0.1.81 以前）拿到含 Douban 的官方包時**：片單照常顯示；點片單項目進詳情頁，只有一條「豆瓣片單（需更新 App）」線路，按播放跳出「這一集沒有可播放的網址」（審查 D-1 修正後；修正前會一直轉圈）。需更新到 0.1.82 才能從片單找其他站播放。發布說明要寫明。

## 9. 回滾

- commit A、B 各自可 `git revert`。只回滾 B：豆瓣片單回到「點了轉圈」。只回滾 A：沒有任何站會產生 `msearch:` id，B 的路由不會被用到。
- 官方包：Douban 有問題時，下一個官方包把 `Douban` 從 `ported` 拿掉即可，不需要改 App。

## 10. 實作紀錄

### commit A：爬蟲（guard `W-175-A`，2026-10-20）

| 檔案 | 內容 |
|---|---|
| `ios/Spiders/Douban.js`（新） | 照 §6.1。8 類＋上游 filters（測試逐字比對 `Douban.java`:265 的 JSON）；`get()` 一律打 `https://frodo.douban.com/api/v2/…?apikey=…`，帶小程式 Referer／UA；分頁以**過濾前**的原始筆數判斷（20 筆 → 還有下一頁，不滿 → 最後一頁）；tags 依 filters 表順序、跳過 sort 與空值（上游走 HashMap、保留空值）；`detailContent` 回「豆瓣片單（需更新 App）」線路（D-1） |
| `ios/Sources/WebHTVCore/Spider/SpiderRegistry.swift` | `ported` 加 `Douban` |
| `ios/Tests/WebHTVCoreTests/SpiderGoldenTests.swift` | 預期清單加 `Douban` |
| `ios/Tests/WebHTVCoreTests/DoubanSpiderTests.swift`（新） | 8 個測試，假站 `DoubanSite` 依路徑＋`start` 回 W-173 閘門的 7 份 frodo 真回應（raw-deflate＋base64，比對 sha256）；預期值由測試用 JSONSerialization 自行算 |
| `scripts/spider_pack.py` | `DEFAULT_ORIGINS` 加 `Douban`（river-fman.jar sha256 `3133519d…`） |

| 驗證 | 結果 | 證據（`.herdr-synapse/webhtv-dev/artifacts/w175-logs/`） |
|---|---|---|
| 紅 | 登錄前 8/8 失敗 | `A-red.txt` |
| 綠 | `DoubanSpiderTests`＋`SpiderGoldenTests` 通過 | `A-green.txt` |
| mutant | 17/17 killed（含 D-1 線路） | `mutants-A.py`、`mutants-A.txt` |
| 全量 | `swift test` 1375 tests／55 suites 通過 | `A-swift-test-full.log` |
| 官方包試建 | `runtime_pack.py build --sequence 9 --version 2026-10-20.w175`：39 支、0 problem（試建輸出在 scratchpad，不入庫）；`test_pack_exclusions.py` PASS（相容 37、官方 39） | `pack.txt`、`pack-exclusions.txt` |
| Ponytail review | Ship，無 finding | — |
