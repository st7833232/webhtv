# IOS-POC-57B-9：博看听书（qist `csp_TingBokan`）

> Recovery anchor（2026-10-12 16:50 CST）：已實作，單元測試、全測試與 Simulator 純音訊實播通過（W-76，guard `QIST-TINGBOKAN-IMPL`，`--no-tag`）。設計：`.herdr-synapse/webhtv-dev/artifacts/qist-tingbokan-gate-2026-10-12.md` D1–D6（W-63 PASS）；資料閘門 W-54 PASS；使用者 2026-10-12 核准實作（W-71）。相容包另由 W-78（Duboku）之後的 pack 步驟處理（Manager #1353／#1355）。下一步：Reviewer code review。

## 來源

- 設定：dianshi:108「博看 • 听书」`csp_TingBokan`（`style.type list`）。JAR：qist/tvbox `spider.jar` sha256 `72a1f3928eca281d878e44fc57162ff6a1f3ef779a2da05a2b351b241b110d69`；`TingBokan.java` 129 行，sha256 `4f69ce63deaa97c3679b99affc1fd26651fa30ce8b5f6828c373ee49b955ef6d`。

## 改動

| 檔案 | 內容 |
|---|---|
| `ios/Sources/WebHTVCore/Resources/Spiders/TingBokan.js`（新） | 設計 D2／D3：請求、欄位、播放照上游，UA 用上游桌機 Chrome 151；只讀 HTTP 200、`code === 0` 的 `data`；首頁上游 18 類的前 11 類、不連網；分類 `tid` 必須是數字（否則不發請求）、`pg` 整數化下限 1、`pagecount = last_page`（不是正整數用目前頁）、`limit 24`；單筆 `id` 不是正整數或 `name` 不是字串就略過，`extra` 不是物件時備註空；詳情只切**第一個** `@`（`7@a@b` → 書名 `a@b`、`album_id=7`），單元從第 1 頁讀到 `last_page`，**上限 50 頁**，任一頁失敗就停（保留已取得的），集網址必須是不含 `$`／`#` 的 http(s)，集名的 `$`／`#` 換空白、空的用序號；播放回原網址＋UA，不合格回空；搜尋用 `encodeURIComponent(key.trim())`，作者空時用 `press` |
| `ios/Sources/WebHTVCore/Spider/SpiderRegistry.swift` | `ported` 加 `TingBokan` |
| `ios/Tests/WebHTVCoreTests/SpiderGoldenTests.swift` | 預期清單加 `TingBokan` |
| `ios/Tests/WebHTVCoreTests/TingBokanSpiderTests.swift`（新） | D5 八組＋首頁共 9 個測試；fixture 為 W-54 的 `category-1303-p1.json`（24 筆，`095a5ca8…`）與 `units-4033132-p1.json`（60 集，`8f6a4fc1…`），raw deflate＋base64 內嵌，載入時驗 sha256 |

## 驗證

| 項目 | 結果 | 證據 |
|---|---|---|
| 單元測試 | `TingBokanSpiderTests` 9 個＋`registryClaimsOnlyWhatIsActuallyPorted` 全過 | `artifacts/w76-logs/w76-tests.log` |
| 全測試 | `swift test --package-path ios` 一次：1115 個全過 | `w76-full.log` |
| Ponytail review | Ship，沒有 finding；未驗：搜尋主機回的 `id` 是否為數字（字串會被略過）→ Simulator 搜尋找得到結果，已排除 | — |
| Simulator 純音訊實播（iPhone 18 Pro／iOS 27.0，checkout＝`edd23bc8`＋本次修改） | `TingBokan.js` 在 checkout／.app／容器三處 sha256 `9f634581…`；選「博看 • 聽書」→ 11 類順序正確，App 自動載入「故事會」24 部 → 往下捲續載 24→120 → 「葵花向太陽」60 集、備註「更新于 2022-12-01 05:30:03」→ 第 1 集**原生播放器**：黑底＋音波圖示、沒有誤報，00:39→01:15／02:06（`http://audio.bookan.com.cn/…/aache64_cf3c3a52.m4a`，起播 3910 ms，`stalls=0 final=good`）→ **背景播放**：Home 約 16 秒後回前景 00:50→01:09，log 有 Suspension 但音訊持續解碼（`audio` 背景模式有效）→ 搜尋「葵花」1 筆（`es.bookan.com.cn` 首次實連）、可開詳情 → 觀看紀錄「看到 1:42」重開續播 01:47→01:55；Simulator 已逐檔還原（BYTE-IDENTICAL） | `/private/tmp/webhtv-gui-57b9-tingbokan/RESULT.md` `de2f47e8…`（76 檔 SHA256SUMS 全 OK；關鍵檔備份 `artifacts/w76-gui-evidence/`） |

## 未驗證

- 實機；MPV；鎖屏、控制中心、來電中斷與長時間背景；其他 10 個分類；多頁單元（`last_page > 1`）的真實書。
- 相容包：依 Manager #1353／#1355，W-78 先加 Duboku，之後 W-76 的 pack 步驟另一個 guard 只加 TingBokan。

## 觀察（未改程式）

- **第 1 集播到檔尾卡住**：續播那次停在 02:06／02:06 轉圈，沒有接第 2 集（第 2 集已預取），結算 `stalls=1 final=poor`；m4a 本身正常（`afinfo` 125.94 秒、支援 Range）。只發生一次，疑為 App 播放器對檔尾的處理，不在 adapter 範圍，已回報 Manager。
- 故事會第 5 頁有 6 張封面 15 秒後回 403（35582 bytes，疑網路中間攔截），同網址在 Mac 上 200。
- 詳情備註依入口不同：從分類開是「更新于…」，從搜尋開是作者（App 沿用清單項目的備註）。
- 來源清單另有 drpy 版「聽書 • 博看聽書」，載入失敗（`cheerio.min.js` 404），與本 adapter 無關。

## 回滾

一個 commit；`git revert` 移除 adapter、Registry 行與測試，不影響其他來源。
