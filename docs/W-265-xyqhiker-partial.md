# W-265 XYQHiker 部分跟進：篩選列、分類網址代換、截取模式

- 工單：herdr W-265（使用者 11-09：要補，但排在後面）。依據 `artifacts/w255/ported-diff.md` 第三節「部分跟」，以及 `artifacts/w255/ported-diff-uncertain.md` 的實測修正。
- 分支：`task/W-265`，自 ios-poc `4fba7c09`。
- 不做：
  - X1 驗證碼 OCR、X2 btwaf、X3 滑動／人機驗證：都屬於繞過網站的人機驗證。
  - X7 `player_aaaa.encrypt` 解碼：W-255 實測农民、動漫巴士、巴士动漫都沒有 encrypt。
  - X8、X9、X10、X11：沒有規則用到，或需要改 App。

## 補了什麼（`ios/Spiders/XYQHiker.js`）

| # | 行為 | 做法 | 影響的站 |
|---|---|---|---|
| X4 | 篩選列 | `homeContent` 回傳 `filters`。`筛选数据` 是物件時（FongMi 自己的格式，依 type_id）直接傳出。是 `"ext"` 時，依 `筛选子分类／地区／年份／排序` 的 `名称` 與 `替换词` 組出來：`||` 依分類順序分組，`空` 表示沒有，替换词 `*` 表示名稱就是值，每組第一個選項是「全部」（不帶值） | 物件型 14 站（kanav、ppp、asianssex…）；`ext` 型：农民 |
| X5 | 分類網址代換 | `categoryContent` 把 extend 的每個鍵都代入 `{key}`；extend 的 `cateId`（子分類）優先於分類 id；沒選的鍵是空字串（原本就是如此） | 同上 |
| X6 | 截取模式＋`+` 串接 | 新增 `field()`／`textField()`。`选集标题链接是否Jsoup写法=0` 時選集標題與連結用 `前&&後` 截取；`详情是否Jsoup写法=0` 時詳情欄位用截取並去掉標籤。`'字'+规则+…` 以 `+`／`＋` 串接（引號內是字面文字），套用在列表副標題、線路標題、選集、詳情欄位。動漫PRO 的選集規則指向播放器節點本身時，以該節點為唯一一集 | 动漫PRO（集數）；15 站的詳情欄位；17 站的列表副標題；19 站的線路標題 |

- `shortcut:` 選擇器引擎不保留節點的原始 HTML，所以對**節點**截取時讀的是節點文字（含 `<script>` 內容）。動漫PRO 的 `video_url: '&&',` 用這個就夠了；如果之後有規則要在節點內依標籤截取，要先補序列化。對**整頁**截取（詳情欄位）不受影響。
- 29 份規則檔裡，`+` 只出現在欄位之間，沒有任何選擇器把它當相鄰兄弟用；沒有 `+` 的規則走原本路徑，行為不變。

## 測試

`ios/Tests/WebHTVCoreTests/XYQHikerRuleTests.swift` 新增 6 個測試。修改前都會失敗：

- `aRuleFileFilterObjectIsTheFilterBar`：物件型篩選直接傳出。
- `anExtFilterBuildsOneGroupPerCategory`：农民的 `ext` 型，含 `空` 與 `*`。
- `aCategoryAddressCarriesEveryChosenFilter`：所有篩選值代入，`cateId` 優先；沒選時 `by//`。
- `aCutModePlaylistReadsTheEpisodeFromThePlayerScript`：動漫PRO 從播放器腳本切出集數，線路標題是純字面串接。
- `cutModeDetailFieldsLoseTheirMarkup`：`<p>類型：&&</p>`。
- `aJoinedRemarkReadsEachPart`：`'⏱️'+.time&&Text+'👁️'+.views&&Text`。

`XYQHikerRuleTests`＋`XBPQRuleTests`＋`SpiderGoldenTests` 共 53 個測試全過。

## 實測結果

### iOS：引擎層，新版對舊版（同一個 JS runtime 與 `host.js`，直接打真實站點，2026-11-09 15:40）

29 份 XYQHiker 規則檔（wang-movie 3 份＋wang-sex 26 份；直播2 是內嵌規則，沒有列入）。舊版＝ios-poc 的 `XYQHiker.js`，新版＝本分支。證據：`artifacts/w265/live-old.jsonl`、`live-new.jsonl`；探測程式是本機暫時測試，沒有 commit。

