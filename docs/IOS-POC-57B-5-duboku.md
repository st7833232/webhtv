# IOS-POC-57B-5：独播库（qist `csp_Duboku`）

> Recovery anchor（2026-10-12 16:30 CST）：已實作，單元測試、全測試與 Simulator 實播通過（W-43，guard `QIST-DUBOKU-IMPL`，`--no-tag`）。設計：`.herdr-synapse/webhtv-dev/artifacts/qist-duboku-gate-2026-10-09.md` §5（W-25 PASS，snapshot `2ade0510`）；資料與播放閘門 W-19 PASS；使用者 2026-10-12 核准實作。下一步：Reviewer code review。

## 來源

- 設定：dianshi:69、jsm:70「独播 • 影视」`{"type":3,"api":"csp_Duboku"}`，無 ext。JAR：qist/tvbox `spider.jar` sha256 `72a1f3928eca281d878e44fc57162ff6a1f3ef779a2da05a2b351b241b110d69`；`Duboku.java` 257 行，sha256 `079e9d65a784e7a12e233c6a82d2b650fcc00c0bb55f5b9e5886b1d95876c5b3`（`/private/tmp/webhtv-qist-duboku/source/`）。

## 改動

| 檔案 | 內容 |
|---|---|
| `ios/Sources/WebHTVCore/Resources/Spiders/Duboku.js`（新） | 設計 §5.3／§5.4：`java.util.Random` 以 BigInt 重寫（`next`、`nextInt` 含拒絕迴圈）；`sign()` 只讀一次時鐘（`host.now()`），`ssid` 不帶尾端換行，`sign`／`token` 種子是 `2t+60`／`2t+38`（上游 `a()` 內再加一次秒數）；`d()` 每 10 字反轉後 base64；API 只送 UA 與 `Referer: https://www.duboku.tv/`。9 類＋篩選（由 3 組不同的篩選組回 `Duboku.java:180` 的常數，測試以 hash 鎖定）；首頁推薦合併 `/home` 各區；分類路徑照上游、各段 URL 編碼、`pg` 整數化下限 1、paging 照上游（48／頁、pagecount 44739243）；詳情只收 `/voddetail/`、`vod_actor` 以 `,` 連接、集只收 `/vodplay/` 路徑；搜尋只發一次（上游忽略頁碼）；播放只收 `/vodplay/`（相容舊 `path\|集\|名` id），回 `d(HId)` 與 3 個 header（UA、Origin、Referer `w.duboku.io`）；不移植彈幕代理 |
| `ios/Sources/WebHTVCore/Spider/SpiderRegistry.swift` | `ported` 加 `Duboku` |
| `ios/Tests/WebHTVCoreTests/SpiderGoldenTests.swift` | 預期清單加 `Duboku` |
| `ios/Tests/WebHTVCoreTests/DubokuSpiderTests.swift`（新） | 14 個測試；fixture 為 W-19 的 `home.json`／`detail.json`／`play.json`（raw deflate＋base64 內嵌，載入時驗閘門記錄的 sha256）與本次抓的搜尋回覆 |

相容包（`scripts/spider_pack.py`、`spider-pack/`）依設計 §5.6 不在本單，另由 pack 工單處理。

### 與設計的差異

- **`Random(42).nextInt()`、`Random(42).nextInt(62)`、`Random(0).nextInt(16)` 三個向量沒有直接斷言**：`JavaRandom` 是腳本內部函式，沒有為測試開額外入口。上游只用 `nextInt(62)` 與 `nextInt(800000000)`，兩者都由完整 `b(ms)` 的兩組 JDK 向量逐字鎖定（`sign` 60 次、`token` 38 次 `nextInt(62)`；`ssid` 解回 `nextInt(800000000)`＝257141124／147323377）。沒有實作 2 的冪分支與無參數 `nextInt()`（以 `shortcut:` 註記：上游用不到）。
- 集名裡的 `$`、`#` 換成空白（CatVod 用它們分集與分名稱／網址；比照 Bili，IOS-POC-57A-2）。
- 詳情的集全部解不開時，回詳情但不帶線路（上游同樣只在有集時加線路）；`Playlist` 不是陣列時回空。

