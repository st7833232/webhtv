# IOS-POC-6A — drpy JavaScript loader（使用者 roadmap 的 POC-3）

- 狀態：**完成**。D1 + E1/E2/E3/E4 全數完成，**四個 drpy 來源全部端到端驗證並取得媒體位元組**。
- 分支 `ios-poc`，基線 HEAD `5b4b8668`
- 日期：2026-09-18
- 下一步：無。嗅探層的包裝頁處理已於 IOS-POC-6C 完成（見 `docs/current-task-state.md`）。

## D1 — 實際量到的東西

全部在 2026-09-18 對使用者自己的 GitLab repo 實際抓取驗證，不是從設定檔推論的。

### 5 個來源其實是 4 個

| key | api | ext | 狀態 |
|---|---|---|---|
| `bubutv` | `./json/4k.js` | — | **404**。抓回來的是 GitLab 的錯誤頁，repo 裡沒有這個檔案 |
| `drpy_js_去看吧` | `./drpy_libs/drpy2.min.js` | `./drpy_js/去看吧.js` | 12,458 bytes，明文 |
| `drpy_js_爱弹幕` | 同上 | `./drpy_js/爱弹幕.js` | 8,796 bytes，明文 |
| `hipy_js_七色番[漫]` | 同上 | `./drpy_js/七色番[漫].js` | 3,352 bytes，**非明文**（開頭 `h36A5I5Kde…`，不是 base64） |
| `hipy_js_爱弹幕[漫]` | 同上 | `./drpy_js/爱弹幕[漫].js` | 4,340 bytes，**base64**（解出來是 `muban.短视2.二级.img = …`） |

**所以可驅動的候選是 4 個，不是 5 個。** roadmap 寫的「5 個來源」要修正。`bubutv` 是缺檔，
不是技術問題——照既有慣例（`JPianAmns`/`AppV6` 那兩個沒下載的 JAR），**缺檔不記成技術判決**。

### 架構：`api` 是引擎，`ext` 是站規則

這和 `XBPQ`／`XYQHiker` 是同一個形狀（規則引擎 + 規則檔），差別只在引擎本身也是設定檔送來的
JavaScript，而不是我們移植的 class。

### drpy2.min.js 的相依（71,463 bytes，ES module）

```
import cheerio from "assets://js/lib/cheerio.min.js";
import              "assets://js/lib/crypto-js.js";
import              "./jsencrypt.js";
import              "./node-rsa.js";
import              "./pako.min.js";
import 模板    from "./模板.js";
import{gbkTool}from "./gbk.js";
import              "./json5.js";
import              "./jinja.js";
export default {runMain, getRule, init, home, homeVod, category, detail, play, search,
                proxy, sniffer, isVideo, fixAdM3u8Ai, DRPY};
```

**九個相依全部都在使用者自己的 `drpy_libs/` 裡**，包含那兩個 `assets://` 的：

| 檔案 | 大小 | 形式 |
|---|---:|---|
| `cheerio.min.js` | 356,593 | **ES module**（`export{… as default, … as load, …}`） |
| `crypto-js.js` | 204,310 | UMD |
| `jsencrypt.js` | 217,423 | webpack bundle |
| `node-rsa.js` | 167,481 | webpack bundle |
| `json5.js` | 60,431 | UMD |
| `gbk.js` | 56,246 | **ES module**（`export function gbkTool`） |
| `pako.min.js` | 46,859 | UMD |
| `jinja.js` | 22,706 | UMD |
| `模板.js` | 20,033 | **ES module**（`export default {muban, getMubans}`） |

`assets://` 只是 Android app 從自己的 assets 解析的方式；同名檔案在設定檔的 `drpy_libs/` 底下都有。
**所以不需要把任何第三方程式碼 vendor 進這個 repo**——這一點原本是我最擔心的，AGENTS.md 對
「不要靜默複製第三方實作」有明文規定，而這裡完全不會碰到。

### 好消息：需要我們提供的 host 介面很小

