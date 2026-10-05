# IOS-POC-54 爬蟲共用工具第一批（host.js）

## Recovery anchor

- 目標：從既有 `csp_*` JS port 找出真正重複的處理，抽成 `host.js` 的小型共用函式並讓來源實際使用；所有請求、逾時、重試、錯誤、輸出與 identity 不變。
- 狀態：已實作、已驗證（見第 4 節），commit 見第 6 節。未發布新 IPA，真機未驗證。
- 下一步：無。下一個 IPA 發布後，`js.host` 1.2 才會到使用者手上（見第 5 節限制 1）。

## 1. 範圍與基準

- 使用者指示（2026-10-05）：「內部可重複使用的爬蟲工具」第一批，只做 JS；不重寫 SourceClient／SpiderRuntime，不做對外 API、通用爬蟲或框架；Python 共用工具等有實際需求再做；不另跑測試 CI。
- 基準：fetch 後的 `origin/ios-poc` `617e9ca521efd6c733e0876c1fdc1cbbe91c3bae`，工作區乾淨。
- Lane：`quick-fix`，task guard `IOS-POC-54`。
- Scope 中途補了 5 個路徑（`RuntimeABI.swift`、`RuntimeABITests.swift`、`RuntimePackManifestTests.swift`、`scripts/spider_pack.py`、`docs/IOS-POC-5O-remote-compatibility-pack.md`）。原因：`RuntimeABITests` 顯示 `host.js` 是凍結的 `js.host` ABI，改 host.js 就必須依 IOS-POC-12 的規則升版。guard 沒有擴充 scope 的指令，啟動時 protected dirty 為 0，所以直接把這些路徑加進同一個 session 的 scope 檔。
- 設計研究關卡：不適用。這是既有 SDK（`host.js` 開頭就寫明「no spider re-implements them」）裡的局部重構，沒有新能力，也沒有改變架構或行為。

## 2. 盤點結果

讀過 `host.js`、`js-spider.js`、`drpy-bridge.js` 和 13 個 port（App3Q、App99、AppGet、AppQi、Bili、HaokanDJ、HemaDJ、JianPian、Jpys、QimaoDJ、WeiguanDJ、XBPQ、XYQHiker）。drpy2 自帶 cheerio／crypto-js，不用 host 的 HTML 工具；JS spider 和 drpy bridge 都只做名稱對應，沒有可以抽的東西。

### 已抽出／已改用

| 重複處理 | 原本 | 現在 | 採用的來源 |
|---|---|---|---|
| 直接媒體檔判斷 `/\.(m3u8\|mp4\|mkv\|flv)(\?\|$)/i` | 11 份逐字相同的 `isVideoFormat`，AppGet 的 `playerContent` 另有一份 | `host.isVideoFormat(url)` | App3Q、App99、AppGet（兩處）、AppQi、Bili、HaokanDJ、HemaDJ、JianPian、Jpys、QimaoDJ、WeiguanDJ |
| 鏡像清單文字檔取第一個 http(s) 行 | AppGet、AppQi 各有一段 6 行迴圈 | `host.firstURL(text)` | AppGet、AppQi（`ext.site`） |
| 列表四欄位投影 | App3Q、AppGet、AppQi 各有 `vodList`，內容和 `host.result` 本來就做的 `vod()` 投影相同 | 刪掉 `vodList`，直接交給既有的 `host.result.home/page/list` | App3Q、AppGet、AppQi |

`host.result.home` 在 `items` 是 `undefined` 時不輸出 `list`；舊的 `vodList` 會把它變成 `[]`。所以三個來源的 `home` 都寫 `|| []`，讓沒有推薦清單時仍輸出 `"list":[]`。

App99 的 `vodList` 會改欄位名（`id`→`vod_id`），不是重複，保留。

### 看過但沒有抽（據實）

- **JSON 回應裡的 `"url"` 正則**（AppGet 2、AppQi 2、XBPQ、XYQHiker）：每處的欄位優先順序不同，而且 `\/` 還原套在整個結果上。抽出去不是改變重複還原的次數，就是改變套用範圍，無法保證輸出逐字相同。
- **App3Q／App99 的集數編碼** `label$url@from@name@number`：兩份相同，但這是 App-API 家族各自 `playerContent` 拆回去的格式，屬於 adapter 的解析規則，留在 adapter。
- **AppGet／AppQi 的篩選列建構**：邏輯相同，但 HIDDEN、標籤文字、init 路徑、request body 的 key 順序不同，屬於 adapter 規則。
- **`ext` 的 `JSON.parse(extend || '{}')`**（App99、AppGet、AppQi、Bili）：只是一行 try／catch。App3Q 是另一種語意（`'null'` 加 http fallback），不能共用。抽出去沒有實際好處。
- **`replace(/\/+$/, '')`**、**`parseInt(page, 10) || 1`**、**「整頁表示可能有下一頁」的分頁**：都是單一運算式，或只有兩個來源而且參數不同。
- headers、簽名、加解密參數依指示留在各 adapter。

