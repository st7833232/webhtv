# W-185 iOS XBPQ.js 移植篩選規則（網頁站篩選）— 設計

Owner: webhtv-dev-claude-dev-2　Reviewer: webhtv-dev-codex-reviewer-2　狀態: 設計待審（核准後才實作）
根因來源: `.herdr-synapse/webhtv-dev/artifacts/new-sites-filter/根因.md`（W-183 方案 B，使用者 2026-10-20 核准）

## Recovery anchor
- 目標: iOS `csp_XBPQ` 站支援篩選。只動 `ios/Spiders/XBPQ.js`（＋其鏡像 `spider-pack/scripts/XBPQ.js`）與測試。不改 CMSClient（type 1 篩選是另一單）。
- 驗收: Simulator 上有篩選規則的 XBPQ 站（永乐影视類）選篩選後列表改變；沒寫篩選規則的 XBPQ 站（开心影院類）行為不變；build 通過。
- 下一步: 本設計經 Reviewer 核准 → 實作 → task guard commit（ios-poc 基礎）→ Simulator 截圖。

## 1. 原版 XBPQ 篩選規則語法與來源

來源＝使用者 wang-movie.json 既有 XBPQ 站的 `ext`（原版 XBPQ/hikerview 網頁解析規則，catvod `csp_XBPQ`）。實際範例 `永乐影视`（type 3）：

```
分类url = https://www.ylys.tv/vodshow/{cateId}-{area}-{by}-{class}-{lang}-{letter}---{catePg}---{year}.html
分类   = 电影$1#电视劇$2#综艺$3#动漫$4
类型   = 动作片$6#喜劇片$7#…｜｜国产劇$13#港台劇$…        （｜｜依「分类」分組）
```

語法歸納：
- **篩選鍵**（規則鍵名）：`类型`、`地区`、`年份`、`排序`、`语言`、`字母`（原版固定這幾個；站可只寫部分）。
- **選項值**：`显示名$参数值#显示名$参数值#…`；`｜｜` 把選項依 `分类`（一級分類）分組，第 n 組對應第 n 個分類；只有一組時所有分類共用。
- **分类url 占位符**：`{cateId}`（分類 id）、`{catePg}`（頁碼）、以及篩選占位符 `{class}`、`{area}`、`{year}`、`{by}`、`{lang}`、`{letter}`。
- **篩選鍵 ↔ 占位符 固定對應**（D-1 修正）：`类型`→**`{cateId}`**（值是子分類 type_id，取代分類 id，見 §6b）、`地区`→`{area}`、`年份`→`{year}`、`排序`→`{by}`、`语言`→`{lang}`、`字母`→`{letter}`、（`剧情/类别`→`{class}`，現有設定未用）。
- 使用者選了某鍵的某選項，就把該「参数值」填進對應占位符（`类型` 填 `{cateId}`／即 tid）；沒選的占位符維持空白、照 categoryUrl 既有邏輯被刪。

## 2. iOS 現況（根因，XBPQ.js）

- `homeContent`（`ios/Spiders/XBPQ.js:535-537`）：回 `host.result.home(categories(), [])`——**第三參數 filters 沒傳**，App 永遠沒有篩選列（`host.js` `home(classes, items, filters)`）。
- `categoryList(tid, page)`（:564）：**不收 extend**，使用者選的篩選值無處可進。
- `categoryUrl(tid, page)`（:405-423）：已處理占位符，但**沒填的占位符連同 `/名/` 片段一起刪掉**（:417-419）。亦即「填占位符」的機制已存在，只是從來沒有值可填。

→ 缺口只有兩點：①產生 filters ②把 extend 的值填進占位符。占位符替換邏輯不用改。

**Swift 側已完備、不用改（與 W-184 無重疊）**：extend 其實已經一路傳到 JS——`SourceClient.category` `.spider` 分支 `session.category(...,extend:)`（`SourceClient.swift:66`）→ `SpiderSession.category(...,extend:)`（:33/36）→ `JavaScriptSpiderRuntime.categoryContent` 把 extend 當第 4 參數丟進 JS（`:154` `text("categoryContent",[tid,page,filter,extend])`）。問題在 XBPQ.js 的 `categoryContent: function (tid, page)` 忽略了第 3/4 參數（filter、extend）。所以 **W-185 只動 XBPQ.js，不碰 SourceClient**；SourceClient 的 `.cms` 分支（type 1 不傳 extend）是 W-184 的範圍。

