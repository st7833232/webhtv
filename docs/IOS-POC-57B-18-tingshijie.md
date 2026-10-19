# IOS-POC-57B-18：世界听书（qist `csp_TingShijie`，有聲書）

> Recovery anchor（2026-10-19 CST）：W-153，guard `W-153`，`--no-tag`。閘門 W-148 GO（有條件）：`.herdr-synapse/webhtv-dev/artifacts/qist-TingShijie-gate-2026-10-16.md` 與 `tingshijie-gate-fixtures/`。使用者核准 Wwys、TingShijie 實作，審過直接發官方包序號 5（Manager #2846）。程式、單元測試與 Simulator 真網址驗證都完成（第一次 Simulator 被停工打斷、證據隨暫存目錄刪除，2026-10-19 重做為 run2）。

## 來源

- JAR：qist/tvbox `spider.jar` 新版（dianshi／jsm 的 pin，md5 `bf32cf121ae92e49326a9fed7a82b76b`），sha256 `03bef7dd5f86e4005f00b10e7cfeb0427fe3f8b99893cca7e44b9a6e400cd6b1`（`artifacts/qist-next-batch-2026-10-16/jar-new/spider.jar`）。
- 閘門用的反編譯輸出 `/private/tmp/webhtv-qist-batch-work/…` 已不在，2026-10-19 從同一份 jar 用 `jadx --single-class com.github.catvod.spider.TingShijie` 重新反編譯：`TingShijie.java` 219 行，和閘門記的行號一致（`b()` :21–23、`init` :131–145、`playerContent` :147–185、`searchContent` :187–218）。檔案 sha256 是 `7e3c143c…4977`（閘門記的是 `bfb862fa…`；差在 jadx 輸出的檔頭與路徑註解，閘門也記載新舊兩版邏輯相同）。
- 站：`dianshi.json`:106、`jsm`:107，`{"key":"世界听书","api":"csp_TingShijie","searchable":1}`，沒有 `ext`。

## 改動

| 檔案 | 內容 |
|---|---|
| `ios/Spiders/TingShijie.js`（新） | 照上游移植，加上閘門的三個必要條件：① 播放結果帶 `User-Agent: okhttp/4.12.0`（CDN 對其他 UA 一律 403，閘門 #8–#16）；② 不等設定檔主機（見下）；③ 搜尋關鍵字 `encodeURIComponent`。API 一律帶上游的 `TingShiJie/1.8.8 (m.i275.com)`，`status !== 0` 一律當沒有資料。 |
| `ios/Sources/WebHTVCore/Spider/SpiderRegistry.swift` | `ported` 加 `TingShijie`，`aliases` 沒動 |
| `ios/Tests/WebHTVCoreTests/SpiderGoldenTests.swift` | 預期清單在 `TingJinxia` 與 `TuXiaoBei` 之間加 `TingShijie` |
| `ios/Tests/WebHTVCoreTests/TingShijieSpiderTests.swift`（新） | 8 個測試，假站 `ShijieSite`（URLProtocol）照閘門回應的形狀回 JSON（`Content-Type: text/html`、`count` 是字串、每頁 1000 章、`status 1 分集地址解析失败`）。簽章用 CryptoKit 的 MD5 從請求的 `timeStamp` 重算比對。 |
| `scripts/spider_pack.py` | `DEFAULT_ORIGINS` 加 `TingShijie` 的來源 jar 與 sha256（官方包與相容包的 provenance）。沒有重建 `spider-pack/` 相容包（不在本單範圍）。 |

### 和上游不同的地方

- **不問設定檔主機**：上游 `init` 先 GET `http://101.43.48.231:8090/config/tingchina2025.txt` 拿 API 根，失敗才用 `https://app.365ting.com/listen/Apitzg2025/`。閘門兩次都 TCP 逾時 20 秒。原本打算給 3 秒逾時、只接受 `http(s)://…/` 形式的回應，但測試發現 runtime 會把 `init` 裡失敗的請求記成這個 session 的 `initFailure`（`JavaScriptSpiderRuntime.swift`:65–70），之後**每一個空結果**（沒有結果的搜尋、空分類）都會被報成「無法連線 101.43.48.231」。所以直接用退路根，`init` 不發請求；工單「設定檔主機逾時時用退路根」的結果相同，且不多等 3 秒。代價：站方若只在設定檔公告新根，本 spider 不會跟著換（設定檔主機目前本來就連不上）。
- **集名用 `title`**：上游用 `position`，加更集出現後會和「第N集」對不上（閘門：position 1000 是「第992集」）；`title` 去掉 `$`、`#`，空的才退回 position。
- **分類頁數**：上游固定 `pagecount 100`；改成本頁滿 120 筆才給下一頁，避免一直翻到空頁。
- **詳情頁數上限 20**（2 萬集），防伺服器回荒謬的 `count`；`count` 0 不發章節請求。
- **搜尋只有一頁**：第 2 頁起直接回空（上游 `searchContent` 也不看頁碼，一次全回）。
- **id 檢查**：分類 id、書 id 只接受數字；播放 id 必須是 `<數字>|<數字>`，否則不發請求。`src` 必須是不含 `$`、`#`、空白的 `http(s)://` 網址。
- **取不到網址的章節**：站方對部分章節固定回 `status 1 分集地址解析失败请重试点击播放`（閘門 #7、#17–#22，原因不明，上游同樣回空網址）。本 port 回空網址，App 既有流程顯示「這一集沒有可播放的網址。」（`WebHTVApp.swift`:3165），不會開播放器空等；站方的原文沒有帶到畫面上（要帶得改 App，本單不改 App）。