## 3. ABI 升版（js.host 1.1 → 1.2）

`host.js` 屬於 `js.host` 面（IOS-POC-12）。只要改到它，fingerprint 就會變；新增匯出算 minor。

- `RuntimeABI.swift`：`.jsHost` 改為 `Version(1, 2)`；`jsHostExports` 加入 `isVideoFormat`、`firstURL`。`SpiderPackStore.hostApiVersion` 由 minor 推導，所以變成 2。
- `RuntimeABITests.swift`：新增 `.init(1, 2)` 的凍結列 `d314325a5c270d800a104edeece16a2634ccf629f4643365739a98897eab2d09`（1.1 已出貨，保留不改）。`hostApiVersion == 1` 的釘值改成 2。
- `RuntimePackManifestTests.swift`：「需要更新的 minor 會被拒絕」原本寫死 `minMinor 2`／`installed 1`，改成由 build 的 minor 推導。
- `scripts/spider_pack.py`：`HOST_API = 2`。之後產生的 pack 會要求 host API 2，舊 App 會整包拒絕（顯示需要較新的 App），不會在呼叫 `host.firstURL` 時才失敗。
- 文件：`docs/IOS_SPIDER_RUNTIME_SPEC.md`（Utility 列、hostApiVersion 2）、`docs/IOS-POC-5O-remote-compatibility-pack.md`（hostApiVersion 2）。

## 4. 驗證

| 檢查 | 結果 |
|---|---|
| 新舊版差分比較（Node `vm`，scratchpad 的 `diff.js`）：改動前的 13 個 port＋舊 host.js，對照改動後的版本。`__http`／`__crypto`／`__store`／`__util`、`Math.random`、`Date` 都換成固定值。每個來源跑 3～5 種 `ext`，依序呼叫 init → home → category ×2 → detail → search → 各種 play id → manualVideoCheck → destroy，再跑一次全部空回應，最後用 11 種 URL 呼叫 `isVideoFormat`。逐字比對每個請求（url、method、headers、body、timeout、redirect）與每個輸出 | 13／13 **SAME**，共 327 個請求 |
| 差分比較的突變測試：分別在 `firstURL`、`isVideoFormat` 的正則、AppGet home 的 `\|\| []`、App3Q search 植入錯誤 | 4／4 都出現 DIFF |
| `swift test --filter`：SpiderHost、ShortDramaSpider、SpiderPack、RuntimeABI、RuntimePackManifest、XBPQRule、XYQHikerRule、DrpyEngine、SpiderGolden 這 9 個檔案的全部測試（真的 JavaScriptCore；新增 `sharesTheMirrorListAndVideoChecksThePortsUsed`） | 128／128 通過。SpiderGolden 需要 `CSP_GOLDEN_SITE` 才會連線，這次沒設，所以沒有打即時站台 |
| 本機 Xcode 27 未簽章 device Release 建置（`xcodebuild -scheme WebHTVApp -configuration Release -sdk iphoneos -destination generic/platform=iOS`，簽章參數同 release workflow） | **BUILD SUCCEEDED**（26 秒）。App bundle 裡的 `host.js`、`AppGet.js` 和原始檔逐位元相同。第一次少帶 `EXPANDED_CODE_SIGN_IDENTITY=-`，在 Install Python 簽 framework 時失敗（`no identity found`），補上 workflow 的參數後重跑通過 |

沒有跑：完整 `swift test`、測試 CI、即時 golden、Simulator 或真機。

Ponytail（`ponytail:ponytail-review`，對最終 diff）：提出 1 項（`firstURL` 的迴圈縮成 map/filter，少 4 行），已套用。套用後重算 fingerprint，差分比較與 128 個測試都重跑過。

## 5. 限制

1. 目前裝在手機上的 `0.1.67 (68)` 是 `js.host` 1.1。用新 `HOST_API = 2` 產生的 pack 在它上面會被整包拒絕，要等下一版 IPA。這次沒有發布，也沒有產生 pack。
2. 差分比較用的是固定的假回應，證明的是新舊程式在相同輸入下行為相同，不能代表即時站台現在的狀況。
3. 真機未驗證。內建 spider 的程式路徑只換成呼叫共用函式，差分比較的結果是逐字相同。

## 6. Commit 與回復

- Commit：見 `git log`（`refactor(ios): share the spiders' video check and mirror-list helper in host.js (IOS-POC-54)`）。
- 回復：`git revert` 這個 commit。ABI 會回到 1.1，`HOST_API` 回到 1。這次沒有發布，所以 1.2 的凍結列可以一起撤掉。