## 3. 移植範圍（最小改動）

只動 `XBPQ.js`（＋鏡像）與測試：

1. **解析篩選規則**（init 期）：讀 `类型/地区/年份/排序/语言/字母` 六鍵，各自解析成 `{分组: [{n:显示名, v:参数值}]}`。兩種分項語法都要支援（D-2）：`名$值#名$值…`（有 `$`，n/v 不同，如永乐 `类型`）與 `名&名&…`（無 `$`，`&` 分隔，n＝v，如 AG動漫/歐樂/If101/YLSP 的 `地区`）；`｜｜` 仍是依 `分类` 的分組分隔（只有 `$` 型用得到多分組，`&` 型通常單組共用）。
2. **homeContent 產 filters**：對每個一級分類 id，組 `filters[cateId] = [{key:占位符名, name:鍵中文名, value:[{n,v}…]}]`（value 前補一筆「全部/`{n:鍵名, v:''}`」）。選對應分組（多組時依分類序，單組時共用）。回 `host.result.home(categories(), [], filters)`。
3. **categoryContent/categoryList 收 extend**：`categoryContent` 改 `(tid, page, filter, extend)`（Swift 已把 extend 當第 4 參數傳進來，見下框）；`categoryList(tid, page, extend)` 把 extend 傳給 `categoryUrl`。`categoryUrl` 先算 tid＝`extend['类型'] || tid`（类型 取代 {cateId}），再把 `地区/年份/排序/语言/字母` 的值填進 `{area}/{year}/{by}/{lang}/{letter}`。`homeVideoContent` 的 categoryList 呼叫傳空 extend。
4. **無篩選規則的站不變**：六鍵都沒寫 → filters 為空 map → App 不顯示篩選列（同现状）；categoryUrl 的空占位符照樣被刪 → URL 與現在完全相同。开心影院即屬此類。

不動 `categoryUrl` 的占位符刪除邏輯、不動 `host.result` 介面、不動 CMSClient/SourceClient。

## 4. 現有 XBPQ 站實際用到哪些篩選欄位（wang-movie.json 12 站）

| 站 | 分类url 占位符 | 定義了選項的篩選鍵 |
|---|---|---|
| 永乐影视 | area/by/class/lang/letter/year | 类型（多分組） |
| csp_If101 / 歐樂ORG / YLSP / AG動漫 | area/by/class/year | 地区 等（4 站寫了地区） |
| 果果短剧 / 片库 | — | 剧情（分类）|
| 天天動漫 | class/by | — |
| xbpq_开心影院 / 奈飞工厂 / 饭搭子 / 追影 | 分类url 占位符全空 | **無**（維持無篩選，退化檢查目標）|

→ 有實際篩選資料可驗的站＝永乐影视類（类型/地区有定義選項）。无篩選資料的站＝开心影院類（退化檢查）。W-181 新增的 XBPQ 站多屬开心影院類（分类url 無篩選占位符），本單移植完後它們「有能力」顯示篩選，但要各站補規則才會出現——補規則是後續逐站工作，**本單不補**（符合根因建議第 3 點）。

## 5. 方案比較

- **no change**：維持無篩選。否決（使用者已核准要篩選）。
- **照搬原版 XBPQ 全部篩選語法**：原版還有更多邊角（自訂占位符名、篩選鍵別名）。採「只實作六個標準鍵＋固定占位符對應」的窄移植，涵蓋現有 12 站所有已寫的篩選欄位，其餘邊角不做（現有設定都沒用到）。
- **採用（窄移植）**：§3。風險最小、對無篩選站零影響。

