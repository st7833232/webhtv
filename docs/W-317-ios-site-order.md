# W-317 iOS 自訂站點順序（拖曳排序）

- 規格：Manager #9049，使用者決定的修訂 #9054（取代「健康排序開時全依健康」）。依賴 W-316（同一頁）。
- 分支 `task/W-317`，接在 `task/W-316` `e76cac4c` 之後。只提交不推送。
- 證據 `.herdr-synapse/webhtv-dev/artifacts/w317/`（不進 git）。

## 1. 規格（#9054）

- 使用者拖曳過的站＝「已排站」，依使用者排的順序放在最前面。
- 其餘「未排站」接在後面：「站點健康排序」開→依健康分數；關→依設定檔順序。
- 拖任何站就把它加進已排區；每個已排站可以「取消自訂」回到自動區；「恢復設定檔順序」清空全部。
- 以 `ConfigSource.identity` 分開存，每個設定來源各存一份已排站的 `Site.id` 陣列；設定檔裡已經刪掉的站自動丟掉，新增的站自然落在未排區。
- 套用在站點切換清單（首頁與設定頁）與全站台搜尋的發問順序。健康排序開時，已排站順序不變，只有未排站跟著健康分數變動。

## 2. 現況（`ios/WebHTVApp/Sources/WebHTVApp.swift`，底 e76cac4c）

| 用到站點順序的地方 | 現在 | 位置 |
|---|---|---|
| 首頁站點切換清單（sheet） | `healthSort ? SiteHealth.ordered(sites, by: health) : sites` | `sourcePicker`，約 :1216 |
| 設定頁「目前來源」→ 站點清單 | 同上 | `SiteChoiceList.body`，約 :3060 |
| 全站台搜尋發問順序 | `byHealth` 時 `SiteHealth.ordered(targets, by: health)`，否則設定檔順序；W-316 的略過在排序之後過濾 | `AggregateSearchView.submit()`，約 :2223 |
| 追更檢查（W-313） | 用健康分數判斷該不該問，不是清單順序 | `FollowSchedule.due`，約 :4557 — 不改 |

W-316 的「參與搜尋的站台」頁（`SearchSitesView`）只列可搜尋站，一站一個開關，存法是 `SearchExclusions`（JSON 存 `UserDefaults`，因為 `Site.id` 含 NUL）。

## 3. 方案比較

| 方案 | 做法 | 優點 | 缺點 |
|---|---|---|---|
| 不改 | 只有設定檔順序與健康排序 | 零風險 | 不符使用者需求 |
| 全部自訂（像 FongMi 拖曳後整串存下） | 拖一次就把整串順序存起來，之後健康排序失效 | 最直覺 | 和 #9054 衝突：健康排序開時未排站要能動；新增站的位置要另外決定 |
| **已排區＋自動區（採用）** | 只存拖過的站；顯示順序＝已排站（使用者順序）＋未排站（健康或設定檔順序） | 符合 #9054；新增站自然在自動區；刪除站只要過濾；資料小（只存拖過的） | 拖到自動區中間的站會被放到已排區的最後，不是放開的位置（見 §4.2） |

## 4. 決定

### 4.1 Core（新檔 `ios/Sources/WebHTVCore/SiteOrder.swift`）

- `SiteOrder.apply(_ sites:, pinned:, health:)`：已排站（只取設定裡還在的，依 `pinned` 順序）＋其餘站（`health` 有給就用 `SiteHealth.ordered`，沒給就保持輸入順序）。
- `SiteOrder.moved(_ shown:, from:, to:, pinned:)`：清單上把一站從 `from` 拖到 `to` 之後新的 `pinned`。
- `SiteOrderStore`：同 `SearchExclusions` 的存法，鍵 `webhtv.siteOrder`，`[identity: [Site.ID]]` 的 JSON。存的時候丟掉設定裡已經沒有的站。
- 三個用到順序的地方都改成 `SiteOrder.apply(..., health: healthSort ? health : nil)`；搜尋先排序再套 W-316 的略過。

### 4.2 拖曳的規則

清單是一整串（已排在前、自動在後），被拖的站一定變成已排站，插入位置＝放開的位置，但最多到已排區的尾端。也就是說，拖到自動區中間會停在已排區最後一個；自動區的站只有被拖到的那一站會變成已排站，其他站不會被連帶固定。這樣才符合「被使用者拖曳過的站＝已排站」。

### 4.3 畫面

- W-316 的「參與搜尋的站台」頁改成「站點順序與搜尋」：列出全部站（不只可搜尋的），照實際順序排；可搜尋的站保留參與搜尋開關；已排站顯示圖釘標記。
- 右上「排序」進入拖曳模式（不用系統 `EditButton`，它在這個 App 顯示英文 Edit）；已排站可左滑「取消自訂」；頁尾「恢復設定檔順序」清空這個設定來源的已排清單。
- 頁尾說明：已排站固定在最前；其餘依「站點健康排序」或設定檔順序。

## 5. 驗收