drpy2 **自帶 HTML 解析（cheerio）與加解密（crypto-js / node-rsa / jsencrypt）**，它自己定義
`pdfh`／`pdfa`／`pd`／`print`／`log`。真正向外要的只有：

- HTTP：`req` / `request` / `fetch` — `CatVodHost` 已經有
- 儲存：`local` — `CatVodHost` 已經有
- `getProxy` — 被 `typeof getProxy` 保護，可不提供

也就是說，計畫裡「`host.js` 已經有 drpy-compatible 的 `pdfh/pdfa/pd`」這句話是對的但**用不上**，
drpy2 不會用我們那一套。**這反而讓 D5（補 primitive）大幅縮小。**

### 更好的消息：export 幾乎與我們的 ABI 一對一

| drpy2 | `SpiderRuntime` |
|---|---|
| `init(ext)` | `initialize(extend:)` |
| `home(filter)` | `homeContent(filter:)` |
| `homeVod()` | `homeVideoContent()` |
| `category(tid, pg, filter, extend)` | `categoryContent(tid:page:filter:extend:)` |
| `detail(id)` | `detailContent(ids:)` |
| `search(wd, quick, pg)` | `searchContent(key:quick:page:)` |
| `play(flag, id, flags)` | `playerContent(flag:id:vipFlags:)` |
| `isVideo(url)` | `isVideoFormat(url:)` |
| `proxy(params)` | `proxy(params:)` |

adapter 大約 20 行的名稱對映，沒有新 ABI——與使用者指示的「不是重新設計整套 ABI」一致。

## 設計

### 不新增第二套 runtime

`JavaScriptSpiderRuntime` 收 `prelude` + `script`，自己建 `JSContext`、裝 `CatVodHost`、
用 `module.exports` 取出 spider、用 `invokeMethod` 派送。drpy 完全套得進去：

```
prelude = host.js
        + 七個 UMD/webpack lib（原樣 eval）
        + 四個 ESM 檔（cheerio / 模板 / gbk / drpy2，改寫後 eval）
script  = drpy-bridge.js   // module.exports = 13 個方法，轉呼叫 drpy2
extend  = 該站 ext 解析出來的絕對 URL（沿用 CSPSourceResolver.resolvedExtend，已經會做）
```

**唯一的新元件是 `DrpyEngine`**：抓取並組出那段 prelude，per-process 快取一份。

### ESM 改寫，只針對四個已知檔案的已知形狀

只有四個檔案用 ESM，而且形狀都很窄：

| 形狀 | 改寫成 |
|---|---|
| `import X from "…"` | `var X = <對應的 global>;` |
| `import "…"`（純副作用） | 刪掉（該 lib 已在 prelude 前面 eval 過） |
| `import{a}from "…"` | `var a = <global>.a;` |
| `export default X` | `globalThis.<name> = X;` |
| `export{a as b, c as default}` | `globalThis.<name> = {b: a, default: c, …};` |

**改寫後會做一次檢查**：若還有 statement 開頭的 `import`/`export` 殘留就直接報錯，而不是丟進
`evaluateScript` 讓它爛在半路。

`ponytail:` 這是**針對這四個檔案的窄改寫，不是 ES module loader**。JavaScriptCore 有
`JSScript`/`setModuleLoaderDelegate` 可以做真的 module loading，但那要處理 cache file URL 與
相依解析，而這裡的相依圖是靜態的九個檔案。真的遇到改寫不了的形狀再升級。

### 路由

- `Site.isDrpySpider` = `type == 3 && api` 以 `.js` 結尾
- `CSPSourceResolver.canResolve` 與 `session(for:)` 認得它（`session(for:)` 要變 `async`，
  因為要抓 1.2 MB；`SpiderSessionStore.session` 跟著變 `async`）
- `WebHTVConfig.drivableSites` 因此自動包含它們，UI 不用改（IOS-POC-5D 的路由早就通了）
- `SourceClient` 完全不用動——drpy 站回傳的就是 CatVod JSON

### 切片

