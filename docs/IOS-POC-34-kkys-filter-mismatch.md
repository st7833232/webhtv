# IOS-POC-34 — 可可影視的分類篩選結果與網站不同

- 狀態：**評估中（2026-09-28）；沒有修改任何程式。等使用者提供第三節的資料之一。**
- 使用者回報（2026-09-28，`0.1.29 (30)`，附兩張截圖）：「為什麼搜尋的資源有落差」。
  - 網站 `www.kkys20.com`，連續劇、類型全部、地區台湾、語言全部、年份 2026、排序最新：转角那间心药局、再见1987、邮票与舒芙蕾、黑白清道夫、赴海、整个世界只有你连上了我、针线缘……每張卡片都有「更新至第17集」「已完结」「全12集」「BT」這類標記。
  - App 來源「可可影視」，地區台灣、語言全部、年份 2026、排序最新（類型列被來源選單遮住）：來金來號、熾熱的他、轉過頭幫你擦眼淚、孔雀縛金戈……卡片沒有任何標記。
- 分類：來源腳本的問題，不是 App 程式。腳本在使用者 GitLab `st7833232/recha` 的 `py/kkys.py`，不在本 repo；要修改時由 agent 提供 patch、使用者套用。

## 一、已確認的事

1. **截圖是分類篩選，不是搜尋。** IOS-POC-33 的簡繁雙搜尋不經過這條路；IOS-POC-32 C 只改畫面文字。
2. **App 傳給 spider 的值與網站相同。**
   - `CMSView.filterChip` 以 `option.value`（腳本給的原值，例如 `台湾`）存進 `chosenFilters`；畫面上的「台灣」是 IOS-POC-32 C 的顯示轉換。
   - `PythonSpiderRuntime.categoryContent` 以 JSON 傳 `[tid, page, filter, extend]`，`ios/WebHTVApp/Python/webhtv_runtime.py:72` 以 `method(*json.loads(args_json))` 呼叫，腳本收到的是字典。
3. **來源設定**：`wang-movie.json`（GitLab `st7833232/recha` `main`，2026-09-28 取得，127,425 bytes，SHA-256 `a567f33f6b29d58b05ecfc255b9d9f4e6da385a7e4453e9a42e56abfc5d505e1`）的 site `kkys20`：`type` 3，`api` `https://gitlab.com/st7833232/recha/-/raw/main/py/kkys.py`。
4. **`kkys.py`**（2026-09-28 取得，1,031 行，SHA-256 `f272b8ae9815bbbbbd3f231b0a9c6779dcf38cb780f720a4ee576df94950abb3`）：
   - `categoryContent` 組 `SITE + "/show/{tid}-{type}-{area}-{lang}-{year}-{sort}-{page}.html"`；截圖的條件是 `/show/2--台湾--2026-2-1.html`。
   - 排序寫死為 综合 `1`、最新 `2`、最热 `3`、评分 `4`；沒選時用 `3`。
   - `_parse_list` 取整頁所有 class 含 `module-item` 的節點，依頁面順序、以詳情網址去重；備註只讀 `v-item-note`、`module-item-note`、`module-item-text`、`module-item-caption`。
5. **網站網址格式**（搜尋引擎收錄的網站頁面）：`/show/1-惊悚--日语-2026-2-1.html`、`/show/4-Season-韩国-国语-1980_1989-2-1.html`、`/show/2----2026-3-1.html`。欄位順序與腳本相同；頁面標題是通用範本，看不出 `2`、`3` 哪個是「最新」。
6. **本環境連不上 `www.kkys20.com`**（egress proxy 403，curl 與 WebFetch 都被擋），無法取得網頁 HTML 比對。

## 二、可能原因（依可能性排序，都未驗證）

1. **腳本抓到的不是網站的主清單。** 可能是頁面上另一個同樣用 `module-item` 的區塊（例如推薦或熱播），也可能網站以 JavaScript 載入篩選後的清單、腳本只讀到伺服器的預設內容。證據：兩邊片單完全不同，且 App 卡片沒有任何備註，網站卡片都有。
2. **排序代碼對應錯。** 若網站的「最新」不是 `2`，App 選「最新」時拿到的是另一種排序。證據：App 前幾部像熱門排序。
3. **App 的「類型」列選擇未知**：截圖中被來源選單遮住；網站是「全部」。

## 三、需要的資料（擇一）

1. 使用者在雲端環境的 Network access 允許 `www.kkys20.com`（標題列的環境選單 → Edit），agent 直接比對網頁 HTML 與腳本的解析結果。
2. 使用者提供 Safari 網址列那一頁的完整網址，先確認排序代碼與欄位。

## Recovery anchor

- 目標：找出可可影視分類篩選結果與網站不同的原因；需要時提出 `kkys.py` 的修正 patch（由使用者套用到 GitLab `recha`）。
- 狀態（2026-09-28）：評估中；沒有修改任何程式；原因未驗證（第二節）。
- 相關檔案：GitLab `st7833232/recha` `py/kkys.py`（`categoryContent`、`_parse_list`、`_item_remark`、`COMMON_SORT`）；本 repo 只讀過 `ios/WebHTVApp/Sources/WebHTVApp.swift`（`CMSView`）、`PythonSpiderRuntime.swift`、`Python/webhtv_runtime.py`，都沒有修改。
- 下一步（唯一）：取得第三節的資料之一後，抓 `https://www.kkys20.com/show/2--台湾--2026-2-1.html`（與排序 `3` 的同一頁），比對網頁的主清單、備註 class 與 `kkys.py` 的解析結果。
