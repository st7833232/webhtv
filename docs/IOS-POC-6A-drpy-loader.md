# IOS-POC-6A — drpy JavaScript loader（使用者 roadmap 的 POC-3）

- 狀態：**D1 觀測完成，計畫待核可**。尚未改任何 production 程式碼。
- 分支 `ios-poc`，基線 HEAD `5b4b8668`
- 日期：2026-09-18
- 下一步：**一個需要你決定的事項**（見「待你決定」），其餘都已定案

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

## 待你決定（只有這一項）

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