| 切片 | 內容 | 驗證 |
|---|---|---|
| **E1** | `DrpyEngine`：相依清單、抓取、ESM 改寫、殘留檢查、快取 | 單元測試用**本機 fixture**，不打網路：四種 ESM 形狀各一，加一個「改寫不掉就報錯」 |
| **E2** | `drpy-bridge.js` + 路由（`isDrpySpider`、resolver、async session） | 單元測試：一個假的 drpy2 stub 走完 13 個方法的派送 |
| **E3** | 一個真站 end-to-end golden | `DRPY_GOLDEN_SITE=<site json>` live golden：`init → home → category → detail → search → play`，最後要拿到媒體位元組 |
| **E4** | 擴到 4 站 + 更新 `drivableSites` 的計數斷言（62 → 66） | `swift test` 全綠 + `xcodebuild` |

`七色番[漫].js` 那個非 base64 的編碼要在 E3/E4 才會知道 drpy2 能不能自己解（`getRule` 應該會處理），
若不能就把那一站標為 blocked，**不擴大範圍去逆向它**。

## 待你決定（已於 2026-09-18 由使用者選定 **A+**，保留原文供追溯）

**要不要讓 App 在執行期抓取並 eval 約 1.2 MB 未經驗證的第三方 JavaScript？**

這是這個階段唯一超出既有信任模型的地方，我不自己決定：

- IOS-POC-5O 的 compatibility pack 明文寫著「網路來的可執行碼，信任程度等同它來自的 URL」，
  而且那還是**逐檔 SHA-256 驗證**的幾 KB 腳本。
- 這裡要 eval 的是 cheerio、crypto-js、node-rsa、jsencrypt 等**未驗證**的 bundle，共約 1.2 MB，
  來源是同一個設定檔 origin。
- 它們跑在 `JSContext` 裡，只看得到 `CatVodHost` 給的東西（HTTP、儲存、加解密），**沒有 native
  bridge、沒有檔案系統、沒有 entitlement**——與既有 spider 同一個沙箱，不會更寬。
- 但這仍然是把「執行任意第三方程式碼」的量級從 KB 拉到 MB。

**我的建議：做，但加兩道護欄。** 理由是設定檔本來就被信任（它已經可以指定 compatibility pack），
而 drpy2 沒有替代路徑——不 eval 引擎就沒有 drpy 支援。護欄：

1. **只從設定檔自己的 origin 抓**，且強制 HTTPS，與 compatibility pack 同一條規則。
2. **把抓到的每個檔案的 SHA-256 記進階段文件**，第一次抓完就固定下來；之後改變會被看見。
   （不做強制 pin，因為使用者自己會更新那個 repo。）

你也可以選：

- **B：先只做 E1+E2**（loader 與路由，含本機 fixture 測試），真的抓網路那一步等你點頭。
- **C：不做 drpy**，直接跳到 POC-4 Python。

## 驗收條件

| # | 條件 | 怎麼驗 |
|---|---|---|
| G1 | 四種 ESM 形狀都改寫得出來，殘留時報錯而不是 eval 壞碼 | 單元測試（本機 fixture） |
| G2 | 一個 drpy 站跑完 `init → home → category → detail → search → play` | live golden |
| G3 | 最後那個 URL 真的取得到媒體位元組 | golden 內 `MediaProbe.classify == .media` |
| G4 | `drivableSites` 從 62 變成 62 + 實際可驅動的 drpy 站數 | 既有計數測試更新 |
| G5 | 既有 62 站、CMS、WebHome、playback、watch history 全數無退步 | `swift test` 全綠 + `xcodebuild` |
| G6 | 引擎抓不到或改寫失敗時，該站不可用而**其他站不受影響** | 單元測試（注入失敗的 fetch） |

## 回滾

- 未 commit：`git restore`。
- 已 commit 未 push：`git revert`，不 amend、不改寫歷史。
- 資料層：drpy 只新增來源，不動既有資料；引擎快取在記憶體，重啟即清。

## 風險