| 站 | 分類片數 舊→新 | 篩選分類數 舊→新 | 選一個篩選後片數 | 詳情集數 舊→新 | 副標題 舊→新 |
|---|---|---|---|---|---|
| 农民影视 | 30→30 | 0→5 | cateId=5：30 | 1→1 | 有→有 |
| 動漫巴士 | 36→36 | 0→0 | — | 482→482 | 有→有 |
| 巴士动漫 | 36→36 | 0→0 | — | 482→482 | 有→有 |
| 18av | 24→24 | 0→0 | — | 1→1 | 有→有 |
| 300分类 | 48→48 | 0→0 | — | 1→1 | 空→空 |
| airav | 60→60 | 0→12 | — | 1→1 | 空→有 |
| asianssex | 20→20 | 0→8 | by=day/：0 | 1→1 | 空→有 |
| hohoj | 24→24 | 0→8 | by=latest：24 | 1→1 | 空→有 |
| kanav | 0→0 | 0→6 | by=time_add：24 | —→— | 空→空 |
| owoav | 0→0 | 0→0 | — | —→— | 空→空 |
| ppp | 24→24 | 0→8 | — | 1→1 | 空→有 |
| thisav | 0→0 | 0→9 | by=published_at：0 | —→— | 空→空 |
| xgroovy | 25→25 | 0→8 | by=new：25 | 1→1 | 空→有 |
| 正妹av | 23→23 | 0→8 | cateId=local：23 | 1→1 | 空→空 |
| 紫色成人 | 0→0 | 0→3 | — | —→— | 空→空 |
| 鲨鱼av | 12→12 | 0→0 | — | 1→1 | 空→有 |
| avbebe | 36→36 | 0→8 | — | 1→1 | 空→有 |
| bongacams直播 | 36→36 | 0→5 | by=camscore：36 | 1→1 | 空→空 |
| jiedm | 52→52 | 0→8 | — | 1→1 | 空→有 |
| qinav | 40→40 | 0→8 | — | 1→1 | 空→有 |
| ujizzcn | 3→3 | 0→26 | by=&s=n：0 | 1→1 | 有→有 |
| 台湾kiss | 0→0 | 0→0 | — | —→— | 空→空 |
| 亚色影库 | 20→20 | 0→8 | by=latest：20 | 1→1 | 空→有 |
| 动漫pro | 24→24 | 0→8 | — | 0→1 | 空→有 |
| 好色tv | 24→24 | 0→3 | — | 1→1 | 有→有 |
| 直播1 | 83→83 | 0→1 | cateId=jsonweishizhibo：83 | 1→1 | 空→空 |
| 黄色仓库123 | 40→40 | 0→0 | — | 1→1 | 空→空 |
| 黄色仓库啦 | 40→40 | 0→1 | — | 1→1 | 空→有 |
| 小嫂子 | 12→12 | 0→0 | — | 1→1 | 有→有 |

- **沒有退化**：29 站的分類片數、詳情集數新舊完全相同。
- 新增：
  - 篩選列：20 站（农民 `ext` 型 5 個分類；其餘是物件型）。
  - 动漫pro：詳情集數 0 → 1（線路「📽️在线播放📺」）。
  - 列表副標題：12 站從空白變成有內容，ujizzcn、好色tv 補上 `⏱️` 前綴。
- **kanav**：沒選篩選時分類是 0 部（`{by}` 空字串時站方不回清單），選「最新發布」後 24 部。新版之前，iOS 完全看不到 kanav 的分類。
- 分類片數為 0 的站（kanav 預設、owoav、thisav、紫色成人、台湾kiss）新舊版都是 0，是站方或規則本身的問題，不是本次造成。

### iOS：App 畫面抽查（Simulator webhtv-w202）

測試站點設定 `w265-test.json`，以相容包 `spiders/XYQHiker.js`（本分支版本）覆蓋官方包。kanav「中文字幕」分類：
1. 一開始「沒有內容」，下面有「子分類與篩選 / 展開」。
2. 展開後出現「排序：最新發布／最多觀看／最熱好評／評分」。
3. 選「最新發布」→ 列出 18 部（畫面可見部分），顯示「已選 1 項」。

證據：`artifacts/w265/w265-filters.png`、`w265-filtered.png`。

動漫PRO 的 UI 抽查沒有做：切換測試站點沒有生效，改用上方引擎層結果作證據。

### Android（FongMi 5.8.4，emulator-5560，jar＝設定的 xyqxbpq／river-fman）

| FongMi 站（wang-sex） | 首頁片數 |
|---|---|
| 18av | 8 |
| 300分类 | 0 |
| airav | 8 |
| asianssex | 8 |
| hohoj | 8 |
| kanav | 8 |
| owoAV | 0 |
| ppp | 8 |
| thisav | 8 |
| xgroovy | 8 |
| 正妹AV | 7 |
| 紫色成人 | 0 |
| 鲨鱼av | 8 |
| avbebe | 6 |
| bongacams直播 | 8 |
| jiedm | 8 |
| qinav | 8 |
| ujizzcn | 8 |
| 台湾kiss | 0 |
| 亚色影库 | 8 |
| 动漫PRO | 8 |
| 好色TV | 0 |
| 直播1 | 8 |
| 直播2 | 8 |
| 黄色仓库123 | 8 |
| 黄色仓库la | 8 |
| 小嫂子av | 0 |

