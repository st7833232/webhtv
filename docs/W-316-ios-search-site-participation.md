# W-316 iOS 搜尋第二批：固定失敗站暫停參與（A10）＋每站參與搜尋開關（A6）

- 規格：`docs/W-312-ios-search-improvements.md` §5 的 A10、A6，§8 回退。設計已在 W-312 評估定案，本單只實作，不重做研究。
- 分支 `task/W-316`，底 `ios-poc` `ae662d20`（0.1.105）。只提交不推送。
- 證據 `.herdr-synapse/webhtv-dev/artifacts/w316/`（不進 git）。

## 1. 做了什麼

| 項目 | commit | 改動 |
|---|---|---|
| A6 每站參與搜尋開關 | 94e2ee99 | `AggregateSearch.sites(from:excluding:)` 多一個排除清單參數（預設空，舊呼叫不變）。新增 `SearchExclusions`：以 `ConfigSource.identity` 為鍵、`Site.id` 集合為值，JSON 存在 `UserDefaults`（鍵 `webhtv.search.excludedSites`；`Site.id` 含 NUL，所以不直接存字串陣列）。設定頁「內容來源」加「參與搜尋的站台」，每個可搜尋站一個開關，切換時立刻存。搜尋頁的發問清單與空白頁的「會搜尋 n 個站台」都扣掉關閉的站。 |
| A10 固定失敗站暫停參與 | 本次提交 | `SiteHealth` 加兩個欄位 `searchFailStreak`（上次搜尋成功後連續失敗次數，成功歸零）、`lastSearchFailAt`；宣告成 optional，舊的 `site-health.json` 照樣解得開。`keepsFailingSearch(at:)`：連續失敗 ≥3 且最後一次失敗在 7 天內。搜尋頁在新開關「略過一直失敗的站」（設定頁「內容來源」，鍵 `webhtv.search.skipFailingSites`，預設開）開啟時把這些站從本次發問清單拿掉，進度列多一行「略過 n 個近期一直失敗的站」，點開列出站名與「現在重試這些站」；重試只問這幾站、結果併進目前畫面（晶片編號接在第一批後面，不會撞號），搜尋進行中不能按。全部可搜尋站都被略過時，空白頁說明原因並指向重試。設定頁說明補上新開關的行為。 |

### 判斷與取捨

- 「連續 ≥3 次失敗且無成功」解讀為：上次搜尋成功之後連續失敗 ≥3 次（`searchFailStreak`）。只看搜尋事件；首頁、詳情、播放失敗不算。逾時與失敗一樣計入（沿用既有 `recordHealth` 的分類）；「上一輪仍在執行」不記錄，所以不計。首頁單站搜尋也寫同一種 `.search` 紀錄（`CMSView` 的搜尋），所以它的失敗也算進連續失敗、成功也會歸零（Reviewer #9035 第 3 點）；來源檢查不記搜尋。
- 「一週後再問」以最後一次失敗時間起算：被略過期間沒有新紀錄，7 天後自動回到發問清單；那次又失敗則 streak 變 4、時間更新，再略過一週。手動重試失敗也一樣。
- A10 原規格掛在「站點健康排序」下；Manager #9050 改成獨立開關「略過一直失敗的站」（預設開），因為 W-317 自訂站點順序需要關健康排序，不能連帶失去略過。兩個開關互不影響：排序只決定發問順序，略過只決定問不問。略過開關關掉就完全不略過。
- 被 A6 關掉的站先從清單拿掉，所以不會出現在略過數、失敗數或總數裡，也不會產生健康紀錄。
- 只影響全站台搜尋（`AggregateSearchView`）。首頁單站搜尋、瀏覽、換站清單、來源檢查都不讀關閉清單也不略過。
- 升級後舊紀錄沒有 streak，固定失敗的站要再失敗 3 次才會被略過。

## 2. 驗證

- Core：`swift test` A6 後 1603 項全過、A10 後 1604 項全過（`core-tests-a6.txt`、`core-tests-a10.txt`）（新增 `leavesOutTheSitesSwitchedOffForThisConfiguration`：排除只對該設定來源、重新建立 `SearchExclusions` 仍讀得到、含 NUL 的 `Site.id`、清空後移除）。A10 新增 `aSiteWhoseSearchesKeepFailingSitsOutForAWeek`（2 次不略過、3 次略過、7 天後不略過、瀏覽／播放失敗不計、成功後重新計、舊 JSON 可解）。全部結果見 §2.1。
- App：Debug 模擬器建置成功（`build-a6.txt`、`build-a10.txt`）。