| # | 風險 | 對策 |
|---|---|---|
| R1 | 1.2 MB 於第一次開 drpy 站時抓取，冷啟動慢 | per-process 快取；四站共用同一份引擎。磁碟快取列為升級路徑，不先做 |
| R2 | 這些 bundle 用到 JavaScriptCore 沒有的 Web API（`window`、`XMLHttpRequest`、`TextDecoder`） | E1 的殘留檢查抓不到這種，要靠 E3 的 golden。真缺就在 `host.js` 補最小 shim，**不改第三方碼** |
| R3 | `七色番[漫].js` 的非 base64 編碼 drpy2 可能解不開 | 標為 blocked，不逆向 |
| R4 | drpy2 是 minified，出錯訊息不好讀 | golden 直接印 `JSContext` 的 exception |
| R5 | 記憶體：每站一個 `JSContext` × 1.2 MB 引擎 | 四站就是四份。若真的吃緊，改成共用一個 context 分 namespace——但那會破壞既有的「一站一 context」隔離保證，**不先做** |

## Ponytail（實作前）

① 需要存在——使用者 roadmap 的下一個 bounded stage。② 已有的東西先用——`JavaScriptSpiderRuntime`、
`CatVodHost`、`SpiderSession`、`SpiderSessionStore`、`ConfigSource.resourceURL`、
`CSPSourceResolver.resolvedExtend` 全部原樣沿用；**不新增 runtime**，唯一新元件是 `DrpyEngine`
這個 loader。③ 標準庫——`URLSession` + 字串改寫，無新相依。⑤ 不 vendor 任何第三方碼（相依都在
使用者 repo）。⑦ 最小可行：一個新檔 + 一個新 JS bridge + 三處小改（`Site`、resolver、session store 轉 async）。

刻意不做：真正的 ES module loader（相依圖是靜態的九個檔案）、磁碟快取、共用 `JSContext`、
逆向 `七色番[漫].js` 的編碼、`bubutv`（缺檔）。


---

# 實作紀錄（IOS-POC-6B，2026-09-18）

使用者選 **A+**：允許執行期下載並 eval，但邊界要收緊。以下逐條對應。

## A+ 的每一條，實作在哪

| 要求 | 實作 |
|---|---|
| 只從目前設定檔自己的 origin 載入 | `DrpyEngine.checked(_:origin:)`，比對 scheme + host + port |
| 強制 HTTPS | 同上，非 https 直接 `insecureURL` |
| 禁止任意跨 origin import | 同上；`assets://` 被映射到設定檔的 `drpy_libs/`，不另開連線 |
| 只用既有 JavaScriptCore + `host.js` + `CatVodHost` | 沒有新 runtime。drpy 站跑的是**同一個** `JavaScriptSpiderRuntime`、同一個 `JSContext`、同一個 `CatVodHost`。無 native bridge、檔案系統、entitlement、shell |
| eval 前比對 approved SHA-256，不符拒絕 | `DrpyEngine.load` 先下載、再比對 `dependencies` 裡的 hash，不符拋 `hashMismatch`。**沒有警告後繼續的路徑** |
| cache 也要重新驗證 | 只有記憶體 cache，存的是**本 process 已驗證過的文字**，未驗證的位元組沒有進入點。**刻意沒有磁碟 cache**，因為那才需要回頭重驗 |
| 單檔與整包大小上限 | 單檔 512 KB、整包 2 MB、站規則 256 KB。用 `URLSession.bytes` 邊收邊檢查，**超過就中止**而不是先緩衝完再說 |
| 不建立第二套 runtime | 見上。`DrpyEngine` 是 loader，`drpy-bridge.js` 是 adapter |
| 共用 library 只載入一次 | `DrpyEngineStore` 以設定檔 origin 為鍵做 per-process 快取；四個 drpy 站共用同一份引擎，且不會每次呼叫重抓 |
| 區分 dependency 與 site rule，記錄 provenance | 見下表。dependency 被 hash pin，site rule 不被 pin（理由見下） |
| 失敗一律 fail closed | hash 不符、HTTP 失敗、超過上限、非 UTF-8、改寫後的語法錯誤、缺 host primitive，全部讓**該站**不可用並帶名稱，不退化成執行未驗證碼 |

