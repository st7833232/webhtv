# IOS-POC-57B-12：堇夏听书（qist `csp_TingJinxia`，有聲書）

> Recovery anchor（2026-10-13 17:00 CST）：已實作，單元測試與全測試通過（W-103，guard `QIST-TINGJINXIA-IMPL`，`--no-tag`）。閘門 W-95 GO：`.herdr-synapse/webhtv-dev/artifacts/qist-TingJinxia-gate-2026-10-13.md` 與 `tingjinxia-gate-fixtures/`；審查預備 `review-prep-W-103-2026-10-13.md`（W-106）。使用者 2026-10-13「先把爬蟲工具補齊」視同核准。Simulator 實播 PASS（原生起播、自動接第 2 集、3977 集詳情）。下一步：Reviewer code review。

## 來源

- JAR：qist/tvbox `spider.jar`，sha256 `72a1f3928eca281d878e44fc57162ff6a1f3ef779a2da05a2b351b241b110d69`。這份 jar 裡的 `classes.dex` 就是閘門反編譯用的 `21026b36c4c35618e3ac2d19e37f45383969fc4c17aae49bfa40f0a9a78b1562`（2026-10-13 解壓 `/private/tmp/webhtv-qist-next-candidate.work/j-spider.jar` 核對過），所以相容包的 `jarSha256` 沿用前幾支 spider.jar 的值。
- `TingJinxia.java` 339 行，sha256 `8ac738cf705050ccb5b4451a7fa4da34f6ffa4b21cfc9a9430ace50b01f72cd8`。
- 文件編號：57B-1～11 都已被使用（7 是 shortxingya，8 是 sportsfeiqiu，11 是 sportskafei），所以用 57B-12。review-prep 寫的是「未確認，由 Manager 決定」，送審時請 Manager 確認。

## 改動

| 檔案 | 內容 |
|---|---|
| `ios/Sources/WebHTVCore/Resources/Spiders/TingJinxia.js`（新） | 閘門的 5 項適配都做了：① 首頁沒有 `.clist`，改用 `section a[href]:has(h3)`，再用 `/\.html$/` 過濾（host.js 沒有 `$=`）；② 分類第 2 頁起用 `/<tid>/index<pg>.html`（上游少了 `.html`，會 404）；③ neoplay 回應只剝開頭那一個 BOM 再 `JSON.parse`；④ 音訊網址只在沒有 `%XX` 時才 `encodeURI`，不會雙重編碼；⑤ 播放結果帶 `User-Agent`（Chrome 151）和 `Referer: https://m.ting15.com/`，neoplay POST 的 Referer 是章節頁網址。頁數照位元碼（`.cpage span` 含 `/` 才取，jadx 印成相反）；`limit`、`total` 是本頁筆數（照上游）。清單依 `vod_id` 去重，首頁 27 個連結會變成 22 本。tid 只收 `[a-z]+`，order 只收 `hits`／`addtime`，其他值忽略。詳情和章節頁的 id 必須是 `^/[A-Za-z0-9_/-]+\.html$`，不符合就不送請求。播放的退路順序：neoplay 的 `url` → `ourl` → `audio#player@src` → 空網址；**不回傳章節頁網址**，避免對聽書站啟動網頁嗅探。首頁清單放在 `homeVideoContent`，`homeContent` 只回 9 類和 `order` 篩選（全部／热门／最新） |
| `ios/Sources/WebHTVCore/Spider/SpiderRegistry.swift` | `ported` 加 `TingJinxia`，`aliases` 沒動 |
| `ios/Tests/WebHTVCoreTests/SpiderGoldenTests.swift` | 預期清單在 `TingBokan` 與 `TuXiaoBei` 之間加 `TingJinxia` |
| `ios/Tests/WebHTVCoreTests/TingJinxiaSpiderTests.swift`（新） | 10 個測試。fixture 用閘門的 10 份原始回應（首頁、武侠玄幻第 1／2 頁、热门排序、搜尋「三国」、3977 集詳情、第 1 集和最後一集的章節頁、兩份帶 BOM 的 neoplay 回應），以 raw deflate＋base64 內嵌，載入時驗 sha256（每個值都和閘門的 `SHA256SUMS.txt` 核對過）。假站從 `httpBodyStream` 讀 POST 表單，路由用 `percentEncodedPath`，因為 `URL.path` 會去掉結尾的 `/` |
| `scripts/spider_pack.py`、`spider-pack/` | `DEFAULT_ORIGINS` 加 `TingJinxia`，只用 base host API（get／post／parse／select／text／result），不帶 `minHostApi`。相容包重建為 `2026-10-13.5`（32 支），只多了 TingJinxia 一列，舊 entry 全部不變；pack 與內建腳本 byte 相同（sha256 `63f7d24b…b8be`）；`verify` 0 problems |