- Core：套用自訂順序、新增站接在自動區、刪除站丟掉、空清單＝原順序、健康排序時已排站不動只有未排站動、拖曳規則。
- Simulator（熱點、GitHub recha `main` 記 SHA）：拖曳後首頁站點切換清單與搜尋發問順序一致；重開 App 仍在；不同設定來源各自獨立；恢復設定檔順序有效；健康排序開時已排站順序不變。
- Ponytail 審查記錄；`task_guard finish --no-tag`。

## 6. 回退

一個 commit，可單獨 `git revert`。`webhtv.siteOrder` 回退後只是不再被讀取。

## 7. 驗證結果

- Core：`swift test` 1608 項全過（`core-tests.txt`；新增 4 項見 `SiteOrderTests.swift`，另跑 `core-tests-focused.txt`）。App：Debug 模擬器建置成功（`build.txt`）。兩者都在最後一次改動之後。
- Simulator：模擬器 webhtv-w316（iOS 26，Debug，熱點）；設定 `https://raw.githubusercontent.com/st7833232/recha/main/wang-movie.json`，recha `main` = `f650d84378821a2d0ff2964a2d9022f48ed798fc`（測試時與 2026-11-19 復工後再查一致，`recha-main-sha.txt`）。

| 驗收項目 | 結果 | 證據（`sim/`） |
|---|---|---|
| 拖曳 | 把「红果短剧」拖到最上、再把「8Movie」拖進自動區中間 → 8Movie 停在已排區最後；偏好檔存成 `{"<設定網址>":["红果短剧\u0000","8movie\u0000"]}` | `o9s`–`o11s`、`order-pref.txt` |
| 「排序」按鈕 | 上一列是改按鈕前的建置（系統 `EditButton` 顯示英文 Edit／Done）；改成 App 自己的按鈕後重驗：按「排序」進入拖曳模式、標題變「完成」，拖曳後按「完成」回到「排序」 | `e2a`、`e3a` |
| 首頁換站清單 | 前兩個是 紅果・短劇、8Movie，其餘照設定檔順序 | `o12s.png` |
| 搜尋發問順序 | 前兩個發問的是 红果短剧、8Movie，與清單一致 | `s4-search.log`、`s4-ask-order.txt` |
| 健康排序開 | 已排兩站仍在最前，之後換成依健康分數排列（與設定檔順序不同） | `h1`–`h8`、`h8-ask-order.txt` |
| 重開 App | 順序仍在，搜尋仍先問這兩站 | `r1-search.log` |
| 不同設定來源 | 改用同一倉庫以 SHA 指定的網址（另一個 `ConfigSource.identity`）：沒有已排站，78 站照設定檔順序 | `i1-search.log` |
| 恢復設定檔順序 | 偏好檔變成 `{}`，搜尋回到純健康順序 | `order-pref-after-restore.txt`、`x7-search.log` |
| 左滑「取消自訂」 | 已排站（洛雪TV）左滑出現「取消自訂」，按下後圖釘消失、不再排第一；模擬器關機重開後讀偏好檔為 `{}`（當下立即讀到舊值，是偏好檔尚未寫入磁碟） | `e4a`、`e4b`、`order-pref-after-unpin-reread.txt` |

自動化備註：系統的左滑手勢用按住拖曳模擬不出來，探針驅動另加 `swipel`（以無障礙標籤找元素後 `swipeLeft`）。

### 7.1 Ponytail

`ponytail:ponytail-review` 審全部差異（`SiteOrder.swift`、測試、`WebHTVApp.swift`）：沒有發現問題，判定可出貨（Ship）。核對了拖曳落點換算（往下拖減一、最多到已排區尾端，四種情況與測試一致）、搜尋時已排站不受健康排序影響且 W-316 略過仍在排序之後、刪除的站在套用與存檔時都會丟掉、`SearchSitesView` 改收全部站後只有可搜尋站有開關。實作過程的自我檢查另外採納兩項：縮排修正；拖曳模式按鈕改用 App 自己的「排序／完成」，因為系統 `EditButton` 在這個 App 顯示英文 Edit。

### 7.2 沒驗到的

- 真機。
- 設定檔真的刪站或加站：只有單元測試（`apply` 跳過已刪除的站、新站落在自動區），沒有在 Simulator 換一份少站的設定檔。

## 8. W-324 小修（審查備註 N-2、N-1）

分支 `task/W-324`，從 `task/W-317` `f3d5e42f` 開；兩個 commit，不進 0.1.106。

### 8.1 原地放回不固定（N-2）

- 問題：拿起未排站又放回原位時，SwiftUI 若仍呼叫 `onMove`，`SiteOrder.moved` 會把它加進已排區尾端，畫面上那站往上跳。
- 改法：`moved` 開頭判斷 `to == from` 或 `to == from + 1`（SwiftUI `onMove` 對「原位」的兩種目的地）就原樣回傳 `pinned`。已排站原地放回也一樣不變。
- Core：新增 `aSitePutBackWhereItWasIsNotPinned`（兩種原位目的地、已排站原位、往上一格仍算移動）；`swift test` 1609 項全過（`artifacts/w324/core-tests-a.txt`）。