## Ponytail 對「hash 寫死進 App」的回答

使用者允許我在不降低 fail-closed 的前提下提最小替代方案。**不需要替代方案，因為 pin 並不會破壞熱更新目標**：

IOS-POC-5O 已經畫過同一條線——compatibility pack 可以換 **spider script**，但 `host.js` **刻意不可 pack**，因為那是 script 跑在上面的 SDK，換 SDK 就是發版。drpy2 與它的九個 library 正是同一類東西：它們是站規則跑在上面的引擎，約 1 MB 的第三方 bundle，**很少變動**。所以：

- **dependency library → 綁進 App 的 SHA-256**，不符就拒絕該站。與 `host.js` 站在同一側。
- **site rule/script → 不 pin**，只受同源 + HTTPS + 大小上限約束。它是 spider 的對應物，幾 KB、常變動，**這才是真正需要熱更新的那一半**。

所以熱更新能力一點都沒少，只是把引擎放到 `host.js` 本來就在的那一邊。

## Provenance：這次實際 pin 的十個檔案

全部量自 `https://gitlab.com/st7833232/recha/-/raw/main/drpy_libs/`，2026-09-18。

| 檔案 | bytes | SHA-256 |
|---|---:|---|
| cheerio.min.js | 356,593 | `f03171a4d979593c59dff2267b4beee8aaedd1a0af04f34f9984bdf5f7bdeade` |
| crypto-js.js | 204,310 | `731c9606953ddedd5bafe52e32eeced73f2a3750fbdac3c812b4a04881e48c07` |
| jsencrypt.js | 217,423 | `dfba3a7905507484399622e0938cd5462a44c913450927ea8c3eb760d57660dd` |
| node-rsa.js | 167,481 | `b2e1d9c402ce06c19d08e1659624bfbbda91994d06339300970c395977e6d37c` |
| pako.min.js | 46,859 | `7b7a3b8db4d7b65846b807f1309688a8955961dbde5538694862a6c5cbc932cf` |
| 模板.js | 20,033 | `0f6874dc6d19aa9fb71125780bc3ffd349ef7be80032f95a76985a1f1ac8cbf2` |
| gbk.js | 56,246 | `cf46ccf34d32ce873f021fc5e94c43a73afcb7a551004be8d6a02e94986d0696` |
| json5.js | 60,431 | `1b3d54f76b9106641e540b6561dc950ffe281590f8546b88f26fc7a91c225e10` |
| jinja.js | 22,706 | `6cf1781f0c32206236049d392383dbc558b530244926d93762dfa3362967bff2` |
| drpy2.min.js | 71,463 | `cbfd7b23f86b07f8fa55ba85aae66af430b2a1c5501160f8867e1852661adba2` |
| **合計** | **1,223,545**（1,194 KB） | |

**Site rule script（不 pin，只記錄）**：`去看吧.js` 12,458 B、`爱弹幕.js` 8,796 B、
`七色番[漫].js` 3,352 B（非 base64 的未知編碼）、`爱弹幕[漫].js` 4,340 B（base64）。

## 補進 `CatVodHost` 的 primitive

使用者要求缺的 primitive 放共用層、不寫進單站 script。這一輪補了三樣，全在共用層：

1. **`pdfh` / `pdfa` / `pd` / `joinUrl` / `local` 的 bare global 別名**（`DrpyEngine.moduleRuntime`）。
   drpy 的 host 契約把它們放全域，我們一直放在 `host.` 命名空間下。**是別名不是第二套實作。**
2. **`req`**（同上）。`CatVodHost.req` 本來就會發請求，回 `{body, json, headers, code}`；drpy 讀
   `res.content`。只映射這一個欄位名。
3. **選擇器的 `:gt(n)` / `:lt(n)`**（`host.js`）。`去看吧` 的 `class_parse` 是
   `.fed-pops-list:eq(0)&&li:gt(0):lt(6)`，我們的引擎原本只有 `:eq(n)`，分類清單因此是空的。
   照 jQuery 語意實作並可鏈接。**這是唯一一個真正新增的能力，而且在共用層。**

