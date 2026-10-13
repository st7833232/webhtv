# IOS-POC-57B-6：戏曲多多（qist `csp_AppLY`）

> Recovery anchor（2026-10-12 17:45 CST）：已實作，單元測試通過（W-73，guard `QIST-APPLY-IMPL`，`--no-tag`）。設計：`.herdr-synapse/webhtv-dev/artifacts/qist-aply-gate-2026-10-12.md` D1–D6（W-60 PASS，含 W60-01）；資料閘門 W-50 PASS；使用者 2026-10-12 核准實作（W-71）。Simulator 實播已對 `f4978111` 補做（與 W-83 同一輪）；後續 commit 修 A89-01 並收緊測試（Manager #1516）。下一步：Reviewer code review。

## 來源

- JAR：qist/tvbox `spider.jar` sha256 `72a1f3928eca281d878e44fc57162ff6a1f3ef779a2da05a2b351b241b110d69`；`AppLY.java` 121 行，sha256 `8d8954cc20cb33ab311303e1a3e3b89eb2c5e8a9c6cb09b83ce712a59278fc5c`。

## 改動

| 檔案 | 內容 |
|---|---|
| `ios/Sources/WebHTVCore/Resources/Spiders/AppLY.js`（新） | 設計 D2／D3：4 個請求都是 `POST https://fly.daoran.tv/API_ROP/<path>`，body 先 `JSON.stringify`（鍵順序照 gate `probe.py`），標頭照上游 3 個（`Content-Type: application/json;charset=utf-8`、`User-Agent: okhttp/3.9.1`、固定 `md5`）；只讀 HTTP 200 的 JSON 物件。首頁分類來自伺服器 `sects[]`（不輸出 list）；分類 `tid` 須符合 `^[A-Za-z0-9_]+$`、`pg` 整數化下限 1、`pagecount = pb.totalPage`（不是正整數時 `list.length ? page + 1 : page`）；圖片只在 `img` 是字串時組；詳情與播放的 id 須符合 `^[A-Za-z0-9]+$`（W60-01），否則不發請求；集名 `$`／`#` 換空白、空名用 `第<序號>集`；`vod_director` 照上游讀 `album.vod_director`（缺少時是空字串）；播放每次重取 `playres.playurl`，必須是 `^https?://`，parse 0、不帶 header；搜尋回空 |
| `ios/Sources/WebHTVCore/Spider/SpiderRegistry.swift` | `ported` 加 `AppLY` |
| `ios/Tests/WebHTVCoreTests/SpiderGoldenTests.swift` | 預期清單在 `AppGet` 與 `AppQi` 之間加 `AppLY` |
| `ios/Tests/WebHTVCoreTests/AppLYSpiderTests.swift`（新） | D5 八組測試；fixture 為 W-50 的 `home.json`（77 類）、`category.json`、`detail1.json`（5 集）、`playurl1.json`，raw deflate＋base64 內嵌、驗 sha256；4 個 body 全字串比對，3 個標頭全值比對（host 缺值時會自己補 UA 與表單型別） |
| `scripts/spider_pack.py`、`spider-pack/` | `DEFAULT_ORIGINS` 加 `AppLY`（`spider.jar` `72a1f392…`，只用 base host API：`host.post`、`host.result`）；相容包重建為 `2026-10-12.12`（29 支）：只新增 AppLY、舊 entry 全部不變，pack 與內建同 blob `484a4b95…`；`verify` 0 problems |

### 與設計的差異

- 分類列表裡 `code` 不符合 `^[A-Za-z0-9]+$` 的項目也略過（設計 C7 只寫缺 `code` 略過）：這種項目點進去會被詳情的 id 檢查擋下，列出來只會是打不開的項目。
- 首頁照設計不輸出 list（上游會輸出空的 `list: []`，兩者 App 行為相同）。

## 驗證

| 項目 | 結果 | 證據 |
|---|---|---|
| 單元測試 | `AppLYSpiderTests` 8 個＋`registryClaimsOnlyWhatIsActuallyPorted` 全過 | `artifacts/w73-logs/w73-tests.log` |
| 全測試 | `swift test --package-path ios` 一次：1132 個全過 | `w73-full.log` |
| 相容包 | build／verify 0 problems；只新增 AppLY | `w73-pack.log` |
| Ponytail review | Ship，沒有 finding | — |
| Simulator 實播（iPhone 18 Pro／iOS 27.0，checkout＝`30048684`＋W-83 修正，`AppLY.js` `d45a5e43…` 三處相同） | 「戲曲 • 多多」→ 77 類、第一個棗梆 → 棗梆 2 部 → 詳情 5 集 → 第 1 集：原生 10 秒內未起播（neverReady），App 自動改 MPV 起播並播完接第 2 集；再播一次原生 7.2 秒起播。播放網址 `http://flytx.daoran.tv/sv/…m3u8?auth_key=…`，adapter 不帶 header 也能播 → 從紀錄重開：重新取網址（新 auth_key）、原生 00:21→00:56；還原 BYTE-IDENTICAL | `/private/tmp/webhtv-gui-w83-fix/RESULT.md` `f099c8cc…`（B 段；關鍵檔備份 `artifacts/w73-gui-evidence/`） |
| 後續 commit（A89-01＋測試收緊） | 首頁 `sects[]` 的 `code`／`name` 若是數字，照上游 `optString` 轉成字串保留（空 code 仍略過）；新測試在舊版失敗、新版通過；另補 C5 第 2 筆全欄位、P3 播放網址全等、9b（集全被略過仍回詳情、線路空）、9d（limit 20／total 999999）、9e（tid 含底線）與首頁 `{}` 為 0 類的斷言；相容包 `2026-10-13.1` 只改 AppLY，pack 與內建同 blob `edaf64fc…` | `artifacts/w73-logs/w73f-*.log` |

## 未驗證

- 實機；其他戲種是否都免費可播（gate 只試了第 1 個戲種）；`md5` 標頭若被站方更換即全部失效（設計 D6）。

## 回滾

一個 commit；`git revert` 移除 adapter、Registry 行、測試與相容包列，不影響其他來源。