- 27 站中 21 站首頁有片。
- owoAV、紫色成人、台湾kiss 首頁空：iOS 新舊版也拿不到，兩個平台一致。
- 300分类、好色TV、小嫂子av：FongMi 首頁空，iOS 分類頁有片。兩邊量的項目不同（首頁 vs 分類頁），沒有再深究。
- **BLOCKED**：wang-movie 的 3 站（农民、動漫巴士、巴士动漫）沒有在 FongMi 跑到。改點播網址時，主機負載平均 100 以上（安全掃描程式＋另一台 Simulator），模擬器系統持續「Process system isn't responding」，冷開機後也一樣。
  - 這 3 站裡只有农民受本次影響（`ext` 型篩選）；動漫巴士、巴士动漫在 iOS 新舊版完全相同。
- 模擬器已關機。點播網址：我沒有按下 movie 網址的 OK，而且 FongMi 只在設定載入成功時才存網址，所以應該仍是 `http://10.0.2.2:18226/wang-sex.json`。但最後一次冷開機後因為系統無回應，**沒能讀回確認**。下一位使用 5560 的人開機後請先看點播網址。

## 官方爬蟲包

只改 `ios/Spiders/XYQHiker.js`；官方包由 workflow 從 `ios/Spiders` 建置，發包由 Manager 經授權執行。版本說明草稿：

> XYQHiker 類站點：分類頁新增篩選列（排序、子分類、地區等，依站點設定）；部分站點的詳情頁補上集數；列表的時長、觀看數等副標題正確顯示。

## 回退

單一 commit，`git revert <commit>`；官方包回到上一版即可。

## Ponytail

`ponytail:ponytail-review` 審查最終 diff：沒有必修，可以出貨。

- 唯一的建議（不改）：`FILTER_KEYS` 的 年份／排序 在 29 份規則檔裡沒人用。只多兩個陣列項目，又和原版引擎的鍵一致，所以保留。
- 已確認的行為：
  - 規則沒有 `+` 時走原路徑。
  - 線路標題取不到時改用「線路N」，不再是空字串。
  - 對節點截取時讀的是節點文字（已加 `shortcut:` 註解）。

## 補測（Reviewer #7036，2026-11-09 16:30–17:05，主機負載降到約 11 之後）

### wang-movie 3 站（FongMi，`artifacts/w265/android/movie-results.jsonl`）

| 站 | 首頁片數 | 第一部 |
|---|---|---|
| 农民 | 9 | 起播 |
| 動漫巴士 | 9 | 起播 |
| 巴士动漫 | 第 1 次選站清單找不到；重試 1 次 0 部（`TimeoutException`）；重試 2 次又找不到 | 未測 |

巴士动漫記為**不確定**，不再重試。它和動漫巴士用同一個主機（dm84.net）、同一個 jar（xyqxbpq），規則檔只差格式，動漫巴士同時可以播。W-265 對這站沒有改變（沒有篩選資料；iOS 新舊版的分類片數 36、集數 482 完全相同）。

### 新篩選選到空清單的三站（FongMi 對照，`artifacts/w265/android/filt-results.jsonl`）

只記數字；截圖有露骨畫面，已刪除不保存。

| 站 | 分類／篩選 | FongMi 選前→選後 | iOS 先前探測 | 判斷 |
|---|---|---|---|---|
| asianssex | 最新／排序「今天」 | 8 → 0 | 0 | 兩平台一致：站方「今天」本來就沒有片 |
| thisav | 中文字幕／排序「最近更新」 | 8 → 8 | 不選也是 0（新舊版都是） | iOS 抓不到 thisav 是既有問題，和篩選無關 |
| ujizzcn | 日本成人片／排序「时间」 | 8 → 8 | 不選 3、選了 0 | 重抓兩頁，用 iOS 同一份 `host.js` 解析，有選、沒選都是 12 筆（站方兩頁各有 69 個 `.th-itm`）。先前的 3／0 是當時站方回應不穩，不是篩選造成 |

結論：新篩選列不會讓 iOS 比 Android 差。asianssex 的「今天」在兩個平台都是空清單，屬站方內容。

### 5560 交還

- 補測前冷開機讀回：點播／直播都是 `http://10.0.2.2:18226/wang-sex.json`（補上次沒讀回的確認）。
- 補測時暫時改成 wang-movie，測完改回後**再冷開機讀回**，點播／直播都是 `http://10.0.2.2:18226/wang-sex.json`。
- 已關機；18226 已停。