## ESM 改寫踩到的兩個坑

1. **side-effect import 的 regex 咬進字串字面值。** cheerio 的 minified 內容含
   `"parseImport: expected import"`，`import"` 這個序列真的出現在字串裡，於是幾百個字元的真程式碼
   被換成分號，症狀是 `'break' is only valid inside a switch or loop`。修法：所有 pattern 都錨定在
   陳述式邊界（`^` / `;` / `}` / 換行）。
2. **連續的 import 互相吃掉分隔符。** drpy2 把九個 import 放在同一行，前一個 match 若吃掉結尾的
   `;`，下一個就沒有錨點，而掃描不會回頭。修法：import 形式**不消耗結尾的 `;`**。

殘留檢查刻意**不自己寫掃描器**——改寫不掉的東西仍是 module 語法，`evaluateScript` 會拋
SyntaxError，該站 fail closed。引擎自己的 parser 比任何分不清字串與程式碼的掃描器都準。

## 驗證

### 離線（預設就會跑）

`WANG_MOVIE_JSON=<config> swift test --package-path ios` → **140 測試全過**（6B 之前是 124）。
新增 16 條：四種 ESM 形狀、模組不共用頂層名稱、未載入模組要拋錯、改寫不掉要 SyntaxError、
非 HTTPS 拒絕、跨 origin 拒絕、imported config 不給 drpy、路徑解析、pin 清單自洽且在上限內、
SHA-256 演算法向量、bridge 走完 13 個方法、無引擎時 bridge 要拒絕。
`SourceClientTests` 的計數測試擴充為：imported config 列 62、remote config 多列 5 個 drpy 站。

`xcodebuild … -scheme WebHTVApp … Debug build` → **BUILD SUCCEEDED**。

### Live golden — `去看吧`，兩次一致

```
DRPY_GOLDEN_BASE='https://gitlab.com/st7833232/recha/-/raw/main/wang-movie.json' DRPY_GOLDEN_SITE='{"key":"drpy_js_去看吧",…,"ext":"./drpy_js/去看吧.js"}'   swift test --package-path ios --filter drpyDrivesARealSourceEndToEnd
```

```
[drpy] engine verified and loaded for drpy_js_去看吧
[drpy] home: ["高清原碟", "日漫", "国语动漫", "劇場", "女频", "日韩剧"]
[drpy] category 33: 48 items, first=浪漫追星社
[drpy] detail 浪漫追星社: flags=["线路空" …×5], episodes=12
[drpy] search 我: 10 results
[drpy] player: parse=1 url=https://www.k9dm.com/index.php/vod/play/id/10959/sid/3/nid/1.html
[drpy] playback: https://www.k9dm.com/1006/vip/?url=https://vip.dytt-network.com/…/index.m3u8
```

**十個相依全部 hash 驗證通過並載入，`home → category → detail → search → player` 全通，資料是真的。**

## 沒做到的：G3 的最後一哩，與 E4

- **G3（媒體位元組）在 `去看吧` 上沒達成。** drpy 回 `parse:1`（一個頁面），把頁面變成串流是
  `MediaSniffer` 的工作，而它停在一個**外層播放頁**：
  `https://www.k9dm.com/1006/vip/?url=https://vip.dytt-network.com/…/index.m3u8`。
  真正的 m3u8 就在 `?url=` 查詢參數裡。兩次執行結果一致，不是時序抖動。
  **這是嗅探層的缺口，不是 drpy loader 的**——loader 的責任到 `parse:1` 頁面為止，而那一步是對的。
  修法（下一步，不在本階段）：`MediaSniffer` 遇到候選頁時，先看 URL 的查詢參數裡有沒有直接的媒體位址。
- **E4（擴到全部來源）沒完成。** 另外三站 `爱弹幕`、`七色番[漫]`、`爱弹幕[漫]` **一次都沒量到**：
  GitLab 在我反覆抓 1.2 MB 之後開始拒絕連線。`curl` 從 shell 直接測也是
  `http=000 size=0`，**與 App 無關，是站方限流**。放長逾時（引擎專用 session，60 s/180 s）沒有用，
  因為連線根本沒建立。等冷卻後重跑即可。