## 驗證

| 項目 | 結果 | 證據（`artifacts/w153-logs/`） |
|---|---|---|
| 先紅 | Registry 已列、腳本還沒寫：8 個 TingShijie 測試＋`registryClaimsOnlyWhatIsActuallyPorted` 全紅 | `red.log` |
| 後綠 | `TingShijie|registryClaims|SpiderGolden` 14 個全過 | `green.log` |
| Mutant | 11/11 被抓到：播放不帶 okhttp UA、只 md5 一次、`status 1` 不擋、`count` 只當數字、只讀第 1 頁章節、集名改回 position、關鍵字不編碼、不檢查 `src`、畸形 id 也送出、每頁都說有下一頁、API 不帶上游 UA | `mutants.log` |
| 全測試 | `swift test` 1326 tests／50 suites：11 個失敗，都是 WebKit 嗅探、5 秒計時或下載佇列「等狀態」的測試（`MediaSnifferTests`、`GlobalParseTests`、`SourceClientTests.theProbeReadsOnlyTheHeadOfABodyThatNeverEnds`、`FavoriteOwnershipTests` 兩個、`OfflineTitleGroupTests` 一個），當時 load average 約 398；單獨重跑 11 個全過。本單只動 JS spider 與名單，沒有碰這些程式 | `full.log`、`rerun-load.log` |
| 官方包序號 5 試建 | `runtime_pack.py build --sequence 5 --version 2026-10-19.1`：36 支（多 TingShijie，sha256 `de282749…2703`），`verify` 0 problem；`test_pack_exclusions.py` PASS（相容包 34 支不含 Djuu／Ikanbot，官方包 36 支含）；`test_spider_compat.py` ok。試建輸出已刪，正式發包由 workflow 做 | `pack5-build.txt`、`pack5-verify.txt`、`pack-exclusions.txt`、`spider-compat.txt` |
| Ponytail review（最終 diff） | Ship，沒有 finding。查過：所有外來值（數字 id、`book|chapter` 播放 id、`src` 必須是不含 `$`／`#` 的 http(s)、章節頁上限 20、`count` 0 不發請求）、取不到網址的章節走 App 既有訊息、每一行有風險的邏輯都有 mutant 抓得到 | — |
| Simulator 真網址（2026-10-19 13:4x，暫存機 iPhone 18 Pro／iOS 27.0，本機 HTTPS 提供序號 5 試建包與只有本站的設定；手機熱點、省流量） | 6/6 PASS：a 裝上序號 5（`applied … seq 5`）；b 11 個分類、都市言情載入 120 部；c 鳴龍第 1 集 `started … on 原生 in 2019ms`、`stalls=0`、純音訊進度 00:25／06:43——**音訊真的下載（約 594 KB），CDN 沒有 403，播放 header 的 `okhttp/4.12.0` 在原生播放器生效**；d「逃荒」第 1 集與 e 鳴龍第 501 集都顯示「這一集沒有可播放的網址。」、不開播放器；d 用 curl 直接問 API，該書第 1 集與簡介章都回 `status 1 分集地址解析失败`，是站方限制（同閘門）；f 搜尋「万古」114 筆（同閘門）。受測腳本 `git hash-object` 前後相同；流量約 3 MB（第 1 集因第一次關閉沒點到多播約 86 秒） | `artifacts/w153-gui-evidence/run2/RESULT.md` |

## 未驗證／風險

- 原生播放器已證實帶 okhttp UA 過得了 CDN（Simulator run2）；**MPV 回退路徑是否也帶這個 header 未驗**（這輪一直在原生上播）。
- 後段章節取不到網址（站方限制，上游一樣），可播比例未知。
- `auth_key` 時效只知道 ≥64 秒；長時間暫停後 seek 可能 403。
- 實機。

## 回滾

一個 commit；`git revert` 移除 spider、Registry 一行、測試與 provenance 一列。官方包要等下一個序號才會拿掉。