## 6. 驗收 / 回滾
- 單元測試：永乐影视類 ext → homeContent 產出含「类型」的 filters；categoryList 帶 extend `{class:'6'}` → URL 的 `{class}` 填成 6、其餘空占位符仍被刪。无篩選 ext（开心影院）→ filters 空、URL 與現状相同（pin 一條）。
- Simulator（D-3）：三情境並附「選篩選前／後的分類網址 log」——①一個 `地区` 站（AG動漫／歐樂／If101／YLSP 之一）選地区後列表改變；②永乐 `类型` 選子分類後列表改變（tid/{cateId} 變化）；③开心影院（無篩選規則）回歸、仍無篩選列、分類網址與現状相同。永乐類若不可達，改用另一個可達的子分類篩選站並標明。另附 W-181 新增 XBPQ 站不退化。
- 回滾：單一 commit，revert 即回到無篩選。

## 6b. Reviewer REVISE 回應（#3617，待補齊後重送）

- **D-1（占位符對應要改）**：Reviewer 指出永乐 `类型`（动作片$6…）的值是**子分類 id**，在苹果CMS/stui 下 `/vodshow/6-…` 的第一格就是 type_id，所以 `类型` 選取應**取代 {cateId}（＝categoryList 的 tid）**，不是填 `{class}`。
  - 程式佐證：`XBPQ.js:416` `url.split('{cateId}').join(tid)`——{cateId} 填的就是 tid。故「类型」這類「值為 type_id」的篩選鍵，選取後要改走的是 tid，不是具名占位符。
  - **修正後的對應規則**：篩選鍵的「值是不是 type_id」決定它走 {cateId} 還是具名占位符。永乐把子分類放在 `类型`；`地区→{area}`、`年份→{year}`、`排序→{by}`、`语言→{lang}`、`字母→{letter}` 仍填各自占位符；`{class}` 對應的是「剧情/类别」這類鍵（永乐沒寫，留空被刪）。
  - **定讞依據（規則語意推導，Manager #3663 認可）**：永乐 `类型` 用 `｜｜` **依 `分类` 分組**＝各一級分類的子分類；值 `6/7/13…` 落在 `分类`（1-4）之外、是獨立 type_id。stui `/vodshow/{id}` 的第一格就是 type_id，`/vodshow/6` 直接顯示动作片。若 `类型` 是 `{class}`（剧情/类别）過濾鍵，選項不會依分類分組、值也不會是 type_id。→ **`类型` 是子分類選擇器，選取取代 {cateId}/tid**。採此設計。
  - **live 未驗**：www.ylys.tv 本網路 http=000（純 curl 逾時；乾淨 DoH 解到 104.21.31.174 後 `--resolve` 仍 000，站不可達／TLS 層被擋，非我方可控）。外部搜尋未找到原版 XBPQ 一手源碼（US 搜尋不含中文 TVBox 爬蟲）。**此對應在實作的 Simulator D-3 用「選篩選前後分類網址 log」佐證**（永乐類若屆時仍不可達，改用另一個有子分類篩選的可達站，並於 work done 標明）。
- **D-2（& 分隔）**：AG動漫、歐樂、If101、YLSP 的 `地区` 用 `&` 分隔、沒有 `$`（值＝顯示名）。解析器要同時支援 `名$值#…`（永乐類型）與 `名&名&…`（地区）兩種，`&` 型的 n 與 v 相同。測試要各補一條。
- **D-3（Simulator 驗收）**：要包含「一個地区站（AG動漫/歐樂/If101/YLSP 之一）＋永乐类型＋开心影院回歸」三種，並附「選篩選前／後的分類網址 log」。

## 6c. 中文篩選值的編碼（Reviewer #3715：不能雙重編碼）

- `categoryUrl` 對篩選值用 `encodeURIComponent`（地区「大陆」→ `%E5%A4%A7%E9%99%86`）。
- 送出路徑不會再編一次：`host.js` `req` → `__http.request(url)` → `HTTPHost.swift:21` `URL(string: url)`。`URL(string:)` **原樣接受已 %-編碼的字串、不會把 `%` 再編成 `%25`**。故中文值在分類網址中**只編碼一次**（`%E5…`，非 `%25E5…`）。
- Simulator D-3 的 category URL log 會再實證一次。

## 7. 待 Manager 決定
W-181 新增的 6 個 XBPQ 站（开心影院類）分类url 沒有篩選占位符，本單移植後仍不會顯示篩選。**是否同時替這些站補篩選規則**（逐站實測各站 vodshow 的篩選網址格式）？建議另開工作單，不併入本單（本單只動 App 程式，不改設定檔）。