### 和上游不同的地方

- 清單和集數的 href 必須是以 `/` 開頭的 `.html` 路徑。上游也接受相對路徑，但 fixture 裡沒有這種情況，而且這樣才能保證交給 App 的 id 一定能被詳情接受。
- 首頁依 `vod_id` 去重（review-prep §2.7 的建議）：重複的 id 會讓 SwiftUI `ForEach` 的行為不保證。
- 什麼都拿不到時回空網址，不回章節頁網址（閘門 :78 的建議）。
- `status` 用 `Number(...) === 1`，所以字串 `"1"` 也接受，和上游 `optInt` 一致。

## 驗證

| 項目 | 結果 | 證據 |
|---|---|---|
| node 預跑（草稿階段） | 用 repo 的 host.js 在 node `vm` 裡跑 fixture，結果全部符合 review-prep 的預期值 | `artifacts/w103-logs/node-harness.js` |
| 先紅 | 腳本已放進 Resources，但 Registry 還沒列：9 個測試全紅，能編譯 | `w103-logs/red.log` |
| 後綠 | 10/10 通過（含 Registry 測試）。3977 集詳情在 JavaScriptCore 上 23ms，測試另外設了 2 秒的寬鬆上限，只用來防止嚴重退化 | `green.log` |
| Mutant（review-prep §4） | 10 個都被抓到：播放不帶 Referer、POST 的 Referer 改成根網址、不剝 BOM、選擇器改回 `$=`、第 2 頁不補 `.html`、頁數照 jadx 字面寫、一律 `encodeURI`（雙重編碼）、不編碼、不去重、詳情接受畸形 id。selector 這個 mutant 第一次讓測試在 `items[0]` 越界 crash，改成先 `try #require` 筆數再取索引，重跑後是正常失敗。全部還原後 sha256 與原檔一致 | `mut-*.log` |
| 全測試 | `swift test` 1167 tests／38 suites 全部通過 | `full-summary.txt` |
| 相容包 | build `2026-10-13.5`，verify 0 problems；manifest 的差異只有版本號和新增的一列 | `manifest.before.json` 對照 |
| Ponytail review | Ship，沒有 finding | — |
| Simulator 實播（iPhone 18 Pro／iOS 27.0；HEAD `8bee0b02`＋本單工作樹；`TingJinxia.js` `63f7d24b…` 在 checkout、.app、容器三處相同；容器裡沒有相容包，用的是內建腳本） | 首頁 22 本（海報請求 59 次都回 200）→ 武侠玄幻 8 本，翻頁到 56 本 →《无敌剑域》「堇夏 · 3977 集」、40 個區塊 chip，最後一塊看得到 3972～3977，能切回第一塊；313 KB 詳情頁下載約 3.5 秒，解析加上畫面出現最多約 2.5 秒；記憶體 121 → 136 → 148 MB（峰值 154 MB），沒有明顯卡頓 → **第 1 集原生起播** 1698ms，00:01→00:16，沒有任何切換到 MPV 的 log → **自動接第 2 集**：`prefetched 2` → `finished (end) at 951s/951s` → 第 2 集原生 1220ms，沒有重複接集 → 從觀看紀錄續播：重新打章節頁和 POST，原生 1378ms，從約 1:4x 接著播。還原：App 與整個 data 容器 BYTE-IDENTICAL。Referer 是間接證明：同一個音訊主機不帶 Referer 一律回 400，而原生播放器確實在播 | `artifacts/w103-gui-evidence/RESULT.md` `5c9ac514…ee87` |

## 未驗證／風險

- resolve 偏慢（第 1 集 7.7 秒、續播 5.3 秒，主要是章節頁、POST 和 `.m4a` 探測），App 既有流程，不在本單。
- 其他 8 個分類、搜尋（GUI 沒測）、`addtime` 排序、搜尋多頁、付費章節、`[..]` 前綴的書名、`_c`（`xt`）有沒有時效、海報不帶 Referer 會不會被擋（閘門 §未驗證）。
- 實機。

## 回滾

一個 commit；`git revert` 會移除 adapter、Registry 那一行、測試與相容包那一列，不影響其他來源。