### 2.1 Simulator（熱點 172.20.10.1；設定 `https://raw.githubusercontent.com/st7833232/recha/main/wang-movie.json`，recha `main` = `f650d84378821a2d0ff2964a2d9022f48ed798fc`；新建模擬器 webhtv-w316，iOS 26，Debug）

| 步驟 | 結果 | 證據 |
|---|---|---|
| 第 1–3 輪（慶餘年、怪奇物語、哪吒） | 每輪 78 站全問，45.7／40.3／39.9 秒 | `sim/r1–r3-search.log` |
| 3 輪後健康紀錄 | 10 個站 `searchFailStreak`=3、成功 0 | `sim/health-after-r3.json`、`sim/streak3-after-r3.txt` |
| 第 4 輪（慶餘年） | 只問 68 站（那 10 站一個都沒有 `ask` 行），21.9 秒完成；進度列「已完成 34/68」＋「略過 10 個近期一直失敗的站」 | `sim/r4-search.log`、`sim/r4a.labels` |
| 點開略過 | 選單標題「近期連續搜尋失敗 3 次以上，一週後會再試」、站名、「現在重試這些站」 | `sim/r5menu.labels` |
| 現在重試 | 只問那 10 站（20.0 秒），進度變「已完成 78/78」「失敗 12」，略過列消失 | `sim/r7-search.log`、`sim/r7after.labels` |

上表 r1–r7 是改成獨立開關之前的建置（略過掛在健康排序下，健康排序開）；改完後的建置在 §2.2 重新驗證開關組合。

### 2.2 A6 與獨立開關（Manager #9050 之後的建置）

| 步驟 | 結果 | 證據 |
|---|---|---|
| 設定頁 | 「內容來源」有「參與搜尋的站台」與「略過一直失敗的站」（預設 1）；說明文字更新 | `sim/p2a.labels` |
| 參與搜尋的站台 | 每個可搜尋站一個開關，預設全開；關掉「可可影視」後偏好檔存成 `{"<設定網址>":["kkys20\u0000"]}` | `sim/p2b.labels`、`sim/p4.labels`、`sim/a6-excluded-pref.txt` |
| 關站後搜尋（排序開、略過開） | 問 65 站＝78－1（關掉）－12（略過），日誌沒有「可可影視」；進度列「略過 12 個…」，關掉的站不在略過數裡 | `sim/a6s-search.log`、`sim/a6s.labels` |
| 重開 App | 「可可影視」開關仍是 0，其他站 1 | `sim/p6.labels` |
| 略過關（排序開） | 問 77 站，包含原本被略過的站 | `sim/off1-search.log`、`sim/p8.labels` |
| 排序關、略過開 | 先累積到連續 3 次，下一輪問 66 站＝77－11，進度列「略過 11 個近期一直失敗的站」，發問順序回到設定檔順序 | `sim/p13a.txt`、`sim/on3-search.log`、`sim/on4-search.log`、`sim/on4s.txt` |

on4 這輪 66 站用了 82.3 秒（前一輪 77 站 33.9 秒），是單次觀測；略過只會讓問的站變少，推測是當時熱點或個別站變慢，沒有再追。

自動化備註：

- XCUITest 以元素點選選單內的「現在重試這些站」沒有觸發（選單停留），改以座標點同一按鈕就觸發；開關也要點右側的切換鈕才會切換。屬測試驅動與 iOS 26 控制項的互動，不是 App 行為。
- 搜尋結果很多時，XCUITest 抓整頁無障礙標籤會卡住數分鐘（取樣：主執行緒在 `XCTElementSnapshotRequest`），所以後段改用畫面結構檔＋App 日誌當證據。
- 測試時一次座標點選誤點到「清除站點健康記錄」，健康紀錄被清空；之後重新累積 3 次失敗才驗證略過（on3、on4）。

### 2.3 Ponytail

`ponytail:ponytail-review` 審 A6＋A10 全部差異：判定可出貨（Ship），只有一項「可以再改好」：略過條件在 `submit()` 算兩次。已採納，改成先算一次略過站的 ID 集合，兩邊共用。另外記下沒驗到的：手動重試時，被重試的站如果有結果，晶片編號應接在第一批後面（offset），但實測時重試的站全部失敗，這條路徑只有讀程式碼確認。

## 3. 回退

- 兩項各一個 commit，可單獨 `git revert`。
- A6 回退後 `webhtv.search.excludedSites` 只是不再被讀取。
- A10 回退後 `site-health.json` 裡多出的兩個欄位會被舊版忽略（`Codable` 不認得的鍵直接略過），`webhtv.search.skipFailingSites` 不再被讀取。使用者也可以關「略過一直失敗的站」立即停止略過。

## 4. 沒驗到的

- 真機。
- 「一週後再問」只有單元測試，沒有在 Simulator 等一週或改時鐘。