- **`bubutv`（`./json/4k.js`）是 404**，缺檔，不列為技術判決。
- **實機仍然從未驗證。**

## Ponytail（final diff）

刪掉沒有呼叫端的 `DrpyEngine.engineModule`。`host` 的別名區塊加了 `typeof host === 'undefined'`
守衛，讓改寫器能在裸 context 裡被測試而不用拖進整個 host。沒有新增 runtime、沒有 vendor 任何
第三方碼、沒有新的 native 能力；唯一真正新增的能力是選擇器的 `:gt`/`:lt`，而它在共用層。
三個 `ponytail:` 註記：改寫器是針對已知四種形狀（非 ES module loader）、殘留檢查交給引擎自己的
parser、記憶體快取不落磁碟。


---

# E4 收尾與 G3 達成（2026-09-18，IOS-POC-6C 之後）

先前擋住的兩件事都解決了。

## G3 —— 媒體位元組拿到了

原因跟我先前寫的不一樣，值得更正：**問題不在輸入頁，而在嗅探結果**。
`去看吧` 的播放頁沒有 query string；是**嗅探器回報的候選** `…/1006/vip/?url=…/index.m3u8`
本身是個包裝頁，而它之所以通過關鍵字比對，正是因為被它包住的那個位址含 `.m3u8`。

修法（IOS-POC-6C）：把候選的比對述詞抽成 `MediaSniffer.isCandidate`（hook 與 query 檢查共用，
避免兩條路徑對「什麼是串流」產生分歧），並在**接受候選時**用 `MediaSniffer.unwrapped` 拆一層。
輸入頁本身就帶 query 的情況也一併短路處理——那條路連 web view 都不用開。只拆一層。

結果：`去看吧` 的 playback 從包裝頁變成
`https://vip.dytt-network.com/20260914/39525_86d53348/index.m3u8`，`MediaProbe` 回 `.media`。

## E4 —— 四個來源全部通過

GitLab 冷卻後重跑，四站都是 `home → category → detail → search → player` 全通，
且**最後都取得媒體位元組**：

| 來源 | 規則檔形式 | home | category | detail | search | player | 媒體 |
|---|---|---|---|---|---|---|---|
| `drpy_js_去看吧` | 明文 | 6 類 | 48 筆 | 5 線路 / 12 集 | 10 | `parse:1` → 嗅探 → 拆包裝 | ✔ |
| `drpy_js_爱弹幕` | 明文 | ✔ | ✔ | ✔ | ✔ | `parse:0` 直出 | ✔ |
| `hipy_js_七色番[漫]` | **非 base64 的編碼** | 3 類 | 20 筆 | 2 線路 / 43 集 | 12 | `parse:1` → 嗅探 | ✔ |
| `hipy_js_爱弹幕[漫]` | **base64** | 6 類 | 48 筆 | 2 線路 / 12 集 | 0 | `parse:0` 直出 | ✔ |

**風險 R3 解除**：`七色番[漫].js` 那個非 base64 的編碼，drpy2 的 `getOriginalJs` 自己解得開，
我們一行都不用碰，也沒有逆向任何東西。

`bubutv`（`./json/4k.js`）仍是 404，缺檔。它在遠端設定下**仍會被列出**（列出依形狀判斷，與
其他 62 站「列出不等於可播」的既有立場一致），開啟時會以具名錯誤失敗。

## 本輪的環境變化

`xcodebuild` 的 `-destination 'platform=iOS Simulator,name=iPhone 17 Pro'` **不再唯一**：
機器上多了 iOS 27.0 runtime，`iPhone 17 Pro` 同時存在於 26.0 與 26.3，xcodebuild 因此拒絕解析。
改用 `-destination 'platform=iOS Simulator,id=7B4E9557-4774-4EB9-B408-BB544DCC8657'`（一路以來
驗證用的那台，iOS 26.3）即可。