## 驗證

| 項目 | 結果 | 證據 |
|---|---|---|
| RED | `HEAD` 的 `SpiderRegistry.swift` 沒有 `Duboku`（`git show HEAD:… \| grep -c Duboku` = 0）→ `csp_Duboku` 無法驅動 | — |
| 簽章黃金向量（JDK 17） | `b(1791500000123)` 與 `b(1791500288123)`（Golden2，第一個 `next(31)` 被拒絕 1 次）的 `sign`／`ssid`／`token` 逐字相等；`ssid` 解回 257141124／147323377，且不等於天真寫法的 `NTE4…Mw..`／483559477 | `DubokuSpiderTests` |
| 反證 | 拿掉拒絕迴圈（天真 `next(31) % bound`）→ Golden2 測試 4 條斷言失敗，天真值與 JDK 記錄的天真值相同；種子寫成 `t+60`／`t+38` 時兩個簽章測試的 `sign`／`token` 失敗 | `artifacts/w43-logs/w43-mutant.log` |
| 搜尋 fixture | 2026-10-12 16:05 CST 以 W-19 已被接受的 Swift 簽章抓一次：`wd=兰香如故` → 200、1 筆（`/voddetail/149953`）；含空白的關鍵字用 `%20` 或 `+` 都回 `[]`（相同），所以 `encodeURIComponent` 與上游 `URLEncoder` 的差異不影響 | `/private/tmp/webhtv-qist-duboku/inputs-search/`（`search.json` `5cb5d384…`、`probe-output.txt`） |
| 單元測試 | `DubokuSpiderTests` 14 個全過 | `w43-tests.log` |
| 全測試 | `swift test --package-path ios` 一次：1106 個全過 | `w43-full.log` |
| Ponytail review | Ship，沒有 finding | — |
| Simulator 實播（iPhone 18 Pro／iOS 27.0，checkout＝`3ee26487`＋本次修改） | `Duboku.js` 在 checkout／.app／容器三處 sha256 `3f900c98…`；選「獨播 • 影視」→ 9 類順序正確、篩選 6 列都出現 → 首頁推薦 81 部，海報（image.tmdb.org）全部顯示、0 張替代圖示 → 陸劇 48 部，套「年代 2024」清單隨之改變 → 《蘭香如故》47 集、線路「獨播庫」→ 第 1 集**原生播放器** 00:11→00:54／46:37（`vid.dbokutv.com/…/chunklist.m3u8`，起播 4823 ms，`stalls=0 final=good`）→ 搜尋「兰香如故」1 筆、可開詳情 → 觀看紀錄「看到 1:14」重開從 01:17 續播到 01:27（起播 699 ms）；伺服器接受 JS 簽章；Simulator 已逐檔還原（BYTE-IDENTICAL） | `/private/tmp/webhtv-gui-57b5-duboku/RESULT.md` `e5261382…`（71 檔 SHA256SUMS 全 OK；關鍵檔備份 `artifacts/w43-gui-evidence/`） |

## 未驗證

- 實機；MPV（原生已直接播成功）；簽章對裝置時鐘誤差的容忍度（設計 §5.4 已知風險）；其他分類、翻頁、年代以外的篩選。

## 觀察（未改程式）

- 首頁推薦捲到底時 App 會接著載入下一批（81→129→177），是 App 既有的翻頁行為。
- 上游電影類的年代篩選沒有 2021（劇集類有），照上游常數保留。

## 回滾

一個 commit；`git revert` 移除 adapter、Registry 行與測試，`csp_Duboku` 回到未支援，不影響其他來源。
